import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'echo_filter.dart';
import 'speakers.dart';
import 'transcriber.dart';

/// Расшифровка на лету: звук обоих каналов идёт в фоновый изолят, Silero VAD
/// в нём режет поток на фразы, и каждая законченная фраза сразу уходит в GigaAM.
/// Реплика появляется примерно через 0,5–1 с после того, как её договорили.
///
/// Пока фраза ещё звучит, сказанное с её начала перераспознаётся примерно раз
/// в секунду — это черновик ([partials]), его сменяет окончательная реплика.
/// Реплики собеседников подписываются по голосу: «Собеседник 1», «Собеседник 2»…
///
/// GigaAM не потоковая модель, но фраза распознаётся за доли секунды, поэтому
/// качество то же, что у расшифровки готового файла.
class LiveTranscriber {
  LiveTranscriber._(this._isolate, this._fromIsolate);

  final Isolate _isolate;
  final ReceivePort _fromIsolate;
  SendPort? _toIsolate;
  final _pending = <Object>[];
  final _utterances = StreamController<Utterance>.broadcast();
  final _partials = StreamController<PartialUtterance>.broadcast();
  final _all = <Utterance>[];
  final _ready = Completer<void>();
  Completer<void>? _done;

  /// Слияние голосов после встречи (см. SpeakerClusters.consolidated) — приходит перед 'done'.
  List<int> _merged = const [];

  /// Реплики по мере распознавания (не по порядку времени: каналы идут независимо).
  Stream<Utterance> get utterances => _utterances.stream;

  /// Черновики звучащих фраз; пустой текст — черновик канала снят.
  Stream<PartialUtterance> get partials => _partials.stream;

  /// Запускает изолят; модель грузится в нём, а звук до готовности копится здесь.
  static Future<LiveTranscriber> start(String modelsDir) async {
    final fromIsolate = ReceivePort();
    final isolate = await Isolate.spawn(_isolateMain, (fromIsolate.sendPort, modelsDir));
    final live = LiveTranscriber._(isolate, fromIsolate);
    fromIsolate.listen(live._onMessage);
    return live;
  }

  /// Ждёт, пока модель загрузится; ошибка загрузки (например, нет модели) — здесь.
  Future<void> get ready => _ready.future;

  /// channel — "mic" или "system" (как в meet_capture).
  void feed(String channel, Float32List samples) {
    final message = (channel, TransferableTypedData.fromList([samples]));
    final port = _toIsolate;
    port == null ? _pending.add(message) : port.send(message);
  }

  /// Пауза записи: фраза, звучавшая в этот момент, дописывается сразу — иначе слова
  /// до и после паузы склеились бы в одну реплику. Черновики снимаются.
  void pause() {
    final port = _toIsolate;
    port == null ? _pending.add('pause') : port.send('pause');
  }

  /// Дорасшифровывает остаток после остановки записи и закрывает изолят.
  /// Возвращает все реплики по порядку времени, без эха собеседников в микрофоне.
  Future<List<Utterance>> finish() async {
    await ready;
    final done = _done = Completer<void>();
    _toIsolate!.send('finish');
    await done.future;
    _fromIsolate.close();
    _isolate.kill();
    await _utterances.close();
    await _partials.close();
    final sorted = [..._all]..sort((a, b) => a.start.compareTo(b.start));
    return dropEchoes(relabelSpeakers(sorted, _merged));
  }

  /// Бросает изолят без дорасшифровки (например, запись не удалась).
  void cancel() {
    _fromIsolate.close();
    _isolate.kill(priority: Isolate.immediate);
    _utterances.close();
    _partials.close();
  }

  void _onMessage(Object? message) {
    switch (message) {
      case SendPort port:
        _toIsolate = port;
        _pending.forEach(port.send);
        _pending.clear();
        _ready.complete();
      case Utterance utterance:
        _all.add(utterance);
        _utterances.add(utterance);
      case PartialUtterance partial:
        _partials.add(partial);
      case _SpeakerMap(:final merged):
        _merged = merged;
      case 'done':
        _done?.complete();
      case _LiveError(:final message):
        final error = StateError(message);
        if (!_ready.isCompleted) _ready.completeError(error);
        _done?.completeError(error);
    }
  }
}

/// Черновик фразы, которая ещё звучит. Пустой [text] — черновик канала снят
/// (фраза закончилась и пришла окончательной репликой или оказалась пустой).
class PartialUtterance {
  /// "mic" или "system".
  final String channel;
  final double start;
  final String text;

  const PartialUtterance(this.channel, this.start, this.text);

  String get speaker => channel == 'mic' ? meLabel : othersLabel;
}

class _SpeakerMap {
  final List<int> merged;
  const _SpeakerMap(this.merged);
}

class _LiveError {
  final String message;
  const _LiveError(this.message);
}

const _channels = ['mic', 'system'];

/// Сколько звука до срабатывания VAD держим в буфере: детектор замечает речь с опозданием
/// (минимальная длина речи 0,25 с), а перед фразой ещё нужен запас vadPreroll.
const _lookback = sampleRate;

/// Черновик — не длиннее последних 20 с фразы (столько же максимум у фразы в VAD).
const _maxPartial = 20 * sampleRate;

/// Звук канала с отметкой, с какого отсчёта записи он начинается.
class _ChannelAudio {
  Float32List _data = Float32List(sampleRate * 4);
  int _length = 0;

  /// Номер первого отсчёта буфера от начала записи.
  int start = 0;

  /// Начало звучащей фразы (номер отсчёта); null — сейчас тишина.
  int? speechStart;

  /// Когда пора делать следующий черновик и как часто: не чаще раза в секунду
  /// и не чаще, чем вдвое дольше последнего распознавания.
  DateTime nextPartial = DateTime.fromMillisecondsSinceEpoch(0);
  bool hasPartial = false;

  int get end => start + _length;

  void append(Float32List samples) {
    if (_length + samples.length > _data.length) {
      final grown = Float32List((_length + samples.length) * 2);
      grown.setRange(0, _length, _data);
      _data = grown;
    }
    _data.setRange(_length, _length + samples.length, samples);
    _length += samples.length;
  }

  /// Оставляет только звук начиная с отсчёта [from].
  void keepFrom(int from) {
    final drop = (from - start).clamp(0, _length);
    if (drop == 0) return;
    _data.setRange(0, _length - drop, _data, drop);
    _length -= drop;
    start += drop;
  }

  Float32List slice(int from) => Float32List.fromList(Float32List.sublistView(_data, (from - start).clamp(0, _length), _length));

  /// Звук [from, to) по номерам отсчётов записи; null, если его уже нет в буфере.
  Float32List? range(int from, int to) {
    if (from < start || to > end || from >= to) return null;
    return Float32List.fromList(Float32List.sublistView(_data, from - start, to - start));
  }
}

void _isolateMain((SendPort, String) args) {
  final (out, modelsDir) = args;
  final so.OfflineRecognizer recognizer;
  final Map<String, so.VoiceActivityDetector> vads;
  try {
    recognizer = createRecognizer(modelsDir);
    vads = {for (final channel in _channels) channel: createVad(modelsDir)};
  } catch (e) {
    out.send(_LiveError('$e'));
    return;
  }
  // Без модели отпечатков голоса все собеседники идут одной меткой.
  final extractor = createSpeakerExtractor(modelsDir);
  final clusters = SpeakerClusters(sameSpeakerThreshold: speakerThreshold);

  // VAD получает звук окнами по 512 отсчётов; неполное окно ждёт следующей порции.
  final remainders = {for (final channel in _channels) channel: Float32List(0)};
  final audio = {for (final channel in _channels) channel: _ChannelAudio()};

  void clearPartial(String channel) {
    final a = audio[channel]!;
    a.speechStart = null;
    if (a.hasPartial) {
      a.hasPartial = false;
      out.send(PartialUtterance(channel, 0, ''));
    }
  }

  /// Законченные фразы → окончательные реплики; черновик канала снимается.
  void drain(String channel) {
    final vad = vads[channel]!;
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      clearPartial(channel);
      // Фраза с запасом перед ней (см. vadPreroll) — из буфера канала, если он его ещё держит.
      final end = segment.start + segment.samples.length;
      final phrase =
          audio[channel]!.range((segment.start - vadPreroll).clamp(0, end), end) ?? segment.samples;
      final text = recognize(recognizer, phrase);
      if (text.isEmpty) continue;
      final start = segment.start / sampleRate;
      final speaker = channel == 'mic' ? meLabel : labelForOthers(extractor, clusters, phrase);
      out.send(Utterance(start, start + segment.samples.length / sampleRate, speaker, text));
    }
  }

  /// Пока фраза звучит — черновик сказанного с её начала.
  void partial(String channel) {
    final a = audio[channel]!;
    final vad = vads[channel]!;
    if (!vad.isDetected()) {
      // Тишина: держим только запас на начало следующей фразы.
      if (a.speechStart == null) a.keepFrom(a.end - _lookback);
      return;
    }
    a.speechStart ??= (a.end - _lookback).clamp(a.start, a.end);
    final now = DateTime.now();
    if (now.isBefore(a.nextPartial) || a.end - a.speechStart! < sampleRate) return;
    final from = (a.end - _maxPartial).clamp(a.speechStart!, a.end);
    final watch = Stopwatch()..start();
    final text = recognize(recognizer, a.slice(from));
    final cost = watch.elapsedMilliseconds;
    a.nextPartial = DateTime.now().add(Duration(milliseconds: cost * 2 > 1000 ? cost * 2 : 1000));
    if (text.isEmpty) return;
    a.hasPartial = true;
    out.send(PartialUtterance(channel, a.speechStart! / sampleRate, text));
  }

  final inbox = ReceivePort();
  inbox.listen((message) {
    if (message == 'pause') {
      for (final channel in _channels) {
        vads[channel]!.flush();
        drain(channel);
        clearPartial(channel);
      }
      return;
    }
    if (message == 'finish') {
      for (final channel in _channels) {
        final vad = vads[channel]!;
        final rest = remainders[channel]!;
        if (rest.isNotEmpty) vad.acceptWaveform(rest);
        vad.flush();
        drain(channel);
        clearPartial(channel);
        vad.free();
      }
      recognizer.free();
      extractor?.free();
      out.send(_SpeakerMap(clusters.consolidated()));
      out.send('done');
      inbox.close();
      return;
    }
    final (channel, data) = message as (String, TransferableTypedData);
    final vad = vads[channel];
    if (vad == null) return;
    final incoming = data.materialize().asFloat32List();
    final previous = remainders[channel]!;
    final samples = Float32List(previous.length + incoming.length)
      ..setAll(0, previous)
      ..setAll(previous.length, incoming);
    final whole = samples.length - samples.length % vadWindow;
    for (var i = 0; i < whole; i += vadWindow) {
      vad.acceptWaveform(Float32List.sublistView(samples, i, i + vadWindow));
    }
    audio[channel]!.append(Float32List.sublistView(samples, 0, whole));
    remainders[channel] = Float32List.fromList(Float32List.sublistView(samples, whole));
    drain(channel);
    partial(channel);
  });
  out.send(inbox.sendPort);
}
