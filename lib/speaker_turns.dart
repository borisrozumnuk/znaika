import 'dart:math' as math;
import 'dart:typed_data';

/// Смена говорящего внутри одной фразы VAD.
///
/// VAD режет звук по паузам от 0,5 с, а в созвоне собеседники часто отвечают друг другу
/// быстрее — и в одну «фразу» попадают двое-трое. Подписать её целиком одним голосом нельзя:
/// на синтетических созвонах 3–7 русских дикторов VoxForge (сжатие Opus, перебивания)
/// таких фраз 37%, и верно подписано только 62–70% речи. Если резать фразу там, где голос
/// слева и справа непохож, — 91% (встречи по 3–4 мин) и 94% (по 18–20 мин). На настоящем
/// созвоне 7 человек (89 мин) число голосов то же — 7. Шаг 0,5 с вдвое дешевле, но
/// хуже: 89% и лишний голос на том же созвоне.
///
/// Точки — по сетке записи с шагом [turnHop]; окна по [turnWindow] слева и справа от точки
/// сравниваются по отпечаткам голоса; разрез — в локальном минимуме сходства ниже
/// [threshold], не ближе [turnEdge] к краям фразы и [minGap] к предыдущему разрезу.
/// [phrase] — звук фразы с отсчёта [offset] записи; отпечатки окон — из [windows] (многие
/// посчитаны заранее, пока фраза звучала). Возвращает разрезы в отсчётах фразы.
List<int> speakerChangePoints(
  Float32List phrase,
  int offset,
  TurnWindows windows, {
  double threshold = speakerChangeThreshold,
  int minGap = 16000,
}) {
  if (phrase.length < 2 * turnEdge + turnHop) return const [];
  final end = offset + phrase.length;
  final points = [for (var t = gridAtOrAfter(offset + turnEdge); t <= end - turnEdge; t += turnHop) t];
  final similarity = [
    for (final t in points)
      switch ((
        windows.at(phrase, offset, math.max(offset, t - turnWindow), t),
        windows.at(phrase, offset, t, math.min(end, t + turnWindow)),
      )) {
        (final l?, final r?) => _cosine(l, r),
        _ => 1.0,
      },
  ];
  final cuts = <int>[];
  for (var i = 0; i < points.length; i++) {
    final s = similarity[i];
    if (s >= threshold) continue;
    if (i > 0 && similarity[i - 1] < s || i + 1 < points.length && similarity[i + 1] < s) continue;
    final cut = points[i] - offset;
    if (cuts.isNotEmpty && cut - cuts.last < minGap) continue;
    cuts.add(cut);
  }
  return cuts;
}

/// Шаг точек, окно и отступ от краёв фразы — в отсчётах 16 кГц (0,25 / 1,5 / 1,0 с).
/// Окно кратно шагу: правое окно точки — левое окно точки на 1,5 с позже.
const turnHop = 4000;
const turnWindow = 24000;
const turnEdge = 16000;

/// Ближайшая точка сетки не раньше [sample].
int gridAtOrAfter(int sample) => (sample + turnHop - 1) ~/ turnHop * turnHop;

/// Отпечатки окон звука по номерам отсчётов записи, с кэшем. Поиск разрезов в конце фразы
/// стоил бы ~1,3 с на фразу (89 мин записи — +15 мин), поэтому на лету полные окна сетки
/// считаются, пока фраза звучит ([precompute]), — к её концу остаются окна у краёв.
class TurnWindows {
  TurnWindows(this._embed);

  /// Отпечаток звука; null — слишком короткий.
  final Float32List? Function(Float32List samples) _embed;
  final _cache = <(int, int), Float32List?>{};

  /// Отпечаток отсчётов [lo, hi) записи; [samples] начинается с отсчёта [offset].
  Float32List? at(Float32List samples, int offset, int lo, int hi) =>
      _cache.putIfAbsent((lo, hi), () => _embed(Float32List.sublistView(samples, lo - offset, hi - offset)));

  /// Полные окна сетки внутри [from, to) — заранее, пока фраза ещё звучит.
  void precompute(Float32List samples, int offset, int from, int to) {
    for (var g = gridAtOrAfter(from); g + turnWindow <= to; g += turnHop) {
      at(samples, offset, g, g + turnWindow);
    }
  }

  /// Забыть окна, начавшиеся раньше [sample], — фраза до него уже разобрана.
  void forgetBefore(int sample) => _cache.removeWhere((key, _) => key.$1 < sample);

  int get length => _cache.length;
}

/// Порог сходства окон: ниже — другой голос. 0,3 лучше 0,45: при 0,45 точность та же,
/// но лишние разрезы чаще заводят ложных собеседников.
const speakerChangeThreshold = 0.3;

/// Кусок фразы между разрезами: [from, to) — отсчёты фразы, [text] — слова, что начались в нём.
class TurnPiece {
  final int from;
  final int to;
  final String text;

  const TurnPiece(this.from, this.to, this.text);
}

/// Делит распознанный текст фразы по разрезам [cuts] (отсчёты): слово — куску, в котором
/// начался его первый токен. [tokens] — токены GigaAM (начало слова — с пробела),
/// [timestamps] — их время от начала фразы в секундах. Куски без слов отбрасываются.
List<TurnPiece> splitByTurns(
  List<String> tokens,
  List<double> timestamps,
  List<int> cuts,
  int length, {
  int sampleRate = 16000,
}) {
  final edges = [0, ...cuts, length];
  final texts = List.generate(edges.length - 1, (_) => StringBuffer());
  var piece = 0;
  for (var i = 0; i < tokens.length && i < timestamps.length; i++) {
    final token = tokens[i];
    // Кусок меняется только на начале слова — слово не рвётся посередине.
    if (token.startsWith(' ') || i == 0) {
      final sample = (timestamps[i] * sampleRate).round();
      while (piece + 1 < texts.length && sample >= edges[piece + 1]) {
        piece++;
      }
    }
    texts[piece].write(token);
  }
  return [
    for (var p = 0; p < texts.length; p++)
      if (texts[p].toString().trim() case final text when text.isNotEmpty)
        TurnPiece(edges[p], edges[p + 1], text),
  ];
}

/// Реплика, отрезанная посреди фразы, — с заглавной.
String capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

double _cosine(Float32List a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var k = 0; k < a.length; k++) {
    dot += a[k] * b[k];
    na += a[k] * a[k];
    nb += b[k] * b[k];
  }
  return na == 0 || nb == 0 ? 1.0 : dot / math.sqrt(na * nb);
}
