import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:macos_ui/macos_ui.dart';

import 'app_globals.dart';
import 'log.dart';
import 'meeting_chat.dart';
import 'meeting_view.dart';
import 'meetings.dart';
import 'summarizer.dart';
import 'ui.dart';

/// Демо-переписка для скриншотов README (test/readme_screenshots_test.dart): вопросы,
/// готовые ответы и встречи-источники. В приложении не используется.
@visibleForTesting
List<({String question, String answer, List<Meeting> sources})>? debugChatDemo;

/// Вопрос в чате и ответ на него, пока он пишется.
class _Turn {
  _Turn(this.question);

  final String question;
  String answer = '';
  List<ChatSource> sources = const [];

  /// Что происходит сейчас («Ищу во встречах…»); null — ответ пишется или готов.
  String? status = 'Ищу во встречах…';
  String? error;
  bool done = false;
}

/// Чат по прошедшим встречам, как в Foresight: вопрос — ответ Gemma по заметкам
/// и расшифровкам, под ответом встречи-источники (щелчок открывает встречу).
/// Всё на этом Mac; переписка живёт, пока открыто приложение.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.onOpenMeeting});

  final void Function(Meeting meeting) onOpenMeeting;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _turns = <_Turn>[];
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  ScrollController? _scroll;
  NotesStop? _stop;

  bool get _answering => _stop != null;

  @override
  void initState() {
    super.initState();
    for (final demo in debugChatDemo ?? const <({String question, String answer, List<Meeting> sources})>[]) {
      _turns.add(_Turn(demo.question)
        ..answer = demo.answer
        ..sources = [for (final m in demo.sources) ChatSource(m)]
        ..status = null
        ..done = true);
    }
  }

  static const _suggestions = [
    'Что решили на последней встрече?',
    'Какие задачи на мне?',
    'О чём говорили на этой неделе?',
  ];

  @override
  void dispose() {
    _stop?.stop();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _ask(String text) async {
    final question = text.trim();
    if (question.isEmpty || _answering) return;
    final history = [
      for (final t in _turns)
        if (t.done && t.error == null) ChatTurn(t.question, t.answer, t.sources),
    ];
    final turn = _Turn(question);
    final stop = NotesStop();
    setState(() {
      _turns.add(turn);
      _stop = stop;
      _input.clear();
    });
    _scrollToEnd(force: true);
    try {
      if (!selftestMode && !modelManager.isReady(summaryModelChoice.effective.package)) {
        throw StateError('Модель для заметок ещё скачивается — спросите, когда загрузка закончится.');
      }
      final meetings = await meetingStore.list();
      if (meetings.isEmpty) throw StateError('Записанных встреч пока нет — спрашивать не о чем.');
      final sources = await findChatSources(
        meetingStore,
        question,
        previous: history.isEmpty ? const [] : [for (final s in history.last.sources) s.meeting],
      );
      setState(() {
        turn.sources = sources;
        turn.status = summarizer.busy
            ? 'Gemma пишет заметки — отвечу, как только допишет текущую часть…'
            : 'Читаю ${_meetingsWord(sources.length)}…';
      });
      final prompt = chatPrompt(question, sources, history, DateTime.now());
      final answer = await summarizer.answer(
        prompt,
        system: chatSystem,
        stop: stop,
        onStart: () {
          if (mounted) setState(() => turn.status = 'Читаю ${_meetingsWord(sources.length)}…');
        },
        onText: (text) {
          if (!mounted) return;
          setState(() {
            turn.status = null;
            turn.answer = text;
          });
          _scrollToEnd();
        },
      );
      turn.answer = answer.trim();
    } on NotesStopped {
      if (turn.answer.isEmpty) turn.error = 'Остановлено.';
    } catch (e) {
      logLine('Чат: не удалось ответить: $e');
      turn.error = e is StateError ? e.message : 'Не удалось ответить: $e';
    } finally {
      if (mounted) {
        setState(() {
          turn.status = null;
          turn.done = true;
          _stop = null;
        });
        _inputFocus.requestFocus();
      }
    }
  }

  void _newChat() {
    setState(_turns.clear);
    _inputFocus.requestFocus();
  }

  /// Вниз к новому тексту — если пользователь и так внизу (или задал вопрос).
  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scroll = _scroll;
      if (scroll == null || !scroll.hasClients) return;
      if (force || scroll.position.extentAfter < 200) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MacosScaffold(
      toolBar: ToolBar(
        title: const Text('Чат по встречам'),
        titleWidth: 300,
        actions: [
          ToolBarIconButton(
            label: 'Новый чат',
            icon: const MacosIcon(CupertinoIcons.square_pencil),
            showLabel: false,
            tooltipMessage: 'Новый чат',
            onPressed: _turns.isEmpty || _answering ? null : _newChat,
          ),
        ],
      ),
      children: [
        ContentArea(
          builder: (context, scrollController) {
            _scroll = scrollController;
            return Column(
              children: [
                Expanded(
                  child: _turns.isEmpty
                      ? _EmptyChat(suggestions: _suggestions, onPick: _ask)
                      : PageContent(
                          controller: scrollController,
                          children: [
                            for (final (i, turn) in _turns.indexed) ...[
                              if (i > 0) const SizedBox(height: Gap.group),
                              _QuestionBubble(turn.question),
                              const SizedBox(height: Gap.small),
                              _Answer(turn: turn, onOpenMeeting: widget.onOpenMeeting),
                            ],
                          ],
                        ),
                ),
                _Composer(
                  controller: _input,
                  focusNode: _inputFocus,
                  answering: _answering,
                  onSend: () => _ask(_input.text),
                  onStop: () => _stop?.stop(),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// «1 встречу», «3 встречи», «5 встреч».
String _meetingsWord(int n) {
  final word = n % 10 == 1 && n % 100 != 11
      ? 'встречу'
      : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14) ? 'встречи' : 'встреч');
  return '$n $word';
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.suggestions, required this.onPick});

  final List<String> suggestions;
  final void Function(String question) onPick;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.group),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MacosIcon(
                CupertinoIcons.chat_bubble_2,
                size: 40,
                color: tertiaryLabel(context),
              ),
              const SizedBox(height: Gap.small),
              Text('Спросите о прошедших встречах', style: typography.title2, textAlign: TextAlign.center),
              const SizedBox(height: Gap.line),
              Text(
                'Gemma ответит по заметкам и расшифровкам и покажет, на каких встречах это было. '
                'Всё работает на этом Mac.',
                textAlign: TextAlign.center,
                style: typography.body.copyWith(color: secondaryLabel(context)),
              ),
              const SizedBox(height: Gap.group),
              for (final s in suggestions) ...[
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
                  onPressed: () => onPick(s),
                  child: Text(s),
                ),
                const SizedBox(height: Gap.tiny),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Вопрос пользователя — справа, в пузыре цвета акцента, как в «Сообщениях».
class _QuestionBubble extends StatelessWidget {
  const _QuestionBubble(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.75),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.small, vertical: Gap.related),
            decoration: BoxDecoration(
              color: theme.primaryColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              text,
              style: theme.typography.body.copyWith(color: MacosColors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ответ: этап, текст по мере генерации и встречи-источники.
class _Answer extends StatelessWidget {
  const _Answer({required this.turn, required this.onOpenMeeting});

  final _Turn turn;
  final void Function(Meeting meeting) onOpenMeeting;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.status case final status?) ActivityRow(status),
        if (turn.answer.isNotEmpty) SummaryMarkdown(turn.answer),
        if (turn.error case final error?)
          Text(error, style: typography.body.copyWith(color: secondaryLabel(context))),
        // Под ответом — встречи, на которые он ссылается (номера как в тексте).
        if (turn.done && turn.error == null)
          if (citedSources(turn.answer, turn.sources.length) case final cited when cited.isNotEmpty) ...[
            const SizedBox(height: Gap.small),
            Text('Источники', style: typography.callout.copyWith(color: secondaryLabel(context))),
            const SizedBox(height: Gap.tiny),
            for (final n in cited..sort())
              _SourceRow(
                number: n,
                meeting: turn.sources[n - 1].meeting,
                onTap: () => onOpenMeeting(turn.sources[n - 1].meeting),
              ),
          ],
      ],
    );
  }
}

class _SourceRow extends StatefulWidget {
  const _SourceRow({required this.number, required this.meeting, required this.onTap});

  final int number;
  final Meeting meeting;
  final VoidCallback onTap;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final typography = theme.typography;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '[${widget.number}]',
                  style: typography.callout.copyWith(color: secondaryLabel(context)),
                ),
              ),
              Flexible(
                child: Text(
                  widget.meeting.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.callout.copyWith(
                    color: theme.primaryColor,
                    decoration: _hovered ? TextDecoration.underline : null,
                    decorationColor: theme.primaryColor,
                  ),
                ),
              ),
              Text(
                ' · ${formatMeetingTime(widget.meeting.startedAt)}',
                style: typography.callout.copyWith(color: secondaryLabel(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Поле вопроса внизу: Return — отправить; пока Gemma отвечает — «Остановить».
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.answering,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool answering;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.group, Gap.small, Gap.group, Gap.group),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
      child: Row(
        children: [
          Expanded(
            child: MacosTextField(
              controller: controller,
              focusNode: focusNode,
              placeholder: 'Спросите о встречах…',
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: Gap.related),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => answering
                ? MacosIconButton(
                    semanticLabel: 'Остановить ответ',
                    icon: MacosIcon(CupertinoIcons.stop_circle_fill, size: 24, color: theme.primaryColor),
                    boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    onPressed: onStop,
                  )
                : MacosIconButton(
                    semanticLabel: 'Отправить вопрос',
                    icon: MacosIcon(
                      CupertinoIcons.arrow_up_circle_fill,
                      size: 24,
                      color: controller.text.trim().isEmpty ? tertiaryLabel(context) : theme.primaryColor,
                    ),
                    boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    onPressed: controller.text.trim().isEmpty ? null : onSend,
                  ),
          ),
        ],
      ),
    );
  }
}
