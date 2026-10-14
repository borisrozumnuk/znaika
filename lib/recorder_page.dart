import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:meet_capture/meet_capture.dart';

import 'app_globals.dart';
import 'echo_filter.dart';
import 'live_transcriber.dart';
import 'log.dart';
import 'meeting_view.dart';
import 'meetings.dart';
import 'summarizer.dart';
import 'summary_models.dart';
import 'transcriber.dart';
import 'ui.dart';

/// Запись новой встречи: запись → расшифровка на лету → выжимка → заголовок.
/// Управление записью снаружи экрана записи: пункт строки меню.
class RecorderController {
  Future<bool?> Function()? _toggle;

  /// Начать запись или остановить идущую. true — запись началась, false — остановлена,
  /// null — сейчас нельзя (запись запускается или встреча ещё обрабатывается).
  Future<bool?> toggle() => _toggle?.call() ?? Future.value(null);
}

/// Записанная встреча, которую осталось обработать: дорасшифровать, написать заметки
/// и заголовок. Обрабатывается в фоне — экран записи сразу готов к следующей встрече.
class RecordedMeeting {
  const RecordedMeeting({required this.dir, required this.transcribe, required this.summarize});

  final Directory dir;

  /// Дорасшифровать (остаток на лету или, если она не поднялась, файлы целиком),
  /// сохранить transcript.md и вернуть реплики «[мм:сс] Кто: текст».
  final Future<List<String>> Function() transcribe;

  /// Писать ли заметки и заголовок (самопроверка без ZNAIKA_FULL — нет).
  final bool summarize;
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({
    super.key,
    required this.store,
    required this.recording,
    required this.onRecorded,
    this.controller,
  });

  final RecorderController? controller;

  final MeetingStore store;

  /// Идёт ли запись — для строки «Новая запись» в боковой панели.
  final ValueNotifier<bool> recording;

  /// Запись остановлена, встреча уже в списке: открыть её и обработать в фоне.
  /// Future завершается, когда обработка закончена.
  final Future<void> Function(RecordedMeeting meeting) onRecorded;

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  bool _recording = false;
  bool _busy = false;
  CaptureStarted? _started;
  CaptureLevels _levels = const CaptureLevels();
  StreamSubscription<CaptureLevels>? _levelsSub;
  DateTime? _startedAt;
  Timer? _clock;

  /// Автоостановка: когда в последний раз звучала речь (реплика или черновик фразы)
  /// и когда остановим запись, если речь так и не появится.
  DateTime _lastSpeechAt = DateTime.now();
  DateTime? _autoStopAt;

  /// Расшифровка на лету работает — без неё тишину не отличить, автоостановки нет.
  bool _liveOk = false;

  /// Пауза: звук не пишется; часы стоят. Сколько всего длились паузы и когда началась текущая.
  bool _paused = false;
  DateTime? _pausedAt;
  Duration _pausedTotal = Duration.zero;
  List<CapturedFile> _files = [];
  String? _recordingDir;
  bool _transcribing = false;
  Transcript? _transcript;
  LiveTranscriber? _live;
  StreamSubscription<AudioChunk>? _audioSub;
  StreamSubscription<Utterance>? _liveSub;
  StreamSubscription<PartialUtterance>? _partialSub;

  /// Черновики звучащих фраз по каналам.
  final _partials = <String, PartialUtterance>{};

  /// Реплики, распознанные во время записи, по порядку времени.
  final _liveUtterances = <Utterance>[];
  ScrollController? _scroll;
  String? _summaryStage;
  String? _summary;
  String? _error;

  bool get _processing => _transcribing || _summaryStage != null;

  @override
  void initState() {
    super.initState();
    widget.controller?._toggle = _toggle;
    // Самопроверка без UI: ZNAIKA_SELFTEST=N — записать N секунд, вывести итог и выйти.
    final selftest = int.tryParse(Platform.environment['ZNAIKA_SELFTEST'] ?? '');
    if (selftest != null) WidgetsBinding.instance.addPostFrameCallback((_) => _selftest(selftest));
    // ZNAIKA_TRANSCRIBE=<папка записи> — расшифровать готовую запись, вывести и выйти.
    // ZNAIKA_SUMMARIZE=<папка записи> — расшифровать, сделать выжимку, вывести и выйти.
    final summarizeDir = Platform.environment['ZNAIKA_SUMMARIZE'];
    if (summarizeDir != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _transcribe(summarizeDir);
        _printSelftestTranscript();
        final watch = Stopwatch()..start();
        await _summarize(summarizeDir);
        stdout.writeln('SELFTEST summary in ${watch.elapsedMilliseconds} ms');
        stdout.writeln(_summary ?? '');
        if (_error != null) stdout.writeln('SELFTEST error: $_error');
        exit(_error == null ? 0 : 1);
      });
    }
    // ZNAIKA_IMPORT=<wav 16 кГц> [ZNAIKA_IMPORT_AT=<ISO-время начала>] — готовая запись
    // (например, звук из видео созвона) становится встречей: всё, что после обычной записи.
    // Звук один, поэтому все голоса идут как собеседники, без «Я».
    final importFile = Platform.environment['ZNAIKA_IMPORT'];
    if (importFile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _import(importFile));
    }
    // ZNAIKA_RESUMMARIZE=<папка записи> — заметки по готовому transcript.md (как
    // «Пересоздать заметки»: имена собеседников в нём сохраняются), вывести и выйти.
    final resummarizeDir = Platform.environment['ZNAIKA_RESUMMARIZE'];
    if (resummarizeDir != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lines = (await File('$resummarizeDir/transcript.md').readAsLines()).where((l) => l.startsWith('[')).toList();
        // ZNAIKA_STOP_AFTER=N — через N с нажать «Остановить», затем сделать заметки заново:
        // проверка, что остановка прерывает модель и она остаётся рабочей.
        final stopAfter = int.tryParse(Platform.environment['ZNAIKA_STOP_AFTER'] ?? '');
        if (stopAfter != null) {
          final stop = NotesStop();
          final stopWatch = Stopwatch()..start();
          Future<void>.delayed(Duration(seconds: stopAfter), stop.stop);
          try {
            await summarizer.summarize(lines, outFile: File('$resummarizeDir/summary.md'), stop: stop);
            stdout.writeln('SELFTEST stop: заметки успели до остановки');
          } on NotesStopped {
            stdout.writeln('SELFTEST stop: остановлено через ${stopWatch.elapsedMilliseconds} ms');
          }
        }
        final watch = Stopwatch()..start();
        final summary = await summarizer.summarize(
          lines,
          outFile: File('$resummarizeDir/summary.md'),
          onProgress: (stage) => stdout.writeln('SELFTEST ${watch.elapsedMilliseconds ~/ 1000}s $stage'),
        );
        stdout.writeln('SELFTEST summary in ${watch.elapsedMilliseconds} ms');
        // Встреча из списка — как после «Пересоздать заметки»: пометка снята, поиск обновлён.
        final meetings = await widget.store.list();
        final meeting = meetings.where((m) => m.dir.absolute.path == Directory(resummarizeDir).absolute.path).firstOrNull;
        if (meeting != null) await widget.store.notesRegenerated(meeting);
        stdout.writeln(summary);
        exit(0);
      });
    }
    final transcribeDir = Platform.environment['ZNAIKA_TRANSCRIBE'];
    if (transcribeDir != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _transcribe(transcribeDir);
        _printSelftestTranscript();
        exit(_error == null ? 0 : 1);
      });
    }
  }

  Future<void> _import(String wavPath) async {
    final startedAt = DateTime.tryParse(Platform.environment['ZNAIKA_IMPORT_AT'] ?? '') ?? DateTime.now();
    final dir = await widget.store.create(startedAt);
    await File(wavPath).copy('${dir.path}/system.wav');
    stdout.writeln('SELFTEST import ${dir.path}');
    var watch = Stopwatch()..start();
    await _transcribe(dir.path);
    final t = _transcript;
    stdout.writeln('SELFTEST transcript ${t?.audioSeconds.toStringAsFixed(0)}s audio, '
        '${t?.utterances.length} реплик, ${speakersOf([for (final u in t?.utterances ?? <Utterance>[]) u.line]).length} '
        'собеседников in ${watch.elapsedMilliseconds} ms');
    if (_error != null) stdout.writeln('SELFTEST error: $_error');
    watch = Stopwatch()..start();
    await _summarize(dir.path);
    stdout.writeln('SELFTEST summary in ${watch.elapsedMilliseconds} ms');
    watch = Stopwatch()..start();
    var title = '';
    final summary = _summary;
    if (summary != null && summary.isNotEmpty) title = await summarizer.makeTitle(summary);
    stdout.writeln('SELFTEST title «$title» in ${watch.elapsedMilliseconds} ms');
    await widget.store.finish(dir, title: title, durationSeconds: t?.audioSeconds);
    if (_error == null && t != null) await widget.store.deleteAudio(dir);
    if (_error != null) stdout.writeln('SELFTEST error: $_error');
    exit(_error == null ? 0 : 1);
  }

  Future<bool?> _toggle() async {
    if (_busy || _processing) return null;
    if (_recording) {
      // Не ждём обработки: запись уже остановлена, заметки допишутся сами.
      unawaited(_stopAndFinish());
      return false;
    }
    await _start();
    return _recording ? true : null;
  }

  void _printSelftestTranscript() {
    final t = _transcript;
    if (t != null) {
      stdout.writeln('SELFTEST transcript ${t.audioSeconds.toStringAsFixed(1)}s audio in ${t.elapsed.inMilliseconds} ms');
      for (final u in t.utterances) {
        stdout.writeln('SELFTEST ${u.line}');
      }
    }
    if (_error != null) stdout.writeln('SELFTEST error: $_error');
  }

  Future<void> _selftest(int seconds) async {
    await _start();
    if (_error != null) {
      stdout.writeln('SELFTEST start error: $_error');
      exit(1);
    }
    stdout.writeln('SELFTEST mic=${_started?.micDevice} bluetooth=${_started?.micIsBluetooth}');
    // ZNAIKA_SELFTEST_PAUSE=5-10 — пауза с 5-й по 10-ю секунду записи.
    final pause = RegExp(r'^(\d+)-(\d+)$').firstMatch(Platform.environment['ZNAIKA_SELFTEST_PAUSE'] ?? '');
    if (pause != null) {
      Future<void>.delayed(Duration(seconds: int.parse(pause[1]!)), _togglePause);
      Future<void>.delayed(Duration(seconds: int.parse(pause[2]!)), _togglePause);
    }
    final started = DateTime.now();
    final live = _live?.utterances.listen((u) {
      final at = DateTime.now().difference(started).inMilliseconds / 1000;
      stdout.writeln('SELFTEST live +${at.toStringAsFixed(1)}s (конец фразы ${u.end.toStringAsFixed(1)}s) ${u.line}');
    });
    final partials = _live?.partials.listen((p) {
      final at = DateTime.now().difference(started).inMilliseconds / 1000;
      stdout.writeln('SELFTEST partial +${at.toStringAsFixed(1)}s ${p.channel}: ${p.text.isEmpty ? '(снят)' : p.text}');
    });
    await Future<void>.delayed(Duration(seconds: seconds));
    // ZNAIKA_FULL=1 — как после кнопки: ещё выжимка и заголовок.
    final full = Platform.environment['ZNAIKA_FULL'] == '1';
    await _stopAndFinish(summarize: full);
    if (full) {
      stdout.writeln('SELFTEST meeting.json ${await File('$_recordingDir/meeting.json').readAsString()}');
    }
    await live?.cancel();
    await partials?.cancel();
    for (final f in _files) {
      stdout.writeln('SELFTEST file ${f.channel} ${f.seconds.toStringAsFixed(1)}s peak=${f.peak.toStringAsFixed(3)} ${f.path}');
    }
    _printSelftestTranscript();
    exit(_error == null ? 0 : 1);
  }

  @override
  void dispose() {
    _live?.cancel();
    _audioSub?.cancel();
    _liveSub?.cancel();
    _partialSub?.cancel();
    _levelsSub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
      _files = [];
      _transcript = null;
      _summary = null;
      _liveUtterances.clear();
      _partials.clear();
    });
    try {
      // Папка и meeting.json с локальным временем начала.
      final outDir = (await widget.store.create(DateTime.now())).path;
      // Для самопроверки: ZNAIKA_CHANNELS=mic или system — писать только один канал.
      final channels = Platform.environment['ZNAIKA_CHANNELS'];
      // Расшифровка на лету: модель грузится в фоне, звук до готовности копится.
      // Если она не поднимется, после остановки расшифруем готовые файлы.
      final live = await LiveTranscriber.start(modelsDir);
      _liveOk = false;
      live.ready.then((_) => _liveOk = true, onError: (Object e) {
        stderr.writeln('Расшифровка на лету недоступна: $e');
      });
      _live = live;
      _liveSub = live.utterances.listen(_addLiveUtterance);
      _partialSub = live.partials.listen((p) => setState(() {
            if (p.text.isEmpty) {
              _partials.remove(p.channel);
            } else {
              _partials[p.channel] = p;
              _heardSpeech();
            }
          }));
      _audioSub = MeetCapture.audio.listen((chunk) => live.feed(chunk.channel, chunk.samples));
      final started = await MeetCapture.start(
        outDir: outDir,
        system: channels == null || channels == 'system',
        mic: channels == null || channels == 'mic',
        streamAudio: true,
      );
      _recordingDir = outDir;
      _levelsSub = MeetCapture.levels.listen((levels) => setState(() => _levels = levels));
      _startedAt = DateTime.now();
      _paused = false;
      _pausedAt = null;
      _pausedTotal = Duration.zero;
      _lastSpeechAt = DateTime.now();
      _autoStopAt = null;
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() {});
        _checkSilence();
      });
      setState(() {
        _started = started;
        _recording = true;
      });
      widget.recording.value = true;
    } catch (e) {
      await _audioSub?.cancel();
      await _liveSub?.cancel();
      _live?.cancel();
      _live = null;
      setState(() => _error = _describeError(e));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Сколько тишины до предупреждения и сколько ещё ждать после него.
  /// ZNAIKA_SILENCE_LIMIT=<секунды> — для самопроверки.
  static final _silenceLimit = Duration(
    seconds: int.tryParse(Platform.environment['ZNAIKA_SILENCE_LIMIT'] ?? '') ?? 10 * 60,
  );
  static const _autoStopGrace = Duration(minutes: 1);

  void _heardSpeech() {
    _lastSpeechAt = DateTime.now();
    _autoStopAt = null;
  }

  /// Раз в секунду: долгая тишина — предупреждение с обратным отсчётом, затем остановка.
  void _checkSilence() {
    if (!_recording || _busy || !_liveOk || _paused) return;
    final now = DateTime.now();
    if (now.difference(_lastSpeechAt) < _silenceLimit) return;
    final stopAt = _autoStopAt ??= now.add(_autoStopGrace);
    if (now.isAfter(stopAt)) {
      _autoStopAt = null;
      logLine('Запись остановлена: тишина ${_silenceLimit.inSeconds} с');
      _stopAndFinish();
    }
  }

  void _addLiveUtterance(Utterance u) {
    _heardSpeech();
    // Каналы распознаются независимо: вставляем реплику на её место по времени.
    var i = _liveUtterances.length;
    while (i > 0 && _liveUtterances[i - 1].start > u.start) {
      i--;
    }
    setState(() => _liveUtterances.insert(i, u));
    // Прокручиваем к новой реплике, если пользователь и так внизу.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scroll = _scroll;
      if (scroll != null && scroll.hasClients && scroll.position.extentAfter < 200) {
        scroll.animateTo(scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    await _levelsSub?.cancel();
    _clock?.cancel();
    try {
      final stopped = await MeetCapture.stop();
      await _audioSub?.cancel();
      // Хвост записи, не успевший прийти через поток audio.
      for (final chunk in stopped.tail) {
        _live?.feed(chunk.channel, chunk.samples);
      }
      setState(() => _files = stopped.files);
    } catch (e) {
      setState(() => _error = _describeError(e));
    } finally {
      setState(() {
        _recording = false;
        _busy = false;
        _levels = const CaptureLevels();
      });
      widget.recording.value = false;
    }
  }

  Future<void> _transcribe(String recordingDir) async {
    setState(() {
      _transcribing = true;
      _transcript = null;
    });
    try {
      final transcript = await transcribeRecording(recordingDir: recordingDir, modelsDir: modelsDir);
      setState(() => _transcript = transcript);
    } catch (e) {
      setState(() => _error = 'Расшифровка: $e');
    } finally {
      setState(() => _transcribing = false);
    }
  }

  Future<void> _summarize(String recordingDir) async {
    final transcript = _transcript;
    if (transcript == null || transcript.utterances.isEmpty) return;
    setState(() {
      _summaryStage = 'Подготовка…';
      _summary = null;
    });
    try {
      await waitForSummaryModel((stage) => setState(() => _summaryStage = stage));
      await summarizer.summarize(
        transcript.utterances.map((u) => u.line).toList(),
        outFile: File('$recordingDir/summary.md'),
        onProgress: (stage) => setState(() => _summaryStage = stage),
        onText: (text) => setState(() => _summary = text),
      );
    } catch (e) {
      setState(() => _error = 'Выжимка: $e');
    } finally {
      setState(() => _summaryStage = null);
    }
  }

  /// Останавливает запись и отдаёт встречу на обработку: она сразу появляется в списке,
  /// расшифровка, заметки и заголовок дописываются в фоне.
  Future<void> _stopAndFinish({bool summarize = true}) async {
    await _stop();
    final dir = _recordingDir;
    final live = _live;
    _live = null;
    await _liveSub?.cancel();
    await _partialSub?.cancel();
    if (_error != null || dir == null) {
      live?.cancel();
      return;
    }
    final duration = _files.fold(0.0, (m, f) => f.seconds > m ? f.seconds : m);
    // Заголовок появится, когда будут заметки.
    await widget.store.finish(Directory(dir), title: 'Новая встреча', durationSeconds: duration > 0 ? duration : null);
    // Закроют приложение посреди обработки — при следующем запуске она продолжится.
    await widget.store.setProcessing(Directory(dir), true);

    Future<List<String>> transcribe() async {
      Transcript? transcript;
      if (live != null) {
        final watch = Stopwatch()..start();
        try {
          transcript = Transcript(await live.finish(), duration, watch.elapsed);
          await saveTranscript(dir, transcript);
        } catch (e) {
          logLine('Расшифровка на лету не удалась, расшифровываю файлы: $e');
          transcript = null;
        }
      }
      transcript ??= await transcribeRecording(recordingDir: dir, modelsDir: modelsDir);
      // Самопроверка печатает расшифровку с экрана записи.
      if (selftestMode && mounted) setState(() => _transcript = transcript);
      return [for (final u in transcript.utterances) u.line];
    }

    // Экран записи готов к следующей встрече; предупреждение о беззвучном
    // системном канале (по _files) остаётся до неё.
    setState(() {
      _liveUtterances.clear();
      _partials.clear();
      _transcript = null;
      _summary = null;
    });
    await widget.onRecorded(RecordedMeeting(dir: Directory(dir), transcribe: transcribe, summarize: summarize));
  }

  /// Черновики по времени начала. Черновик «Я», пока звучит черновик собеседников,
  /// почти наверняка эхо из динамиков — его не показываем.
  List<String> _pendingLines() {
    final shown = _partials.values.where((p) => !(p.channel == 'mic' && _partials.containsKey('system'))).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return [for (final p in shown) Utterance(p.start, p.start, p.speaker, p.text).line];
  }

  /// PlatformException от плагина — показываем только понятный текст.
  String _describeError(Object e) {
    final text = '$e';
    final match = RegExp(r'PlatformException\([^,]*, (.*?), null').firstMatch(text);
    return match?.group(1) ?? text;
  }

  /// Пауза / продолжение записи. Устройства не останавливаются — пропускается звук.
  Future<void> _togglePause() async {
    if (!_recording || _busy) {
      logLine('Пауза: сейчас нельзя (запись: $_recording, занято: $_busy)');
      return;
    }
    if (_paused) {
      logLine('Запись продолжена: ${await MeetCapture.resume()}');
      setState(() {
        _pausedTotal += DateTime.now().difference(_pausedAt!);
        _pausedAt = null;
        _paused = false;
        _heardSpeech();
      });
    } else {
      logLine('Запись на паузе: ${await MeetCapture.pause()}');
      _live?.pause();
      setState(() {
        _paused = true;
        _pausedAt = DateTime.now();
        _autoStopAt = null;
        _partials.clear();
      });
    }
  }

  /// Время записи без пауз.
  String get _elapsed {
    final start = _startedAt;
    if (start == null || !_recording) return '00:00';
    final now = DateTime.now();
    final paused = _pausedTotal + (_pausedAt == null ? Duration.zero : now.difference(_pausedAt!));
    final s = (now.difference(start) - paused).inSeconds;
    final mm = (s ~/ 60 % 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return MacosScaffold(
      toolBar: const ToolBar(title: Text('Новая встреча'), titleWidth: 300),
      children: [
        ContentArea(
          builder: (context, scrollController) {
            _scroll = scrollController;
            return PageContent(controller: scrollController, children: _content(context));
          },
        ),
      ],
    );
  }

  List<Widget> _content(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final micDevice = _started?.micDevice;
    final systemSilent = _files.any((f) => f.channel == 'system' && f.peak == 0);
    final (title, subtitle) = switch ((_recording, _busy, _processing)) {
      (true, _, _) when _paused => ('Пауза', 'Звук не записывается'),
      (true, _, _) => ('Идёт запись', micDevice != null ? 'Микрофон: $micDevice' : 'Системный звук и микрофон'),
      (false, true, _) => ('Подготовка…', 'Запускаю запись'),
      (false, false, true) => ('Обработка встречи', 'Расшифровка и заметки — прямо на этом Mac'),
      _ => ('Начать запись', 'Звук собеседников и ваш микрофон. Всё остаётся на этом Mac.'),
    };

    return [
      Row(
        children: [
          RecordButton(
            recording: _recording,
            onPressed: (_busy || _processing) ? null : (_recording ? _stopAndFinish : _start),
          ),
          const SizedBox(width: Gap.small),
          if (_recording) ...[
            PauseButton(paused: _paused, onPressed: _busy ? null : _togglePause),
            const SizedBox(width: Gap.small),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: typography.title2),
                const SizedBox(height: Gap.line),
                Text(subtitle, style: typography.body.copyWith(color: secondaryLabel(context))),
              ],
            ),
          ),
          // На паузе часы серые и мягко мигают раз в секунду — как в «Диктофоне».
          AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: _paused && DateTime.now().second.isOdd ? 0.35 : 1,
            child: Text(
              _elapsed,
              style: typography.largeTitle.copyWith(
                fontWeight: FontWeight.w300,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: _recording && !_paused ? null : tertiaryLabel(context),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: Gap.group),
      GroupBox(
        child: Column(
          children: [
            LevelMeter(icon: CupertinoIcons.speaker_2, label: othersLabel, db: _recording && !_paused ? _levels.system : null),
            const SizedBox(height: Gap.small),
            LevelMeter(icon: CupertinoIcons.mic, label: meLabel, db: _recording && !_paused ? _levels.mic : null),
          ],
        ),
      ),
      if (systemSilent) ...[
        const SizedBox(height: Gap.small),
        const Callout(
          kind: CalloutKind.warning,
          text: 'Звук собеседников не записался: либо ничего не играло, либо у приложения нет разрешения '
              'на запись системного звука (Системные настройки → Конфиденциальность и безопасность).',
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: Gap.small),
        Callout(kind: CalloutKind.error, text: _error!),
      ],
      if (_recording && _autoStopAt != null) ...[
        const SizedBox(height: Gap.small),
        Callout(
          kind: CalloutKind.warning,
          text: '${_minutes(_silenceLimit)} тишины — запись остановится через '
              '${_autoStopAt!.difference(DateTime.now()).inSeconds.clamp(0, 999)} с.',
          action: PushButton(
            controlSize: ControlSize.regular,
            onPressed: () => setState(_heardSpeech),
            child: const Text('Продолжить запись'),
          ),
        ),
      ],
      if (_recording) ...[
        const SizedBox(height: Gap.group),
        const SectionHeader('Расшифровка'),
        // Эхо собеседников в микрофоне скрывается на лету; если «оригинал» ещё
        // не распознан, реплика видна и исчезнет, когда он появится.
        if (_liveUtterances.isEmpty && _partials.isEmpty)
          Text('Реплики появятся здесь по ходу разговора.',
              style: typography.body.copyWith(color: secondaryLabel(context)))
        else
          TranscriptLines(
            dropEchoes(_liveUtterances).map((u) => u.line).toList(),
            pending: _pendingLines(),
          ),
      ],
      if (_transcribing) ...[
        const SizedBox(height: Gap.group),
        const ActivityRow('Расшифровка…'),
      ],
      if (_summaryStage != null || _summary != null) ...[
        const SizedBox(height: Gap.group),
        const SectionHeader('Заметки'),
        if (_summaryStage != null) ...[ActivityRow(_summaryStage!), const SizedBox(height: Gap.small)],
        if (_summary != null) SummaryMarkdown(_summary!),
      ],
      if (_transcript != null && !_recording) ...[
        const SizedBox(height: Gap.group),
        Disclosure(
          title: _transcript!.utterances.isEmpty ? 'Речь не найдена' : 'Расшифровка · ${_transcript!.utterances.length} реплик',
          child: TranscriptLines(_transcript!.utterances.map((u) => u.line).toList()),
        ),
      ],
    ];
  }
}

/// «5 минут», «1 минута», «2 минуты», «30 с».
String _minutes(Duration d) {
  if (d.inMinutes == 0) return '${d.inSeconds} с';
  final m = d.inMinutes;
  final word = m % 10 == 1 && m % 100 != 11
      ? 'минута'
      : (m % 10 >= 2 && m % 10 <= 4 && (m % 100 < 12 || m % 100 > 14) ? 'минуты' : 'минут');
  return '$m $word';
}
