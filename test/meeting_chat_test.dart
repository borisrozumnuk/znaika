import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/database.dart';
import 'package:znaika/meeting_chat.dart';
import 'package:znaika/meetings.dart';

Meeting _meeting(String name, DateTime at) => Meeting(dir: Directory('/m/$name'), title: name, startedAt: at);

void main() {
  // Вторник, 13 октября 2026.
  final now = DateTime(2026, 10, 13, 18);

  test('слова для поиска — без служебных и общих для вопросов о встречах', () {
    expect(chatKeywords('Что мы решили по релизу на последней встрече?'), ['релизу']);
    expect(chatKeywords('Какие задачи у Кости по платёжке?'), ['кости', 'платежке']);
    expect(chatKeywords('А кто за это отвечает?'), ['отвечает']);
    expect(chatKeywords('О чём говорили вчера?'), isEmpty);
  });

  test('период из вопроса', () {
    expect(chatPeriod('что было вчера?', now), (from: DateTime(2026, 10, 12), to: DateTime(2026, 10, 13)));
    expect(chatPeriod('О чём говорили на этой неделе?', now), (from: DateTime(2026, 10, 12), to: DateTime(2026, 10, 14)));
    expect(chatPeriod('итоги прошлой недели', now), (from: DateTime(2026, 10, 5), to: DateTime(2026, 10, 12)));
    expect(chatPeriod('встречи в прошлом месяце', now), (from: DateTime(2026, 9), to: DateTime(2026, 10)));
    expect(chatPeriod('что решили по релизу?', now), isNull);
  });

  test('выбор встреч: найденные, период, последняя, уточнение, запасной вариант', () {
    final today = _meeting('сегодня', DateTime(2026, 10, 13, 10));
    final yesterday = _meeting('вчера', DateTime(2026, 10, 12, 10));
    final old = _meeting('давно', DateTime(2026, 9, 1, 10));
    final all = [today, yesterday, old];
    List<String> names(List<Meeting> list) => [for (final m in list) m.title];

    expect(names(chooseChatMeetings(question: 'что по релизу?', meetings: all, ranked: [old], now: now)), ['давно']);
    // Период ограничивает и найденные: давняя встреча не подходит под «вчера».
    expect(names(chooseChatMeetings(question: 'что по релизу вчера?', meetings: all, ranked: [old], now: now)),
        ['вчера']);
    // Со словами в периоде — только найденные; без слов — все встречи периода.
    expect(names(chooseChatMeetings(question: 'что по релизу на этой неделе?', meetings: all, ranked: [yesterday], now: now)),
        ['вчера']);
    expect(names(chooseChatMeetings(question: 'что было на этой неделе?', meetings: all, ranked: const [], now: now)),
        ['сегодня', 'вчера']);
    // За период — сначала длинные встречи.
    final long = Meeting(dir: Directory('/m/long'), title: 'часовая', startedAt: DateTime(2026, 10, 12, 9), durationSeconds: 3600);
    final short = Meeting(dir: Directory('/m/short'), title: 'проверка', startedAt: DateTime(2026, 10, 13, 9), durationSeconds: 20);
    expect(names(chooseChatMeetings(question: 'что было на этой неделе?', meetings: [short, long], ranked: const [], now: now)),
        ['часовая', 'проверка']);
    expect(names(chooseChatMeetings(question: 'что решили на последней встрече?', meetings: all, ranked: const [], now: now)),
        ['сегодня']);
    // Уточнение без своих слов — о встречах прошлого ответа.
    expect(names(chooseChatMeetings(question: 'а кто?', meetings: all, ranked: const [], previous: [old], now: now)),
        ['давно']);
    // Ничего не нашлось — последние встречи.
    expect(names(chooseChatMeetings(question: 'что по бюджету?', meetings: all, ranked: const [], now: now)),
        ['сегодня', 'вчера', 'давно']);
  });

  test('ссылки ответа на встречи', () {
    expect(citedSources('Релиз в пятницу [2]. Тесты — Аня [1, 2]. Таймкод [00:12].', 3), [2, 1]);
    expect(citedSources('В материалах ответа нет.', 3), isEmpty);
    expect(citedSources('См. [7].', 3), isEmpty);
    expect(citedSources('Подготовить демо [12:30].', 1), [1]);
    expect(citedSources('Подготовить демо [12:30].', 2), isEmpty);
  });

  test('реплики со словами вопроса', () {
    final lines = ['[00:01] Я: Релиз в пятницу.', '[00:05] Собеседник 1: Про бюджет потом.', '[00:09] Я: Релизы — по средам.'];
    expect(matchingLines(lines, ['релизу']), [lines[0], lines[2]]);
    expect(matchingLines(lines, []), isEmpty);
  });

  test('запрос: встречи под номерами, прошлые вопросы, вопрос в конце', () {
    final m = Meeting(dir: Directory('/m/a'), title: 'Планёрка', startedAt: DateTime(2026, 10, 12, 9, 30), durationSeconds: 1500);
    final prompt = chatPrompt(
      'А сроки?',
      [ChatSource(m, summary: '## Кратко\nРелиз в пятницу [00:01].', lines: const ['[00:01] Я: Релиз в пятницу.'])],
      [ChatTurn('Что по релизу?', 'Релиз в пятницу [1].', const [])],
      now,
    );
    expect(prompt, contains('Сегодня вторник, 13 октября 2026.'));
    expect(prompt, contains('[1] «Планёрка» — понедельник, 12 октября 2026, 09:30, 25 мин'));
    expect(prompt, contains('Заметки:\n## Кратко\nРелиз в пятницу.'));
    // Таймкодов нет — в квадратных скобках модель видит только номера встреч.
    expect(prompt, contains('Фрагменты расшифровки:\nЯ: Релиз в пятницу.'));
    expect(prompt, isNot(contains('00:01')));
    expect(prompt, contains('Вопрос: Что по релизу?\nОтвет: Релиз в пятницу [1].'));
    expect(prompt, endsWith('Вопрос: А сроки?'));
  });

  test('поиск для чата: любое из слов, заголовок важнее расшифровки', () async {
    final root = await Directory.systemTemp.createTemp('chat_rank');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final store = MeetingStore(root, db);
    Future<void> add(DateTime at, String title, String transcript) async {
      final dir = await store.create(at);
      await File('${dir.path}/transcript.md').writeAsString('# Расшифровка\n\n$transcript\n');
      await store.finish(dir, title: title);
    }

    await add(DateTime(2026, 10, 10), 'Бюджет на рекламу', '[00:01] Я: Про релиз скажу позже.');
    await add(DateTime(2026, 10, 11), 'Подготовка релиза', '[00:01] Я: Собираем сборку.');
    await add(DateTime(2026, 10, 12), 'Найм', '[00:01] Я: Ищем тестировщика.');

    final ranked = await store.rank(['релизу', 'платежке']);
    expect([for (final m in ranked) m.title], ['Подготовка релиза', 'Бюджет на рекламу']);
    expect(await store.rank(const []), isEmpty);
  });
}
