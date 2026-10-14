import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import 'app_globals.dart';
import 'model_cards.dart';
import 'model_manager.dart';
import 'model_manifest.dart';
import 'ui.dart';

/// Какой моделью писать заметки. Выбор хранится в settings.json рядом с встречами;
/// пока пользователь не выбирал — рекомендованная для этого Mac ([recommend]).
/// Выбранная модель качается вместе с обязательными; пока она не скачана, заметки
/// пишет другая скачанная, если такая есть.
class SummaryModelChoice extends ChangeNotifier {
  SummaryModelChoice(this.settingsFile) {
    try {
      final settings = jsonDecode(settingsFile.readAsStringSync()) as Map;
      final id = settings['summaryModel'];
      if (summaryModels.any((m) => m.id == id)) {
        _id = id as String;
        _saved = true;
      }
    } catch (_) {
      // Нет файла или он испорчен — рекомендованная модель.
    }
    modelManager.summaryPackage = chosen.package;
    modelManager.addListener(_onModels);
  }

  final File settingsFile;
  String _id = gemmaE4b.id;

  /// Пользователь выбирал модель сам — рекомендация её не меняет.
  bool _saved = false;

  /// Рекомендованная для этого Mac (по памяти); null — ещё не определили.
  SummaryModel? recommended;

  /// Модель, которую выбрали скачать: когда скачается — станет выбранной.
  String? _wanted;

  SummaryModel get chosen => summaryModels.firstWhere((m) => m.id == _id);

  /// Модель, которой на самом деле пишутся заметки: выбранная, а пока она не скачана —
  /// любая другая скачанная; если скачанных нет — выбранная (заметки её дождутся).
  SummaryModel get effective {
    if (modelManager.isReady(chosen.package)) return chosen;
    return summaryModels
            .where((m) => modelManager.isReady(m.package))
            .firstOrNull ??
        chosen;
  }

  /// Рекомендация по памяти этого Mac: становится выбором, если пользователь не выбирал.
  void recommend(SummaryModel model) {
    recommended = model;
    if (!_saved) _setChosen(model);
    notifyListeners();
  }

  void select(SummaryModel model) {
    _wanted = null;
    _saved = true;
    if (model.id != _id) _setChosen(model);
    _save();
    notifyListeners();
  }

  void _setChosen(SummaryModel model) {
    _id = model.id;
    modelManager.summaryPackage = model.package;
  }

  /// Скачать модель и, когда скачается, сразу писать заметки ею.
  Future<void> download(SummaryModel model) async {
    _wanted = model.id;
    await modelManager.download(model.package);
    notifyListeners();
  }

  /// Удалить скачанную модель вместе с её кэшем GPU-ядер (он размером почти с модель).
  Future<void> delete(SummaryModel model) async {
    if (model.id == _wanted) _wanted = null;
    // Удалили выбранную — выбираем другую скачанную (или рекомендованную).
    if (model.id == _id) {
      final other =
          summaryModels
              .where((m) => m.id != model.id && modelManager.isReady(m.package))
              .firstOrNull ??
          recommended ??
          gemmaE4b;
      select(other);
    }
    await modelManager.delete(model.package);
    final cache = Directory('${appCacheDir.path}/litert-lm-f32');
    if (await cache.exists()) {
      await for (final entry in cache.list()) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && name.startsWith(model.file)) {
          await entry.delete();
        }
      }
    }
    notifyListeners();
  }

  void _onModels() {
    final wanted = _wanted;
    if (wanted == null) return;
    final model = summaryModels.firstWhere((m) => m.id == wanted);
    final status = modelManager.stateOf(model.package).status;
    if (status == PackageStatus.ready) {
      select(model);
    } else if (status == PackageStatus.failed ||
        status == PackageStatus.missing) {
      _wanted = null;
    }
  }

  void _save() {
    try {
      Map<String, Object?> settings = {};
      if (settingsFile.existsSync()) {
        settings = (jsonDecode(settingsFile.readAsStringSync()) as Map)
            .cast<String, Object?>();
      }
      settings['summaryModel'] = _id;
      settingsFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(settings),
      );
    } catch (_) {}
  }
}

/// Модель для заметок ещё докачивается — ждём её, сообщая процент; загрузка на паузе —
/// возобновляем.
Future<void> waitForSummaryModel(void Function(String stage) onStage) async {
  final package = summaryModelChoice.effective.package;
  if (selftestMode || modelManager.isReady(package)) return;
  if (!modelManager.downloading) await modelManager.start();
  void update() {
    final percent =
        (modelManager.stateOf(package).received * 100 / package.size).floor();
    onStage('Жду загрузку модели для заметок… $percent%');
  }

  modelManager.addListener(update);
  update();
  try {
    await modelManager.waitFor(package);
  } finally {
    modelManager.removeListener(update);
  }
}

/// Лист «Модель для заметок»: список моделей, скачивание, выбор и удаление.
class SummaryModelsSheet extends StatelessWidget {
  const SummaryModelsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return MacosSheet(
      child: Padding(
        padding: const EdgeInsets.all(Gap.group),
        child: ListenableBuilder(
          listenable: Listenable.merge([modelManager, summaryModelChoice]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Модель для заметок', style: typography.title2),
              const SizedBox(height: Gap.tiny),
              Text(
                'Все модели встроенные: скачиваются один раз и работают на этом Mac без интернета. '
                'Модель меняется для следующих заметок.',
                style: typography.body.copyWith(color: secondaryLabel(context)),
              ),
              if (modelManager.error case final error?) ...[
                const SizedBox(height: Gap.small),
                Callout(text: error, kind: CalloutKind.warning),
              ],
              const SizedBox(height: Gap.group),
              Expanded(
                // Моделей три — строятся все сразу, в маленьком окне список прокручивается.
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, model) in summaryModels.indexed) ...[
                        if (i > 0) const SizedBox(height: Gap.small),
                        _ModelRow(model),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.group),
              Align(
                alignment: Alignment.centerRight,
                child: PushButton(
                  controlSize: ControlSize.large,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Готово'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow(this.model);

  final SummaryModel model;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final typography = theme.typography;
    final state = modelManager.stateOf(model.package);
    final ready = state.status == PackageStatus.ready;
    final inUse = summaryModelChoice.effective.id == model.id;
    final loading =
        state.status == PackageStatus.downloading ||
        state.status == PackageStatus.queued;

    final Widget action = switch (state.status) {
      PackageStatus.ready when inUse => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MacosIcon(
            CupertinoIcons.checkmark_alt,
            size: 15,
            color: theme.primaryColor,
          ),
          const SizedBox(width: Gap.tiny),
          Text(
            'Используется',
            style: typography.body.copyWith(color: theme.primaryColor),
          ),
        ],
      ),
      PackageStatus.ready => PushButton(
        controlSize: ControlSize.regular,
        onPressed: () => summaryModelChoice.select(model),
        child: const Text('Выбрать'),
      ),
      PackageStatus.checking => Text(
        'Проверяю…',
        style: typography.body.copyWith(color: secondaryLabel(context)),
      ),
      PackageStatus.downloading || PackageStatus.queued => PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: () => summaryModelChoice.delete(model),
        child: const Text('Отменить'),
      ),
      PackageStatus.missing || PackageStatus.failed => PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: () => summaryModelChoice.download(model),
        child: Text(state.received > 0 ? 'Докачать' : 'Скачать'),
      ),
    };

    // Удалить можно любую скачанную (или начатую), кроме той, которой пишутся заметки.
    final canDelete =
        !loading && !(inUse && ready) && (ready || state.received > 0);
    final showProgress =
        loading ||
        state.status == PackageStatus.failed ||
        (!ready && state.received > 0);
    // Красная корзина в правом нижнем углу карточки (как удаление в списках macOS).
    final Widget? trash = canDelete
        ? MacosTooltip(
            message: 'Удалить модель',
            child: MacosIconButton(
              semanticLabel: 'Удалить модель',
              icon: MacosIcon(
                CupertinoIcons.trash,
                size: 16,
                color: MacosColors.systemRedColor.resolveFrom(context),
              ),
              boxConstraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: const EdgeInsets.all(4),
              onPressed: () => summaryModelChoice.delete(model),
            ),
          )
        : null;

    return Container(
      padding: const EdgeInsets.all(Gap.small),
      decoration: BoxDecoration(
        color: inUse
            ? theme.primaryColor.withValues(
                alpha: isDark(context) ? 0.16 : 0.08,
              )
            : null,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: inUse ? theme.primaryColor : theme.dividerColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ModelTitleLine(
                        title: model.name,
                        size: model.package.size,
                      ),
                      if (summaryModelChoice.recommended?.id == model.id) ...[
                        const SizedBox(height: Gap.line),
                        const RecommendedBadge(),
                      ],
                      const SizedBox(height: Gap.line),
                      Text(
                        model.note,
                        style: typography.callout.copyWith(
                          color: secondaryLabel(context),
                        ),
                      ),
                      ModelLicenseLine(
                        description: model.package.description,
                        ready: ready,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Gap.small),
                // Действие сверху, корзина — внизу справа (если ниже нет полосы загрузки).
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [action, if (trash != null && !showProgress) trash],
                ),
              ],
            ),
          ),
          // Загрузка — как на экране первого запуска: полоса и статус во всю ширину.
          if (showProgress) ...[
            const SizedBox(height: Gap.related),
            ProgressBar(
              value: (state.received * 100 / model.package.size)
                  .clamp(0, 100)
                  .toDouble(),
              height: 4,
            ),
            const SizedBox(height: Gap.tiny),
            Row(
              children: [
                Expanded(
                  child: Text(
                    modelStatusText(model.package, state, modelManager.speed),
                    style: typography.callout.copyWith(
                      color: state.status == PackageStatus.failed
                          ? MacosColors.systemRedColor.resolveFrom(context)
                          : secondaryLabel(context),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                ?trash,
              ],
            ),
          ],
        ],
      ),
    );
  }
}
