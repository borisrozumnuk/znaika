import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'model_downloader.dart';
import 'model_manifest.dart';

enum PackageStatus { checking, missing, queued, downloading, ready, failed }

class PackageState {
  final PackageStatus status;

  /// Сколько байт пакета уже на диске (готовые файлы + начатый .part).
  final int received;
  final String? error;

  const PackageState(this.status, {this.received = 0, this.error});
}

/// Состояние моделей и их загрузка в фоновом изоляте.
///
/// Изолят нужен не ради сети, а ради SHA-256: подсчёт суммы 3,6 ГБ в основном
/// изоляте подвешивал бы интерфейс. Пауза — это остановка изолята; .part
/// остаётся на диске, и «Продолжить» докачивает с места остановки.
class ModelManager extends ChangeNotifier {
  ModelManager(this.modelsDir);

  final Directory modelsDir;
  final _states = {for (final p in allPackages) p.id: const PackageState(PackageStatus.checking)};

  /// Пакеты, которые попросили скачать, пока шла другая загрузка.
  final _pending = <ModelPackage>[];
  final _waiters = <String, List<Completer<void>>>{};
  Isolate? _worker;
  ReceivePort? _port;
  String? _error;

  /// Скорость загрузки, байт/с (скользящее среднее).
  double speed = 0;
  int _speedBytes = 0;
  DateTime _speedAt = DateTime.now();

  /// Выбранная модель для заметок — качается вместе с обязательными.
  ModelPackage get summaryPackage => _summaryPackage;
  ModelPackage _summaryPackage = llmPackage;
  set summaryPackage(ModelPackage p) {
    if (p == _summaryPackage) return;
    _summaryPackage = p;
    notifyListeners();
  }

  /// Что нужно для работы: распознавание, голоса и выбранная модель для заметок.
  List<ModelPackage> get requiredPackages => [...basePackages, _summaryPackage];

  PackageState stateOf(ModelPackage p) => _states[p.id]!;
  bool isReady(ModelPackage p) => stateOf(p).status == PackageStatus.ready;
  bool get downloading => _worker != null;

  /// Общая ошибка, не относящаяся к одному пакету (например, мало места).
  String? get error => _error;

  /// Запись и расшифровка работают без Gemma.
  bool get transcriptionReady => isReady(vadPackage) && isReady(asrPackage);
  bool get allReady => requiredPackages.every(isReady);

  /// Загрузка начата, но не закончена (приложение закрыли посреди неё) — продолжать сразу,
  /// не дожидаясь кнопки: модели пользователь уже выбрал. Ничего не скачано — ждём «Скачать».
  bool get shouldResume => !allReady && totalReceived > 0;

  int get totalSize => requiredPackages.fold(0, (sum, p) => sum + p.size);
  int get totalReceived => requiredPackages.fold(0, (sum, p) => sum + stateOf(p).received);
  int get _allReceived => allPackages.fold(0, (sum, p) => sum + stateOf(p).received);

  /// Проверяет, что уже скачано. Первый раз считает суммы готовых файлов (секунды).
  Future<void> check() async {
    for (final p in allPackages) {
      _states[p.id] = const PackageState(PackageStatus.checking);
    }
    notifyListeners();
    final dir = modelsDir.path;
    final result = await Isolate.run(() async {
      final downloader = ModelDownloader(Directory(dir));
      final out = <String, (bool, int)>{};
      for (final p in allPackages) {
        var ready = true;
        var present = 0;
        for (final f in p.files) {
          if (await downloader.isReady(f)) {
            await downloader.removeStalePart(f);
          } else {
            ready = false;
          }
          present += await downloader.bytesPresent(f);
        }
        out[p.id] = (ready, present);
      }
      return out;
    });
    for (final p in allPackages) {
      final (ready, present) = result[p.id]!;
      _setState(p, PackageState(ready ? PackageStatus.ready : PackageStatus.missing, received: present));
    }
    notifyListeners();
  }

  /// Скачивает недостающие модели по порядку: маленькие первыми.
  Future<void> start() async {
    if (_worker != null) return;
    _error = null;
    final missing = requiredPackages.where((p) => !isReady(p)).toList();
    if (missing.isEmpty) return;
    await _spawn(missing);
  }

  /// Скачивает один пакет по запросу (другую модель для заметок). Если уже идёт
  /// загрузка — встаёт в очередь за ней.
  Future<void> download(ModelPackage p) async {
    if (isReady(p) || _pending.contains(p)) return;
    final status = stateOf(p).status;
    if (status == PackageStatus.downloading || status == PackageStatus.queued) return;
    if (_worker != null) {
      _pending.add(p);
      _states[p.id] = PackageState(PackageStatus.queued, received: stateOf(p).received);
      notifyListeners();
      return;
    }
    _error = null;
    await _spawn([p]);
  }

  /// Удаляет скачанный пакет (или начатую загрузку) с диска.
  Future<void> delete(ModelPackage p) async {
    _pending.remove(p);
    if (stateOf(p).status == PackageStatus.downloading) pause();
    for (final f in p.files) {
      for (final file in [File('${modelsDir.path}/${f.path}'), File('${modelsDir.path}/${f.path}.part')]) {
        if (await file.exists()) await file.delete();
      }
    }
    _states[p.id] = const PackageState(PackageStatus.missing);
    notifyListeners();
  }

  Future<void> _spawn(List<ModelPackage> missing) async {
    await modelsDir.create(recursive: true);
    final remaining = missing.fold(0, (sum, p) => sum + p.size - stateOf(p).received);
    final free = await freeDiskSpace(modelsDir);
    const margin = 300 * 1024 * 1024;
    if (free != null && free < remaining + margin) {
      _error = 'Не хватает места на диске: нужно ${formatBytes(remaining + margin)}, '
          'свободно ${formatBytes(free)}.';
      notifyListeners();
      return;
    }

    // В «загружается» пакет переходит с первым прогрессом от изолята.
    for (final p in missing) {
      _states[p.id] = PackageState(PackageStatus.queued, received: stateOf(p).received);
    }
    speed = 0;
    _speedBytes = _allReceived;
    _speedAt = DateTime.now();
    notifyListeners();

    final port = _port = ReceivePort();
    _worker = await Isolate.spawn(_downloadWorker, (port.sendPort, modelsDir.path, [for (final p in missing) p.id]));
    port.listen(_onMessage);
  }

  /// Останавливает загрузку; начатые файлы остаются для докачки.
  void pause() {
    _stopWorker();
    _pending.clear();
    for (final p in allPackages) {
      final s = stateOf(p);
      if (s.status == PackageStatus.downloading || s.status == PackageStatus.queued) {
        _states[p.id] = PackageState(PackageStatus.missing, received: s.received);
      }
    }
    speed = 0;
    notifyListeners();
  }

  /// Ждёт, пока пакет будет готов (например, Gemma для выжимки).
  Future<void> waitFor(ModelPackage p) {
    if (isReady(p)) return Future.value();
    final waiter = Completer<void>();
    _waiters.putIfAbsent(p.id, () => []).add(waiter);
    return waiter.future;
  }

  @override
  void dispose() {
    _stopWorker();
    super.dispose();
  }

  void _onMessage(Object? message) {
    switch (message) {
      case ('progress', final String id, final int received):
        _states[id] = PackageState(PackageStatus.downloading, received: received);
        _updateSpeed();
      case ('ready', final String id):
        _setState(_package(id), PackageState(PackageStatus.ready, received: _package(id).size));
      case ('failed', final String id, final String error):
        _states[id] = PackageState(PackageStatus.failed, received: stateOf(_package(id)).received, error: error);
        // Остальные пакеты в очереди не начаты: возвращаем их в «ожидает».
        _pending.clear();
        for (final p in allPackages) {
          final s = stateOf(p);
          if (s.status == PackageStatus.queued) _states[p.id] = PackageState(PackageStatus.missing, received: s.received);
        }
        _stopWorker();
      case 'done':
        _stopWorker();
        speed = 0;
        if (_pending.isNotEmpty) {
          final next = [..._pending];
          _pending.clear();
          _spawn(next);
        }
    }
    notifyListeners();
  }

  void _updateSpeed() {
    final now = DateTime.now();
    final seconds = now.difference(_speedAt).inMilliseconds / 1000;
    if (seconds < 1) return;
    final instant = (_allReceived - _speedBytes) / seconds;
    speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3;
    _speedBytes = _allReceived;
    _speedAt = now;
  }

  void _setState(ModelPackage p, PackageState state) {
    _states[p.id] = state;
    if (state.status == PackageStatus.ready) {
      for (final waiter in _waiters.remove(p.id) ?? const <Completer<void>>[]) {
        waiter.complete();
      }
    }
  }

  ModelPackage _package(String id) => allPackages.firstWhere((p) => p.id == id);

  void _stopWorker() {
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _port?.close();
    _port = null;
  }
}

/// Фоновый изолят: качает пакеты по очереди и шлёт прогресс не чаще 5 раз в секунду.
Future<void> _downloadWorker((SendPort, String, List<String>) args) async {
  final (out, dir, ids) = args;
  final downloader = ModelDownloader(Directory(dir));
  for (final id in ids) {
    final package = allPackages.firstWhere((p) => p.id == id);
    var done = 0;
    var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      for (final f in package.files) {
        await downloader.download(f, onProgress: (received) {
          final now = DateTime.now();
          if (now.difference(lastSent).inMilliseconds < 200) return;
          lastSent = now;
          out.send(('progress', id, done + received));
        });
        done += f.size;
      }
      out.send(('ready', id));
    } catch (e) {
      out.send(('failed', id, '$e'));
      return;
    }
  }
  out.send('done');
}

/// «3,7 ГБ», «170 МБ», «644 КБ» — в десятичных единицах, как в Finder.
String formatBytes(num bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final text = value >= 10 || unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '${text.replaceAll('.', ',')} ${units[unit]}';
}
