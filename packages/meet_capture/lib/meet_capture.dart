import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Устройство ввода звука.
class InputDevice {
  final String name;
  final bool isBluetooth;
  final bool isDefault;

  const InputDevice({required this.name, required this.isBluetooth, required this.isDefault});
}

/// Что вернул старт записи.
class CaptureStarted {
  /// Название микрофона, с которого идёт запись; null, если микрофон не пишется.
  final String? micDevice;

  /// Bluetooth-микрофон переводит наушники в гарнитурный режим: звук в них хуже.
  final bool micIsBluetooth;

  const CaptureStarted({this.micDevice, this.micIsBluetooth = false});
}

/// Записанный файл одного канала.
class CapturedFile {
  /// "system" или "mic".
  final String channel;
  final String path;
  final double seconds;

  /// Пиковое значение 0…1; 0 — цифровая тишина.
  final double peak;

  const CapturedFile({required this.channel, required this.path, required this.seconds, required this.peak});
}

/// Порция звука одного канала: 16 кГц, моно, Float32.
class AudioChunk {
  /// "system" или "mic".
  final String channel;
  final Float32List samples;

  const AudioChunk(this.channel, this.samples);
}

/// Итог остановки: файлы и хвост звука, не успевший прийти через [MeetCapture.audio].
class CaptureStopped {
  final List<CapturedFile> files;
  final List<AudioChunk> tail;

  const CaptureStopped(this.files, this.tail);
}

/// Уровни каналов в дБ (−120 — тишина); null, если канал не пишется.
class CaptureLevels {
  final double? system;
  final double? mic;

  const CaptureLevels({this.system, this.mic});
}

/// Захват системного звука и микрофона на macOS 14.2+.
///
/// Пишет `system.wav` и `mic.wav` (16 кГц, моно, PCM16) в указанную папку.
class MeetCapture {
  static const _channel = MethodChannel('meet_capture');
  static const _levels = EventChannel('meet_capture/levels');
  static const _audio = EventChannel('meet_capture/audio');

  static Future<List<InputDevice>> inputDevices() async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('inputDevices') ?? [];
    return [
      for (final d in list)
        InputDevice(
          name: d['name'] as String,
          isBluetooth: d['isBluetooth'] as bool,
          isDefault: d['isDefault'] as bool,
        ),
    ];
  }

  /// [micDevice] — часть названия микрофона; null — вход, выбранный в системе.
  /// [streamAudio] — отдавать звук в [audio] для расшифровки на лету.
  static Future<CaptureStarted> start({
    required String outDir,
    bool system = true,
    bool mic = true,
    String? micDevice,
    bool streamAudio = false,
  }) async {
    final info = await _channel.invokeMapMethod<String, Object?>('start', {
      'outDir': outDir,
      'system': system,
      'mic': mic,
      'micDevice': micDevice,
      'streamAudio': streamAudio,
    });
    return CaptureStarted(
      micDevice: info?['micDevice'] as String?,
      micIsBluetooth: info?['micIsBluetooth'] as bool? ?? false,
    );
  }

  /// Пауза: звук не пишется в файлы и не идёт в поток [audio]; устройства продолжают
  /// работать (индикатор микрофона в строке меню остаётся). false — записи нет.
  static Future<bool> pause() async => await _channel.invokeMethod<bool>('pause') ?? false;

  /// Продолжить запись после [pause].
  static Future<bool> resume() async => await _channel.invokeMethod<bool>('resume') ?? false;

  static Future<CaptureStopped> stop() async {
    final result = await _channel.invokeMapMethod<String, Object?>('stop') ?? {};
    final files = (result['files'] as List<Object?>? ?? []).cast<Map<Object?, Object?>>();
    final tail = (result['tail'] as Map<Object?, Object?>? ?? {});
    return CaptureStopped(
      [
        for (final f in files)
          CapturedFile(
            channel: f['channel'] as String,
            path: f['path'] as String,
            seconds: (f['seconds'] as num).toDouble(),
            peak: (f['peak'] as num).toDouble(),
          ),
      ],
      [for (final e in tail.entries) AudioChunk(e.key as String, e.value as Float32List)],
    );
  }

  /// Звук во время записи (если start вызван с streamAudio: true).
  static Stream<AudioChunk> get audio => _audio.receiveBroadcastStream().map((event) {
        final map = event as Map<Object?, Object?>;
        return AudioChunk(map['channel'] as String, map['samples'] as Float32List);
      });

  static Stream<CaptureLevels> get levels => _levels.receiveBroadcastStream().map((event) {
        final map = event as Map<Object?, Object?>;
        return CaptureLevels(
          system: (map['system'] as num?)?.toDouble(),
          mic: (map['mic'] as num?)?.toDouble(),
        );
      });
}
