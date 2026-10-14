import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/summarizer.dart';

void main() {
  test('чат проходит между частями заметок: после начатого запроса, впереди остальных', () async {
    final lock = ModelLock();
    final order = <String>[];
    final firstChunk = Completer<void>();
    Future<void> job(String name, {bool urgent = false, Future<void>? until}) => lock.run(urgent: urgent, () async {
          order.add('$name начат');
          await until;
          order.add('$name готов');
        });

    final chunk1 = job('часть 1', until: firstChunk.future);
    await Future<void>.delayed(Duration.zero);
    expect(lock.busy, isTrue);
    final chunk2 = job('часть 2');
    final chat = job('чат', urgent: true);
    firstChunk.complete();
    await Future.wait([chunk1, chunk2, chat]);
    expect(order, ['часть 1 начат', 'часть 1 готов', 'чат начат', 'чат готов', 'часть 2 начат', 'часть 2 готов']);
    expect(lock.busy, isFalse);
  });

  test('«Остановить», пока вопрос ждёт, — сразу, очередь не ломается', () async {
    final lock = ModelLock();
    final release = Completer<void>();
    final running = lock.run(() => release.future);
    await Future<void>.delayed(Duration.zero);

    final stop = NotesStop();
    var ran = false;
    final waiting = lock.run(urgent: true, stop: stop, () async => ran = true);
    stop.stop();
    await expectLater(waiting, throwsA(isA<NotesStopped>()));
    expect(ran, isFalse);

    final after = lock.run(() async => 'дальше');
    release.complete();
    await running;
    expect(await after, 'дальше');
    expect(lock.busy, isFalse);

    // Уже остановленный — не встаёт в очередь вовсе.
    await expectLater(lock.run(stop: stop, () async => 1), throwsA(isA<NotesStopped>()));
  });
}
