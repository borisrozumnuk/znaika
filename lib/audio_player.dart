import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import 'log.dart';
import 'ui.dart';

/// Прослушивание звука встречи (audio.m4a) через AVAudioPlayer — канал `znaika/player`
/// в MainFlutterWindow.swift. Пока идёт воспроизведение, позиция опрашивается 4 раза в секунду.
class MeetingAudio extends ChangeNotifier {
  static const _channel = MethodChannel('znaika/player');

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  double rate = 1;

  /// Файл открылся (иначе — плеера нет: файл повреждён или его нет).
  bool ready = false;

  /// Громкость по [waveformBars] отрезкам записи (0…1) для дорожки-«волны»; пусто — ещё считается.
  List<double> waveform = const [];
  static const waveformBars = 240;
  Timer? _poll;
  bool _disposed = false;

  Future<void> open(String path) async {
    try {
      final seconds = await _channel.invokeMethod<double>('open', {'path': path});
      if (_disposed) return;
      duration = _fromSeconds(seconds ?? 0);
      position = Duration.zero;
      playing = false;
      ready = duration > Duration.zero;
      notifyListeners();
      if (ready) unawaited(_loadWaveform(path));
    } on PlatformException catch (e) {
      logLine('Звук встречи не открылся: ${e.message}');
    } on MissingPluginException {
      // Нет нативной части (тесты без мока) — плеер просто не показывается.
    }
  }

  Future<void> toggle() => playing ? pause() : play();

  Future<void> play() async {
    // Доиграли до конца — сначала.
    if (position >= duration - const Duration(milliseconds: 300)) await seek(Duration.zero);
    playing = await _channel.invokeMethod<bool>('play') ?? false;
    notifyListeners();
    _poll?.cancel();
    if (playing) _poll = Timer.periodic(const Duration(milliseconds: 250), (_) => _refresh());
  }

  Future<void> pause() async {
    await _channel.invokeMethod<void>('pause');
    await _refresh();
  }

  /// Перемотка; [andPlay] — сразу слушать (щелчок по времени реплики).
  Future<void> seek(Duration to, {bool andPlay = false}) async {
    position = to < Duration.zero ? Duration.zero : (to > duration ? duration : to);
    notifyListeners();
    await _channel.invokeMethod<void>('seek', {'seconds': position.inMilliseconds / 1000});
    if (andPlay && !playing) await play();
  }

  /// Скорость 0,5–2×.
  Future<void> setRate(double value) async {
    rate = value.clamp(0.5, 2.0).toDouble();
    notifyListeners();
    await _channel.invokeMethod<void>('rate', {'rate': rate});
  }

  /// «Волна» считается один раз (декодирование часовой записи — около секунды) и хранится
  /// рядом со звуком в waveform.json.
  Future<void> _loadWaveform(String audioPath) async {
    final cache = File('${File(audioPath).parent.path}/waveform.json');
    try {
      if (await cache.exists() && (await cache.lastModified()).isAfter(await File(audioPath).lastModified())) {
        final saved = (jsonDecode(await cache.readAsString()) as List).cast<num>();
        if (saved.length == waveformBars) {
          waveform = [for (final v in saved) v.toDouble()];
          if (!_disposed) notifyListeners();
          return;
        }
      }
      final levels = await _channel.invokeListMethod<double>('waveform', {'path': audioPath, 'bars': waveformBars});
      if (levels == null || levels.isEmpty || _disposed) return;
      waveform = levels;
      notifyListeners();
      await cache.writeAsString(jsonEncode([for (final v in levels) double.parse(v.toStringAsFixed(3))]));
    } catch (e) {
      logLine('«Волна» звука не посчиталась: $e');
    }
  }

  Future<void> _refresh() async {
    final state = await _channel.invokeMapMethod<String, Object?>('state');
    if (_disposed || state == null) return;
    position = _fromSeconds(state['position'] as num? ?? 0);
    playing = state['playing'] == true;
    if (!playing) _poll?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _channel.invokeMethod<void>('close').catchError((_) {});
    super.dispose();
  }

  static Duration _fromSeconds(num seconds) => Duration(milliseconds: (seconds * 1000).round());
}

/// «12:03» / «1:02:03».
String formatPlayerTime(Duration d) {
  final s = d.inSeconds;
  final mm = (s ~/ 60 % 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:$mm:$ss' : '$mm:$ss';
}

/// Отметка реплики «[мм:сс]» / «[ч:мм:сс]» → время от начала записи.
Duration? parseTimestamp(String stamp) {
  final parts = stamp.split(':').map(int.tryParse).toList();
  if (parts.isEmpty || parts.length > 3 || parts.contains(null)) return null;
  return Duration(seconds: parts.fold(0, (sum, p) => sum * 60 + p!));
}

/// Полоска плеера: ▶︎/❚❚, текущее время, дорожка-«волна», длительность, скорость.
class AudioPlayerBar extends StatelessWidget {
  const AudioPlayerBar({super.key, required this.audio, this.onSave});

  final MeetingAudio audio;

  /// «Сохранить запись…» — выгрузить звук файлом; null — кнопки нет.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final timeStyle = theme.typography.callout.copyWith(
      color: secondaryLabel(context),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        return GroupBox(
          padding: const EdgeInsets.symmetric(horizontal: Gap.small, vertical: Gap.tiny),
          child: Row(
            children: [
              MacosTooltip(
                message: audio.playing ? 'Пауза' : 'Слушать запись',
                child: MacosIconButton(
                  semanticLabel: audio.playing ? 'Пауза' : 'Слушать запись',
                  icon: MacosIcon(
                    audio.playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                    size: 18,
                    color: theme.primaryColor,
                  ),
                  boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: const EdgeInsets.all(4),
                  onPressed: audio.toggle,
                ),
              ),
              const SizedBox(width: Gap.tiny),
              Text(formatPlayerTime(audio.position), style: timeStyle),
              const SizedBox(width: Gap.small),
              Expanded(child: WaveformSeekBar(audio: audio)),
              const SizedBox(width: Gap.small),
              Text(formatPlayerTime(audio.duration), style: timeStyle),
              const SizedBox(width: Gap.small),
              _RateButton(audio: audio),
              if (onSave != null) ...[
                const SizedBox(width: Gap.tiny),
                MacosTooltip(
                  message: 'Сохранить запись…',
                  child: MacosIconButton(
                    semanticLabel: 'Сохранить запись',
                    icon: MacosIcon(CupertinoIcons.arrow_down_to_line, size: 16, color: secondaryLabel(context)),
                    boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: const EdgeInsets.all(4),
                    onPressed: onSave,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// «1×», «1,25×», «0,5×».
String formatRate(double rate) {
  final text = rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : '$rate'.replaceAll(RegExp(r'0+$'), '');
  return '${text.replaceAll('.', ',')}×';
}

/// Дорожка-«волна», как у голосовых сообщений: столбики громкости, прослушанное — цветом
/// акцента. Щелчок или перетаскивание — перемотка.
class WaveformSeekBar extends StatelessWidget {
  const WaveformSeekBar({super.key, required this.audio});

  final MeetingAudio audio;

  static const height = 30.0;

  void _seekTo(double dx, double width) {
    if (width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    audio.seek(Duration(milliseconds: (audio.duration.inMilliseconds * fraction).round()));
  }

  @override
  Widget build(BuildContext context) {
    final total = audio.duration.inMilliseconds;
    final progress = total == 0 ? 0.0 : (audio.position.inMilliseconds / total).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _seekTo(d.localPosition.dx, constraints.maxWidth),
          onHorizontalDragUpdate: (d) => _seekTo(d.localPosition.dx, constraints.maxWidth),
          child: Semantics(
            label: 'Дорожка записи',
            slider: true,
            value: formatPlayerTime(audio.position),
            child: CustomPaint(
              size: Size(constraints.maxWidth, height),
              painter: _WaveformPainter(
                levels: audio.waveform,
                progress: progress.toDouble(),
                played: MacosTheme.of(context).primaryColor,
                rest: tertiaryLabel(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({required this.levels, required this.progress, required this.played, required this.rest});

  final List<double> levels;
  final double progress;
  final Color played;
  final Color rest;

  static const _bar = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final count = math.max(1, ((size.width + _gap) / (_bar + _gap)).floor());
    final step = size.width / count;
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      // Столбик — самый громкий из отрезков записи, что на него приходятся.
      var level = 0.0;
      if (levels.isNotEmpty) {
        final from = i * levels.length ~/ count;
        final to = math.max(from + 1, (i + 1) * levels.length ~/ count);
        for (var j = from; j < to && j < levels.length; j++) {
          level = math.max(level, levels[j]);
        }
      }
      // Корень — чтобы тихая речь не терялась на фоне громких мест; тишина — точкой.
      final h = math.max(_bar, math.sqrt(level) * size.height);
      final x = i * step + (step - _bar) / 2;
      paint.color = (i + 0.5) / count <= progress ? played : rest;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, _bar, h), const Radius.circular(_bar / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || !identical(old.levels, levels) || old.played != played || old.rest != rest;
}

/// Кнопка скорости «1×»; по щелчку над ней всплывает панель с вертикальным ползунком
/// 0,5–2× (шаг 0,25). Закрывается щелчком мимо или Esc.
class _RateButton extends StatefulWidget {
  const _RateButton({required this.audio});

  final MeetingAudio audio;

  @override
  State<_RateButton> createState() => _RateButtonState();
}

class _RateButtonState extends State<_RateButton> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  static const _panelHeight = 196.0;
  static const _panelWidth = 64.0;

  /// Над кнопкой не хватает места (плеер у верха окна) — панель открывается вниз.
  bool _below = false;

  void _toggle() {
    if (!_portal.isShowing) {
      final box = context.findRenderObject() as RenderBox?;
      final top = box == null ? double.infinity : box.localToGlobal(Offset.zero).dy;
      setState(() => _below = top < _panelHeight + 16);
    }
    _portal.toggle();
  }

  // Дискретный MacosSlider работает только с долей 0…1 (min/max игнорирует):
  // 0 — 0,5×, 1 — 2×, шаги по 0,25×.
  static double _toFraction(double rate) => (rate - 0.5) / 1.5;
  static double _toRate(double fraction) => ((0.5 + fraction * 1.5) * 4).round() / 4;

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          targetAnchor: _below ? Alignment.bottomCenter : Alignment.topCenter,
          followerAnchor: _below ? Alignment.topCenter : Alignment.bottomCenter,
          offset: Offset(0, _below ? 6 : -6),
          child: Align(
            alignment: _below ? Alignment.topCenter : Alignment.bottomCenter,
            child: TapRegion(
              groupId: _link,
              onTapOutside: (_) => _portal.hide(),
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): _portal.hide},
                child: Focus(autofocus: true, child: _panel(context)),
              ),
            ),
          ),
        ),
        child: TapRegion(
          groupId: _link,
          child: MacosTooltip(
            message: 'Скорость воспроизведения',
            child: _RateLabel(rate: widget.audio.rate, open: _portal.isShowing, onTap: _toggle),
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final theme = MacosTheme.of(context);
    final small = theme.typography.caption1.copyWith(color: secondaryLabel(context));
    return ListenableBuilder(
      listenable: widget.audio,
      builder: (context, _) => Container(
        width: _panelWidth,
        height: _panelHeight,
        padding: const EdgeInsets.symmetric(vertical: Gap.small),
        decoration: BoxDecoration(
          color: theme.canvasColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.dividerColor),
          boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: Column(
          children: [
            Text(formatRate(widget.audio.rate), style: theme.typography.headline),
            const SizedBox(height: Gap.tiny),
            Text('2×', style: small),
            Expanded(
              // Горизонтальный ползунок macOS, повёрнутый вертикально: вверх — быстрее.
              child: RotatedBox(
                quarterTurns: 3,
                child: MacosSlider(
                  semanticLabel: 'Скорость воспроизведения',
                  value: _toFraction(widget.audio.rate),
                  discrete: true,
                  splits: 7,
                  onChanged: (fraction) => widget.audio.setRate(_toRate(fraction)),
                ),
              ),
            ),
            Text('0,5×', style: small),
          ],
        ),
      ),
    );
  }
}

/// Скорость текстом («1×», «1,25×»), по щелчку — ползунок. Ширина постоянная — по самой
/// длинной подписи, чтобы при движении ползунка соседние элементы не сдвигались.
class _RateLabel extends StatefulWidget {
  const _RateLabel({required this.rate, required this.open, required this.onTap});

  final double rate;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_RateLabel> createState() => _RateLabelState();
}

class _RateLabelState extends State<_RateLabel> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final style = theme.typography.callout.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: _hovered || widget.open ? theme.primaryColor : secondaryLabel(context),
    );
    final width = (TextPainter(
          text: TextSpan(text: formatRate(1.75), style: style),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout())
            .width
            .ceilToDouble();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          label: 'Скорость воспроизведения',
          child: SizedBox(
            width: width,
            child: Text(formatRate(widget.rate), style: style, textAlign: TextAlign.center, softWrap: false),
          ),
        ),
      ),
    );
  }
}
