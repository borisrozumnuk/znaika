import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'echo_filter.dart';
import 'speakers.dart';

/// Офлайн-расшифровка русской речи: Silero VAD + GigaAM v3 (sherpa-onnx).
/// Повторяет asr-proto/transcribe.py.

const sampleRate = 16000;
const _sampleRate = sampleRate;
const _gigaam = 'sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16';

/// Имя файла от meet_capture → подпись говорящего.
const channelLabels = {'mic.wav': meLabel, 'system.wav': othersLabel};

class Utterance {
  final double start;
  final double end;
  final String speaker;
  final String text;

  const Utterance(this.start, this.end, this.speaker, this.text);

  String get line => '[${formatTimestamp(start)}] $speaker: $text';
}

class Transcript {
  final List<Utterance> utterances;
  final double audioSeconds;
  final Duration elapsed;

  const Transcript(this.utterances, this.audioSeconds, this.elapsed);

  String get text => utterances.map((u) => u.line).join('\n');

  String get markdown => '# Расшифровка\n\n${utterances.map((u) => u.line).join('\n\n')}\n';
}

String formatTimestamp(double seconds) {
  final s = seconds.floor();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// Расшифровывает папку записи (mic.wav + system.wav) в фоновом изоляте
/// и сохраняет transcript.md рядом.
Future<Transcript> transcribeRecording({required String recordingDir, required String modelsDir}) async {
  final transcript = await Isolate.run(() => _transcribe(recordingDir, modelsDir));
  await saveTranscript(recordingDir, transcript);
  return transcript;
}

/// Модель отпечатков голоса (3D-Speaker ERes2Net, VoxCeleb). Необязательная: без неё
/// все собеседники идут одной меткой «Собеседники».
const speakerModelFile = '3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx';

/// Порог сходства «тот же голос» для этой модели. Подобран моделированием 300 встреч
/// по 2–5 русских дикторов VoxForge тем же алгоритмом: 99,2% реплик подписаны верно,
/// число собеседников угадано в 90% встреч (0,53 и 0,57 — чуть хуже).
const speakerThreshold = 0.55;

/// «Собеседник 1», «Собеседник 2»… — по номеру голоса с нуля.
String otherSpeakerLabel(int index) => 'Собеседник ${index + 1}';

/// Извлекатель отпечатков голоса или null, если модели нет (или она не загрузилась).
/// Вызывать в изоляте, где он будет работать (после initBindings).
so.SpeakerEmbeddingExtractor? createSpeakerExtractor(String modelsDir) {
  final path = '$modelsDir/$speakerModelFile';
  if (!File(path).existsSync()) return null;
  try {
    return so.SpeakerEmbeddingExtractor(
      config: so.SpeakerEmbeddingExtractorConfig(model: path, numThreads: 2, debug: false),
    );
  } catch (_) {
    return null;
  }
}

/// Отпечаток голоса фразы; null — фраза слишком короткая для модели.
Float32List? speakerEmbedding(so.SpeakerEmbeddingExtractor extractor, Float32List samples) {
  final stream = extractor.createStream();
  try {
    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
    stream.inputFinished();
    return extractor.isReady(stream) ? extractor.compute(stream) : null;
  } finally {
    stream.free();
  }
}

/// Подпись реплики канала собеседников: по голосу, если доступны отпечатки.
String labelForOthers(so.SpeakerEmbeddingExtractor? extractor, SpeakerClusters clusters, Float32List samples) {
  if (extractor == null) return othersLabel;
  final embedding = speakerEmbedding(extractor, samples);
  if (embedding == null) {
    // Слишком короткая фраза: последний известный голос, если он есть.
    clusters.addSeconds(clusters.lastAssigned, samples.length / _sampleRate);
    return clusters.count == 0 ? otherSpeakerLabel(0) : otherSpeakerLabel(clusters.lastAssigned);
  }
  return otherSpeakerLabel(clusters.assign(embedding, samples.length / _sampleRate));
}

Future<void> saveTranscript(String recordingDir, Transcript transcript) =>
    File('$recordingDir/transcript.md').writeAsString(transcript.markdown);

/// Распознаватель GigaAM. Вызывать внутри изолята, где он будет работать:
/// привязки FFI у каждого изолята свои.
so.OfflineRecognizer createRecognizer(String modelsDir) {
  so.initBindings();
  final model = '$modelsDir/$_gigaam';
  for (final path in ['$model/encoder.int8.onnx', '$modelsDir/silero_vad.onnx']) {
    if (!File(path).existsSync()) throw StateError('Модель не найдена: $path');
  }
  return so.OfflineRecognizer(so.OfflineRecognizerConfig(
    feat: const so.FeatureConfig(sampleRate: _sampleRate, featureDim: 64),
    model: so.OfflineModelConfig(
      transducer: so.OfflineTransducerModelConfig(
        encoder: '$model/encoder.int8.onnx',
        decoder: '$model/decoder.onnx',
        joiner: '$model/joiner.onnx',
      ),
      tokens: '$model/tokens.txt',
      numThreads: 4,
      modelType: 'nemo_transducer',
      debug: false,
    ),
  ));
}

/// Распознаёт одну фразу.
String recognize(so.OfflineRecognizer recognizer, Float32List samples) {
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
  recognizer.decode(stream);
  final text = recognizer.getResult(stream).text.trim();
  stream.free();
  return text;
}

Transcript _transcribe(String recordingDir, String modelsDir) {
  final watch = Stopwatch()..start();
  final recognizer = createRecognizer(modelsDir);
  final extractor = createSpeakerExtractor(modelsDir);
  final clusters = SpeakerClusters(sameSpeakerThreshold: speakerThreshold);

  final utterances = <Utterance>[];
  var audioSeconds = 0.0;
  try {
    for (final entry in channelLabels.entries) {
      final file = File('$recordingDir/${entry.key}');
      if (!file.existsSync()) continue;
      final samples = readWav(file.readAsBytesSync());
      audioSeconds = audioSeconds > samples.length / _sampleRate ? audioSeconds : samples.length / _sampleRate;
      for (final segment in _splitSpeech(samples, modelsDir)) {
        final phrase = withPreroll(samples, segment.start, segment.samples.length);
        final text = recognize(recognizer, phrase);
        if (text.isEmpty) continue;
        final start = segment.start / _sampleRate;
        final speaker = entry.value == othersLabel ? labelForOthers(extractor, clusters, phrase) : entry.value;
        utterances.add(Utterance(start, start + segment.samples.length / _sampleRate, speaker, text));
      }
    }
  } finally {
    recognizer.free();
    extractor?.free();
  }
  utterances.sort((a, b) => a.start.compareTo(b.start));
  return Transcript(dropEchoes(relabelSpeakers(utterances, clusters.consolidated())), audioSeconds, watch.elapsed);
}

/// Метки собеседников после встречи: «Собеседник N» → итоговый голос по [merged]
/// (номер голоса с нуля → номер, с которым он слит, см. SpeakerClusters.consolidated),
/// затем номера по порядку первой реплики: 1, 2, 3… без пропусков.
/// [utterances] — по порядку времени.
List<Utterance> relabelSpeakers(List<Utterance> utterances, List<int> merged) {
  final numbered = RegExp(r'^Собеседник (\d+)$');
  final renumbered = <int, int>{};
  return [
    for (final u in utterances)
      if (numbered.firstMatch(u.speaker) case final m?)
        Utterance(
          u.start,
          u.end,
          otherSpeakerLabel(renumbered.putIfAbsent(_mergedVoice(merged, int.parse(m[1]!) - 1), () => renumbered.length)),
          u.text,
        )
      else
        u,
  ];
}

int _mergedVoice(List<int> merged, int voice) => voice < merged.length ? merged[voice] : voice;

/// Silero VAD с теми же настройками, что в asr-proto.
so.VoiceActivityDetector createVad(String modelsDir) => so.VoiceActivityDetector(
    config: so.VadModelConfig(
      sileroVad: so.SileroVadModelConfig(
        model: '$modelsDir/silero_vad.onnx',
        threshold: 0.5,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        // Длинные куски GigaAM распознаёт хуже и дольше; 20 с — с запасом для одной реплики.
        maxSpeechDuration: 20,
      ),
      sampleRate: _sampleRate,
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );

/// Окно Silero VAD в отсчётах.
const vadWindow = 512;

/// Запас звука перед началом фразы, которое нашёл VAD. Silero иногда отмечает начало
/// на 0,1–0,15 с позже реального звука, и первый слог теряется («Гон» вместо «Прогон»):
/// на записях через tap запаса 0,2 с уже хватало, берём 0,3 с. Это меньше минимальной
/// паузы между фразами (0,5 с), так что хвост предыдущей фразы в запас не попадает.
const vadPreroll = sampleRate * 3 ~/ 10;

/// Фраза с запасом перед ней: [start] — начало фразы по VAD в отсчётах [audio].
Float32List withPreroll(Float32List audio, int start, int length) {
  final from = (start - vadPreroll).clamp(0, audio.length);
  final to = (start + length).clamp(from, audio.length);
  return Float32List.sublistView(audio, from, to);
}

/// Режет запись на фразы через Silero VAD.
List<so.SpeechSegment> _splitSpeech(Float32List samples, String modelsDir) {
  final vad = createVad(modelsDir);
  final segments = <so.SpeechSegment>[];
  void collect() {
    while (!vad.isEmpty()) {
      segments.add(vad.front());
      vad.pop();
    }
  }

  try {
    for (var i = 0; i < samples.length; i += vadWindow) {
      final end = i + vadWindow < samples.length ? i + vadWindow : samples.length;
      vad.acceptWaveform(Float32List.sublistView(samples, i, end));
      collect();
    }
    vad.flush();
    collect();
  } finally {
    vad.free();
  }
  return segments;
}

/// Читает PCM16 WAV 16 кГц и сводит каналы в моно.
/// Разбирает чанки по порядку: AVAudioFile добавляет служебный чанк FLLR перед data.
Float32List readWav(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('не WAV');

  int? channels, sampleRate, bits;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = tag(offset);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (bits != 16 || sampleRate != _sampleRate || channels == null) {
        throw FormatException('нужен PCM16 $_sampleRate Гц, а не $bits бит $sampleRate Гц');
      }
      final frames = size ~/ (2 * channels);
      final out = Float32List(frames);
      for (var f = 0; f < frames; f++) {
        var sum = 0;
        for (var c = 0; c < channels; c++) {
          sum += data.getInt16(body + (f * channels + c) * 2, Endian.little);
        }
        out[f] = sum / channels / 32768.0;
      }
      return out;
    }
    offset = body + size + (size & 1);
  }
  throw const FormatException('в WAV нет чанка data');
}
