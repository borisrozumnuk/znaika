import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/database.dart';
import 'package:znaika/meetings.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late MeetingStore store;

  Future<Directory> meeting(DateTime at, {required String title, String summary = '', String transcript = ''}) async {
    final dir = await store.create(at);
    await File('${dir.path}/mic.wav').writeAsString('x');
    if (summary.isNotEmpty) await File('${dir.path}/summary.md').writeAsString('# Заметки по встрече\n\n$summary\n');
    if (transcript.isNotEmpty) await File('${dir.path}/transcript.md').writeAsString('# Расшифровка\n\n$transcript\n');
    await store.finish(dir, title: title);
    return dir;
  }

  Future<List<String>> titles(String query) async => [for (final h in await store.search(query)) h.meeting.title];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('search_test');
    db = AppDatabase(NativeDatabase.memory());
    store = MeetingStore(root, db);
    await meeting(
      DateTime(2026, 10, 10, 9),
      title: 'Планёрка по релизу',
      summary: '## Кратко\nРелиз мобильного приложения переносим на **пятницу**.',
      transcript: '[00:05] Я: Релиз остаётся на пятницу?\n\n[00:09] Собеседники: Да, экран оплаты — в версию 2.1.',
    );
    await meeting(
      DateTime(2026, 10, 12, 15),
      title: 'Бюджет и найм',
      summary: '## Кратко\nУрезаем бюджет на рекламу, нанимаем двух тестировщиков.',
      transcript: '[00:02] Собеседники: Ёлку на корпоратив не покупаем.',
    );
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('русские окончания: «пятница» находит «на пятницу»', () async {
    expect(await titles('пятница'), ['Планёрка по релизу']);
    expect(await titles('бюджета'), ['Бюджет и найм']);
    expect(await titles('тестировщик'), ['Бюджет и найм']);
  });

  test('ищет по заголовку, выжимке и расшифровке; ё = е', () async {
    expect(await titles('планерка'), ['Планёрка по релизу']);
    expect(await titles('оплаты'), ['Планёрка по релизу']);
    expect(await titles('елку'), ['Бюджет и найм']);
    expect(await titles('ЁЛКА'), ['Бюджет и найм']);
  });

  test('все слова обязательны, сверху новые', () async {
    expect(await titles('бюджет релиз'), isEmpty);
    expect(await titles('релиз пятница'), ['Планёрка по релизу']);
    await meeting(DateTime(2026, 10, 13, 10), title: 'Ретро релиза', summary: 'Релиз прошёл хорошо.');
    expect(await titles('релиз'), ['Ретро релиза', 'Планёрка по релизу']);
  });

  test('фрагмент с выделенным совпадением', () async {
    final hit = (await store.search('пятницу')).single;
    expect(hit.snippet, contains('\u0001пятницу\u0002'));
  });

  test('пустой запрос и знаки препинания ничего не ищут', () async {
    expect(await store.search(''), isEmpty);
    expect(await store.search('  ?!, '), isEmpty);
    expect(searchExpression('"бюджет" OR NOT'), '"бюдж"* "or"* "not"*');
  });

  test('новый заголовок переиндексируется', () async {
    final dir = Directory('${root.path}/${(await store.list()).last.dir.uri.pathSegments.where((s) => s.isNotEmpty).last}');
    await store.finish(dir, title: 'Квартальное планирование');
    expect(await titles('квартальное'), ['Квартальное планирование']);
    expect(await titles('планёрка'), isEmpty);
  });

  test('sync восстанавливает индекс (как после обновления базы до версии с поиском)', () async {
    await db.customStatement('DELETE FROM meetings_fts');
    expect(await titles('пятница'), isEmpty);
    await store.sync();
    expect(await titles('пятница'), ['Планёрка по релизу']);
  });
}
