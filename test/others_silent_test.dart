import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/recorder_page.dart';

void main() {
  test('«не слышно собеседников»: только во время записи, после минуты, вы говорили, от них — ни звука', () {
    bool hint({bool recording = true, int seconds = 90, bool micSpoke = true, bool systemHeard = false}) =>
        othersSilentHint(
          recording: recording,
          recordedFor: Duration(seconds: seconds),
          micSpoke: micSpoke,
          systemHeard: systemHeard,
        );
    expect(hint(), isTrue);
    // Тихая запись, где вы молчали (как на новой машине), — не подсказываем.
    expect(hint(micSpoke: false), isFalse);
    // Собеседников хоть раз было слышно — разрешение есть.
    expect(hint(systemHeard: true), isFalse);
    // Первая минута — ещё рано; после «Стоп» и на паузе — нет.
    expect(hint(seconds: 59), isFalse);
    expect(hint(recording: false), isFalse);
  });
}
