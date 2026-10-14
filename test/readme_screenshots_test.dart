// Скриншоты для README: настоящие экраны приложения, отрисованные вне экрана, на
// вымышленных встречах (ничего из настоящих записей). По умолчанию пропускается:
//
//   ZNAIKA_SCREENSHOTS=1 flutter test test/readme_screenshots_test.dart
//
// Пишет docs/screenshots/<экран>-<light|dark>.png: окно в рамке macOS с тенью,
// шрифт — системный SF Pro (из /System/Library/Fonts), иконки — CupertinoIcons.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:meet_capture/meet_capture.dart';
import 'package:znaika/app_globals.dart';
import 'package:znaika/chat_page.dart';
import 'package:znaika/database.dart';
import 'package:znaika/home_page.dart';
import 'package:znaika/live_transcriber.dart';
import 'package:znaika/meetings.dart';
import 'package:znaika/model_manager.dart';
import 'package:znaika/model_manifest.dart';
import 'package:znaika/recorder_page.dart';
import 'package:znaika/setup_page.dart';
import 'package:znaika/transcriber.dart';

final _enabled = Platform.environment['ZNAIKA_SCREENSHOTS'] == '1';
const _window = Size(1180, 760);
const _margin = 48.0;
final _frameKey = GlobalKey();

/// Модели «скачаны» (или качаются — для экрана первого запуска) без гигабайт на диске.
class _FakeModels extends ModelManager {
  _FakeModels(super.modelsDir, {this.progress = const {}});

  /// id пакета → доля скачанного; остальные — готовы.
  final Map<String, double> progress;

  @override
  PackageState stateOf(ModelPackage p) => switch (progress[p.id]) {
        final part? when part < 1 => PackageState(
            part == 0 ? PackageStatus.queued : PackageStatus.downloading,
            received: (p.size * part).round(),
          ),
        _ => PackageState(PackageStatus.ready, received: p.size),
      };

}

void main() {
  late Directory root;
  final meetings = <String, Meeting>{};

  setUpAll(() async {
    if (!_enabled) return;
    await _loadFonts();
    root = await Directory.systemTemp.createTemp('readme_shots');
    appSupportDir = root;
    appCacheDir = Directory('${root.path}/cache');
    meetingStore = MeetingStore(Directory('${root.path}/recordings'), AppDatabase(NativeDatabase.memory()));
    modelManager = _FakeModels(Directory('${root.path}/models'));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final demo in _demoMeetings(today)) {
      final dir = await meetingStore.create(demo.at);
      await File('${dir.path}/transcript.md').writeAsString('# Расшифровка\n\n${demo.transcript.join('\n')}\n');
      if (demo.summary != null) {
        await File('${dir.path}/summary.md').writeAsString('# Заметки по встрече\n\n${demo.summary}\n');
      }
      await meetingStore.finish(dir, title: demo.title, durationSeconds: demo.minutes * 60.0);
    }
    for (final m in await meetingStore.list()) {
      meetings[m.title] = m;
    }
    await Directory('docs/screenshots').create(recursive: true);
  });

  tearDownAll(() async {
    if (_enabled) await root.delete(recursive: true);
  });

  setUp(() {
    // Нативные каналы (окно, меню, системные цвета) в тестах недоступны — как в ui_test.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['macos_window_utils/window_manipulator', 'macos_window_utils/ns_window_delegate', 'znaika/system']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(SystemChannels.menu, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('appkit_ui_element_colors'), (call) async {
      if (call.method == 'getColor') return 0xFF007AFF;
      final components = ((call.arguments as Map)['components'] as List).cast<String>();
      return {for (final c in components) c: c.contains('alpha') ? 1.0 : 0.5};
    });
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('README: встреча с заметками — ${mode.name}', skip: !_enabled, variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
      await _pump(tester, const HomePage(), mode);
      await tester.tap(find.text('Планирование релиза 2.4'));
      await _settle(tester);
      await _shot(tester, 'meeting-${mode.name}', mode);
      await _finish(tester);
    });

    testWidgets('README: идёт запись — ${mode.name}', skip: !_enabled, variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
      debugRecorderDemo = _recorderDemo;
      addTearDown(() => debugRecorderDemo = null);
      await _pump(tester, const HomePage(), mode);
      await _shot(tester, 'recording-${mode.name}', mode);
      await _finish(tester);
    });

    testWidgets('README: чат по встречам — ${mode.name}', skip: !_enabled, variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
      debugChatDemo = _chatDemo(meetings);
      addTearDown(() => debugChatDemo = null);
      await _pump(tester, const HomePage(), mode);
      // «Чат» доступен, когда HomePage прочитает файлы встреч (есть обработанные).
      final disabled = find.byWidgetPredicate((w) => w is MacosTooltip && w.message.startsWith('Чат заработает'));
      for (var i = 0; i < 40 && disabled.evaluate().isNotEmpty; i++) {
        await _settle(tester);
      }
      expect(disabled, findsNothing);
      await tester.tap(find.text('Чат'));
      await _settle(tester);
      await _shot(tester, 'chat-${mode.name}', mode);
      await _finish(tester);
    });

    testWidgets('README: первый запуск — ${mode.name}', skip: !_enabled, variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
      final models = _FakeModels(
        Directory('${root.path}/models'),
        progress: {gemmaE4b.package.id: 0.37, asrPackage.id: 1},
      );
      await _pump(tester, SetupPage(models: models, onContinue: () {}), mode, size: const Size(900, 760));
      await _shot(tester, 'setup-${mode.name}', mode, size: const Size(900, 760), sidebar: 0);
      await _finish(tester);
    });
  }
}

// MARK: отрисовка

Future<void> _loadFonts() async {
  final sf = File('/System/Library/Fonts/SFNS.ttf').readAsBytes();
  for (final family in ['.AppleSystemUIFont', 'Roboto']) {
    await (FontLoader(family)..addFont(sf.then(ByteData.sublistView))).load();
  }
  final config = jsonDecode(await File('.dart_tool/package_config.json').readAsString()) as Map;
  final cupertino = (config['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'cupertino_icons');
  final icons = File('${Uri.parse(cupertino['rootUri'] as String).toFilePath()}/assets/CupertinoIcons.ttf');
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(icons.readAsBytes().then(ByteData.sublistView)))
      .load();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _pump(WidgetTester tester, Widget home, ThemeMode mode, {Size size = _window}) async {
  tester.view.physicalSize = Size(size.width + 2 * _margin, size.height + 2 * _margin);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Системные цвета macOS (фон окна, боковой панели) берутся из темы системы, а не приложения.
  tester.platformDispatcher.platformBrightnessTestValue =
      mode == ThemeMode.dark ? Brightness.dark : Brightness.light;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  await tester.pumpWidget(MacosApp(
    debugShowCheckedModeBanner: false,
    theme: MacosThemeData.light(),
    darkTheme: MacosThemeData.dark(),
    themeMode: mode,
    home: _Frame(size: size, child: home),
  ));
  await _settle(tester);
}

/// Снимок окна поверх подложки. Фон окна и боковой панели macos_ui оставляет прозрачным —
/// в приложении сквозь него видна нативная «вибрация» macOS, — поэтому подложка (цвета
/// боковой панели и контента, как у macOS), скругление, обводка и тень дорисовываются здесь.
Future<void> _shot(WidgetTester tester, String name, ThemeMode mode, {Size size = _window, double sidebar = 260}) async {
  const scale = 2.0;
  final dark = mode == ThemeMode.dark;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_frameKey));
  await tester.runAsync(() async {
    final window = await boundary.toImage(pixelRatio: scale);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    final rect = Offset(_margin, _margin) & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    canvas.drawRRect(
      rrect.shift(const Offset(0, 14)),
      Paint()
        ..color = Color(dark ? 0x99000000 : 0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(rect, Paint()..color = Color(dark ? 0xFF1E1E1E : 0xFFFFFFFF));
    if (sidebar > 0) {
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, sidebar, rect.height),
        Paint()..color = Color(dark ? 0xFF2C2B30 : 0xFFEBEAEF),
      );
    }
    canvas.scale(1 / scale);
    canvas.drawImage(window, rect.topLeft * scale, Paint());
    canvas.restore();
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Color(dark ? 0x40FFFFFF : 0x26000000),
    );
    final image = await recorder.endRecording().toImage(
      ((size.width + 2 * _margin) * scale).round(),
      ((size.height + 2 * _margin) * scale).round(),
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('docs/screenshots/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

/// macos_window_utils синхронизирует материал боковой панели по таймеру — даём ему сработать.
Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

/// Окно macOS: скругление, тень, кнопки «закрыть/свернуть/развернуть», фон под
/// полупрозрачной боковой панелью. Вокруг — прозрачные поля под тень.
/// Окно размером [size] с кнопками «закрыть/свернуть/развернуть» (их рисует macOS, а не
/// приложение); подложку, тень и скругление добавляет [_shot].
class _Frame extends StatelessWidget {
  const _Frame({required this.size, required this.child});

  final Size size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RepaintBoundary(
        key: _frameKey,
        child: SizedBox.fromSize(
          size: size,
          child: Stack(
            children: [
              // Окну — его размер, а не размер холста с полями под тень.
              Positioned.fill(
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(size: size, padding: EdgeInsets.zero),
                  child: child,
                ),
              ),
              for (final (i, color) in [0xFFFF5F57, 0xFFFEBC2E, 0xFF28C840].indexed)
                Positioned(
                  left: 16 + i * 20.0,
                  top: 26 - 7,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Color(color),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0x1F000000), width: 0.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// MARK: вымышленные встречи

typedef _Demo = ({String title, DateTime at, int minutes, List<String> transcript, String? summary});

List<_Demo> _demoMeetings(DateTime today) => [
      (
        title: 'Планирование релиза 2.4',
        at: today.add(const Duration(hours: 11)),
        minutes: 47,
        transcript: const [
          '[00:00:05] Я: Коллеги, всем привет. Сегодня решаем по срокам релиза 2.4 и по офлайн-режиму.',
          '[00:00:14] Аня: Регресс ещё не закончен, нам нужно минимум два дня.',
          '[00:01:02] Дима: По офлайн-режиму плохие новости: при конфликте синхронизация теряет правки.',
          '[00:01:20] Я: Тогда офлайн-режим в 2.4 не берём?',
          '[00:01:31] Дима: Предлагаю спрятать его за флагом и выпустить в 2.5.',
          '[00:02:10] Собеседник 4: Поддержка просит не выпускать во вторник — у них пик обращений.',
          '[00:02:25] Я: Хорошо, Олег, тогда четверг. Аня, успеете с релизными заметками?',
          '[00:02:31] Собеседник 4: Четверг нам подходит.',
          '[00:02:40] Аня: Да, подготовлю к среде.',
        ],
        summary: '''## Кратко
Релиз 2.4 выходит в четверг, 23 октября: QA нужно ещё два дня на регресс, а во вторник у поддержки пик обращений. Офлайн-режим переносится в 2.5 — синхронизация пока теряет правки при конфликте.

## Обсуждение
- **Сроки.** Регресс не закончен, релиз во вторник рискованный [00:00:14]
- **Офлайн-режим.** При конфликте синхронизация теряет правки; решили спрятать за флагом [00:01:02]
- **Поддержка.** Просит не выпускать во вторник — пик обращений [00:02:10]

## Решения
- Релиз 2.4 — в четверг, 23 октября.
- Офлайн-режим — в 2.5, до тех пор за фича-флагом.

## Задачи
- [ ] Аня — подготовить релизные заметки — к среде [00:02:40]
- [ ] Дима — починить потерю правок при конфликте синхронизации — к 2.5 [00:01:31]
- [ ] Я — согласовать дату релиза с поддержкой — завтра [00:02:25]

## Открытые вопросы
- Нужен ли отдельный анонс для корпоративных клиентов?''',
      ),
      (
        title: 'Синк с дизайном: новый онбординг',
        at: today.add(const Duration(hours: 9, minutes: 30)),
        minutes: 32,
        transcript: const [
          '[00:00:03] Я: Посмотрим макеты онбординга?',
          '[00:00:09] Марина: Да, сократили до трёх шагов и убрали обязательную регистрацию.',
        ],
        summary: '''## Кратко
Онбординг сокращён до трёх шагов, регистрация — после первого полезного действия.

## Задачи
- [ ] Марина — финальные макеты — к пятнице [00:05:12]
- [ ] Я — оценить доработку API регистрации — до среды [00:07:40]''',
      ),
      (
        title: 'Интервью: frontend-разработчик',
        at: today.subtract(const Duration(days: 1)).add(const Duration(hours: 16)),
        minutes: 58,
        transcript: const ['[00:00:04] Я: Расскажите о последнем проекте.'],
        summary: '## Кратко\nСильный кандидат: React, тесты, опыт с дизайн-системой. Следующий этап — техническое интервью.',
      ),
      (
        title: 'Ретро спринта 41',
        at: today.subtract(const Duration(days: 2)).add(const Duration(hours: 15)),
        minutes: 41,
        transcript: const ['[00:00:02] Я: Что прошло хорошо в этом спринте?'],
        summary: '## Кратко\nСпринт закрыт на 85%; мешали долгие ревью. Договорились о ревью в течение дня.',
      ),
      (
        title: 'Бюджет на маркетинг Q4',
        at: today.subtract(const Duration(days: 3)).add(const Duration(hours: 12)),
        minutes: 36,
        transcript: const ['[00:00:06] Я: Начнём с итогов третьего квартала.'],
        summary: '## Кратко\nБюджет Q4 — без роста; рекламу на конференциях заменяют вебинарами.',
      ),
      (
        title: '1:1 с Мариной',
        at: today.subtract(const Duration(days: 6)).add(const Duration(hours: 10)),
        minutes: 28,
        transcript: const ['[00:00:03] Я: Как тебе новый проект?'],
        summary: '## Кратко\nМарина хочет больше исследовательских задач; обсудили план развития на полгода.',
      ),
    ];

final _recorderDemo = (
  elapsed: const Duration(minutes: 12, seconds: 37),
  micDevice: 'AirPods Pro',
  lines: const [
    Utterance(705, 711, 'Собеседник 1', 'Давайте начнём с метрик: конверсия в регистрацию выросла до 18%.'),
    Utterance(712, 716, 'Я', 'Отлично. А что с удержанием на второй неделе?'),
    Utterance(717, 726, 'Собеседник 2', 'Удержание пока на прежнем уровне, около 31%. Ждём эффекта от нового онбординга.'),
    Utterance(727, 733, 'Собеседник 1', 'Онбординг выкатываем на половину пользователей в понедельник.'),
    Utterance(734, 739, 'Я', 'Тогда через две недели сравним группы и решим, раскатывать ли на всех.'),
    Utterance(741, 748, 'Собеседник 2', 'Согласна. Я подготовлю дашборд с разбивкой по каналам привлечения.'),
  ],
  partial: const PartialUtterance('system', 750, 'И ещё по рекламе: кампания в поиске'),
  levels: const CaptureLevels(system: -18, mic: -42),
);

List<({String question, String answer, List<Meeting> sources})> _chatDemo(Map<String, Meeting> m) => [
      (
        question: 'Что решили по релизу 2.4?',
        answer: '''- Релиз 2.4 выходит в **четверг, 23 октября**: QA нужно ещё два дня на регресс, а во вторник у поддержки пик обращений [1].
- **Офлайн-режим** переносится в 2.5 и до тех пор будет за фича-флагом: синхронизация теряет правки при конфликте [1].''',
        sources: [m['Планирование релиза 2.4']!],
      ),
      (
        question: 'Какие задачи на мне на этой неделе?',
        answer: '''- Согласовать дату релиза с поддержкой — завтра [1].
- Оценить доработку API регистрации для нового онбординга — до среды [2].''',
        sources: [m['Планирование релиза 2.4']!, m['Синк с дизайном: новый онбординг']!],
      ),
    ];
