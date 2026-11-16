import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'log.dart';

/// Звук встречи для прослушивания: после обработки system.wav и mic.wav сводятся в один
/// моно-файл и сжимаются в AAC 32 кбит/с — `audio.m4a`, ~14 МБ на час вместо ~230 МБ WAV
/// (89 минут: 163 МБ → 20,5 МБ, ~3 с). Сжимает системный `afconvert`; исходные WAV
/// удаляются, только если сжатие удалось.
const audioFileName = 'audio.m4a';

/// Сжимает звук встречи в [audioFileName]. true — готово (WAV удалены); false — сжимать
/// нечего или не удалось (WAV остаются, причина — в журнале).
Future<bool> archiveMeetingAudio(Directory dir) async {
  final sources = [
    for (final name in ['system.wav', 'mic.wav'])
      if (File('${dir.path}/$name').existsSync()) File('${dir.path}/$name'),
  ];
  if (sources.isEmpty) return false;
  final mix = File('${dir.path}/.audio-mix.wav');
  final part = File('${dir.path}/.audio.m4a.part');
  try {
    // Два канала — сначала сводим в один WAV (в фоне: часовая встреча — ~230 МБ).
    final paths = [for (final f in sources) f.path];
    final mixPath = mix.path;
    final input = sources.length == 1 ? sources.single.path : await Isolate.run(() => mixWavFiles(paths, mixPath));
    final result = await Process.run('/usr/bin/afconvert', ['-f', 'm4af', '-d', 'aac', '-b', '32000', input, part.path]);
    if (result.exitCode != 0) throw ProcessException('afconvert', [], '${result.stderr}'.trim(), result.exitCode);
    if (!await part.exists() || await part.length() < 1024) throw const FileSystemException('пустой результат сжатия');
    await part.rename('${dir.path}/$audioFileName');
    for (final f in sources) {
      await f.delete();
    }
    return true;
  } catch (e) {
    logLine('Звук встречи не сжат (${dir.path}): $e');
    if (await part.exists()) await part.delete();
    return false;
  } finally {
    if (await mix.exists()) await mix.delete();
  }
}

/// Сводит WAV PCM16 моно 16 кГц (как пишет захват) в один: отсчёты складываются, с
/// ограничением по краям диапазона. Каналы выровнены по общему началу записи; файл длиной
/// с самый длинный. Возвращает путь [outPath].
String mixWavFiles(List<String> inputs, String outPath) {
  final sources = [for (final path in inputs) WavReader(path)];
  try {
    final length = sources.map((s) => s.samples).reduce((a, b) => a > b ? a : b);
    final out = File(outPath).openSync(mode: FileMode.write);
    try {
      out.writeFromSync(wavHeader(length));
      const chunk = 1 << 20;
      for (var at = 0; at < length; at += chunk) {
        final n = length - at < chunk ? length - at : chunk;
        final mixed = Int32List(n);
        for (final s in sources) {
          final samples = s.read(at, n);
          for (var i = 0; i < samples.length; i++) {
            mixed[i] += samples[i];
          }
        }
        out.writeFromSync(clampToPcm16(mixed).buffer.asUint8List());
      }
    } finally {
      out.closeSync();
    }
    return outPath;
  } finally {
    for (final s in sources) {
      s.close();
    }
  }
}

/// Сумма отсчётов → PCM16 с ограничением (без переполнения при громких каналах).
Int16List clampToPcm16(Int32List mixed) {
  final out = Int16List(mixed.length);
  for (var i = 0; i < mixed.length; i++) {
    final v = mixed[i];
    out[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
  }
  return out;
}

/// Заголовок WAV: PCM16, моно, 16 кГц, [samples] отсчётов.
Uint8List wavHeader(int samples) {
  final data = samples * 2;
  final b = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // моно
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little); // байт в секунду
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  return b.buffer.asUint8List();
}

/// WAV PCM16 моно 16 кГц для чтения кусками: ищет блок «data» (перед ним бывают «LIST»
/// и другие). Размер блока у недописанного файла бывает нулевым — тогда до конца файла.
class WavReader {
  WavReader(String path) : _file = File(path).openSync() {
    final length = _file.lengthSync();
    final header = Uint8List(12);
    _file.readIntoSync(header);
    if (String.fromCharCodes(header, 0, 4) != 'RIFF' || String.fromCharCodes(header, 8, 12) != 'WAVE') {
      throw FormatException('не WAV: $path');
    }
    var at = 12;
    while (at + 8 <= length) {
      _file.setPositionSync(at);
      final chunk = Uint8List(8);
      _file.readIntoSync(chunk);
      final id = String.fromCharCodes(chunk, 0, 4);
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      if (id == 'fmt ') {
        final fmt = Uint8List(16);
        _file.readIntoSync(fmt);
        final view = ByteData.sublistView(fmt);
        final format = view.getUint16(0, Endian.little);
        final channels = view.getUint16(2, Endian.little);
        final rate = view.getUint32(4, Endian.little);
        final bits = view.getUint16(14, Endian.little);
        if (format != 1 || channels != 1 || rate != 16000 || bits != 16) {
          throw FormatException('не PCM16 моно 16 кГц: $path');
        }
      } else if (id == 'data') {
        _data = at + 8;
        final available = length - _data;
        samples = (size == 0 || size > available ? available : size) ~/ 2;
        return;
      }
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
    throw FormatException('нет звука в WAV: $path');
  }

  final RandomAccessFile _file;
  late final int _data;
  late final int samples;

  /// До [count] отсчётов с [from]; за концом файла — пусто (там тишина).
  Int16List read(int from, int count) {
    if (from >= samples) return Int16List(0);
    final n = from + count > samples ? samples - from : count;
    final bytes = Uint8List(n * 2);
    _file.setPositionSync(_data + from * 2);
    _file.readIntoSync(bytes);
    return bytes.buffer.asInt16List();
  }

  void close() => _file.closeSync();
}
