import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/summarizer.dart';

/// «Токены» — длина строки в символах.
int count(String s) => s.length;

void main() {
  test('короткие заметки частей — группами по лимиту', () {
    final parts = ['a' * 400, 'b' * 400, 'c' * 400, 'd' * 400];
    expect(groupForMerge(parts, count, 1000), ['${'a' * 400}\n\n${'b' * 400}', '${'c' * 400}\n\n${'d' * 400}']);
  });

  test('каждая заметка больше половины лимита — всё равно попарно, а не все сразу (E2B: 12198 >= 8192)', () {
    final parts = [for (final c in 'abcde'.split('')) c * 2000];
    final groups = groupForMerge(parts, count, 3000);
    expect(groups.length, 3);
    expect(groups.first, '${'a' * 2000}\n\n${'b' * 2000}');
    expect(groups.last, 'e' * 2000);
  });

  test('проходы объединения сходятся к одной заметке', () {
    var parts = [for (var i = 0; i < 9; i++) 'x' * 2500];
    var rounds = 0;
    while (parts.length > 1) {
      // «Модель» сжимает группу в заметку того же порядка длины.
      parts = [for (final _ in groupForMerge(parts, count, 3000)) 'y' * 2000];
      rounds++;
    }
    expect(rounds, lessThanOrEqualTo(4));
  });

  test('расшифровка режется по строкам, длинная строка — отдельно', () {
    expect(splitByTokens(['aa', 'bb', 'c' * 10, 'dd'], count, 6), ['aa\nbb', 'c' * 10, 'dd']);
  });
}
