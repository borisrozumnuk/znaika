import 'transcriber.dart';

/// Подпись микрофона и системного звука в расшифровке.
const meLabel = 'Я';
const othersLabel = 'Собеседники';

/// Реплика собеседника: одной меткой «Собеседники» или по голосу «Собеседник N».
bool isOthers(String speaker) => speaker != meLabel;

/// Насколько раньше или позже реплики собеседников ещё может звучать её эхо, в секундах.
const _echoWindow = 1.0;

/// Какая доля слов реплики «Я» должна найтись у собеседников, чтобы счесть её эхом.
const _echoShare = 0.6;

/// Убирает эхо: когда звук идёт через динамики, микрофон слышит собеседников,
/// и их реплики появляются второй раз под меткой «Я».
///
/// Реплика «Я» считается эхом, если рядом по времени есть реплики собеседников
/// и в их тексте находится не меньше 60% её слов. Сравниваются все соседние
/// реплики вместе: VAD режет эхо и оригинал на фразы по-разному.
/// Слова сравниваются по началу: распознавание эха часто путает окончания.
List<Utterance> dropEchoes(List<Utterance> utterances) {
  final others = utterances.where((u) => isOthers(u.speaker)).toList();
  if (others.isEmpty) return utterances;
  return [
    for (final u in utterances)
      if (u.speaker != meLabel || !_isEcho(u, others)) u,
  ];
}

bool _isEcho(Utterance mine, List<Utterance> others) {
  final nearby = others.where((o) => o.start < mine.end + _echoWindow && o.end > mine.start - _echoWindow);
  if (nearby.isEmpty) return false;
  final words = _words(mine.text);
  if (words.isEmpty) return false;
  final reference = _words(nearby.map((o) => o.text).join(' '));
  final matched = words.where((w) => reference.any((r) => _sameWord(w, r))).length;
  return matched / words.length >= _echoShare;
}

final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

List<String> _words(String text) => text
    .toLowerCase()
    .replaceAll('ё', 'е')
    .split(_nonWord)
    .where((w) => w.isNotEmpty)
    .toList();

/// Совпадение слова с точностью до окончания: «пятницы» = «пятницу».
bool _sameWord(String a, String b) {
  if (a == b) return true;
  if (a.length < 4 || b.length < 4) return false;
  final stem = a.length < 5 || b.length < 5 ? 3 : 5;
  return a.substring(0, stem) == b.substring(0, stem);
}
