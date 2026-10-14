import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/app_globals.dart';
import 'package:znaika/model_manager.dart';
import 'package:znaika/model_manifest.dart';
import 'package:znaika/summary_models.dart';

void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('summary_models');
    modelManager = ModelManager(Directory('${root.path}/models'));
    await modelManager.check();
  });

  tearDownAll(() => root.delete(recursive: true));

  test('выбор сохраняется в settings.json и становится моделью для загрузки', () {
    final file = File('${root.path}/settings.json');
    final choice = SummaryModelChoice(file);
    expect(choice.chosen, gemmaE4b);

    choice.select(gemmaE2b);
    expect(SummaryModelChoice(file).chosen, gemmaE2b);
    expect(modelManager.requiredPackages.last, gemmaE2b.package);
    // Ничего не скачано — заметки дождутся выбранной.
    expect(choice.effective, gemmaE2b);
  });

  test('рекомендация по памяти: выбор по умолчанию, но не поверх выбора пользователя', () {
    expect(recommendedSummaryModel(16 << 30), gemmaE4b);
    expect(recommendedSummaryModel(8 << 30), gemmaE2b);

    final fresh = SummaryModelChoice(File('${root.path}/fresh.json'));
    fresh.recommend(gemmaE2b);
    expect(fresh.chosen, gemmaE2b);
    expect(fresh.recommended, gemmaE2b);

    final saved = File('${root.path}/saved.json')..writeAsStringSync('{"summaryModel": "${qwen3_4b.id}"}');
    final user = SummaryModelChoice(saved)..recommend(gemmaE4b);
    expect(user.chosen, qwen3_4b);
  });

  test('испорченный settings.json — основная модель', () {
    final file = File('${root.path}/broken.json')..writeAsStringSync('{не json');
    expect(SummaryModelChoice(file).chosen, gemmaE4b);
  });

  test('у моделей для заметок разные файлы и пакеты', () {
    expect(summaryModels.map((m) => m.file).toSet(), hasLength(summaryModels.length));
    expect(allPackages.map((p) => p.id).toSet(), hasLength(allPackages.length));
    expect(allPackages, containsAll([for (final m in summaryModels) m.package]));
    expect(modelManager.stateOf(gemmaE2b.package).status, PackageStatus.missing);
  });

  test('все модели качаются по HTTPS с закреплённой версии и с SHA-256', () {
    for (final p in allPackages) {
      for (final f in p.files) {
        expect(Uri.parse(f.url).scheme, 'https', reason: f.url);
        expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.path);
        if (f.url.contains('huggingface.co')) {
          expect(f.url, matches(RegExp(r'/resolve/[0-9a-f]{40}/')), reason: 'версия не закреплена: ${f.url}');
        }
      }
    }
  });
}
