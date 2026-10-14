import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import 'model_manager.dart';
import 'model_manifest.dart';
import 'ui.dart';

// Части карточек моделей — одинаковые на экране первого запуска и в листе
// «Модель для заметок»: заголовок с размером, строка лицензии с «скачана»,
// отметка «Рекомендуется», статус загрузки.

/// Заголовок карточки модели: название и размер — одинаково у всех карточек экрана.
class ModelTitleLine extends StatelessWidget {
  const ModelTitleLine({super.key, required this.title, required this.size});

  final String title;
  final int size;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: typography.headline),
          TextSpan(
            text: '   ${formatBytes(size)}',
            style: typography.body.copyWith(color: secondaryLabel(context)),
          ),
        ],
      ),
    );
  }
}

/// «Модель (автор) · лицензия · скачана» — «скачана» зелёным.
class ModelLicenseLine extends StatelessWidget {
  const ModelLicenseLine({
    super.key,
    required this.description,
    required this.ready,
  });

  final String description;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final style = MacosTheme.of(context).typography.callout;
    return Text.rich(
      TextSpan(
        style: style.copyWith(color: secondaryLabel(context)),
        children: [
          TextSpan(text: description),
          if (ready)
            TextSpan(
              text: ' · скачана',
              style: TextStyle(
                color: MacosColors.systemGreenColor.resolveFrom(context),
              ),
            ),
        ],
      ),
    );
  }
}

/// «Рекомендуется для этого Mac» — у модели, подобранной по памяти.
class RecommendedBadge extends StatelessWidget {
  const RecommendedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final color = MacosTheme.of(context).primaryColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MacosIcon(CupertinoIcons.star_fill, size: 11, color: color),
        const SizedBox(width: Gap.tiny),
        Text(
          'Рекомендуется для этого Mac',
          style: MacosTheme.of(context).typography.callout
              .copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// «1,2 ГБ из 3,7 ГБ · 25 МБ/с · осталось 2 мин», «Готово», «В очереди · 2,6 ГБ»…
String modelStatusText(
  ModelPackage package,
  PackageState state,
  double speed,
) => switch (state.status) {
  PackageStatus.checking => 'Проверка…',
  PackageStatus.ready => 'Готово',
  PackageStatus.failed => 'Ошибка: ${state.error}',
  PackageStatus.queued =>
    state.received > 0
        ? 'В очереди · загружено ${formatBytes(state.received)} из ${formatBytes(package.size)}'
        : 'В очереди · ${formatBytes(package.size)}',
  PackageStatus.missing =>
    state.received > 0
        ? 'Загружено ${formatBytes(state.received)} из ${formatBytes(package.size)}'
        : formatBytes(package.size),
  PackageStatus.downloading => [
    '${formatBytes(state.received)} из ${formatBytes(package.size)}',
    if (speed > 0) '${formatBytes(speed)}/с',
    if (speed > 0)
      'осталось ${formatEta((package.size - state.received) / speed)}',
  ].join(' · '),
};

String formatEta(double seconds) {
  if (seconds < 60) return '${seconds.ceil()} с';
  final minutes = (seconds / 60).ceil();
  return minutes < 60
      ? '$minutes мин'
      : '${minutes ~/ 60} ч ${minutes % 60} мин';
}
