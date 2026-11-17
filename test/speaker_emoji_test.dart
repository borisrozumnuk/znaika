import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/speaker_emoji.dart';

void main() {
  test('178 разных эмодзи: звери, потом существа и профессии, феникс последним', () {
    expect(speakerEmoji.length, 178);
    expect(speakerEmoji.toSet().length, 178);
    expect(speakerEmoji.take(3), ['🦊', '🐻', '🦉']);
    expect(speakerEmoji.last, '🐦‍🔥');
  });

  test('метка голоса → эмодзи, имя и «Я» — как есть', () {
    expect(displaySpeaker('Собеседник 1'), '🦊');
    expect(displaySpeaker('Собеседник 2'), '🐻');
    expect(displaySpeaker('Костя'), 'Костя');
    expect(displaySpeaker('Я'), 'Я');
    expect(displaySpeaker('Собеседники'), 'Собеседники');
  });

  test('эмодзи кончились — по кругу с номером круга', () {
    expect(speakerEmojiFor(178), '🦊2');
    expect(speakerEmojiFor(179), '🐻2');
  });

  test('в тексте заметок — и склонённые метки, но не «Собеседники» и не «Собеседник 12» вместо 1', () {
    expect(
      withSpeakerEmoji('Собеседник 1 предложил, Собеседнику 2 поручили, с Собеседником 12 договорились. Собеседники согласны.'),
      '🦊 предложил, 🐻 поручили, с 🦋 договорились. Собеседники согласны.',
    );
  });
}
