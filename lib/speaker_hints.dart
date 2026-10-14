import 'echo_filter.dart';

/// Подсказки имён собеседников по расшифровке: «Слушай, Кость, возьмёшь?» — и следующим
/// ответил Собеседник 5, значит, Собеседник 5, скорее всего, Костя.
///
/// Правило, а не Gemma: маленькая модель путает, кто кому отвечал (проверено на
/// тестовых встречах), а обращение по имени и смена говорящего видны в разметке.
/// Каждое обращение — голос за пару «следующий ответивший — имя»; собеседнику
/// предлагается имя с большинством голосов, и каждое имя — только одному собеседнику.
class SpeakerNameHint {
  /// Метка собеседника («Собеседник 5»).
  final String speaker;

  /// Имя в той форме, как к человеку обращаются («Костя», а не «Константин»).
  final String name;

  /// Сколько раз после обращения по этому имени ответил этот собеседник.
  final int votes;

  /// Реплика с обращением и ответ — показать, откуда подсказка.
  final String evidence;

  const SpeakerNameHint(this.speaker, this.name, this.votes, this.evidence);
}

/// Сколько секунд после обращения ещё ждём ответа.
const _replyWindow = 30.0;

final _line = RegExp(r'^\[([\d:]+)\]\s+([^:]+):\s+(.*)$');

/// Подсказки для собеседников с метками «Собеседник N» / «Собеседники».
List<SpeakerNameHint> suggestSpeakerNames(List<String> transcript) {
  final lines = [
    for (final raw in transcript)
      if (_line.firstMatch(raw) case final m?) (seconds: _seconds(m[1]!), speaker: m[2]!.trim(), text: m[3]!, raw: raw),
  ];
  // Голоса: (собеседник, имя) → число и первое подтверждение.
  final votes = <(String, String), int>{};
  final evidence = <(String, String), String>{};
  for (var i = 0; i < lines.length; i++) {
    final names = vocatives(lines[i].text);
    if (names.isEmpty) continue;
    // Ответил первый следующий другой говорящий.
    for (var j = i + 1; j < lines.length && lines[j].seconds - lines[i].seconds <= _replyWindow; j++) {
      final next = lines[j];
      if (next.speaker == lines[i].speaker) continue;
      if (next.speaker != meLabel && _isAnonymous(next.speaker)) {
        for (final name in names) {
          final key = (next.speaker, name);
          votes[key] = (votes[key] ?? 0) + 1;
          evidence.putIfAbsent(key, () => '${lines[i].raw}\n${next.raw}');
        }
      }
      break;
    }
  }
  // Жадно: самые уверенные пары первыми; имя и собеседник — по одному разу.
  final pairs = votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final usedSpeakers = <String>{};
  final usedNames = <String>{};
  // Имена, которые уже есть в расшифровке как метки, второй раз не предлагаем.
  usedNames.addAll(lines.map((l) => l.speaker).where((s) => !_isAnonymous(s)));
  final hints = <SpeakerNameHint>[];
  for (final MapEntry(key: (speaker, name), value: count) in pairs) {
    if (usedSpeakers.contains(speaker) || usedNames.contains(name)) continue;
    // Имя должно указывать в основном на этого собеседника, а не делиться между несколькими.
    final total = votes.entries.where((e) => e.key.$2 == name).fold(0, (s, e) => s + e.value);
    if (count * 2 < total) continue;
    usedSpeakers.add(speaker);
    usedNames.add(name);
    hints.add(SpeakerNameHint(speaker, name, count, evidence[(speaker, name)]!));
  }
  return hints;
}

bool _isAnonymous(String speaker) => speaker == othersLabel || RegExp(r'^Собеседник \d+$').hasMatch(speaker);

double _seconds(String stamp) =>
    stamp.split(':').map(int.parse).fold(0, (sum, part) => sum * 60 + part).toDouble();

/// Имена в позиции обращения: слово из словаря, отделённое от фразы запятой или
/// стоящее перед «?», «!», «.» — «Кость, возьмёшь?», «Спасибо, Дима.», «Давай, Вадим, …».
/// Без знаков препинания («Игорь поднимет стенд») — не обращение.
List<String> vocatives(String text) {
  final found = <String>[];
  for (final m in _vocative.allMatches(text)) {
    final name = _names[m[2] ?? m[4]!];
    if (name != null && !found.contains(name)) found.add(name);
  }
  return found;
}

/// В начале фразы и с запятой/«?»/«!» после («Лёш, у тебя…», «Кость?») или после запятой
/// («Слушай, Кость, возьмёшь?», «Спасибо, Дима.»). «…вчера прислал Руслан.» — упоминание.
final _vocative = RegExp(
  r'(?:(^|[.!?…]\s+)([А-ЯЁ][а-яё]+)(?=\s*[,!?])|(,\s*)([А-ЯЁ][а-яё]+)(?=\s*[,.!?…]|\s*$))',
  unicode: true,
);

/// Обращение → имя для подсказки. Полные имена и привычные короткие формы;
/// у коротких на -а/-я — ещё усечённые обращения разговорной речи (Саш, Кость, Вань).
/// Слова, которые чаще значат не имя («Вера», «Надежда», «Любовь», «Слава», «Лев»,
/// «Роман»), не включены.
final Map<String, String> _names = () {
  const names = [
    'Александр', 'Саша', 'Шура', 'Алексей', 'Лёша', 'Алёша', 'Андрей', 'Антон', 'Артём', 'Артур',
    'Богдан', 'Борис', 'Боря', 'Вадим', 'Валентин', 'Валера', 'Василий', 'Вася', 'Виктор', 'Витя',
    'Виталий', 'Влад', 'Владимир', 'Вова', 'Володя', 'Владислав', 'Вячеслав', 'Георгий', 'Гоша',
    'Глеб', 'Григорий', 'Гриша', 'Даниил', 'Данила', 'Даня', 'Денис', 'Дима', 'Дмитрий', 'Евгений',
    'Женя', 'Егор', 'Иван', 'Ваня', 'Игорь', 'Илья', 'Кирилл', 'Константин', 'Костя', 'Леонид',
    'Лёня', 'Макс', 'Максим', 'Миша', 'Михаил', 'Никита', 'Николай', 'Коля', 'Олег', 'Павел',
    'Паша', 'Пётр', 'Петя', 'Рома', 'Руслан', 'Сергей', 'Серёжа', 'Серёга', 'Стас', 'Станислав',
    'Степан', 'Тимофей', 'Тимур', 'Фёдор', 'Федя', 'Юрий', 'Юра', 'Ярослав', 'Ярик',
    'Анастасия', 'Настя', 'Анна', 'Аня', 'Алёна', 'Алина', 'Валентина', 'Валя', 'Варвара', 'Варя',
    'Вика', 'Виктория', 'Галина', 'Галя', 'Дарья', 'Даша', 'Евгения', 'Екатерина', 'Катя', 'Елена',
    'Лена', 'Елизавета', 'Лиза', 'Ирина', 'Ира', 'Карина', 'Кристина', 'Ксения', 'Ксюша', 'Лариса',
    'Люда', 'Людмила', 'Маргарита', 'Рита', 'Марина', 'Мария', 'Маша', 'Наталья', 'Наташа', 'Нина',
    'Оксана', 'Ольга', 'Оля', 'Полина', 'Светлана', 'Света', 'Соня', 'София', 'Татьяна', 'Таня',
    'Ульяна', 'Юлия', 'Юля', 'Яна',
  ];
  final map = <String, String>{};
  for (final name in names) {
    map[name] = name;
    map[name.replaceAll('ё', 'е').replaceAll('Ё', 'Е')] = name;
    // Усечённое обращение: Саша → Саш, Костя → Кость, Ваня → Вань, Серёжа → Серёж.
    if (name.length >= 4 && (name.endsWith('а') || name.endsWith('я'))) {
      final stem = name.substring(0, name.length - 1);
      final short = name.endsWith('я') ? '$stemь' : stem;
      for (final form in [short, short.replaceAll('ё', 'е')]) {
        map.putIfAbsent(form, () => name);
      }
    }
  }
  return map;
}();
