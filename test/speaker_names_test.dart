import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/database.dart';
import 'package:znaika/meetings.dart';

void main() {
  test('собеседники — в порядке первой реплики, без «Я»', () {
    expect(
      speakersOf([
        '[00:01] Я: Привет.',
        '[00:03] Собеседник 2: Привет.',
        '[00:05] Собеседник 1: Здравствуйте.',
        '[00:07] Собеседник 2: Начнём?',
      ]),
      ['Собеседник 2', 'Собеседник 1'],
    );
  });

  test('недопустимые имена', () {
    expect(cleanSpeakerName('  Анна   Петрова '), 'Анна Петрова');
    expect(cleanSpeakerName(''), isNull);
    expect(cleanSpeakerName('Я'), isNull);
    expect(cleanSpeakerName('Анна: тимлид'), isNull);
  });

  test('расшифровка: меняется только метка нужного собеседника', () {
    const text = '[00:01] Я: Собеседник 1, начнёшь?\n\n'
        '[00:08] Собеседник 1: Да.\n\n'
        '[00:09] Собеседник 10: Подожди.\n';
    expect(
      renameSpeakerInTranscript(text, 'Собеседник 1', 'Анна'),
      '[00:01] Я: Собеседник 1, начнёшь?\n\n'
      '[00:08] Анна: Да.\n\n'
      '[00:09] Собеседник 10: Подожди.\n',
    );
  });

  test('заметки: падежные формы метки, но не другой номер', () {
    const text = '- Собеседник 1 — сделать возвраты\n'
        '- Я — вернуться к Собеседнику 1, спросить Собеседника 1 и Собеседника 12\n';
    expect(
      renameSpeakerInSummary(text, 'Собеседник 1', 'Анна'),
      '- Анна — сделать возвраты\n'
      '- Я — вернуться к Анна, спросить Анна и Собеседника 12\n',
    );
    expect(
      renameSpeakerInSummary('Собеседники обещали, у Собеседников нет данных', 'Собеседники', 'Олег'),
      'Олег обещали, у Олег нет данных',
    );
    expect(renameSpeakerInSummary('Анна и Аннабель', 'Анна', 'Аня'), 'Аня и Аннабель');
  });

  test('переименование во встрече и поиск по новому имени', () async {
    final root = await Directory.systemTemp.createTemp('speaker_names');
    addTearDown(() => root.delete(recursive: true));
    final store = MeetingStore(Directory('${root.path}/recordings'), AppDatabase(NativeDatabase.memory()));
    final dir = await store.create(DateTime(2026, 10, 13, 10));
    await File('${dir.path}/mic.wav').writeAsString('x');
    await File('${dir.path}/transcript.md').writeAsString('# Расшифровка\n\n[00:08] Собеседник 1: Возвраты за три дня.\n');
    await File('${dir.path}/summary.md').writeAsString('# Заметки по встрече\n\n## Задачи\n- Собеседник 1 — возвраты\n');
    await store.finish(dir, title: 'Спринт');
    final meeting = (await store.list()).single;

    await store.renameSpeaker(meeting, 'Собеседник 1', ' Анна ');

    expect(await meeting.readTranscript(), ['[00:08] Анна: Возвраты за три дня.']);
    expect(await meeting.readSummary(), contains('- Анна — возвраты'));
    expect(await store.search('анна'), hasLength(1));
    expect(await meeting.notesOutdated(), isTrue);
    await store.notesRegenerated(meeting);
    expect(await meeting.notesOutdated(), isFalse);
    expect((await store.list()).single.title, 'Спринт');
    await expectLater(store.renameSpeaker(meeting, 'Анна', 'Я'), throwsArgumentError);
  });
}
