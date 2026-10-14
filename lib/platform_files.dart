import 'dart:io';

import 'package:flutter/services.dart';

/// Действия с файлами через AppKit (канал `znaika/files` в MainFlutterWindow.swift).
abstract final class PlatformFiles {
  static const _channel = MethodChannel('znaika/files');

  /// Перемещает файл или папку в Корзину macOS.
  static Future<void> moveToTrash(FileSystemEntity entity) =>
      _channel.invokeMethod<void>('trash', {'path': entity.path});

  /// Стандартная панель «Сохранить»; путь сохранённого файла или null, если отменили.
  static Future<String?> saveText({required String suggestedName, required String text}) =>
      _channel.invokeMethod<String>('saveText', {'name': suggestedName, 'text': text});
}
