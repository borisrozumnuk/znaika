import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:macos_ui/macos_ui.dart';

/// Общие элементы в духе macOS поверх macos_ui: цвета берутся из системной темы
/// (светлая/тёмная) и системного акцентного цвета.

/// Шкала отступов по Apple HIG для macOS: 4 / 8 / 12 / 20.
abstract final class Gap {
  /// Строки текста одного блока (заголовок и подзаголовок).
  static const double line = 2;

  /// Подпись и её элемент.
  static const double tiny = 4;

  /// Связанные элементы: строки списка, кнопка и поле.
  static const double related = 8;

  /// Элементы внутри группы, соседние группы в боковой панели.
  static const double small = 12;

  /// Между группами и разделами, поля окна.
  static const double group = 20;

  /// Отступ строк боковой панели от её краёв.
  static const double sidebarInset = 10;
}

Color secondaryLabel(BuildContext context) => MacosColors.secondaryLabelColor.resolveFrom(context);
Color tertiaryLabel(BuildContext context) => MacosColors.tertiaryLabelColor.resolveFrom(context);
bool isDark(BuildContext context) => MacosTheme.brightnessOf(context) == Brightness.dark;

/// Скруглённая группа с тонкой рамкой — как блоки в «Системных настройках».
class GroupBox extends StatelessWidget {
  const GroupBox({super.key, required this.child, this.padding = const EdgeInsets.all(Gap.small)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: dark ? const Color(0x0FFFFFFF) : const Color(0x08000000),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: dark ? const Color(0x1AFFFFFF) : const Color(0x14000000)),
      ),
      child: child,
    );
  }
}

/// Заголовок раздела над группой.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.related),
      child: Row(
        children: [
          Expanded(child: Text(text, style: MacosTheme.of(context).typography.headline)),
          ?trailing,
        ],
      ),
    );
  }
}

enum CalloutKind { info, warning, error }

/// Плашка с иконкой: подсказка, предупреждение или ошибка.
class Callout extends StatelessWidget {
  const Callout({super.key, required this.text, this.kind = CalloutKind.info, this.action});

  final String text;
  final CalloutKind kind;

  /// Кнопка под текстом («Пересоздать заметки»).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (kind) {
      CalloutKind.info => (MacosTheme.of(context).primaryColor, CupertinoIcons.info_circle_fill),
      CalloutKind.warning => (MacosColors.systemOrangeColor.resolveFrom(context), CupertinoIcons.exclamationmark_triangle_fill),
      CalloutKind.error => (MacosColors.systemRedColor.resolveFrom(context), CupertinoIcons.xmark_octagon_fill),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.small, vertical: Gap.related),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark(context) ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: MacosIcon(icon, size: 15, color: color),
          ),
          const SizedBox(width: Gap.related),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(text, style: MacosTheme.of(context).typography.body),
                if (action != null) ...[const SizedBox(height: Gap.related), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Маленький спиннер и подпись: «Расшифровка…», «Пишу выжимку…».
class ActivityRow extends StatelessWidget {
  const ActivityRow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const ProgressCircle(radius: 7),
        const SizedBox(width: Gap.related),
        Expanded(
          child: Text(
            text,
            style: MacosTheme.of(context).typography.body.copyWith(color: secondaryLabel(context)),
          ),
        ),
      ],
    );
  }
}

/// Индикатор уровня канала: подпись слева, полоса, значение в дБ справа.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.icon, required this.label, required this.db});

  final IconData icon;
  final String label;

  /// null — канал не пишется; −120 и ниже — тишина.
  final double? db;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final value = db == null ? 0.0 : ((db!.clamp(-60.0, 0.0) + 60) / 60 * 100);
    final active = db != null && db! > -50;
    return Row(
      children: [
        MacosIcon(icon, size: 15, color: secondaryLabel(context)),
        const SizedBox(width: Gap.related),
        SizedBox(width: 200, child: Text(label, overflow: TextOverflow.ellipsis, style: typography.body)),
        const SizedBox(width: Gap.small),
        Expanded(
          child: ProgressBar(
            value: value,
            height: 6,
            trackColor: active ? MacosColors.systemGreenColor.resolveFrom(context) : tertiaryLabel(context),
          ),
        ),
        const SizedBox(width: Gap.small),
        SizedBox(
          width: 56,
          child: Text(
            db == null ? '—' : (db! <= -100 ? 'тишина' : '${db!.round()} дБ'),
            textAlign: TextAlign.right,
            style: typography.callout.copyWith(color: secondaryLabel(context), fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    );
  }
}

/// Круглая кнопка записи, как в «Диктофоне»: красный круг — начать, красный квадрат — остановить.
class RecordButton extends StatefulWidget {
  const RecordButton({super.key, required this.recording, required this.onPressed});

  final bool recording;
  final VoidCallback? onPressed;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final red = MacosColors.systemRedColor.resolveFrom(context);
    final ring = isDark(context) ? const Color(0x59FFFFFF) : const Color(0x33000000);
    return MacosTooltip(
      message: widget.recording ? 'Остановить запись' : 'Начать запись',
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: !enabled ? 0.4 : (_pressed ? 0.7 : 1),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 3)),
              alignment: Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: widget.recording ? 22 : 42,
                height: widget.recording ? 22 : 42,
                decoration: BoxDecoration(
                  color: red,
                  borderRadius: BorderRadius.circular(widget.recording ? 5 : 21),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пауза записи — в паре с [RecordButton], как в «Диктофоне»: такое же кольцо, но меньше;
/// внутри две полоски паузы, а на паузе — красный треугольник «продолжить».
class PauseButton extends StatefulWidget {
  const PauseButton({super.key, required this.paused, required this.onPressed});

  final bool paused;
  final VoidCallback? onPressed;

  @override
  State<PauseButton> createState() => _PauseButtonState();
}

class _PauseButtonState extends State<PauseButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final ring = isDark(context) ? const Color(0x59FFFFFF) : const Color(0x33000000);
    final bars = MacosTheme.of(context).typography.body.color ?? const Color(0xFF000000);
    final red = MacosColors.systemRedColor.resolveFrom(context);
    return MacosTooltip(
      message: widget.paused ? 'Продолжить запись' : 'Приостановить запись',
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: !enabled ? 0.4 : (_pressed ? 0.7 : 1),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2.5)),
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: widget.paused
                    // Треугольник чуть правее центра — визуально по центру круга.
                    ? Padding(
                        key: const ValueKey('play'),
                        padding: const EdgeInsets.only(left: 3),
                        child: CustomPaint(size: const Size(14, 16), painter: _PlayTriangle(red)),
                      )
                    : Row(
                        key: const ValueKey('pause'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final i in [0, 1]) ...[
                            if (i > 0) const SizedBox(width: 4),
                            Container(
                              width: 4.5,
                              height: 15,
                              decoration: BoxDecoration(color: bars, borderRadius: BorderRadius.circular(1.5)),
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

class _PlayTriangle extends CustomPainter {
  _PlayTriangle(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_PlayTriangle old) => old.color != color;
}

/// Сворачиваемый блок со стрелкой, как раскрывающиеся группы в Finder.
class Disclosure extends StatefulWidget {
  const Disclosure({super.key, required this.title, required this.child, this.initiallyExpanded = false});

  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.tiny),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: MacosIcon(CupertinoIcons.chevron_right, size: 12, color: secondaryLabel(context)),
                  ),
                  const SizedBox(width: Gap.tiny),
                  Text(widget.title, style: MacosTheme.of(context).typography.headline),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) Padding(padding: const EdgeInsets.only(top: Gap.related), child: widget.child),
      ],
    );
  }
}

/// Прокручиваемое содержимое страницы с полями как в окнах macOS.
class PageContent extends StatelessWidget {
  const PageContent({super.key, required this.controller, required this.children});

  final ScrollController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(Gap.group),
      children: children,
    );
  }
}
