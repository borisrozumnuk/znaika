import 'dart:io';

/// Журнал приложения: ~/Library/Logs/Znaika/znaika.log (его видно в «Консоли»).
/// У приложения, открытого из Finder, stderr никуда не попадает — ошибки модели
/// и этапы заметок нужны для разбора проблем пользователя.
final _logFile = File('${Platform.environment['HOME']}/Library/Logs/Znaika/znaika.log');

void logLine(String message) {
  final line = '${DateTime.now().toIso8601String()} $message';
  stderr.writeln(line);
  try {
    _logFile.parent.createSync(recursive: true);
    // Больше 5 МБ — начинаем заново: журнал нужен для свежих проблем.
    final tooBig = _logFile.existsSync() && _logFile.lengthSync() > 5 << 20;
    _logFile.writeAsStringSync('$line\n', mode: tooBig ? FileMode.write : FileMode.append);
  } catch (_) {}
}
