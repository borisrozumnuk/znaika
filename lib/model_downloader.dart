import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'model_manifest.dart';

/// Загрузка и проверка файлов моделей. Чистый Dart без Flutter: работает
/// в фоновом изоляте (ModelManager) и тестируется на локальном HTTP-сервере.
///
/// - качает во временный «файл.part» и докачивает с места обрыва (HTTP Range);
/// - редиректы обрабатывает сам, чтобы Range не потерялся по дороге к CDN;
/// - если данные не приходят [stallTimeout], переоткрывает соединение;
/// - считает SHA-256 по ходу загрузки и переименовывает .part в файл только
///   при совпадении суммы — битый файл в models не попадёт;
/// - запоминает проверенные файлы (размер и время изменения) в .verified.json,
///   чтобы не пересчитывать сумму 3,6 ГБ при каждом запуске.
class ModelDownloader {
  ModelDownloader(
    this.modelsDir, {
    HttpClient Function()? httpClient,
    this.stallTimeout = const Duration(seconds: 30),
    this.maxAttempts = 8,
    this.retryDelay = const Duration(seconds: 2),
  }) : _newClient = httpClient ?? HttpClient.new;

  final Directory modelsDir;
  final HttpClient Function() _newClient;
  final Duration stallTimeout;

  /// Попыток подряд без прогресса; при каждом полученном байте счётчик сбрасывается.
  final int maxAttempts;
  final Duration retryDelay;

  File _file(ModelFile f) => File('${modelsDir.path}/${f.path}');
  File _part(ModelFile f) => File('${modelsDir.path}/${f.path}.part');
  File get _verifiedFile => File('${modelsDir.path}/.verified.json');

  /// Файл на месте и проверен. Без записи в кэше считает SHA-256 (долго для больших
  /// файлов) и при совпадении запоминает результат.
  Future<bool> isReady(ModelFile f) async {
    final file = _file(f);
    if (!await file.exists()) return false;
    final stat = await file.stat();
    if (stat.size != f.size) return false;
    final cache = await _readVerified();
    final entry = cache[f.path];
    if (entry is Map &&
        entry['sha256'] == f.sha256 &&
        entry['size'] == stat.size &&
        entry['modified'] == stat.modified.millisecondsSinceEpoch) {
      return true;
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != f.sha256) return false;
    await _markVerified(f, stat);
    return true;
  }

  /// Файл уже на месте (например, положен вручную) — недокачанная копия не нужна.
  Future<void> removeStalePart(ModelFile f) async {
    final part = _part(f);
    if (await part.exists()) await part.delete();
  }

  /// Сколько байт файла уже есть: целиком готовый или начатый .part.
  Future<int> bytesPresent(ModelFile f) async {
    final file = _file(f);
    if (await file.exists() && (await file.stat()).size == f.size) return f.size;
    final part = _part(f);
    return await part.exists() ? (await part.stat()).size : 0;
  }

  /// Скачивает файл (с докачкой). [onProgress] получает число скачанных байт файла.
  /// Отмена — через [isCancelled]: загрузка останавливается, .part остаётся для докачки.
  Future<void> download(
    ModelFile f, {
    void Function(int received)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (await isReady(f)) {
      await removeStalePart(f);
      onProgress?.call(f.size);
      return;
    }
    final part = _part(f);
    await part.parent.create(recursive: true);

    // Сумма считается по ходу; при докачке сначала прогоняем уже скачанное.
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    // Сколько байт уже в .part и в сумме. _fetch увеличивает его по мере записи,
    // поэтому после обрыва посреди ответа следующая попытка продолжит с верного места.
    final progress = _Progress();
    if (await part.exists()) {
      final existing = (await part.stat()).size;
      if (existing > f.size) {
        await part.delete();
      } else {
        await for (final chunk in part.openRead()) {
          hasher.add(chunk);
        }
        progress.received = existing;
      }
    }
    onProgress?.call(progress.received);

    var failures = 0;
    while (progress.received < f.size) {
      if (isCancelled?.call() ?? false) throw const DownloadCancelled();
      final before = progress.received;
      try {
        await _fetch(f, part, progress, hasher, onProgress, isCancelled);
      } on DownloadCancelled {
        rethrow;
      } on _RestartFromScratch {
        // Сервер не поддержал Range: начинаем файл заново.
        await part.delete();
        return download(f, onProgress: onProgress, isCancelled: isCancelled);
      } catch (e) {
        failures = progress.received > before ? 1 : failures + 1;
        if (failures >= maxAttempts) {
          throw DownloadFailed('${f.path}: не удалось скачать после $maxAttempts попыток: $e');
        }
        await Future<void>.delayed(retryDelay * failures);
      }
    }

    hasher.close();
    final actual = digestSink.value.toString();
    if (actual != f.sha256) {
      await part.delete();
      throw DownloadFailed('${f.path}: контрольная сумма не совпала (получено $actual)');
    }
    final file = await part.rename(_file(f).path);
    await _markVerified(f, await file.stat());
  }

  /// Одна попытка: запрос с Range от progress.received, дописывание в .part.
  Future<void> _fetch(
    ModelFile f,
    File part,
    _Progress progress,
    ByteConversionSink hasher,
    void Function(int)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final offset = progress.received;
    final client = _newClient()..connectionTimeout = stallTimeout;
    try {
      final response = await _get(client, Uri.parse(f.url), offset);
      if (offset > 0 && response.statusCode == HttpStatus.ok) {
        await response.drain<void>();
        throw const _RestartFromScratch();
      }
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}');
      }
      final sink = part.openWrite(mode: FileMode.append);
      try {
        // Тишина дольше stallTimeout — соединение зависло: бросаем и докачиваем заново.
        await for (final chunk in response.timeout(stallTimeout)) {
          if (isCancelled?.call() ?? false) throw const DownloadCancelled();
          if (progress.received + chunk.length > f.size) {
            throw const HttpException('сервер прислал больше, чем ожидалось');
          }
          sink.add(chunk);
          hasher.add(chunk);
          progress.received += chunk.length;
          onProgress?.call(progress.received);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  /// GET с Range; редиректы вручную, чтобы Range дошёл до конечного сервера.
  Future<HttpClientResponse> _get(HttpClient client, Uri uri, int offset) async {
    for (var hop = 0; hop < 10; hop++) {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      if (offset > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await request.close().timeout(stallTimeout);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) throw const HttpException('редирект без адреса');
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw const HttpException('слишком много редиректов');
  }

  Future<Map<String, Object?>> _readVerified() async {
    try {
      return (jsonDecode(await _verifiedFile.readAsString()) as Map).cast<String, Object?>();
    } on Object {
      return {};
    }
  }

  Future<void> _markVerified(ModelFile f, FileStat stat) async {
    final cache = await _readVerified();
    cache[f.path] = {'sha256': f.sha256, 'size': stat.size, 'modified': stat.modified.millisecondsSinceEpoch};
    await _verifiedFile.writeAsString(const JsonEncoder.withIndent('  ').convert(cache));
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class DownloadFailed implements Exception {
  final String message;
  const DownloadFailed(this.message);

  @override
  String toString() => message;
}

class _Progress {
  int received = 0;
}

class _RestartFromScratch implements Exception {
  const _RestartFromScratch();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Свободное место на диске с папкой [dir], байт (через df).
Future<int?> freeDiskSpace(Directory dir) async {
  try {
    final result = await Process.run('/bin/df', ['-k', dir.path]);
    final fields = (result.stdout as String).trim().split('\n').last.split(RegExp(r'\s+'));
    return int.parse(fields[3]) * 1024;
  } on Object {
    return null;
  }
}
