import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/audio_archive.dart';
import 'package:znaika/database.dart';
import 'package:znaika/meetings.dart';
import 'package:znaika/summarizer.dart';

void main() {
  test('дата и время по-русски относительно сегодня', () {
    final now = DateTime(2026, 10, 13, 12);
    expect(formatMeetingTime(DateTime(2026, 10, 13, 1, 57), now: now), 'Сегодня, 01:57');
    expect(formatMeetingTime(DateTime(2026, 10, 12, 23, 10), now: now), 'Вчера, 23:10');
    expect(formatMeetingTime(DateTime(2026, 9, 5, 9, 30), now: now), '5 сентября, 09:30');
    expect(formatMeetingTime(DateTime(2025, 3, 5, 14, 0), now: now), '5 марта 2025, 14:00');
  });

  test('длительность', () {
    expect(formatDuration(45), '45 с');
    expect(formatDuration(12 * 60 + 20), '12 мин');
    expect(formatDuration(65 * 60), '1 ч 05 мин');
  });

  test('заголовок чистится от Markdown, кавычек и точки', () {
    expect(cleanTitle('## «Планирование спринта: платежи и релиз».\n'), 'Планирование спринта: платежи и релиз');
    expect(cleanTitle('Заголовок: Релиз 2.0 переносится'), 'Релиз 2.0 переносится');
    expect(cleanTitle('**Бюджет на рекламу**'), 'Бюджет на рекламу');
  });

  test('список: сверху новые, старые папки без meeting.json, без звука — не в списке', () async {
    final root = await Directory.systemTemp.createTemp('meetings_test');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final store = MeetingStore(root, db);

    final older = await store.create(DateTime(2026, 10, 12, 9, 0));
    await File('${older.path}/mic.wav').writeAsString('x');
    await store.finish(older, title: 'Планёрка', durationSeconds: 600);

    final newer = await store.create(DateTime(2026, 10, 13, 10, 30));
    await File('${newer.path}/system.wav').writeAsString('x');
    await store.finish(newer, title: 'Релиз мобильного приложения');

    // Старая запись: только имя папки и выжимка.
    final legacy = Directory('${root.path}/2026-10-11T08-15-00')..createSync();
    await File('${legacy.path}/mic.wav').writeAsString('x');
    await File('${legacy.path}/summary.md')
        .writeAsString('# Заметки по встрече\n\n## Кратко\nОбсудили бюджет. Решили урезать рекламу.\n');

    // Прерванный старт без звука.
    await store.create(DateTime(2026, 10, 13, 11, 0));

    // finish уже внёс две встречи; sync подхватывает старую папку.
    expect(await store.sync(), (added: 1, removed: 0));
    final list = await store.list();
    expect(list.map((m) => m.title), ['Релиз мобильного приложения', 'Планёрка', 'Обсудили бюджет.']);
    expect(list[1].durationSeconds, 600);
    expect(list[2].startedAt, DateTime(2026, 10, 11, 8, 15));

    // Повторный sync ничего не меняет; удалённая папка исчезает из базы.
    expect(await store.sync(), (added: 0, removed: 0));
    await older.delete(recursive: true);
    expect(await store.sync(), (added: 0, removed: 1));
    expect((await store.list()).map((m) => m.title), ['Релиз мобильного приложения', 'Обсудили бюджет.']);

    // Повторный finish обновляет заголовок, а не дублирует встречу.
    await store.finish(newer, title: 'Релиз 2.0 в пятницу');
    expect((await store.list()).map((m) => m.title), ['Релиз 2.0 в пятницу', 'Обсудили бюджет.']);
  });

  test('после обработки звук сжимается в audio.m4a, встреча остаётся', () async {
    final root = await Directory.systemTemp.createTemp('meetings_audio');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final store = MeetingStore(root, db);
    final dir = await store.create(DateTime(2026, 10, 13, 10));
    // Две секунды «речи» в каждом канале (синус) — настоящие WAV, как пишет захват.
    for (final (name, hz) in [('mic.wav', 220.0), ('system.wav', 330.0)]) {
      final samples = Int16List.fromList([for (var i = 0; i < 32000; i++) (8000 * sin(2 * pi * hz * i / 16000)).round()]);
      await File('${dir.path}/$name').writeAsBytes([...wavHeader(samples.length), ...samples.buffer.asUint8List()]);
    }
    await File('${dir.path}/transcript.md').writeAsString('# Расшифровка\n\n[00:01] Я: Привет.\n');
    await store.finish(dir, title: 'Планёрка');

    expect(await store.unarchived(), [isA<Directory>().having((d) => d.path, 'path', dir.path)]);
    expect(await store.archiveAudio(dir), isTrue);
    expect(File('${dir.path}/mic.wav').existsSync(), isFalse);
    expect(File('${dir.path}/system.wav').existsSync(), isFalse);
    expect(File('${dir.path}/$audioFileName').lengthSync(), greaterThan(1024));
    expect(Directory(dir.path).listSync().map((e) => e.uri.pathSegments.last).where((n) => n.startsWith('.')), isEmpty);
    expect(await store.unarchived(), isEmpty);
    // Без WAV, с расшифровкой и звуком — по-прежнему встреча, и после перезапуска (sync) тоже.
    expect(await store.sync(), (added: 0, removed: 0));
    final fresh = MeetingStore(root, AppDatabase(NativeDatabase.memory()));
    expect(await fresh.sync(), (added: 1, removed: 0));
    expect((await fresh.list()).single.title, 'Планёрка');
  });

  test('сжатие не удалось (не WAV) — исходники остаются', () async {
    final root = await Directory.systemTemp.createTemp('meetings_audio_bad');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/mic.wav').writeAsString('не звук');
    expect(await archiveMeetingAudio(root), isFalse);
    expect(File('${root.path}/mic.wav').existsSync(), isTrue);
    expect(File('${root.path}/$audioFileName').existsSync(), isFalse);
  });

  test('сведение каналов: сумма с ограничением, длина — по длинному', () async {
    expect(clampToPcm16(Int32List.fromList([100, 40000, -40000, -5])), [100, 32767, -32768, -5]);
    final root = await Directory.systemTemp.createTemp('mix');
    addTearDown(() => root.delete(recursive: true));
    Future<String> wav(String name, List<int> samples) async {
      final path = '${root.path}/$name';
      await File(path).writeAsBytes([...wavHeader(samples.length), ...Int16List.fromList(samples).buffer.asUint8List()]);
      return path;
    }

    final out = mixWavFiles([await wav('a.wav', [1000, 2000, 30000]), await wav('b.wav', [10, 20, 30000, 7])], '${root.path}/m.wav');
    final reader = WavReader(out);
    expect(reader.samples, 4);
    expect(reader.read(0, 4), [1010, 2020, 32767, 7]);
    reader.close();
  });

  test('незаконченная обработка: пометка переживает finish и перезапуск, снимается', () async {
    final root = await Directory.systemTemp.createTemp('meetings_unfinished');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final store = MeetingStore(root, db);
    final older = await store.create(DateTime(2026, 10, 13, 9));
    final newer = await store.create(DateTime(2026, 10, 13, 10));
    final done = await store.create(DateTime(2026, 10, 13, 11));
    for (final dir in [older, newer, done]) {
      await File('${dir.path}/mic.wav').writeAsString('x');
      await store.finish(dir, title: 'Новая встреча', durationSeconds: 60);
    }
    await store.setProcessing(older, true);
    await store.setProcessing(newer, true);
    // Заголовок после заметок пометку не снимает — её снимает только конец обработки.
    await store.finish(newer, title: 'Планёрка');

    final fresh = MeetingStore(root, AppDatabase(NativeDatabase.memory()));
    await fresh.sync();
    expect([for (final m in await fresh.unfinished()) m.dir.path], [older.path, newer.path]);
    expect((await fresh.list()).firstWhere((m) => m.dir.path == newer.path).durationSeconds, 60);

    await store.setProcessing(older, false);
    expect([for (final m in await store.unfinished()) m.dir.path], [newer.path]);
  });

  test('переименование и удаление: список, поиск, Корзина', () async {
    final root = await Directory.systemTemp.createTemp('actions_test');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final store = MeetingStore(root, db);
    final dir = await store.create(DateTime(2026, 10, 13, 9));
    await File('${dir.path}/mic.wav').writeAsString('x');
    await store.finish(dir, title: 'Старый заголовок', durationSeconds: 90);

    final meeting = (await store.list()).single;
    await store.rename(meeting, '  Планирование квартала  ');
    final renamed = (await store.list()).single;
    expect(renamed.title, 'Планирование квартала');
    expect(renamed.durationSeconds, 90, reason: 'длительность сохраняется');
    expect((await store.search('квартал')).single.meeting.title, 'Планирование квартала');
    expect(await store.search('старый'), isEmpty);

    final trashed = <String>[];
    await store.delete(renamed, moveToTrash: (d) async {
      trashed.add(d.path);
      await d.delete(recursive: true);
    });
    expect(trashed, [dir.path]);
    expect(await store.list(), isEmpty);
    expect(await store.search('квартал'), isEmpty);
    expect(await store.sync(), (added: 0, removed: 0), reason: 'после удаления база и диск согласованы');
  });

  test('экспорт в Markdown и имя файла', () {
    final meeting = Meeting(
      dir: Directory('/tmp/x'),
      title: 'Релиз 2.0: перенос / пятница?',
      startedAt: DateTime(2026, 10, 13, 9, 5),
      durationSeconds: 65 * 60,
    );
    final md = meetingMarkdown(meeting, summary: '## Кратко\nРелиз в пятницу.', transcript: ['[00:01] Я: Привет.']);
    expect(md, startsWith('# Релиз 2.0: перенос / пятница?\n\n_13 октября 2026, 09:05 · 1 ч 05 мин_\n\n## Кратко'));
    expect(md, contains('## Расшифровка\n\n[00:01] Я: Привет.'));
    expect(exportFileName(meeting), '2026-10-13 Релиз 2.0 перенос пятница.md');
    expect(exportFileName(meeting, extension: 'm4a'), '2026-10-13 Релиз 2.0 перенос пятница.m4a');
    final long = Meeting(dir: Directory('/tmp/y'), title: 'а' * 200, startedAt: DateTime(2026, 1, 2));
    expect(exportFileName(long).length, lessThanOrEqualTo('2026-01-02 .md'.length + 80));
  });

  test('в Корзину — только папка встречи внутри recordings', () async {
    final root = await Directory.systemTemp.createTemp('meetings_trash_guard');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final store = MeetingStore(Directory('${root.path}/recordings'), db);
    final trashed = <String>[];
    Future<void> trash(Directory dir) async => trashed.add(dir.path);
    for (final dir in [root, Directory('${root.path}/recordings/../outside'), Directory('${root.path}/recordings/.hidden')]) {
      await expectLater(
        store.delete(Meeting(dir: dir, title: 'x', startedAt: DateTime(2026)), moveToTrash: trash),
        throwsStateError,
      );
    }
    expect(trashed, isEmpty);
    final ok = Directory('${root.path}/recordings/2026-10-14T10-00-00');
    await store.delete(Meeting(dir: ok, title: 'x', startedAt: DateTime(2026)), moveToTrash: trash);
    expect(trashed, [ok.path]);
  });
}
