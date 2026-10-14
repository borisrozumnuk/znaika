import 'meetings.dart';

/// Чат по прошедшим встречам: на вопрос Gemma отвечает по заметкам и фрагментам
/// расшифровок подходящих встреч. Встречи подбираются полнотекстовым поиском (FTS5,
/// тот же индекс, что у поиска в боковой панели) и по датам из вопроса («вчера»,
/// «на прошлой неделе»); не нашлось ничего — берутся последние встречи.
/// Foresight ищет эмбеддингами (EmbeddingGemma) — это ещё одна модель на скачивание;
/// для вопросов по своим встречам обычно хватает слов из вопроса.

/// Встреча, по которой отвечает модель: её заметки и реплики со словами из вопроса.
class ChatSource {
  final Meeting meeting;
  final String summary;
  final List<String> lines;

  const ChatSource(this.meeting, {this.summary = '', this.lines = const []});
}

/// Вопрос и ответ в чате; [sources] — встречи, по которым ответ написан (номера [1], [2]…).
class ChatTurn {
  final String question;
  final String answer;
  final List<ChatSource> sources;

  const ChatTurn(this.question, this.answer, this.sources);
}

/// Сколько встреч и текста отдаём модели: контекст 8192 токена, из них ~1000 — на ответ.
const _maxSources = 5;
const _contextChars = 13000;
const _summaryChars = 3500;
const _linesPerMeeting = 12;

const chatSystem = '''Ты помощник по прошедшим встречам пользователя. Отвечаешь по-русски на его вопросы только по материалам встреч из запроса: заметкам и фрагментам расшифровок.
- В расшифровках «Я» — сам пользователь; обращайся к нему на «вы».
- Отвечай кратко и по делу, списком, если пунктов несколько.
- После каждого факта ставь номер встречи из материалов в квадратных скобках, например [2]. Таймкоды реплик в ответ не пиши.
- Если в материалах ответа нет, так и скажи; ничего не придумывай.''';

/// Слова, по которым не ищем: служебные, вопросительные, «встреча/обсуждали» — они есть
/// почти в любом вопросе о встречах, — и заголовки разделов заметок («Задачи», «Решения»):
/// по ним нашлась бы любая встреча. Сравнение по началу слова.
const _stopStems = [
  'задач', 'решени', 'вопрос', 'открыт', 'кратк',
  'встреч', 'созвон', 'обсужд', 'обсуди', 'говори', 'расска', 'напомн', 'скажи', 'подскаж',
  'последн', 'недавн', 'недел', 'месяц', 'сегодн', 'вчера', 'позавчер', 'можешь', 'какие',
  'какой', 'какая', 'каких', 'какое', 'каким', 'которы', 'нужно', 'надо', 'было', 'были', 'была',
];
const _stopWords = {
  'что', 'как', 'где', 'когда', 'кто', 'чем', 'чего', 'кого', 'кому', 'зачем', 'почему', 'ли',
  'мы', 'я', 'ты', 'вы', 'он', 'она', 'они', 'оно', 'мне', 'меня', 'мной', 'нам', 'нас', 'нами',
  'вам', 'вас', 'им', 'их', 'его', 'ее', 'её', 'на', 'в', 'во', 'по', 'о', 'об', 'обо', 'про', 'с',
  'со', 'к', 'ко', 'у', 'за', 'из', 'от', 'до', 'для', 'при', 'над', 'под', 'без', 'и', 'а', 'но',
  'или', 'не', 'ни', 'да', 'нет', 'это', 'этот', 'эта', 'эти', 'этой', 'этом', 'этого', 'тот',
  'та', 'те', 'то', 'был', 'быть', 'есть', 'будет', 'мой', 'моя', 'мои', 'моих', 'наш', 'наша',
  'наши', 'наших', 'все', 'всё', 'всех', 'весь', 'вся', 'там', 'тут', 'так', 'же', 'бы', 'уже',
  'ещё', 'еще', 'прошлой', 'прошлую', 'прошлом', 'прошлый', 'итоги', 'итог', 'решили', 'договорились',
};

/// Слова вопроса для поиска встреч, без служебных и общих для всех вопросов.
List<String> chatKeywords(String question) => [
      for (final word in normalizeForSearch(question.toLowerCase())
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        if (word.length >= 3 &&
            !_stopWords.contains(word) &&
            !_stopStems.any((stem) => word.startsWith(normalizeForSearch(stem))))
          word,
    ];

/// Период из вопроса: «сегодня», «вчера», «позавчера», «на этой/прошлой неделе»,
/// «в этом/прошлом месяце». null — дат в вопросе нет.
({DateTime from, DateTime to})? chatPeriod(String question, DateTime now) {
  final q = normalizeForSearch(question.toLowerCase());
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(int offset) => DateTime(today.year, today.month, today.day + offset);
  final monday = day(1 - today.weekday);
  if (q.contains('позавчера')) return (from: day(-2), to: day(-1));
  if (q.contains('вчера')) return (from: day(-1), to: today);
  if (q.contains('сегодня')) return (from: today, to: day(1));
  if (RegExp(r'прошл\S* недел').hasMatch(q)) {
    return (from: DateTime(monday.year, monday.month, monday.day - 7), to: monday);
  }
  if (RegExp(r'(эт\S*|текущ\S*) недел').hasMatch(q)) return (from: monday, to: day(1));
  if (RegExp(r'прошл\S* месяц').hasMatch(q)) {
    return (from: DateTime(today.year, today.month - 1), to: DateTime(today.year, today.month));
  }
  if (RegExp(r'(эт\S*|текущ\S*) месяц').hasMatch(q)) return (from: DateTime(today.year, today.month), to: day(1));
  return null;
}

/// Встречи для ответа, самые подходящие первыми. [meetings] — все встречи (сверху новые),
/// [ranked] — найденные по словам вопроса (лучшие первыми), [previous] — встречи прошлого
/// ответа: уточняющий вопрос без своих слов («а кто за это отвечает?») — о них же.
List<Meeting> chooseChatMeetings({
  required String question,
  required List<Meeting> meetings,
  required List<Meeting> ranked,
  List<Meeting> previous = const [],
  required DateTime now,
}) {
  final period = chatPeriod(question, now);
  bool inPeriod(Meeting m) => period == null || (!m.startedAt.isBefore(period.from) && m.startedAt.isBefore(period.to));
  final chosen = <Meeting>[];
  void add(Iterable<Meeting> list) {
    for (final m in list) {
      if (chosen.length >= _maxSources) return;
      if (inPeriod(m) && !chosen.any((c) => c.dir.path == m.dir.path)) chosen.add(m);
    }
  }

  final q = question.toLowerCase();
  final aboutLatest = RegExp(r'последн|недавн').hasMatch(q);
  if (aboutLatest) add(meetings.take(1));
  add(ranked);
  if (period != null) {
    // «Что было на прошлой неделе» без своих слов (или слова не нашлись) — о встречах
    // периода, сначала длинных: пятиминутная проверка связи важна меньше часового созвона.
    // Со словами — только о найденных.
    if (chosen.isEmpty || chatKeywords(question).isEmpty) {
      add([...meetings]..sort((a, b) => (b.durationSeconds ?? 0).compareTo(a.durationSeconds ?? 0)));
    }
  } else if (chosen.isEmpty) {
    if (previous.isNotEmpty && chatKeywords(question).isEmpty) {
      add(previous);
    } else {
      add(meetings.take(3));
    }
  }
  return chosen;
}

/// Номера встреч, на которые ссылается ответ («[2]», «[1, 3]»), по порядку первого упоминания.
/// Встреча одна, а модель сослалась таймкодом («[48:43]») — значит, на неё.
List<int> citedSources(String answer, int count) {
  if (count == 1 && RegExp(r'\[(1|\d+:\d+(:\d+)?)\]').hasMatch(answer)) return [1];
  final cited = <int>[];
  for (final m in RegExp(r'\[([\d,\s]+)\]').allMatches(answer)) {
    for (final part in m[1]!.split(',')) {
      final n = int.tryParse(part.trim());
      if (n != null && n >= 1 && n <= count && !cited.contains(n)) cited.add(n);
    }
  }
  return cited;
}

/// Реплики со словами вопроса (по началу слова, как в поиске) — до [_linesPerMeeting].
List<String> matchingLines(List<String> transcript, List<String> keywords) {
  if (keywords.isEmpty) return const [];
  final stems = [
    for (final k in keywords) k.length >= 6 ? k.substring(0, k.length - 2) : (k.length >= 4 ? k.substring(0, k.length - 1) : k),
  ];
  return [
    for (final line in transcript)
      if (stems.any(normalizeForSearch(line.toLowerCase()).contains)) line,
  ].take(_linesPerMeeting).toList();
}

final _timecode = RegExp(r'\s*\[\d+:\d+(:\d+)?\]');

const _months = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];
const _weekdays = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];

/// «понедельник, 12 октября 2026, 14:05» — модели нужна полная дата, без «Вчера».
String chatDate(DateTime at) =>
    '${_weekdays[at.weekday - 1]}, ${at.day} ${_months[at.month - 1]} ${at.year}, '
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

/// Запрос к модели: материалы встреч под номерами, прошлые вопросы этого чата и вопрос.
String chatPrompt(String question, List<ChatSource> sources, List<ChatTurn> history, DateTime now) {
  final buffer = StringBuffer('Сегодня ${chatDate(now).split(',').take(2).join(',')}.\n\nМатериалы встреч:\n');
  var budget = _contextChars;
  for (final (i, source) in sources.indexed) {
    final m = source.meeting;
    final duration = m.durationSeconds == null ? '' : ', ${(m.durationSeconds! / 60).ceil()} мин';
    final part = StringBuffer('\n[${i + 1}] «${m.title}» — ${chatDate(m.startedAt)}$duration\n');
    // Таймкоды убраны: иначе модель ставит их вместо номера встречи.
    final summary = source.summary.replaceAll(_timecode, '');
    if (summary.isNotEmpty) {
      part.write('Заметки:\n${summary.length > _summaryChars ? '${summary.substring(0, _summaryChars)}…' : summary}\n');
    }
    if (source.lines.isNotEmpty) {
      part.write('Фрагменты расшифровки:\n${[for (final l in source.lines) l.replaceFirst(_timecode, '').trim()].join('\n')}\n');
    }
    if (source.summary.isEmpty && source.lines.isEmpty) part.write('(заметок и подходящих реплик нет)\n');
    final text = part.toString();
    if (text.length > budget && i > 0) break;
    buffer.write(text.length > budget ? text.substring(0, budget) : text);
    budget -= text.length;
  }
  final recent = history.length > 3 ? history.sublist(history.length - 3) : history;
  if (recent.isNotEmpty) {
    buffer.write('\nПредыдущие вопросы в этом чате:\n');
    for (final turn in recent) {
      final answer = turn.answer.length > 600 ? '${turn.answer.substring(0, 600)}…' : turn.answer;
      buffer.write('Вопрос: ${turn.question}\nОтвет: $answer\n');
    }
  }
  buffer.write('\nВопрос: $question');
  return buffer.toString();
}

/// Подбирает встречи под вопрос и читает их материалы.
Future<List<ChatSource>> findChatSources(
  MeetingStore store,
  String question, {
  List<Meeting> previous = const [],
  DateTime? now,
}) async {
  final keywords = chatKeywords(question);
  final meetings = await store.list();
  final chosen = chooseChatMeetings(
    question: question,
    meetings: meetings,
    ranked: await store.rank(keywords),
    previous: previous,
    now: now ?? DateTime.now(),
  );
  return [
    for (final m in chosen)
      // Встречи без речи модели нечего дать.
      if (await m.readTranscript() case final transcript when transcript.isNotEmpty)
        ChatSource(
          m,
          summary: await m.readSummary() ?? '',
          lines: switch (matchingLines(transcript, keywords)) {
            // Ни слов вопроса, ни заметок (их остановили) — начало разговора.
            final lines when lines.isEmpty && !await m.summaryFile.exists() =>
              transcript.take(40).toList(),
            final lines => lines,
          },
        ),
  ];
}
