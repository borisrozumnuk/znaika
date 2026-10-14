import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:znaika/app_globals.dart';
import 'package:znaika/chat_page.dart';
import 'package:znaika/database.dart';
import 'package:znaika/home_page.dart';
import 'package:znaika/meeting_view.dart';
import 'package:znaika/meetings.dart';
import 'package:znaika/model_manager.dart';
import 'package:znaika/model_manifest.dart';
import 'package:znaika/setup_page.dart';
import 'package:znaika/ui.dart';

/// Тесты интерфейса — как на macOS (по умолчанию flutter_test притворяется Android:
/// там нет системного меню, иначе ведут себя выделение текста и клавиши).
void macTest(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

/// Вёрстка всех экранов в светлой и тёмной теме, в узком и широком окне:
/// тест падает на любом исключении и переполнении (overflow) при отрисовке.
void main() {
  late Directory root;
  late Meeting meeting;

  /// Встреча для теста удаления. Создаётся в setUpAll: запросы к drift из tester.runAsync
  /// внутри теста подвешивают его блокировку для остальных запросов теста.
  late Directory toDelete;

  /// Встреча с обращением по имени — для подсказки имени собеседника.
  late Meeting withHint;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('ui_test');
    appSupportDir = root;
    appCacheDir = Directory('${root.path}/cache');
    meetingStore = MeetingStore(Directory('${root.path}/recordings'), AppDatabase(NativeDatabase.memory()));
    modelManager = ModelManager(Directory('${root.path}/models'));
    // Модели не скачаны: в листе выбора модели — «Скачать»; Qwen начат (.part) — «Докачать»
    // и красная корзина в правом нижнем углу карточки.
    await Directory('${root.path}/models').create(recursive: true);
    await File('${root.path}/models/qwen3_4b_instruct_2507_mixed_int4.litertlm.part').writeAsBytes(List.filled(1 << 20, 0));
    await modelManager.check();

    // Встреча с длинным заголовком, выжимкой и расшифровкой.
    final dir = await meetingStore.create(DateTime.now().subtract(const Duration(hours: 2)));
    await File('${dir.path}/mic.wav').writeAsString('x');
    await File('${dir.path}/summary.md').writeAsString('''# Заметки по встрече

## Кратко
Обсудили **бюджет** на рекламу и найм двух тестировщиков; решили урезать рекламу на 20%.

## Задачи
- [ ] Я — подготовить вакансии до пятницы [00:11]
- [x] Анна — согласовать бюджет [00:03]
  - вложенный пункт с очень длинным текстом, который должен переноситься на следующую строку без переполнения
''');
    await File('${dir.path}/transcript.md').writeAsString('''# Расшифровка

[00:01] Собеседники: Коллеги, по бюджету на рекламу урезаем его на 20%.

[00:11] Я: Хорошо, тогда я подготовлю вакансии до пятницы.
''');
    await meetingStore.finish(dir,
        title: 'Очень длинный заголовок встречи про корректировку бюджета, найм тестировщиков и планы на квартал',
        durationSeconds: 3725);
    // Заметки устарели (собеседникам дали имена) — вёрстка проверяется и с подсказкой.
    final meta = File('${dir.path}/meeting.json');
    await meta.writeAsString((await meta.readAsString()).replaceFirst('{', '{"notesOutdated": true,'));
    meeting = (await meetingStore.list()).single;

    toDelete = await meetingStore.create(DateTime.now().subtract(const Duration(days: 1)));
    await File('${toDelete.path}/mic.wav').writeAsString('x');
    await meetingStore.finish(toDelete, title: 'Встреча на удаление');

    final hintDir = await meetingStore.create(DateTime.now().subtract(const Duration(days: 2)));
    await File('${hintDir.path}/system.wav').writeAsString('x');
    await File('${hintDir.path}/transcript.md').writeAsString('''# Расшифровка

[00:00] Собеседник 2: Слушай, Кость, возьмёшь?

[00:03] Собеседник 1: Да, возьму.
''');
    await meetingStore.finish(hintDir, title: 'Встреча с подсказкой');
    withHint = (await meetingStore.list()).firstWhere((m) => m.title == 'Встреча с подсказкой');
  });

  tearDownAll(() => root.delete(recursive: true));

  setUp(() {
    // Нативная часть macos_window_utils в тестах недоступна.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['macos_window_utils/window_manipulator', 'macos_window_utils/ns_window_delegate']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // Строка меню macOS и Корзина (MainFlutterWindow.swift) в тестах недоступны.
    messenger.setMockMethodCallHandler(SystemChannels.menu, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('znaika/files'), (call) async {
      if (call.method == 'trash') {
        await Directory((call.arguments as Map)['path'] as String).delete(recursive: true);
      }
      return null;
    });
    // Системные цвета (акцентный и т. п.) — как у синего акцента macOS.
    messenger.setMockMethodCallHandler(const MethodChannel('appkit_ui_element_colors'), (call) async {
      if (call.method == 'getColor') return 0xFF007AFF;
      final components = ((call.arguments as Map)['components'] as List).cast<String>();
      return {for (final c in components) c: c.contains('alpha') ? 1.0 : 0.5};
    });
  });

  /// Список встреч и выжимка читаются из базы и файлов в несколько асинхронных шагов,
  /// и каждому шагу нужен свой цикл реального ввода-вывода. Ждём до появления [until]
  /// (или до затишья), но не больше 40 циклов.
  Future<void> settle(WidgetTester tester, {Finder? until}) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 250));
      if (until != null && until.evaluate().isNotEmpty) return;
      if (until == null && i >= 8) return;
    }
  }

  Future<void> pump(WidgetTester tester, Widget home, {required ThemeMode mode, required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MacosApp(
      theme: MacosThemeData.light(),
      darkTheme: MacosThemeData.dark(),
      themeMode: mode,
      home: home,
    ));
    await settle(tester);
  }


  macTest('переименование на месте: Enter сохраняет, Esc отменяет, пустое не принимается', (tester) async {
    final renamed = <String>[];
    final actions = MeetingActions(
      rename: (title) async => renamed.add(title),
      renameSpeaker: (_, _) async {},
      export: () {},
      copyNotes: () {},
      delete: () {},
    );
    await pump(tester, MacosWindow(child: MeetingView(meeting: meeting, actions: actions)),
        mode: ThemeMode.light, size: const Size(1280, 800));
    Future<void> startRename() async {
      await tester.tap(_iconButton(CupertinoIcons.pencil));
      await tester.pump();
      await tester.pump();
    }

    // Двойной клик по заголовку в тулбаре тоже начинает переименование.
    await tester.tap(find.text(meeting.title));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text(meeting.title));
    await tester.pump();
    await tester.pump();
    expect(find.byType(MacosTextField), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(MacosTextField), findsNothing);

    await startRename();
    expect(find.byType(MacosTextField), findsOneWidget);
    await tester.enterText(find.byType(MacosTextField), 'Новый заголовок');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(renamed, ['Новый заголовок']);
    expect(find.byType(MacosTextField), findsNothing);

    await startRename();
    await tester.enterText(find.byType(MacosTextField), 'Не сохранится');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(MacosTextField), findsNothing);

    await startRename();
    await tester.enterText(find.byType(MacosTextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(renamed, ['Новый заголовок'], reason: 'Esc и пустой заголовок ничего не меняют');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  macTest('пока идёт переименование, «Удалить встречу» (⌘⌫) в строке меню выключен', (tester) async {
    await pump(tester, const HomePage(), mode: ThemeMode.light, size: const Size(1280, 800));
    await settle(tester, until: find.textContaining('Очень длинный заголовок'));
    await tester.tap(find.textContaining('Очень длинный заголовок').first);
    await tester.pump(const Duration(milliseconds: 300));
    PlatformMenuItem deleteItem() => tester
        .widget<PlatformMenuBar>(find.byType(PlatformMenuBar))
        .menus
        .whereType<PlatformMenu>()
        .expand((menu) => menu.menus)
        .whereType<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .firstWhere((item) => item.label == 'Удалить встречу');

    expect(deleteItem().onSelected, isNotNull);
    await tester.tap(_iconButton(CupertinoIcons.pencil));
    await tester.pump();
    await tester.pump();
    expect(find.descendant(of: find.byType(MeetingView), matching: find.byType(MacosTextField)), findsOneWidget);
    expect(deleteItem().onSelected, isNull, reason: '⌘⌫ должен достаться полю ввода');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(deleteItem().onSelected, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  macTest('имя собеседника: диалог из строки участников, пустое имя не принимается', (tester) async {
    final named = <(String, String)>[];
    final editing = <bool>[];
    final actions = MeetingActions(
      rename: (_) async {},
      renameSpeaker: (from, to) async => named.add((from, to)),
      export: () {},
      copyNotes: () {},
      delete: () {},
    );
    await pump(
      tester,
      MacosWindow(child: MeetingView(meeting: meeting, actions: actions, onEditingChanged: editing.add)),
      mode: ThemeMode.light,
      size: const Size(1280, 800),
    );
    await settle(tester, until: find.text('Участники:'));
    await tester.tap(find.widgetWithText(PushButton, 'Собеседники'));
    await tester.pumpAndSettle();
    expect(find.text('Как зовут «Собеседники»?'), findsOneWidget);
    expect(editing, [true]);

    // Пустое имя — кнопка выключена.
    await tester.tap(find.widgetWithText(PushButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(named, isEmpty);

    await tester.enterText(find.byType(MacosTextField), '  Олег ');
    await tester.pump();
    await tester.tap(find.widgetWithText(PushButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(named, [('Собеседники', 'Олег')]);
    expect(editing, [true, false]);
    expect(find.text('Как зовут «Собеседники»?'), findsNothing);
  });

  macTest('пересоздание заметок: подсказка с кнопкой, затем этап и текст по мере генерации', (tester) async {
    var regenerated = 0;
    var stopped = 0;
    MeetingActions actionsWith(VoidCallback? regenerate) => MeetingActions(
          rename: (_) async {},
          renameSpeaker: (_, _) async {},
          regenerateNotes: regenerate,
          stopNotes: () => stopped++,
          export: () {},
          copyNotes: () {},
          delete: () {},
        );
    final actions = actionsWith(() => regenerated++);
    await pump(tester, MacosWindow(child: MeetingView(meeting: meeting, actions: actions)),
        mode: ThemeMode.light, size: const Size(1280, 800));
    await settle(tester, until: find.textContaining('имена подставлены без склонения'));
    await tester.tap(find.widgetWithText(PushButton, 'Пересоздать заметки'));
    expect(regenerated, 1);

    await tester.pumpWidget(MacosApp(
      theme: MacosThemeData.light(),
      home: MacosWindow(
        child: MeetingView(
          meeting: meeting,
          actions: actionsWith(null),
          notesProgress: const NotesProgress('Пишу выжимку…', '## Кратко\nАнна сообщила, что возвраты займут три дня.'),
        ),
      ),
    ));
    await settle(tester, until: find.text('Пишу выжимку…'));
    expect(find.text('Пишу выжимку…'), findsOneWidget);
    await tester.tap(find.widgetWithText(PushButton, 'Остановить'));
    expect(stopped, 1);
    expect(find.textContaining('Анна сообщила', findRichText: true), findsOneWidget);
    // Прежние заметки и подсказка на время генерации скрыты.
    expect(find.textContaining('имена подставлены без склонения'), findsNothing);
    expect(find.textContaining('найм двух', findRichText: true), findsNothing);
  });

  for (final (size, mode) in [(const Size(1280, 800), ThemeMode.light), (const Size(760, 520), ThemeMode.dark)]) {
  macTest('модель для заметок: щелчок по названию у кнопок окна открывает выбор — ${size.width.round()}, ${mode.name}', (tester) async {
    await pump(tester, const HomePage(), mode: mode, size: size);
    await tester.tap(find.text('Gemma 4 E4B'));
    await tester.pumpAndSettle();
    expect(find.text('Модель для заметок'), findsOneWidget);
    for (final name in ['Gemma 4 E2B', 'Qwen3 4B']) {
      expect(find.textContaining(name, findRichText: true, skipOffstage: false), findsWidgets);
    }
    expect(find.widgetWithText(PushButton, 'Скачать', skipOffstage: false), findsNWidgets(2));
    expect(find.widgetWithText(PushButton, 'Докачать', skipOffstage: false), findsOneWidget);
    // «Удалить» — не кнопка с текстом, а красная корзина.
    expect(find.text('Удалить'), findsNothing);
    final trash = find.byWidgetPredicate(
      (w) => w is MacosIconButton && w.semanticLabel == 'Удалить модель',
      skipOffstage: false,
    );
    expect(trash, findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is MacosTooltip && w.message == 'Удалить модель', skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(PushButton, 'Готово'));
    await tester.pumpAndSettle();
    expect(find.text('Модель для заметок'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  }

  macTest('подсказка имени: «Костя?» у собеседника, щелчок — имя', (tester) async {
    final named = <(String, String)>[];
    final actions = MeetingActions(
      rename: (_) async {},
      renameSpeaker: (from, to) async => named.add((from, to)),
      export: () {},
      copyNotes: () {},
      delete: () {},
    );
    await pump(tester, MacosWindow(child: MeetingView(meeting: withHint, actions: actions)),
        mode: ThemeMode.light, size: const Size(760, 520));
    await settle(tester, until: find.text('Костя?'));
    await tester.tap(find.text('Костя?'));
    await tester.pump();
    expect(named, [('Собеседник 1', 'Костя')]);
    expect(tester.takeException(), isNull);
  });

  macTest('экран загрузки: модель для заметок выбирается в списке карточек', (tester) async {
    summaryModelChoice.recommend(gemmaE4b);
    await pump(tester, SetupPage(models: modelManager, onContinue: () {}), mode: ThemeMode.light, size: const Size(1280, 800));
    // Щелчок по карточке выбранной — панель с карточками всех моделей.
    await tester.tap(find.textContaining('Gemma 4 E4B   ', findRichText: true));
    await tester.pumpAndSettle();
    for (final m in summaryModels) {
      expect(find.text(m.note), findsWidgets);
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.textContaining('Gemma 4 E2B   ', findRichText: true));
    await tester.pumpAndSettle();
    expect(summaryModelChoice.chosen, gemmaE2b);
    // Панель закрылась: описание каждой модели — не больше одного раза.
    expect(find.text(gemmaE2b.note), findsOneWidget);
    expect(find.text(qwen3_4b.note), findsNothing);
    summaryModelChoice.select(gemmaE4b);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    macTest('кнопка паузы: полоски, на паузе — «продолжить» — ${mode.name}', (tester) async {
      var taps = 0;
      for (final paused in [false, true]) {
        await pump(
          tester,
          Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
            RecordButton(recording: true, onPressed: () {}),
            PauseButton(paused: paused, onPressed: () => taps++),
          ])),
          mode: mode,
          size: const Size(400, 200),
        );
        await tester.tap(find.byType(PauseButton));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
      expect(taps, 2);
    });
  }

  macTest('удаление: диалог подтверждения, «Отменить» и «Удалить»', (tester) async {
    final dir = toDelete;
    await pump(tester, const HomePage(), mode: ThemeMode.light, size: const Size(1280, 800));
    await settle(tester, until: find.text('Встреча на удаление'));
    await tester.tap(find.text('Встреча на удаление'));
    await tester.pump(const Duration(milliseconds: 300));
    Future<void> pressDelete() async {
      await tester.tap(_iconButton(CupertinoIcons.trash));
      // Анимация появления диалога macos_ui: до её конца кнопки не на своих местах.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }

    await pressDelete();
    expect(find.text('Удалить встречу «Встреча на удаление»?'), findsOneWidget);
    await tester.tap(find.text('Отменить'));
    // Анимация закрытия диалога macos_ui.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Удалить встречу «Встреча на удаление»?'), findsNothing);
    expect(dir.existsSync(), isTrue);

    await pressDelete();
    await tester.tap(find.text('Удалить'));
    await settle(tester);
    expect(dir.existsSync(), isFalse, reason: 'папка ушла «в Корзину»');
    expect(find.text('Встреча на удаление'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  macTest('расшифровка: черновик фразы — после реплик, с многоточием, собеседники по голосам', (tester) async {
    await pump(
      tester,
      MacosWindow(
        child: ListView(children: const [
          TranscriptLines(
            ['[00:01] Собеседник 1: Начнём с бюджета.', '[00:05] Собеседник 2: Согласна.', '[1:05:23] Я: Итоги.'],
            pending: ['[00:09] Я: Тогда я подготовлю'],
          ),
        ]),
      ),
      mode: ThemeMode.dark,
      size: const Size(760, 520),
    );
    expect(find.textContaining('Собеседник 2', findRichText: true), findsOneWidget);
    expect(find.textContaining('Тогда я подготовлю…', findRichText: true), findsOneWidget);
    // Время встречи длиннее часа — в одну строку, как и «00:05».
    expect(tester.getSize(find.text('1:05:23')).height, tester.getSize(find.text('00:05')).height);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    macTest('поиск в боковой панели — ${mode.name}', (tester) async {
      await pump(tester, const HomePage(), mode: mode, size: const Size(760, 520));
      final field = find.byType(MacosSearchField);
      expect(field, findsOneWidget);

      await tester.enterText(find.descendant(of: field, matching: find.byType(EditableText)), 'бюджета');
      await settle(tester);
      expect(find.text('Найдено: 1'), findsOneWidget);
      // Фрагмент с совпадением из выжимки.
      expect(find.textContaining('бюджет', findRichText: true), findsWidgets);

      await tester.enterText(find.descendant(of: field, matching: find.byType(EditableText)), 'несуществующее');
      await settle(tester);
      expect(find.text('Ничего не найдено'), findsOneWidget);

      await tester.enterText(find.descendant(of: field, matching: find.byType(EditableText)), '');
      await settle(tester);
      expect(find.text('Встречи'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    for (final size in [const Size(760, 520), const Size(1280, 800)]) {
      final variant = '${mode.name} ${size.width.toInt()}×${size.height.toInt()}';

      macTest('главное окно: боковая панель и экран записи — $variant', (tester) async {
        await pump(tester, const HomePage(), mode: mode, size: size);
        expect(find.text('Новая запись'), findsOneWidget);
        expect(find.text('Встречи'), findsOneWidget);
        expect(find.text('Начать запись'), findsOneWidget);
        expect(find.textContaining('Очень длинный заголовок'), findsWidgets);
        // Модель заметок — у кнопок окна, с иконкой «работает на этом Mac».
        expect(find.text('Gemma 4 E4B'), findsOneWidget);
        expect(_iconButton(CupertinoIcons.device_laptop), findsOneWidget);
        expect(tester.takeException(), isNull);
        // macos_window_utils синхронизирует нативный материал боковой панели по таймеру
        // и падает, если таймер сработает после удаления виджета: даём ему сработать раньше.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });

      macTest('чат по встречам: без модели кнопка неактивна; экран чата, подсказки, вопрос — $variant', (tester) async {
        await pump(tester, const HomePage(), mode: mode, size: size);
        // Модель для заметок не скачана — «Чат» бледный, не нажимается, подсказка объясняет почему.
        expect(find.text('Чат'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is MacosTooltip && w.message == 'Чат заработает, когда будет скачана модель для заметок.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Чат'));
        await tester.pump();
        expect(find.text('Спросите о прошедших встречах'), findsNothing);
        expect(find.text('Начать запись'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));

        // Сам экран чата: пустое состояние и вопрос (модель не скачана — понятный ответ).
        await pump(tester, MacosWindow(child: ChatPage(onOpenMeeting: (_) {})), mode: mode, size: size);
        expect(find.text('Спросите о прошедших встречах'), findsOneWidget);
        expect(find.text('Чат по встречам'), findsOneWidget);
        await tester.tap(find.text('Какие задачи на мне?'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Какие задачи на мне?'), findsOneWidget);
        expect(find.textContaining('ещё скачивается'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });

      macTest('просмотр встречи — $variant', (tester) async {
        await pump(tester, MacosWindow(child: MeetingView(meeting: meeting, actions: _noActions)), mode: mode, size: size);
        expect(find.text('Кратко'), findsOneWidget);
        // Заголовок — только в тулбаре, без дубля в содержимом.
        expect(find.text(meeting.title), findsOneWidget);
        expect(find.textContaining('Расшифровка · 2 реплик'), findsOneWidget);
        // Расшифровка разворачивается без переполнений.
        await tester.tap(find.textContaining('Расшифровка · 2 реплик'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('подготовлю вакансии'), findsWidgets);
        expect(tester.takeException(), isNull);
        // macos_window_utils синхронизирует нативный материал боковой панели по таймеру
        // и падает, если таймер сработает после удаления виджета: даём ему сработать раньше.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });

      macTest('экран загрузки моделей — $variant', (tester) async {
        summaryModelChoice.recommend(gemmaE4b);
        await pump(tester, SetupPage(models: modelManager, onContinue: () {}), mode: mode, size: size);
        expect(find.text('Подготовка Znaika'), findsOneWidget);
        expect(find.textContaining('Распознавание речи', findRichText: true), findsOneWidget);
        // Выбор модели для заметок — карточка выбранной, рекомендованная отмечена.
        // Заголовок карточки: «название   размер».
        expect(find.textContaining('Gemma 4 E4B   ', findRichText: true, skipOffstage: false), findsOneWidget);
        expect(find.text('Рекомендуется для этого Mac', skipOffstage: false), findsOneWidget);
        // Прокрутка на всё окно, без полосы прокрутки.
        expect(find.byType(MacosScrollbar), findsNothing);
        expect(tester.getSize(find.byType(SingleChildScrollView)).width, size.width);
        expect(tester.takeException(), isNull);
        // macos_window_utils синхронизирует нативный материал боковой панели по таймеру
        // и падает, если таймер сработает после удаления виджета: даём ему сработать раньше.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}

final _noActions = MeetingActions(
  rename: (_) async {},
  renameSpeaker: (_, _) async {},
  export: () {},
  copyNotes: () {},
  delete: () {},
);

/// Кнопка по иконке (в тулбаре ToolBarIconButton — не виджет, поэтому ищем саму иконку).
Finder _iconButton(IconData icon) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == icon).hitTestable();
