import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/transcriber.dart';

void main() {
  Utterance u(double t, String who) => Utterance(t, t + 1, who, 'реплика $t');

  test('имя, данное во время записи, — у всех реплик голоса и у слитого с ним мелкого', () {
    final utterances = [u(0, 'Собеседник 1'), u(2, 'Я'), u(4, 'Собеседник 2'), u(6, 'Собеседник 3')];
    // Голос 3 (номер 2 с нуля) после встречи слит с голосом 1 (номер 0).
    const merged = [0, 1, 0];
    final named = relabelSpeakers(applySpeakerNames(utterances, {'Собеседник 1': 'Анна'}, merged), merged);
    expect([for (final x in named) x.speaker], ['Анна', 'Я', 'Собеседник 1', 'Анна']);
  });

  test('имя — метка другого голоса: голоса объединяются', () {
    final utterances = [u(0, 'Собеседник 1'), u(2, 'Собеседник 2'), u(4, 'Собеседник 3')];
    const merged = [0, 1, 2];
    final named = relabelSpeakers(applySpeakerNames(utterances, {'Собеседник 3': 'Собеседник 1'}, merged), merged);
    expect([for (final x in named) x.speaker], ['Собеседник 1', 'Собеседник 2', 'Собеседник 1']);
  });

  test('без имён — как было', () {
    final utterances = [u(0, 'Собеседник 2')];
    expect(identical(applySpeakerNames(utterances, const {}, const []), utterances), isTrue);
  });
}
