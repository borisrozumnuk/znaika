import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/model_downloader.dart';
import 'package:znaika/model_manifest.dart';

/// Локальный сервер, который умеет вести себя как плохая сеть.
class FlakyServer {
  FlakyServer(this.data);

  final Uint8List data;
  late final HttpServer _server;
  final ranges = <String?>[];

  /// Оборвать соединение после стольких байт ответа (только на первом запросе).
  int? dropAfter;

  /// Зависнуть после стольких байт ответа (только на первом запросе).
  int? stallAfter;

  /// Не поддерживать Range: всегда отдавать файл целиком с кодом 200.
  bool ignoreRange = false;

  String get url => 'http://127.0.0.1:${_server.port}/redirect/model.bin';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    // Как Hugging Face: сначала редирект на «CDN».
    if (request.uri.path.startsWith('/redirect/')) {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/cdn/model.bin');
      await request.response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    var start = 0;
    if (range != null && !ignoreRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
      request.response.statusCode = HttpStatus.partialContent;
    }
    final body = data.sublist(start);
    final first = ranges.length == 1;
    final response = request.response..contentLength = body.length;
    if (first && dropAfter != null) {
      // Обрыв посреди ответа: заголовки и часть тела, затем закрытый сокет.
      final socket = await response.detachSocket();
      socket.add(body.sublist(0, dropAfter));
      await socket.flush();
      socket.destroy();
      return;
    }
    if (first && stallAfter != null) {
      response.add(body.sublist(0, stallAfter));
      await response.flush();
      return; // Не закрываем ответ: соединение висит.
    }
    response.add(body);
    await response.close();
  }
}

void main() {
  late Directory dir;
  late Uint8List data;
  late FlakyServer server;
  late ModelFile file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('downloader_test');
    data = Uint8List.fromList(List.generate(300 * 1024, (i) => Random(i).nextInt(256)));
    server = FlakyServer(data);
    await server.start();
    file = ModelFile(path: 'sub/model.bin', url: server.url, size: data.length, sha256: sha256.convert(data).toString());
  });

  tearDown(() async {
    await server.close();
    await dir.delete(recursive: true);
  });

  ModelDownloader downloader() =>
      ModelDownloader(dir, stallTimeout: const Duration(milliseconds: 500), retryDelay: Duration.zero);

  Future<void> expectDownloaded() async {
    expect(await File('${dir.path}/sub/model.bin').readAsBytes(), data);
    expect(File('${dir.path}/sub/model.bin.part').existsSync(), isFalse);
    expect(await downloader().isReady(file), isTrue);
  }

  test('скачивает через редирект, проверяет сумму и запоминает проверенный файл', () async {
    final progress = <int>[];
    await downloader().download(file, onProgress: progress.add);
    await expectDownloaded();
    expect(progress.last, data.length);
    expect(File('${dir.path}/.verified.json').readAsStringSync(), contains(file.sha256));
  });

  test('после обрыва посреди ответа докачивает с нужного места', () async {
    server.dropAfter = 100 * 1024;
    await downloader().download(file);
    await expectDownloaded();
    expect(server.ranges.first, isNull);
    expect(server.ranges.last, startsWith('bytes='));
  });

  test('зависшее соединение переоткрывается и докачивается', () async {
    server.stallAfter = 50 * 1024;
    await downloader().download(file);
    await expectDownloaded();
    expect(server.ranges.length, 2);
  });

  test('если сервер не умеет Range, файл скачивается заново целиком', () async {
    server
      ..dropAfter = 100 * 1024
      ..ignoreRange = true;
    await downloader().download(file);
    await expectDownloaded();
  });

  test('неверная сумма — ошибка, битый файл не остаётся', () async {
    final wrong = ModelFile(path: file.path, url: file.url, size: file.size, sha256: '0' * 64);
    await expectLater(downloader().download(wrong), throwsA(isA<DownloadFailed>()));
    expect(File('${dir.path}/sub/model.bin').existsSync(), isFalse);
    expect(File('${dir.path}/sub/model.bin.part').existsSync(), isFalse);
  });

  test('отмена оставляет .part, следующая загрузка его докачивает', () async {
    server.stallAfter = 120 * 1024;
    var cancel = false;
    final first = downloader().download(file, onProgress: (n) => cancel = n >= 120 * 1024, isCancelled: () => cancel);
    await expectLater(first, throwsA(isA<DownloadCancelled>()));
    final part = File('${dir.path}/sub/model.bin.part');
    expect(part.lengthSync(), greaterThan(0));
    await downloader().download(file);
    await expectDownloaded();
    expect(server.ranges.last, 'bytes=${120 * 1024}-');
  });

  test('готовый файл с изменённым содержимым не считается готовым', () async {
    await downloader().download(file);
    final target = File('${dir.path}/sub/model.bin');
    final corrupted = Uint8List.fromList(data)..[10] ^= 0xFF;
    await target.writeAsBytes(corrupted);
    expect(await downloader().isReady(file), isFalse);
  });
}
