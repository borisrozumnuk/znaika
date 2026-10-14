import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import 'app_globals.dart';
import 'log.dart';
import 'model_cards.dart';
import 'model_manager.dart';
import 'model_manifest.dart';
import 'ui.dart';

/// Экран первого запуска: загрузка моделей и выбор модели для заметок.
/// Окно открывается такой высоты, чтобы всё поместилось без прокрутки, — если это
/// умещается в рабочую область экрана; иначе остаётся прежним и прокручивается.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.models, required this.onContinue});

  final ModelManager models;

  /// Перейти к приложению (доступно, когда готовы модели расшифровки).
  final VoidCallback onContinue;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _column = GlobalKey();
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    widget.models.addListener(_fitOnce);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitOnce());
  }

  @override
  void dispose() {
    widget.models.removeListener(_fitOnce);
    super.dispose();
  }

  /// Один раз, когда проверка скачанного закончилась и строки приняли окончательный вид.
  void _fitOnce() {
    if (_fitted) return;
    final checking = widget.models.requiredPackages.any(
      (p) => widget.models.stateOf(p).status == PackageStatus.checking,
    );
    if (checking) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final box = _column.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      try {
        final fitted = await const MethodChannel('znaika/system')
            .invokeMethod<bool>('fitHeight', {'height': box.size.height});
        logLine(
          'Экран загрузки: высота содержимого ${box.size.height.round()} — '
          '${fitted == true ? 'окно подогнано' : 'не помещается на экран, размер прежний'}',
        );
      } catch (_) {
        // Нет нативной части (тесты) — окно как есть.
      }
    });
  }

  @override
  Widget build(BuildContext context) => _SetupBody(
    models: widget.models,
    onContinue: widget.onContinue,
    columnKey: _column,
  );
}

class _SetupBody extends StatelessWidget {
  const _SetupBody({
    required this.models,
    required this.onContinue,
    required this.columnKey,
  });

  final ModelManager models;
  final VoidCallback onContinue;

  /// Колонка с содержимым — по её высоте подгоняется окно.
  final Key columnKey;

  @override
  Widget build(BuildContext context) {
    return MacosWindow(
      child: MacosScaffold(
        children: [
          ContentArea(
            // Прокручивается всё окно, а не узкая колонка посередине; полосы прокрутки нет.
            builder: (context, scrollController) => ListenableBuilder(
              listenable: Listenable.merge([models, summaryModelChoice]),
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) => ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: ConstrainedBox(
                      // Пока всё помещается — колонка по центру окна и по высоте.
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                        minWidth: constraints.maxWidth,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Padding(
                            key: columnKey,
                            // Сверху — ещё высота заголовка окна с его кнопками.
                            padding: const EdgeInsets.fromLTRB(
                              Gap.group,
                              Gap.group + 28,
                              Gap.group,
                              Gap.group,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _content(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final checking = models.requiredPackages.any(
      (p) => models.stateOf(p).status == PackageStatus.checking,
    );
    return [
      // Волна в цветах иконки приложения: бирюзовый → фиолетовый слева направо.
      ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => const LinearGradient(
          colors: [Color(0xFF40D9F2), Color(0xFFB366F2)],
        ).createShader(bounds),
        child: const MacosIcon(CupertinoIcons.waveform, size: 44),
      ),
      const SizedBox(height: Gap.small),
      Text(
        'Подготовка Znaika',
        textAlign: TextAlign.center,
        style: typography.title1,
      ),
      const SizedBox(height: Gap.related),
      Text(
        'Запись, расшифровка и заметки работают прямо на этом Mac, без интернета. '
        'Для этого один раз нужно скачать модели — ${formatBytes(models.totalSize)}.',
        textAlign: TextAlign.center,
        style: typography.body.copyWith(color: secondaryLabel(context)),
      ),
      const SizedBox(height: Gap.group),
      GroupBox(
        // Последняя строка сама даёт нижний отступ Gap.small.
        padding: const EdgeInsets.fromLTRB(Gap.small, Gap.small, Gap.small, 0),
        child: Column(
          children: [
            for (final p in basePackages)
              _PackageRow(
                package: p,
                state: models.stateOf(p),
                speed: models.speed,
              ),
          ],
        ),
      ),
      const SizedBox(height: Gap.group),
      // Отдельная карточка — как верхняя с моделями распознавания: заголовок,
      // подпись, под ними выбор модели.
      GroupBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Модель для заметок', style: typography.headline),
            Text(
              'Скачается выбранная. Сменить её можно и потом — щелчком по названию модели в окне.',
              style: typography.callout.copyWith(
                color: secondaryLabel(context),
              ),
            ),
            const SizedBox(height: Gap.related),
            _SummaryModelPicker(
              chosen: summaryModelChoice.chosen,
              models: models,
              onSelect: _choose,
            ),
          ],
        ),
      ),
      if (models.error != null) ...[
        const SizedBox(height: Gap.small),
        Callout(kind: CalloutKind.error, text: models.error!),
      ],
      const SizedBox(height: Gap.group),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (checking)
            const Expanded(child: ActivityRow('Проверяю уже скачанное…'))
          else if (models.downloading)
            PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: models.pause,
              child: const Text('Пауза'),
            )
          else if (!models.allReady)
            PushButton(
              controlSize: ControlSize.large,
              secondary: models.transcriptionReady,
              onPressed: models.start,
              child: Text(
                models.totalReceived > 0 ? 'Продолжить загрузку' : 'Скачать',
              ),
            ),
          const SizedBox(width: Gap.small),
          PushButton(
            controlSize: ControlSize.large,
            secondary: !models.transcriptionReady,
            onPressed: models.transcriptionReady ? onContinue : null,
            child: const Text('Начать работу'),
          ),
        ],
      ),
      if (models.transcriptionReady && !models.allReady) ...[
        const SizedBox(height: Gap.small),
        Text(
          'Запись и расшифровка уже работают. Модель для заметок докачается в фоне — приложение можно не закрывать.',
          textAlign: TextAlign.right,
          style: typography.callout.copyWith(color: secondaryLabel(context)),
        ),
      ],
    ];
  }
}

extension on _SetupBody {
  /// Другая модель для заметок: если загрузка уже идёт — перезапускаем её с новой моделью
  /// (начатый файл прежней остаётся на диске для докачки).
  void _choose(SummaryModel model) {
    if (summaryModelChoice.chosen.id == model.id) return;
    final wasDownloading = models.downloading;
    summaryModelChoice.select(model);
    if (wasDownloading) {
      models.pause();
      models.start();
    }
  }
}

/// Выбор модели для заметок: карточка выбранной модели, по щелчку под ней раскрывается
/// панель с карточками всех моделей (название, размер, «Рекомендуется», чем отличается,
/// скачана ли). Закрывается выбором, щелчком мимо или Esc. Под карточкой — ход загрузки.
class _SummaryModelPicker extends StatefulWidget {
  const _SummaryModelPicker({
    required this.chosen,
    required this.models,
    required this.onSelect,
  });

  final SummaryModel chosen;
  final ModelManager models;
  final ValueChanged<SummaryModel> onSelect;

  @override
  State<_SummaryModelPicker> createState() => _SummaryModelPickerState();
}

class _SummaryModelPickerState extends State<_SummaryModelPicker> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _trigger = GlobalKey();
  final _tapGroup = Object();

  /// Панель раскрывается вверх, если снизу в окне не хватает места.
  bool _upwards = false;

  /// Примерная высота панели: три карточки с описаниями.
  static const _panelHeight = 320.0;

  void _toggle() {
    if (_portal.isShowing) {
      _portal.hide();
    } else {
      final box = _trigger.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
        _upwards = bottom + _panelHeight > MediaQuery.sizeOf(context).height;
      }
      _portal.show();
    }
    setState(() {});
  }

  void _select(SummaryModel model) {
    _portal.hide();
    setState(() {});
    widget.onSelect(model);
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final chosen = widget.chosen;
    final state = widget.models.stateOf(chosen.package);
    final ready = state.status == PackageStatus.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => CompositedTransformTarget(
            link: _link,
            child: OverlayPortal(
              controller: _portal,
              overlayChildBuilder: (context) =>
                  _panel(context, constraints.maxWidth),
              child: TapRegion(
                groupId: _tapGroup,
                child: _ModelCard(
                  key: _trigger,
                  model: chosen,
                  ready: ready,
                  trailing: MacosIcon(
                    _portal.isShowing
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 13,
                    color: secondaryLabel(context),
                  ),
                  onTap: _toggle,
                ),
              ),
            ),
          ),
        ),
        if (!ready && state.status != PackageStatus.checking) ...[
          const SizedBox(height: Gap.related),
          ProgressBar(
            value: (state.received * 100 / chosen.package.size)
                .clamp(0, 100)
                .toDouble(),
            height: 4,
          ),
          const SizedBox(height: Gap.tiny),
          Text(
            modelStatusText(chosen.package, state, widget.models.speed),
            style: typography.callout.copyWith(
              color: state.status == PackageStatus.failed
                  ? MacosColors.systemRedColor.resolveFrom(context)
                  : secondaryLabel(context),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }

  Widget _panel(BuildContext context, double width) {
    final theme = MacosTheme.of(context);
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: _upwards ? Alignment.topLeft : Alignment.bottomLeft,
      followerAnchor: _upwards ? Alignment.bottomLeft : Alignment.topLeft,
      offset: Offset(0, _upwards ? -Gap.tiny : Gap.tiny),
      child: Align(
        alignment: _upwards ? Alignment.bottomLeft : Alignment.topLeft,
        child: TapRegion(
          groupId: _tapGroup,
          onTapOutside: (_) => setState(_portal.hide),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  setState(_portal.hide),
            },
            child: Focus(
              autofocus: true,
              child: Container(
                width: width,
                padding: const EdgeInsets.all(Gap.tiny),
                decoration: BoxDecoration(
                  color: theme.canvasColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.dividerColor),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0x33000000),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, m) in summaryModels.indexed) ...[
                      if (i > 0) const SizedBox(height: Gap.tiny),
                      _ModelCard(
                        model: m,
                        ready: widget.models.isReady(m.package),
                        selected: m.id == widget.chosen.id,
                        flat: true,
                        onTap: () => _select(m),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Карточка модели: название и размер, «★ Рекомендуется для этого Mac», чем отличается;
/// справа — скачана ли, выбрана ли или [trailing]. [flat] — без рамки (в панели списка),
/// выбранная там подсвечена акцентным цветом, при наведении — лёгкая подсветка.
class _ModelCard extends StatefulWidget {
  const _ModelCard({
    super.key,
    required this.model,
    required this.ready,
    required this.onTap,
    this.selected = false,
    this.flat = false,
    this.trailing,
  });

  final SummaryModel model;
  final bool ready;
  final bool selected;
  final bool flat;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  State<_ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends State<_ModelCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final typography = theme.typography;
    final model = widget.model;
    final accent = theme.primaryColor;
    final Color background;
    if (widget.flat && widget.selected) {
      background = accent.withValues(alpha: isDark(context) ? 0.22 : 0.12);
    } else if (_hovered) {
      background = theme.dividerColor;
    } else {
      background = const Color(0x00000000);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(Gap.small),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
            border: widget.flat ? null : Border.all(color: theme.dividerColor),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ModelTitleLine(title: model.name, size: model.package.size),
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
                      ready: widget.ready,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.small),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child:
                    widget.trailing ??
                    (widget.selected
                        ? MacosIcon(
                            CupertinoIcons.checkmark_alt,
                            size: 15,
                            color: accent,
                          )
                        : const SizedBox(width: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackageRow extends StatelessWidget {
  const _PackageRow({
    required this.package,
    required this.state,
    required this.speed,
  });

  final ModelPackage package;
  final PackageState state;
  final double speed;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final fraction = package.size == 0 ? 0.0 : state.received / package.size;
    final failed = state.status == PackageStatus.failed;
    final ready = state.status == PackageStatus.ready;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.small),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ModelTitleLine(title: package.title, size: package.size),
          const SizedBox(height: Gap.line),
          ModelLicenseLine(description: package.description, ready: ready),
          // У скачанной — только «скачана» в строке выше, без полосы и статуса.
          if (!ready) ...[
            const SizedBox(height: Gap.related),
            ProgressBar(
              value: state.status == PackageStatus.checking
                  ? 0
                  : (fraction * 100).clamp(0, 100).toDouble(),
              height: 4,
            ),
            const SizedBox(height: Gap.tiny),
            Text(
              modelStatusText(package, state, speed),
              style: typography.callout.copyWith(
                color: failed
                    ? MacosColors.systemRedColor.resolveFrom(context)
                    : secondaryLabel(context),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
