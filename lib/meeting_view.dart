import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import 'meetings.dart';
import 'speaker_hints.dart';
import 'ui.dart';

/// Действия со встречей; выполняет их главное окно (HomePage).
class MeetingActions {
  const MeetingActions({
    required this.rename,
    required this.renameSpeaker,
    this.regenerateNotes,
    this.stopNotes,
    required this.export,
    required this.copyNotes,
    required this.delete,
  });

  final Future<void> Function(String title) rename;

  /// Собеседник [from] получает имя [to] во всей встрече.
  final Future<void> Function(String from, String to) renameSpeaker;

  /// Gemma заново пишет заметки; null — они пересоздаются прямо сейчас.
  final VoidCallback? regenerateNotes;

  /// Остановить пересоздание заметок: прежние остаются.
  final VoidCallback? stopNotes;
  final VoidCallback export;
  final VoidCallback copyNotes;
  final VoidCallback delete;
}

/// Заметки встречи пересоздаются: этап («Пишу выжимку…») и написанное на сейчас.
class NotesProgress {
  final String stage;
  final String text;

  const NotesProgress(this.stage, [this.text = '']);
}

/// Просмотр прошлой встречи: заголовок в тулбаре, дата, выжимка и свёрнутая расшифровка.
/// Заголовок — в начале страницы; переименовывается на месте: карандаш рядом
/// с заголовком, двойной клик по нему или пункт меню.
class MeetingView extends StatefulWidget {
  const MeetingView({
    super.key,
    required this.meeting,
    required this.actions,
    this.renameRequests,
    this.onEditingChanged,
    this.notesProgress,
  });

  final Meeting meeting;
  final MeetingActions actions;

  /// Сигнал «начать переименование» из строки меню.
  final Listenable? renameRequests;

  /// Началось или закончилось переименование: пока оно идёт, главное окно выключает
  /// пункт меню «Удалить встречу» (⌘⌫), иначе его клавиши перехватят ⌘⌫ у поля ввода.
  final ValueChanged<bool>? onEditingChanged;

  /// Заметки сейчас пересоздаются — вместо прежних показываются новые по мере генерации.
  final NotesProgress? notesProgress;

  @override
  State<MeetingView> createState() => _MeetingViewState();
}

class _MeetingViewState extends State<MeetingView> {
  bool _editing = false;
  final _titleController = TextEditingController();
  final _titleFocus = FocusNode();

  /// Заметки, расшифровка и пометка «заметки устарели». Перечитываются, когда главное окно
  /// передаёт новый объект встречи (после правок), а не на каждый кадр генерации.
  late Future<List<Object?>> _data = _load();

  Future<List<Object?>> _load() => Future.wait([
        widget.meeting.readSummary(),
        widget.meeting.readTranscript(),
        widget.meeting.notesOutdated(),
      ]);

  @override
  void initState() {
    super.initState();
    widget.renameRequests?.addListener(_startRename);
    // Как в Finder: щелчок мимо поля сохраняет новое имя.
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editing) _commitRename();
    });
  }

  @override
  void didUpdateWidget(MeetingView old) {
    super.didUpdateWidget(old);
    if (!identical(old.meeting, widget.meeting)) _data = _load();
    if (old.renameRequests != widget.renameRequests) {
      old.renameRequests?.removeListener(_startRename);
      widget.renameRequests?.addListener(_startRename);
    }
    // Выбрали другую встречу посреди переименования — правку бросаем.
    if (old.meeting.dir.path != widget.meeting.dir.path && _editing) {
      _setEditing(false);
    }
  }

  @override
  void dispose() {
    widget.renameRequests?.removeListener(_startRename);
    _titleController.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _setEditing(bool editing) {
    _editing = editing;
    widget.onEditingChanged?.call(editing);
  }

  void _startRename() {
    setState(() {
      _setEditing(true);
      _titleController
        ..text = widget.meeting.title
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.meeting.title.length,
        );
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _titleFocus.requestFocus(),
    );
  }

  Future<void> _commitRename() async {
    final title = _titleController.text.trim();
    setState(() => _setEditing(false));
    // Пустой или прежний заголовок — ничего не меняем.
    if (title.isEmpty || title == widget.meeting.title) return;
    await widget.actions.rename(title);
  }

  void _cancelRename() => setState(() => _setEditing(false));

  /// Диалог «Как зовут собеседника?». Пока он открыт, ⌘⌫ в поле не удаляет встречу.
  Future<void> _nameSpeaker(String speaker, List<String> speakers, {String? hint}) async {
    widget.onEditingChanged?.call(true);
    final name = await showMacosAlertDialog<String>(
      context: context,
      builder: (context) => _SpeakerNameDialog(
        speaker: speaker,
        hint: hint,
        others: [
          for (final s in speakers)
            if (s != speaker) s,
        ],
      ),
    );
    widget.onEditingChanged?.call(false);
    if (name != null && name != speaker) await widget.actions.renameSpeaker(speaker, name);
  }

  @override
  Widget build(BuildContext context) {
    final meeting = widget.meeting;
    final actions = widget.actions;
    return MacosScaffold(
      toolBar: ToolBar(
        actions: [
          ToolBarIconButton(
            label: 'Экспортировать',
            icon: const MacosIcon(CupertinoIcons.square_arrow_up),
            showLabel: false,
            tooltipMessage: 'Экспортировать в Markdown',
            onPressed: actions.export,
          ),
          ToolBarIconButton(
            label: 'Пересоздать заметки',
            icon: const MacosIcon(CupertinoIcons.arrow_clockwise),
            showLabel: false,
            tooltipMessage: 'Пересоздать заметки',
            onPressed: actions.regenerateNotes,
          ),
          ToolBarIconButton(
            label: 'Скопировать заметки',
            icon: const MacosIcon(CupertinoIcons.doc_on_clipboard),
            showLabel: false,
            tooltipMessage: 'Скопировать заметки',
            onPressed: actions.copyNotes,
          ),
          ToolBarIconButton(
            label: 'Удалить',
            icon: const MacosIcon(CupertinoIcons.trash),
            showLabel: false,
            tooltipMessage: 'Удалить встречу',
            onPressed: actions.delete,
          ),
        ],
      ),
      children: [
        ContentArea(
          builder: (context, scrollController) => FutureBuilder(
            // Ключ — папка встречи: при выборе другой встречи данные перечитываются.
            key: ValueKey(meeting.dir.path),
            future: _data,
            builder: (context, snapshot) {
              final typography = MacosTheme.of(context).typography;
              final progress = widget.notesProgress;
              final summary = snapshot.data?[0] as String?;
              final transcript = snapshot.data?[1] as List<String>? ?? const [];
              final outdated = snapshot.data?[2] == true;
              final speakers = speakersOf(transcript);
              final hints = {for (final h in suggestSpeakerNames(transcript)) h.speaker: h};
              final subtitle = [
                formatMeetingTime(meeting.startedAt),
                if (meeting.durationSeconds != null)
                  formatDuration(meeting.durationSeconds!),
              ].join(' · ');
              return PageContent(
                controller: scrollController,
                children: [
                  if (_editing)
                    CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.escape):
                            _cancelRename,
                      },
                      child: MacosTextField(
                        controller: _titleController,
                        focusNode: _titleFocus,
                        style: typography.title1,
                        placeholder: 'Название встречи',
                        onSubmitted: (_) => _commitRename(),
                      ),
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: GestureDetector(
                            onDoubleTap: _startRename,
                            child: Text(
                              meeting.title,
                              style: typography.title1,
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.related),
                        // По высоте — к середине первой строки заголовка.
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: _PencilButton(onPressed: _startRename),
                        ),
                      ],
                    ),
                  const SizedBox(height: Gap.tiny),
                  Text(
                    subtitle,
                    style: typography.body.copyWith(
                      color: secondaryLabel(context),
                    ),
                  ),
                  if (speakers.isNotEmpty) ...[
                    const SizedBox(height: Gap.small),
                    _Participants(
                      speakers: speakers,
                      hints: hints,
                      onPressed: (s) => _nameSpeaker(s, speakers, hint: hints[s]?.name),
                      onAcceptHint: (h) => widget.actions.renameSpeaker(h.speaker, h.name),
                    ),
                  ],
                  const SizedBox(height: Gap.group),
                  // Пока данные перечитываются, остаются прежние — без мигания «Загрузка…».
                  if (snapshot.data == null)
                    const ActivityRow('Загрузка…')
                  else if (progress != null) ...[
                    Row(
                      children: [
                        Expanded(child: ActivityRow(progress.stage)),
                        const SizedBox(width: Gap.small),
                        PushButton(
                          controlSize: ControlSize.regular,
                          secondary: true,
                          onPressed: actions.stopNotes,
                          child: const Text('Остановить'),
                        ),
                      ],
                    ),
                    if (progress.text.isNotEmpty) ...[
                      const SizedBox(height: Gap.group),
                      SummaryMarkdown(progress.text),
                    ],
                  ] else if (summary == null || summary.isEmpty)
                    Text(
                      transcript.isEmpty
                          ? 'Речи в записи не найдено.'
                          : 'Заметок по этой встрече нет.',
                      style: typography.body.copyWith(
                        color: secondaryLabel(context),
                      ),
                    )
                  else ...[
                    if (outdated) ...[
                      Callout(
                        text: 'Собеседники получили имена после того, как были написаны заметки: '
                            'имена подставлены без склонения. Gemma может написать заметки заново.',
                        action: PushButton(
                          controlSize: ControlSize.regular,
                          onPressed: actions.regenerateNotes,
                          child: const Text('Пересоздать заметки'),
                        ),
                      ),
                      const SizedBox(height: Gap.group),
                    ],
                    SummaryMarkdown(summary),
                  ],
                  if (transcript.isNotEmpty) ...[
                    const SizedBox(height: Gap.group),
                    Disclosure(
                      title: 'Расшифровка · ${transcript.length} реплик',
                      child: TranscriptLines(transcript),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// «Участники: Я, [Собеседник 1] [Анна]» — щелчок по собеседнику даёт ему имя.
class _Participants extends StatelessWidget {
  const _Participants({
    required this.speakers,
    required this.onPressed,
    this.hints = const {},
    this.onAcceptHint,
  });

  final List<String> speakers;
  final ValueChanged<String> onPressed;

  /// Подсказки имён по обращениям («Слушай, Кость, возьмёшь?» → ответил этот голос).
  final Map<String, SpeakerNameHint> hints;
  final ValueChanged<SpeakerNameHint>? onAcceptHint;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Wrap(
      spacing: Gap.related,
      runSpacing: Gap.tiny,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Участники:',
          style: typography.body.copyWith(color: secondaryLabel(context)),
        ),
        Text('Я', style: typography.body),
        for (final speaker in speakers) ...[
          MacosTooltip(
            message: 'Указать имя',
            child: PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: () => onPressed(speaker),
              child: Text(speaker),
            ),
          ),
          if (hints[speaker] case final hint?)
            _HintButton(hint: hint, onPressed: () => onAcceptHint?.call(hint)),
        ],
      ],
    );
  }
}

/// «Костя?» рядом с собеседником: щелчок даёт ему это имя; в подсказке — откуда оно.
class _HintButton extends StatefulWidget {
  const _HintButton({required this.hint, required this.onPressed});

  final SpeakerNameHint hint;
  final VoidCallback onPressed;

  @override
  State<_HintButton> createState() => _HintButtonState();
}

class _HintButtonState extends State<_HintButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hint = widget.hint;
    final times = hint.votes == 1 ? 'раз' : 'раза';
    final color = MacosTheme.of(context).primaryColor;
    return MacosTooltip(
      message: 'Похоже, это ${hint.name}: после обращения по имени отвечал этот голос '
          '(${hint.votes} $times). Например:\n${hint.evidence}\n\nЩёлкните, чтобы назвать.',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Text(
            '${hint.name}?',
            style: MacosTheme.of(context).typography.body.copyWith(
                  color: color,
                  decoration: _hovered ? TextDecoration.underline : null,
                  decorationColor: color,
                ),
          ),
        ),
      ),
    );
  }
}

/// Имя собеседника: поле ввода с прежней меткой, Enter — сохранить, Esc — отменить.
class _SpeakerNameDialog extends StatefulWidget {
  const _SpeakerNameDialog({required this.speaker, required this.others, this.hint});

  final String speaker;
  final List<String> others;

  /// Подсказанное имя — сразу в поле.
  final String? hint;

  @override
  State<_SpeakerNameDialog> createState() => _SpeakerNameDialogState();
}

class _SpeakerNameDialogState extends State<_SpeakerNameDialog> {
  late final _controller = TextEditingController(
    // Метку «Собеседник N» сразу заменяют — поле пустое; готовое имя — для правки.
    text: widget.hint ?? (widget.speaker.startsWith('Собеседник') ? '' : widget.speaker),
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _name => cleanSpeakerName(_controller.text);

  void _save() {
    final name = _name;
    if (name != null) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final name = _name;
    final merges = name != null && widget.others.contains(name);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.person_crop_circle, size: 48),
        title: Text('Как зовут «${widget.speaker}»?', textAlign: TextAlign.center),
        message: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              merges
                  ? 'Реплики объединятся с «$name» — если это один и тот же человек.'
                  : 'Имя заменит метку в расшифровке и заметках.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.small),
            MacosTextField(
              controller: _controller,
              autofocus: true,
              placeholder: 'Имя',
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: name == null ? null : _save,
          child: Text(merges ? 'Объединить' : 'Сохранить'),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отменить'),
        ),
      ),
    );
  }
}

/// Небольшой карандаш рядом с заголовком: серый, при наведении — акцентного цвета.
class _PencilButton extends StatefulWidget {
  const _PencilButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_PencilButton> createState() => _PencilButtonState();
}

class _PencilButtonState extends State<_PencilButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MacosTooltip(
      message: 'Переименовать',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: MacosIcon(
            CupertinoIcons.pencil,
            size: 16,
            color: _hovered
                ? MacosTheme.of(context).primaryColor
                : tertiaryLabel(context),
          ),
        ),
      ),
    );
  }
}

/// Реплики «[мм:сс] Кто: текст»: время — серым моноширинными цифрами, говорящий — полужирным.
/// [pending] — черновики звучащих фраз: серым курсивом с многоточием, после остальных.
class TranscriptLines extends StatelessWidget {
  const TranscriptLines(this.lines, {super.key, this.pending = const []});

  final List<String> lines;
  final List<String> pending;

  static final _line = RegExp(r'^\[([\d:]+)\]\s+([^:]+):\s+(.*)$');

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final secondary = secondaryLabel(context);
    final timeStyle = typography.body.copyWith(
      color: secondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // Колонка времени — по самой широкой отметке («1:05:23» у встреч длиннее часа) и отступ.
    final widest = [...lines, ...pending]
        .map((l) => _line.firstMatch(l)?[1] ?? '')
        .fold('00:00', (a, b) => b.length > a.length ? b : a);
    final timeWidth = (TextPainter(
          text: TextSpan(text: widest, style: timeStyle),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout())
            .width
            .ceilToDouble() +
        Gap.small;
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, line) in [...lines, ...pending].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.related),
              child: switch (_line.firstMatch(line)) {
                final m? => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: timeWidth,
                      child: Text(m[1]!, style: timeStyle, softWrap: false),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: index < lines.length
                              ? typography.body
                              : typography.body.copyWith(
                                  color: secondary,
                                  fontStyle: FontStyle.italic,
                                ),
                          children: [
                            TextSpan(
                              text: '${m[2]}  ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: index < lines.length ? m[3] : '${m[3]}…',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                _ => Text(line, style: typography.body),
              },
            ),
        ],
      ),
    );
  }
}

/// Рендер Markdown выжимки: заголовки «##», списки «-»/«*», задачи «- [ ]» и **жирный**.
/// Больше в выжимках Gemma по нашим промптам не встречается.
class SummaryMarkdown extends StatelessWidget {
  const SummaryMarkdown(this.markdown, {super.key});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final blocks = <Widget>[];
    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      final indent = (line.length - line.trimLeft().length) ~/ 2;
      final text = line.trimLeft();
      final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(text);
      final task = RegExp(r'^[-*]\s+\[( |x|X)\]\s+(.*)$').firstMatch(text);
      final bullet = RegExp(r'^[-*]\s+(.*)$').firstMatch(text);
      if (heading != null) {
        blocks.add(
          Padding(
            padding: EdgeInsets.only(
              top: blocks.isEmpty ? 0 : Gap.group,
              bottom: Gap.related,
            ),
            child: Text(
              heading[1]!,
              style: typography.title3.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        );
      } else if (task != null) {
        final done = task[1] != ' ';
        blocks.add(
          _item(
            context,
            indent,
            done ? CupertinoIcons.checkmark_square : CupertinoIcons.square,
            task[2]!,
          ),
        );
      } else if (bullet != null) {
        blocks.add(_item(context, indent, null, bullet[1]!));
      } else {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.related),
            child: Text.rich(_inline(text, typography.body)),
          ),
        );
      }
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: blocks,
      ),
    );
  }

  Widget _item(BuildContext context, int indent, IconData? icon, String text) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: EdgeInsets.only(left: 18.0 * indent, bottom: Gap.tiny),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: icon != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: MacosIcon(
                      icon,
                      size: 14,
                      color: secondaryLabel(context),
                    ),
                  )
                : Text(
                    '•',
                    style: typography.body.copyWith(
                      color: secondaryLabel(context),
                    ),
                  ),
          ),
          Expanded(child: Text.rich(_inline(text, typography.body))),
        ],
      ),
    );
  }

  /// **жирный** → полужирный шрифт.
  TextSpan _inline(String text, TextStyle style) {
    final spans = <TextSpan>[];
    final bold = RegExp(r'\*\*(.+?)\*\*');
    var last = 0;
    for (final m in bold.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        TextSpan(
          text: m[1],
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: style, children: spans);
  }
}
