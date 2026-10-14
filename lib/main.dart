import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app_globals.dart';
import 'database.dart';
import 'home_page.dart';
import 'meetings.dart';
import 'model_manager.dart';
import 'model_manifest.dart';
import 'setup_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _migrateFromMeetNotes();
  // Пути — от системы, а не от HOME: в песочнице они указывают внутрь контейнера.
  appSupportDir = await getApplicationSupportDirectory();
  appCacheDir = await getApplicationCacheDirectory();
  stdout.writeln('Данные: ${appSupportDir.path}');
  stdout.writeln('Кэш: ${appCacheDir.path}');
  await _removeLegacyCache();
  meetingStore = MeetingStore(
    Directory('${appSupportDir.path}/recordings'),
    AppDatabase.open(File('${appSupportDir.path}/znaika.sqlite')),
  );
  modelManager = ModelManager(Directory(modelsDir));
  // Модель для заметок по умолчанию — по памяти этого Mac (если пользователь ещё не выбирал).
  summaryModelChoice.recommend(recommendedSummaryModel(await _physicalMemory()));
  // ZNAIKA_DOWNLOAD=N — проверить модели, качать N секунд, поставить на паузу и выйти.
  final downloadSeconds = int.tryParse(Platform.environment['ZNAIKA_DOWNLOAD'] ?? '');
  if (downloadSeconds != null) return _downloadSelftest(downloadSeconds);

  // Окно как у современных приложений macOS: заголовок прозрачный, контент
  // (и полупрозрачная боковая панель) — на всю высоту окна, под кнопками окна.
  await const MacosWindowUtilsConfig().apply();
  await WindowManipulator.setWindowMinSize(const Size(760, 520));
  runApp(const ZnaikaApp());
}

Future<void> _downloadSelftest(int seconds) async {
  String line() => [
        for (final p in modelManager.requiredPackages)
          '${p.id}=${modelManager.stateOf(p).status.name}'
              ' ${formatBytes(modelManager.stateOf(p).received)}/${formatBytes(p.size)}',
        if (modelManager.speed > 0) '${formatBytes(modelManager.speed)}/с',
        if (modelManager.error != null) 'ошибка: ${modelManager.error}',
      ].join('  ');
  final watch = Stopwatch()..start();
  await modelManager.check();
  stdout.writeln('SELFTEST проверка ${watch.elapsedMilliseconds} мс: ${line()}');
  await modelManager.start();
  while (modelManager.downloading && watch.elapsed.inSeconds < seconds) {
    await Future<void>.delayed(const Duration(seconds: 5));
    stdout.writeln('SELFTEST ${watch.elapsed.inSeconds} с: ${line()}');
  }
  if (modelManager.downloading) modelManager.pause();
  stdout.writeln('SELFTEST итог: ${line()}');
  for (final p in modelManager.requiredPackages) {
    final error = modelManager.stateOf(p).error;
    if (error != null) stdout.writeln('SELFTEST ${p.id}: $error');
  }
  exit(0);
}

/// Объём памяти Mac; без нативной части (тесты) — 16 ГБ.
Future<int> _physicalMemory() async {
  try {
    return await const MethodChannel('znaika/system').invokeMethod<int>('physicalMemory') ?? 16 << 30;
  } catch (_) {
    return 16 << 30;
  }
}

/// До 2026-10-13 приложение называлось MeetNotes (идентификатор local.experiments.meetnotes):
/// встречи, модели, настройки и кэш лежали в папках с этим именем. При первом запуске Znaika
/// они переносятся переименованием — без копирования гигабайт моделей. Новая папка уже с
/// данными — не трогаем ничего.
Future<void> _migrateFromMeetNotes() async {
  final home = Platform.environment['HOME'];
  if (home == null) return;
  Future<void> move(String from, String to) async {
    final old = Directory(from);
    final now = Directory(to);
    if (!await old.exists()) return;
    if (await now.exists()) {
      // Пустую папку могла создать система — её заменяем.
      if (!await now.list().isEmpty) return;
      await now.delete();
    }
    await now.parent.create(recursive: true);
    await old.rename(now.path);
    stdout.writeln('Перенесено: $from → $to');
  }

  for (final base in ['$home/Library/Application Support', '$home/Library/Caches']) {
    await move('$base/local.experiments.meetnotes', '$base/local.experiments.znaika');
  }
  await move('$home/Library/Logs/MeetNotes', '$home/Library/Logs/Znaika');
  final data = '$home/Library/Application Support/local.experiments.znaika';
  for (final suffix in ['', '-wal', '-shm']) {
    final db = File('$data/meetnotes.sqlite$suffix');
    if (await db.exists() && !await File('$data/znaika.sqlite$suffix').exists()) {
      await db.rename('$data/znaika.sqlite$suffix');
    }
  }
  final log = File('$home/Library/Logs/Znaika/meetnotes.log');
  if (await log.exists() && !await File('$home/Library/Logs/Znaika/znaika.log').exists()) {
    await log.rename('$home/Library/Logs/Znaika/znaika.log');
  }
}

/// Ранние сборки клали кэш GPU-ядер в Application Support; теперь он в Caches.
/// Это кэш (~2 ГБ), он пересоздаётся сам, поэтому старую копию просто удаляем.
Future<void> _removeLegacyCache() async {
  final legacy = Directory('${appSupportDir.path}/cache');
  if (await legacy.exists()) {
    await legacy.delete(recursive: true);
    stdout.writeln('Удалён старый кэш: ${legacy.path}');
  }
}

class ZnaikaApp extends StatelessWidget {
  const ZnaikaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MacosApp(
      title: 'Znaika',
      // Светлая или тёмная — как в системе; акцентный цвет macos_ui берёт системный.
      theme: MacosThemeData.light(),
      darkTheme: MacosThemeData.dark(),
      themeMode: ThemeMode.system,
      // Русские подписи стандартных элементов (контекстное меню «Скопировать» и т. п.).
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      home: const _Root(),
    );
  }
}

/// Пока не готовы модели расшифровки — экран загрузки, затем основное окно.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _proceeded = selftestMode;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    if (!selftestMode) {
      modelManager.check().then((_) {
        if (!mounted) return;
        setState(() {
          _checked = true;
          // Запись и расшифровка работают — экран загрузки не нужен; остальное
          // (новые необязательные модели после обновления, Gemma) докачается в фоне.
          if (modelManager.transcriptionReady && !showSetupScreen) {
            _proceeded = true;
            if (!modelManager.allReady) modelManager.start();
          } else if (modelManager.shouldResume) {
            // Экран загрузки после перезапуска посреди загрузки: продолжаем сами,
            // «Продолжить загрузку» остаётся только после явной «Паузы».
            modelManager.start();
          }
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_proceeded) return const HomePage();
    return SetupPage(models: modelManager, onContinue: _checked ? () => setState(() => _proceeded = true) : () {});
  }
}
