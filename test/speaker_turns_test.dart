import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/speaker_turns.dart';

const sr = 16000;

/// Звук из кусков «голосов»: отсчёт — номер голоса (1 или 2).
Float32List voices(List<(int voice, double seconds)> parts) => Float32List.fromList([
      for (final (voice, seconds) in parts) ...List.filled((seconds * sr).round(), voice.toDouble()),
    ]);

/// «Отпечаток»: доля первого и второго голоса в окне.
Float32List? embed(Float32List x) {
  if (x.length < 0.3 * sr) return null;
  final first = x.where((v) => v == 1).length / x.length;
  return Float32List.fromList([first, 1 - first]);
}

List<int> cutsOf(Float32List x) => speakerChangePoints(x, 0, TurnWindows(embed));

void main() {
  test('смена голоса посреди фразы — один разрез на границе', () {
    final cuts = cutsOf(voices([(1, 3), (2, 3)]));
    expect(cuts, [3 * sr]);
  });

  test('один голос, короткая фраза или нет отпечатков — без разрезов', () {
    expect(cutsOf(voices([(1, 8)])), isEmpty);
    expect(cutsOf(voices([(1, 1), (2, 1)])), isEmpty);
    expect(speakerChangePoints(voices([(1, 3), (2, 3)]), 0, TurnWindows((_) => null)), isEmpty);
  });

  test('трое по очереди — два разреза', () {
    final cuts = cutsOf(voices([(1, 3), (2, 3), (1, 3)]));
    expect(cuts, [3 * sr, 6 * sr]);
  });

  test('точки — по сетке записи: фраза не с начала записи режется там же', () {
    // Фраза с 1,5 с записи; смена голоса на 4,5 с записи (3 с от начала фразы) — точка сетки.
    const offset = 24000;
    expect(speakerChangePoints(voices([(1, 3), (2, 3)]), offset, TurnWindows(embed)), [3 * sr]);
  });

  test('окна, посчитанные пока фраза звучала, не считаются заново', () {
    final x = voices([(1, 4), (2, 4)]);
    var calls = 0;
    final windows = TurnWindows((s) {
      calls++;
      return embed(s);
    });
    // По ходу фразы — кусками, как приходит звук.
    for (var end = sr; end <= x.length; end += sr ~/ 10) {
      windows.precompute(x, 0, 0, end);
    }
    final ahead = calls;
    expect(speakerChangePoints(x, 0, windows), [4 * sr]);
    expect(calls - ahead, lessThanOrEqualTo(6), reason: 'в конце — только окна у краёв фразы');
    windows.forgetBefore(x.length);
    expect(windows.length, 0);
  });

  test('текст делится по словам: слово — куску, где оно началось', () {
    final pieces = splitByTurns(
      [' Да', ',', ' конечно', '.', ' ну', ' да', 'вай', ' завтра', '.'],
      [0.2, 0.4, 0.6, 0.9, 2.9, 3.2, 3.3, 3.6, 3.9],
      [3 * sr],
      5 * sr,
    );
    expect([for (final p in pieces) (p.from, p.to, p.text)], [
      (0, 3 * sr, 'Да, конечно. ну'),
      (3 * sr, 5 * sr, 'давай завтра.'),
    ]);
  });

  test('заглавная — у реплики, отрезанной посреди фразы', () {
    expect(capitalized('давай завтра.'), 'Давай завтра.');
    expect(capitalized(''), '');
  });

  test('кусок без слов отбрасывается', () {
    final pieces = splitByTurns([' Привет', '.'], [0.3, 0.8], [2 * sr, 4 * sr], 6 * sr);
    expect([for (final p in pieces) (p.from, p.to, p.text)], [(0, 2 * sr, 'Привет.')]);
  });
}
