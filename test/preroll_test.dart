import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/transcriber.dart';

void main() {
  final audio = Float32List.fromList(List.generate(sampleRate * 3, (i) => i.toDouble()));

  test('фраза в середине получает 0,3 с запаса перед началом', () {
    final phrase = withPreroll(audio, sampleRate, 8000);
    expect(phrase.first, sampleRate - vadPreroll);
    expect(phrase.last, sampleRate + 8000 - 1);
    expect(phrase.length, vadPreroll + 8000);
  });

  test('у начала записи запас не уходит за её пределы', () {
    final phrase = withPreroll(audio, 1000, 2000);
    expect(phrase.first, 0);
    expect(phrase.length, 3000);
  });

  test('у конца записи фраза обрезается по её длине', () {
    final phrase = withPreroll(audio, audio.length - 100, 500);
    expect(phrase.last, audio.length - 1);
  });
}
