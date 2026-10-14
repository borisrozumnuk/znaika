import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_window_utils/macos/ns_window_button_type.dart';

import 'app_globals.dart';
import 'chat_page.dart';
import 'meeting_chat.dart';
import 'log.dart';
import 'meeting_view.dart';
import 'meetings.dart';
import 'model_manager.dart';
import 'model_manifest.dart';
import 'platform_files.dart';
import 'recorder_page.dart';
import 'summarizer.dart';
import 'summary_models.dart';
import 'transcriber.dart';
import 'ui.dart';

/// Окно приложения: слева — боковая панель со встречами, справа — запись или выбранная встреча.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  MeetingStore get _store => meetingStore;
  final _recording = ValueNotifier(false);

  /// Начать/остановить запись из строки меню.
  final _recorder = RecorderController();
  List<Meeting> _meetings = [];

  /// Выбранная встреча; null — экран записи или чат ([_chat]).
  Meeting? _selected;

  /// Открыт чат по встречам (когда встреча не выбрана).
  bool _chat = false;

  /// Есть хоть одна обработанная встреча — чату есть о чём отвечать.
  bool _hasAnalyzed = false;

  /// Почему чат сейчас недоступен (подсказка на кнопке); null — доступен.
  /// Отвечает модель для заметок — без скачанной ни одной чату нечем отвечать;
  /// без обработанных встреч — не по чему.
  String? get _chatUnavailable {
    if (!summaryModels.any((m) => modelManager.isReady(m.package))) {
      final package = summaryModelChoice.effective.package;
      final state = modelManager.stateOf(package);
      final percent = (state.received * 100 / package.size).floor().clamp(
        0,
        100,
      );
      return state.status == PackageStatus.downloading ||
              state.status == PackageStatus.queued
          ? 'Чат заработает, когда скачается модель для заметок ($percent%).'
          : 'Чат заработает, когда будет скачана модель для заметок.';
    }
    if (!_hasAnalyzed) {
      return 'Чат заработает, когда появится первая обработанная встреча.';
    }
    return null;
  }

  /// Чат открыт и доступен (модель удалили, пока он был открыт, — показываем запись).
  bool get _chatShown => _chat && _chatUnavailable == null;

  /// Обработанная — с заметками или расшифровкой с речью, и уже не обрабатывается.
  Future<bool> _anyAnalyzed(List<Meeting> meetings) async {
    for (final m in meetings) {
      if (_notesJobs.containsKey(m.dir.path)) continue;
      if ((await m.readSummary() ?? '').isNotEmpty ||
          (await m.readTranscript()).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  void _onModelsChanged() => setState(() {});

  void _showRecorder() => setState(() {
    _selected = null;
    _chat = false;
  });

  void _showChat() => setState(() {
    _selected = null;
    _chat = true;
  });

  /// Встреча из списка или из источников ответа в чате.
  void _open(Meeting meeting) => setState(() {
    // В списке — свежая версия (заголовок мог смениться после ответа).
    _selected =
        _meetings.where((m) => m.dir.path == meeting.dir.path).firstOrNull ??
        meeting;
    _chat = false;
  });

  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';

  /// Результаты поиска; null — поиска нет, показываем все встречи.
  List<SearchHit>? _hits;

  /// «Переименовать» из строки меню: MeetingView начинает правку заголовка.
  final _renameRequests = _Signal();

  /// Идёт переименование: ⌘⌫ должен достаться полю ввода, а не «Удалить встречу».
  bool _renaming = false;

  /// Встречи, которые обрабатываются сейчас (только что записанные или с пересоздаваемыми
  /// заметками), по папке: этап и текст заметок по мере генерации. Хранятся здесь, а не
  /// в MeetingView: можно уйти к другой встрече или начать новую запись и вернуться.
  final _notesJobs = <String, NotesProgress>{};

  /// Кнопка «Остановить» для этих заметок.
  final _notesStops = <String, NotesStop>{};

  @override
  void initState() {
    super.initState();
    // Слушаем контроллер, а не onChanged: MacosSearchField не вызывает onChanged,
    // когда поле очищают, и список остался бы отфильтрованным.
    _searchController.addListener(
      () => _onQueryChanged(_searchController.text),
    );
    _syncAndReload();
    // Пункт меню «Начать/Остановить запись» меняет название вместе с записью.
    _recording.addListener(_onRecordingChanged);
    // Кнопка «Чат» доступна, когда скачана модель для заметок.
    modelManager.addListener(_onModelsChanged);
  }

  void _onRecordingChanged() => setState(() {});

  /// «Начать/Остановить запись» из меню «Встреча».
  Future<void> _toggleRecording() async {
    if (!_recording.value) _showRecorder();
    await _recorder.toggle();
  }

  @override
  void dispose() {
    _recording.removeListener(_onRecordingChanged);
    modelManager.removeListener(_onModelsChanged);
    _recording.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _renameRequests.dispose();
    super.dispose();
  }

  // MARK: действия со встречей

  Future<void> _rename(Meeting meeting, String title) async {
    await _store.rename(meeting, title);
    await _reload();
  }

  Future<void> _renameSpeaker(Meeting meeting, String from, String to) async {
    try {
      await _store.renameSpeaker(meeting, from, to);
    } catch (e) {
      if (mounted) {
        await _showError('Не удалось переименовать собеседника', '$e');
      }
    }
    await _reload();
  }

  /// Gemma заново пишет заметки по расшифровке — например, после того как собеседники
  /// получили имена. Заголовок не меняется: его мог задать пользователь.
  Future<void> _regenerateNotes(Meeting meeting) async {
    final key = meeting.dir.path;
    if (_notesJobs.containsKey(key)) return;
    var stage = 'Подготовка…';
    void update(NotesProgress progress) {
      if (mounted) setState(() => _notesJobs[key] = progress);
    }

    update(NotesProgress(stage));
    final stop = _notesStops[key] = NotesStop();
    try {
      if (!selftestMode &&
          !modelManager.isReady(summaryModelChoice.effective.package)) {
        throw StateError(
          'Модель для заметок ещё скачивается — попробуйте, когда загрузка закончится.',
        );
      }
      final lines = await meeting.readTranscript();
      if (lines.isEmpty) throw StateError('В расшифровке нет реплик.');
      await summarizer.summarize(
        lines,
        outFile: meeting.summaryFile,
        onProgress: (s) => update(NotesProgress(stage = s)),
        onText: (text) => update(NotesProgress(stage, text)),
        stop: stop,
      );
      await _store.notesRegenerated(meeting);
    } on NotesStopped {
      // Остановили кнопкой: прежние заметки и пометка «устарели» остаются.
      logLine('Пересоздание заметок остановлено: ${meeting.dir.path}');
    } catch (e) {
      logLine('Пересоздание заметок не удалось: $e');
      if (selftestMode) {
        stdout.writeln('SELFTEST regenerate error: $e');
        exit(1);
      }
      if (mounted) await _showError('Не удалось пересоздать заметки', '$e');
    } finally {
      _notesStops.remove(key);
      if (mounted) setState(() => _notesJobs.remove(key));
    }
    await _reload();
  }

  /// Только что записанная встреча: открывается сразу, а расшифровка, заметки и
  /// заголовок дописываются в фоне — тем временем можно записывать следующую.
  /// [open] — открыть встречу (только что записанную; продолжение после запуска — нет).
  Future<void> _processRecording(
    RecordedMeeting recorded, {
    bool open = true,
  }) async {
    final key = recorded.dir.path;
    if (_notesJobs.containsKey(key)) return;
    var stage = 'Расшифровка…';
    void update(NotesProgress progress) {
      if (mounted) setState(() => _notesJobs[key] = progress);
    }

    update(NotesProgress(stage));
    final stop = _notesStops[key] = NotesStop();
    // Встреча с «Новая встреча» в заголовке уже в базе — открываем её.
    await _reload(open: open ? key : null);
    var title = '';
    var interrupted = false;
    try {
      final lines = await recorded.transcribe();
      if (lines.isEmpty) {
        title = 'Встреча без речи';
      } else if (recorded.summarize) {
        await _reload();
        update(NotesProgress(stage = 'Подготовка…'));
        await waitForSummaryModel((s) => update(NotesProgress(stage = s)));
        final summary = await summarizer.summarize(
          lines,
          outFile: File('$key/summary.md'),
          onProgress: (s) => update(NotesProgress(stage = s)),
          onText: (text) => update(NotesProgress(stage, text)),
          stop: stop,
        );
        if (summary.isNotEmpty) {
          update(NotesProgress('Придумываю заголовок…', summary));
          try {
            title = await summarizer.makeTitle(summary);
          } catch (e) {
            logLine('Заголовок не получился: $e');
          }
        }
      }
    } on NotesStopped {
      logLine('Заметки к новой встрече остановлены: $key');
    } catch (e) {
      logLine('Обработка встречи не удалась ($key): $e');
      if (selftestMode) stdout.writeln('SELFTEST error: $e');
      if (mounted && !selftestMode) {
        await _showError('Не удалось обработать встречу', '$e');
      }
    } finally {
      _notesStops.remove(key);
      // Окно закрыли посреди обработки (приложение выходит) — пометка остаётся,
      // при следующем запуске обработка продолжится.
      interrupted = !mounted;
    }
    if (interrupted) return;
    // Пустой заголовок — первая фраза заметок (или «Встреча без заметок»).
    await _store.finish(recorded.dir, title: title);
    await _store.setProcessing(recorded.dir, false);
    // Расшифровка есть — звук больше не нужен (заметки пишутся заново по расшифровке).
    // Нет — оставляем, чтобы встречу можно было обработать заново.
    if (await File('$key/transcript.md').exists()) {
      await _store.deleteAudio(recorded.dir);
    }
    if (mounted) setState(() => _notesJobs.remove(key));
    await _reload();
  }

  /// Обработку прервало закрытие приложения — продолжаем с того, что успело сохраниться:
  /// есть transcript.md — сразу заметки, нет — расшифровка файлов записи.
  Future<void> _resumeUnfinished() async {
    for (final meeting in await _store.unfinished()) {
      if (!mounted) return;
      logLine('Продолжаю обработку встречи: ${meeting.dir.path}');
      await _processRecording(
        RecordedMeeting(
          dir: meeting.dir,
          summarize: true,
          transcribe: () async {
            if (await meeting.transcriptFile.exists()) {
              return meeting.readTranscript();
            }
            final transcript = await transcribeRecording(
              recordingDir: meeting.dir.path,
              modelsDir: modelsDir,
            );
            return [for (final u in transcript.utterances) u.line];
          },
        ),
        open: false,
      );
    }
  }

  Future<String> _markdown(Meeting meeting) async => meetingMarkdown(
    meeting,
    summary: await meeting.readSummary(),
    transcript: await meeting.readTranscript(),
  );

  Future<void> _export(Meeting meeting) async {
    try {
      await PlatformFiles.saveText(
        suggestedName: exportFileName(meeting),
        text: await _markdown(meeting),
      );
    } catch (e) {
      if (mounted) await _showError('Не удалось экспортировать встречу', '$e');
    }
  }

  /// Заметки в буфер обмена (Markdown); если заметок нет — расшифровка.
  Future<void> _copyNotes(Meeting meeting) async {
    final summary = await meeting.readSummary();
    final text = (summary != null && summary.isNotEmpty)
        ? '# ${meeting.title}\n\n$summary'
        : await _markdown(meeting);
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _confirmDelete(Meeting meeting) async {
    // Gemma допишет summary.md в папку, которая уже в Корзине.
    if (_notesJobs.containsKey(meeting.dir.path)) {
      return _showError(
        'Встреча ещё обрабатывается',
        'Удалить её можно, когда заметки будут готовы. Чтобы не ждать, нажмите «Остановить».',
      );
    }
    final confirmed = await showMacosAlertDialog<bool>(
      context: context,
      builder: (context) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.trash, size: 48),
        title: Text(
          'Удалить встречу «${meeting.title}»?',
          textAlign: TextAlign.center,
        ),
        message: const Text(
          'Запись, расшифровка и заметки будут перемещены в Корзину.',
          textAlign: TextAlign.center,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          color: MacosColors.systemRedColor.resolveFrom(context),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Удалить'),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отменить'),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    // После удаления — соседняя встреча (следующая в списке или предыдущая).
    final index = _meetings.indexWhere((m) => m.dir.path == meeting.dir.path);
    final rest = [..._meetings]..removeAt(index);
    final next = rest.isEmpty ? null : rest[index.clamp(0, rest.length - 1)];
    try {
      await _store.delete(meeting, moveToTrash: PlatformFiles.moveToTrash);
    } catch (e) {
      if (mounted) await _showError('Не удалось удалить встречу', '$e');
      return;
    }
    _selected = next;
    await _reload();
  }

  Future<void> _showError(String title, String message) =>
      showMacosAlertDialog<void>(
        context: context,
        builder: (context) => MacosAlertDialog(
          appIcon: MacosIcon(
            CupertinoIcons.exclamationmark_triangle,
            size: 48,
            color: MacosColors.systemOrangeColor.resolveFrom(context),
          ),
          title: Text(title, textAlign: TextAlign.center),
          message: Text(message, textAlign: TextAlign.center),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ),
      );

  MeetingActions _actionsFor(Meeting meeting) => MeetingActions(
    rename: (title) => _rename(meeting, title),
    renameSpeaker: (from, to) => _renameSpeaker(meeting, from, to),
    regenerateNotes: _notesJobs.containsKey(meeting.dir.path)
        ? null
        : () => _regenerateNotes(meeting),
    stopNotes: () => _notesStops[meeting.dir.path]?.stop(),
    export: () => _export(meeting),
    copyNotes: () => _copyNotes(meeting),
    delete: () => _confirmDelete(meeting),
  );

  /// Строка меню macOS: меню приложения, «Встреча» с горячими клавишами, «Окно».
  List<PlatformMenuItem> _menus() {
    final selected = _selected;
    VoidCallback? forSelected(void Function(Meeting m) action) =>
        selected == null ? null : () => action(selected);
    return [
      PlatformMenu(
        label: 'Znaika',
        menus: [
          PlatformMenuItemGroup(
            members: [
              // Своё окно «О приложении» вместо стандартного пункта — с автором.
              PlatformMenuItem(
                label: 'О приложении Znaika',
                onSelected: () =>
                    const MethodChannel('znaika/system')
                        .invokeMethod<void>('showAbout'),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: 'Встреча',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Новая запись',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyN,
                  meta: true,
                ),
                onSelected: _showRecorder,
              ),
              PlatformMenuItem(
                label: _recording.value ? 'Остановить запись' : 'Начать запись',
                onSelected: _toggleRecording,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Переименовать',
                onSelected: forSelected((_) => _renameRequests.fire()),
              ),
              PlatformMenuItem(
                label: 'Экспортировать…',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyE,
                  meta: true,
                ),
                onSelected: forSelected(_export),
              ),
              PlatformMenuItem(
                label: 'Пересоздать заметки',
                onSelected:
                    selected == null ||
                        _notesJobs.containsKey(selected.dir.path)
                    ? null
                    : () => _regenerateNotes(selected),
              ),
              PlatformMenuItem(
                label: 'Скопировать заметки',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyC,
                  meta: true,
                  shift: true,
                ),
                onSelected: forSelected(_copyNotes),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              // ⌘⌫ — как «Переместить в Корзину» в Finder; удаление всё равно подтверждается.
              PlatformMenuItem(
                label: 'Удалить встречу',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.backspace,
                  meta: true,
                ),
                onSelected: _renaming ? null : forSelected(_confirmDelete),
              ),
            ],
          ),
        ],
      ),
      const PlatformMenu(
        label: 'Окно',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.minimizeWindow,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.zoomWindow,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.toggleFullScreen,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
              ),
            ],
          ),
        ],
      ),
    ];
  }

  /// Поиск по мере ввода: пауза 200 мс, чтобы не искать на каждую букву.
  void _onQueryChanged(String query) {
    // Контроллер сообщает и о смене выделения — текст при этом тот же.
    if (query.trim() == _query && _searchDebounce?.isActive != true) return;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      _query = query.trim();
      _runSearch();
    });
  }

  Future<void> _runSearch() async {
    final query = _query;
    final hits = query.isEmpty ? null : await _store.search(query);
    // Пока искали, запрос мог измениться — тогда этот результат уже не нужен.
    if (!mounted || query != _query) return;
    setState(() => _hits = hits);
  }

  /// При запуске база сверяется с папками на диске.
  Future<void> _syncAndReload() async {
    final changes = await _store.sync();
    if (changes.added > 0 || changes.removed > 0) {
      stdout.writeln(
        'Индекс встреч: добавлено ${changes.added}, удалено ${changes.removed}',
      );
    }
    await _reload();
    if (!selftestMode) unawaited(_resumeUnfinished());
    // ZNAIKA_ASK=<вопрос>[|<уточнение>…] — спросить чат по встречам, вывести ответы и выйти.
    final ask = Platform.environment['ZNAIKA_ASK'];
    if (ask != null) {
      // ZNAIKA_ASK_DELAY=N — спросить через N с (например, посреди ZNAIKA_RESUMMARIZE).
      final delay = int.tryParse(Platform.environment['ZNAIKA_ASK_DELAY'] ?? '') ?? 0;
      await Future<void>.delayed(Duration(seconds: delay));
      final history = <ChatTurn>[];
      for (final question in ask.split('|')) {
        final watch = Stopwatch()..start();
        final sources = await findChatSources(
          _store,
          question,
          previous: history.isEmpty
              ? const []
              : [for (final s in history.last.sources) s.meeting],
        );
        stdout.writeln('SELFTEST вопрос: $question');
        for (final (i, s) in sources.indexed) {
          stdout.writeln(
            'SELFTEST [${i + 1}] ${s.meeting.title} (${s.lines.length} реплик)',
          );
        }
        final answer = await summarizer.answer(
          chatPrompt(question, sources, history, DateTime.now()),
          system: chatSystem,
        );
        stdout.writeln(
          'SELFTEST ответ за ${watch.elapsedMilliseconds} мс:\n$answer\n',
        );
        history.add(ChatTurn(question, answer, sources));
      }
      await stdout.flush();
      exit(0);
    }
    // ZNAIKA_REGENERATE=<папка встречи> — открыть встречу и нажать «Пересоздать
    // заметки» в окне (с отрисовкой текста по мере генерации, как у пользователя).
    final regenerate = Platform.environment['ZNAIKA_REGENERATE'];
    if (regenerate != null && mounted) {
      final meeting = _meetings
          .where((m) => m.dir.path == Directory(regenerate).path)
          .firstOrNull;
      if (meeting == null) {
        stdout.writeln('SELFTEST regenerate: встреча не найдена');
        exit(1);
      }
      setState(() => _selected = meeting);
      final watch = Stopwatch()..start();
      await _regenerateNotes(meeting);
      stdout.writeln(
        'SELFTEST regenerate done in ${watch.elapsedMilliseconds} ms',
      );
      exit(0);
    }
  }

  /// [open] — папка встречи, которую надо открыть (только что записанная).
  Future<void> _reload({String? open}) async {
    final meetings = await _store.list();
    if (!mounted) return;
    setState(() {
      _meetings = meetings;
      final target = open ?? _selected?.dir.path;
      // Выбранная встреча могла обновиться (например, получила заголовок).
      _selected = target == null
          ? null
          : meetings.where((m) => m.dir.path == target).firstOrNull;
    });
    // Список — сразу; доступность чата — после чтения файлов встреч.
    unawaited(
      _anyAnalyzed(meetings).then((analyzed) {
        if (mounted && analyzed != _hasAnalyzed) {
          setState(() => _hasAnalyzed = analyzed);
        }
      }),
    );
    if (_query.isNotEmpty) await _runSearch();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(menus: _menus(), child: _window(context));
  }

  Widget _window(BuildContext context) {
    return Stack(
      children: [
        _windowContent(context),
        // Модель заметок — в заголовке окна, справа от кнопок «закрыть/свернуть/развернуть».
        const _SummaryModelLabel(),
      ],
    );
  }

  Widget _windowContent(BuildContext context) {
    return MacosWindow(
      sidebar: Sidebar(
        minWidth: 220,
        startWidth: 260,
        maxWidth: 380,
        // Список встреч — основа окна: мышью панель сужается только до minWidth.
        dragClosed: false,
        // Закреплено сверху: «Новая запись» и под ней поиск; прокручиваются только встречи.
        // macos_ui даёт верхней зоне 8 pt по бокам — добавляем до отступа строк списка.
        top: Padding(
          padding: const EdgeInsets.only(
            left: Gap.sidebarInset - 8,
            right: Gap.sidebarInset - 8,
            bottom: Gap.tiny,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: _recording,
                      builder: (context, recording, _) => _SidebarRow(
                        icon: recording
                            ? CupertinoIcons.circle_fill
                            : CupertinoIcons.mic,
                        iconColor: recording
                            ? MacosColors.systemRedColor.resolveFrom(context)
                            : null,
                        title: recording ? 'Идёт запись' : 'Новая запись',
                        selected: _selected == null && !_chatShown,
                        onTap: _showRecorder,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.tiny),
                  _SidebarRow(
                    icon: CupertinoIcons.chat_bubble_2,
                    title: 'Чат',
                    expand: false,
                    selected: _selected == null && _chatShown,
                    enabled: _chatUnavailable == null,
                    tooltip: _chatUnavailable,
                    onTap: _showChat,
                  ),
                ],
              ),
              const SizedBox(height: Gap.related),
              MacosSearchField(
                controller: _searchController,
                placeholder: 'Поиск',
              ),
            ],
          ),
        ),
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(
            Gap.sidebarInset,
            0,
            Gap.sidebarInset,
            Gap.related,
          ),
          children: [
            if (_hits case final hits?) ...[
              _SidebarSectionHeader(
                hits.isEmpty ? 'Ничего не найдено' : 'Найдено: ${hits.length}',
              ),
              for (final hit in hits)
                _SidebarRow(
                  title: hit.meeting.title,
                  snippet: hit.snippet,
                  subtitle: formatMeetingTime(hit.meeting.startedAt),
                  selected: hit.meeting.dir.path == _selected?.dir.path,
                  onTap: () => _open(hit.meeting),
                ),
            ] else ...[
              const _SidebarSectionHeader('Встречи'),
              if (_meetings.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.related,
                    vertical: Gap.tiny,
                  ),
                  child: Text(
                    'Записанные встречи появятся здесь.',
                    style: MacosTheme.of(context).typography.callout
                        .copyWith(color: secondaryLabel(context)),
                  ),
                ),
              for (final meeting in _meetings)
                _SidebarRow(
                  title: meeting.title,
                  subtitle: _notesJobs.containsKey(meeting.dir.path)
                      ? '${formatMeetingTime(meeting.startedAt)} · обработка…'
                      : formatMeetingTime(meeting.startedAt),
                  selected: meeting.dir.path == _selected?.dir.path,
                  onTap: () => _open(meeting),
                ),
            ],
          ],
        ),
        bottom: const _ModelDownloadStatus(),
      ),
      // Экран записи не пересоздаётся: запись идёт, пока смотришь прошлые встречи.
      child: IndexedStack(
        index: _selected != null ? 2 : (_chatShown ? 1 : 0),
        children: [
          RecorderPage(
            store: _store,
            recording: _recording,
            controller: _recorder,
            onRecorded: _processRecording,
          ),
          // Тоже не пересоздаётся: переписка остаётся, пока смотришь встречи.
          ChatPage(onOpenMeeting: _open),
          if (_selected != null)
            MeetingView(
              meeting: _selected!,
              actions: _actionsFor(_selected!),
              notesProgress: _notesJobs[_selected!.dir.path],
              renameRequests: _renameRequests,
              onEditingChanged: (editing) =>
                  setState(() => _renaming = editing),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// «Gemma 4 E4B 💻» рядом с кнопками окна: какая модель пишет заметки; иконка
/// ноутбука — модель встроенная, работает на этом Mac (подробности — в подсказке).
/// Положение кнопок окна спрашиваем у macOS: оно зависит от стиля заголовка окна.
class _SummaryModelLabel extends StatefulWidget {
  const _SummaryModelLabel();

  @override
  State<_SummaryModelLabel> createState() => _SummaryModelLabelState();
}

class _SummaryModelLabelState extends State<_SummaryModelLabel> {
  /// Правый край кнопки «развернуть» и вертикальный центр кнопок от верха окна.
  /// По умолчанию — как у окна с объединённым тулбаром (до ответа macOS и в тестах).
  double _left = 70;
  double _centerY = 26;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final zoom = await WindowManipulator.getStandardWindowButtonPosition(
        buttonType: NSWindowButtonType.zoomButton,
      );
      final titlebar = await WindowManipulator.getTitlebarHeight();
      if (!mounted) return;
      setState(() {
        _left = zoom.right;
        // y кнопки macOS отсчитывает от низа заголовка окна.
        _centerY = titlebar - zoom.top - zoom.height / 2;
      });
    } catch (_) {
      // Нет нативной части (тесты) — остаёмся на значениях по умолчанию.
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    const height = 20.0;
    return Positioned(
      left: _left + Gap.small,
      top: _centerY - height / 2,
      height: height,
      child: ListenableBuilder(
        listenable: Listenable.merge([summaryModelChoice, modelManager]),
        builder: (context, _) =>
            _label(context, typography, summaryModelChoice.effective.name),
      ),
    );
  }

  Widget _label(BuildContext context, MacosTypography typography, String name) {
    return MacosTooltip(
      message:
          '$name пишет заметки прямо на этом Mac — встроенная модель, без интернета '
          'и облака. Щёлкните, чтобы выбрать другую.',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => showMacosSheet<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) => const SummaryModelsSheet(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: typography.subheadline.copyWith(
                  fontWeight: FontWeight.w600,
                  color: secondaryLabel(context),
                ),
              ),
              const SizedBox(width: Gap.tiny),
              MacosIcon(
                CupertinoIcons.device_laptop,
                size: 13,
                color: tertiaryLabel(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Подпись раздела в боковой панели, как «Избранное» в Finder.
class _SidebarSectionHeader extends StatelessWidget {
  const _SidebarSectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    // По горизонтали — как текст строк (их внутренний отступ Gap.related).
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Gap.related,
        Gap.small,
        Gap.related,
        Gap.tiny,
      ),
      child: Text(
        text,
        style: MacosTheme.of(context).typography.subheadline.copyWith(
          fontWeight: FontWeight.w600,
          color: tertiaryLabel(context),
        ),
      ),
    );
  }
}

/// Строка боковой панели: выделение — системным акцентным цветом, как в Finder и Заметках.
class _SidebarRow extends StatefulWidget {
  const _SidebarRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.snippet,
    this.icon,
    this.iconColor,
    this.expand = true,
    this.enabled = true,
    this.tooltip,
  });

  /// false — строка бледная и не нажимается (почему — в [tooltip]).
  final bool enabled;
  final String? tooltip;

  final String title;

  /// false — по ширине содержимого (короткая кнопка рядом с другой строкой).
  final bool expand;
  final String? subtitle;

  /// Фрагмент найденного текста; совпадения обрамлены \u0001…\u0002.
  final String? snippet;
  final IconData? icon;
  final Color? iconColor;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final typography = theme.typography;
    final selected = widget.selected;
    final onAccent = MacosColors.white;
    final background = selected
        ? theme.primaryColor
        : (_hovered
              ? (isDark(context)
                    ? const Color(0x14FFFFFF)
                    : const Color(0x0F000000))
              : null);
    final row = MouseRegion(
      onEnter: (_) => setState(() => _hovered = widget.enabled),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: Opacity(
          opacity: widget.enabled ? 1 : 0.4,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: EdgeInsets.symmetric(
              horizontal: Gap.related,
              vertical: widget.subtitle == null ? 6 : 5,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  MacosIcon(
                    widget.icon!,
                    size: 16,
                    color: selected
                        ? onAccent
                        : (widget.iconColor ?? theme.primaryColor),
                  ),
                  const SizedBox(width: Gap.related),
                ],
                Flexible(
                  fit: widget.expand ? FlexFit.tight : FlexFit.loose,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.body.copyWith(
                          color: selected ? onAccent : null,
                        ),
                      ),
                      if (widget.snippet != null)
                        Text.rich(
                          _highlight(
                            widget.snippet!,
                            typography.callout.copyWith(
                              color: selected ? onAccent : null,
                            ),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (widget.subtitle != null)
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typography.callout.copyWith(
                            color: selected
                                ? onAccent.withValues(alpha: 0.8)
                                : secondaryLabel(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final tooltip = widget.tooltip;
    return tooltip == null ? row : MacosTooltip(message: tooltip, child: row);
  }
}

/// Фрагмент из поиска: совпадения (\u0001…\u0002) — полужирным.
TextSpan _highlight(String snippet, TextStyle style) {
  final spans = <TextSpan>[];
  for (final (i, part) in snippet.split(RegExp('[\u0001\u0002]')).indexed) {
    if (part.isEmpty) continue;
    // Нечётные части — внутри маркеров, то есть совпадения.
    spans.add(
      TextSpan(
        text: part,
        style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null,
      ),
    );
  }
  return TextSpan(style: style, children: spans);
}

/// Пока какая-то модель докачивается — прогресс внизу боковой панели.
class _ModelDownloadStatus extends StatelessWidget {
  const _ModelDownloadStatus();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: modelManager,
      builder: (context, _) {
        // Первая недокачанная обязательная модель (они качаются по очереди),
        // иначе — модель для заметок, которую выбрали скачать.
        bool active(ModelPackage p) =>
            modelManager.stateOf(p).status == PackageStatus.downloading ||
            modelManager.stateOf(p).status == PackageStatus.queued;
        final package =
            modelManager.requiredPackages
                .where(
                  (p) => modelManager.stateOf(p).status != PackageStatus.ready,
                )
                .firstOrNull ??
            allPackages
                .where(
                  (p) =>
                      !modelManager.requiredPackages.contains(p) && active(p),
                )
                .firstOrNull;
        if (selftestMode || package == null) return const SizedBox.shrink();
        final state = modelManager.stateOf(package);
        if (state.status == PackageStatus.checking) {
          return const SizedBox.shrink();
        }
        final typography = MacosTheme.of(context).typography;
        final percent = (state.received * 100 / package.size).floor();
        final name = package.title;
        final text = switch (state.status) {
          PackageStatus.downloading => '$name: $percent%',
          PackageStatus.queued => '$name: в очереди',
          PackageStatus.failed => '$name: не скачалось',
          _ => '$name: не скачано',
        };
        final isActive = active(package);
        // Отступы вокруг нижней зоны боковой панели задаёт macos_ui (16 pt).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              text,
              style: typography.callout.copyWith(
                color: secondaryLabel(context),
              ),
            ),
            const SizedBox(height: Gap.tiny),
            ProgressBar(value: state.received * 100 / package.size, height: 4),
            if (!isActive &&
                modelManager.requiredPackages.contains(package)) ...[
              const SizedBox(height: Gap.related),
              Align(
                alignment: Alignment.centerLeft,
                child: PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: modelManager.start,
                  child: const Text('Продолжить загрузку'),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Сигнал без значения: «начать переименование» из строки меню.
class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}
