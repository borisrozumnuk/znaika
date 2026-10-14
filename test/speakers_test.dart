import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/speakers.dart';
import 'package:znaika/transcriber.dart';

/// Отпечаток «голоса» [voice] с шумом: у одного голоса — похожие векторы, у разных — нет.
Float32List sample(int voice, Random rng, {double noise = 0.3}) {
  final base = Random(voice * 7919);
  return Float32List.fromList([
    for (var i = 0; i < 192; i++) base.nextDouble() * 2 - 1 + (rng.nextDouble() * 2 - 1) * noise,
  ]);
}

void main() {
  test('один голос — один собеседник, другой голос — новый', () {
    final rng = Random(1);
    final clusters = SpeakerClusters();
    final labels = [
      for (final voice in [0, 0, 1, 0, 1, 1, 2, 0]) clusters.assign(sample(voice, rng), 3),
    ];
    expect(labels, [0, 0, 1, 0, 1, 1, 2, 0]);
    expect(clusters.count, 3);
  });

  test('короткая реплика нового голоса не заводит нового собеседника', () {
    final rng = Random(2);
    final clusters = SpeakerClusters();
    expect(clusters.assign(sample(0, rng), 3), 0);
    // «Угу» другим голосом, 0,6 с — ненадёжно, приписываем ближайшему.
    expect(clusters.assign(sample(5, rng), 0.6), 0);
    expect(clusters.count, 1);
    // Та же реплика подлиннее — уже новый собеседник.
    expect(clusters.assign(sample(5, rng), 3), 1);
    expect(clusters.lastAssigned, 1);
  });

  test('отпечаток собеседника уточняется: шумные реплики того же голоса не расползаются', () {
    final rng = Random(3);
    final clusters = SpeakerClusters();
    for (var i = 0; i < 30; i++) {
      expect(clusters.assign(sample(0, rng, noise: 0.6), 2), 0, reason: 'реплика $i');
    }
    expect(clusters.count, 1);
  });

  test('после длинной встречи «голоса» на пару фраз сливаются с ближайшим настоящим', () {
    final rng = Random(3);
    final clusters = SpeakerClusters();
    // Два настоящих голоса по 5 минут речи.
    for (var i = 0; i < 60; i++) {
      clusters.assign(sample(i.isEven ? 0 : 1, rng), 10);
    }
    // Фраза голоса 1, искажённая так, что стала «новым собеседником».
    // Сходство с голосом 1 около 0,4 — ниже порога, но больше, чем с голосом 0.
    final voice = sample(1, rng, noise: 0);
    final noise = Random(99);
    final norm = sqrt(voice.fold(0.0, (a, x) => a + x * x));
    final odd = Float32List.fromList([for (final x in voice) 0.45 * x / norm + 0.9 * (noise.nextDouble() * 2 - 1) / sqrt(192 / 3)]);
    final extra = clusters.assign(odd, 4);
    expect(extra, 2);
    expect(clusters.consolidated(), [0, 1, clusters.consolidated()[2]]);
    expect(clusters.consolidated()[2], isNot(2));
  });

  test('на короткой встрече голоса не сливаются', () {
    final rng = Random(4);
    final clusters = SpeakerClusters();
    for (var i = 0; i < 10; i++) {
      clusters.assign(sample(i.isEven ? 0 : 1, rng), 5);
    }
    clusters.assign(sample(2, rng), 3);
    expect(clusters.consolidated(), [0, 1, 2]);
  });

  test('метки после встречи: слияние и номера по порядку первой реплики', () {
    const u = [
      Utterance(0, 1, 'Я', 'Привет.'),
      Utterance(1, 2, 'Собеседник 3', 'Здравствуйте.'),
      Utterance(2, 3, 'Собеседник 1', 'Начнём?'),
      Utterance(3, 4, 'Собеседник 2', 'Да.'),
    ];
    // Голос 2 (с нуля; «Собеседник 2») слит с голосом 0.
    expect(relabelSpeakers(u, [0, 0, 2]).map((u) => u.speaker), ['Я', 'Собеседник 1', 'Собеседник 2', 'Собеседник 2']);
  });
}
