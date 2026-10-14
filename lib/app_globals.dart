import 'dart:io';

import 'meetings.dart';
import 'model_manager.dart';
import 'summarizer.dart';
import 'summary_models.dart';

/// Данные приложения (встречи, модели): на macOS без песочницы —
/// ~/Library/Application Support/local.experiments.znaika.
late final Directory appSupportDir;

/// Пересоздаваемое (кэш GPU-ядер Gemma): ~/Library/Caches/local.experiments.znaika.
/// Time Machine его не бэкапит, macOS может чистить при нехватке места.
late final Directory appCacheDir;

/// Встречи: папки в recordings и их индекс в znaika.sqlite.
late final MeetingStore meetingStore;

/// Модели: проверка и загрузка при первом запуске.
late final ModelManager modelManager;

/// Gemma для заметок — одна на всё приложение (создаётся при первом обращении).
/// Кэш GPU-ядер — litert-lm-f32: ядра под float32 (см. LlmEngine.load); старый
/// litert-lm (float16) Summarizer удаляет.
final summarizer = Summarizer(
  modelsDir: modelsDir,
  cacheDir: '${appCacheDir.path}/litert-lm-f32',
  staleCacheDirs: ['${appCacheDir.path}/litert-lm'],
  modelFile: () => summaryModelChoice.effective.file,
);

/// Какой моделью писать заметки (выбор — щелчком по её названию у кнопок окна).
final summaryModelChoice = SummaryModelChoice(File('${appSupportDir.path}/settings.json'));

/// Модели (GigaAM, Silero VAD, Gemma); скачиваются при первом запуске (ModelManager).
String get modelsDir => '${appSupportDir.path}/models';

/// Самопроверка из терминала (ZNAIKA_*): экран загрузки моделей не показываем.
bool get selftestMode =>
    Platform.environment.keys.any((k) => k.startsWith('ZNAIKA_') && k != 'ZNAIKA_SHOW_SETUP');

/// ZNAIKA_SHOW_SETUP=1 — показать экран загрузки моделей, даже если всё скачано
/// (посмотреть, как он выглядит): `open -n --env ZNAIKA_SHOW_SETUP=1 znaika.app`.
bool get showSetupScreen => Platform.environment['ZNAIKA_SHOW_SETUP'] == '1';
