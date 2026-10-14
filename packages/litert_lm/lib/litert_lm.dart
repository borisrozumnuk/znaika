import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Тонкая FFI-обёртка над C API LiteRT-LM (engine.h, conversation.h),
/// той же версии и тем же способом, что Python-пакет litert-lm-api.
///
/// Библиотека и прослойка потокового ответа (StreamShim.swift) линкуются
/// в приложение плагином, поэтому символы ищутся в текущем процессе.

typedef _Ptr = Pointer<Void>;

class _Bindings {
  _Bindings() : _lib = DynamicLibrary.process();

  final DynamicLibrary _lib;

  late final setMinLogLevel = _lib.lookupFunction<Void Function(Int32), void Function(int)>('litert_lm_set_min_log_level');

  late final engineSettingsCreate = _lib.lookupFunction<
      _Ptr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
      _Ptr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('litert_lm_engine_settings_create');
  late final engineSettingsSetMaxNumTokens = _lib
      .lookupFunction<Void Function(_Ptr, Int32), void Function(_Ptr, int)>('litert_lm_engine_settings_set_max_num_tokens');
  late final engineSettingsSetCacheDir = _lib.lookupFunction<Void Function(_Ptr, Pointer<Utf8>),
      void Function(_Ptr, Pointer<Utf8>)>('litert_lm_engine_settings_set_cache_dir');
  late final engineSettingsSetActivationDataType = _lib.lookupFunction<Void Function(_Ptr, Int32),
      void Function(_Ptr, int)>('litert_lm_engine_settings_set_activation_data_type');
  late final engineSettingsDelete =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_engine_settings_delete');
  late final engineCreate = _lib.lookupFunction<_Ptr Function(_Ptr), _Ptr Function(_Ptr)>('litert_lm_engine_create');
  late final engineDelete = _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_engine_delete');

  late final engineTokenize = _lib
      .lookupFunction<_Ptr Function(_Ptr, Pointer<Utf8>), _Ptr Function(_Ptr, Pointer<Utf8>)>('litert_lm_engine_tokenize');
  late final tokenizeResultNumTokens =
      _lib.lookupFunction<Size Function(_Ptr), int Function(_Ptr)>('litert_lm_tokenize_result_get_num_tokens');
  late final tokenizeResultDelete =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_tokenize_result_delete');

  late final samplerParamsCreate =
      _lib.lookupFunction<_Ptr Function(Int32), _Ptr Function(int)>('litert_lm_sampler_params_create');
  late final samplerParamsSetTopK =
      _lib.lookupFunction<Void Function(_Ptr, Int32), void Function(_Ptr, int)>('litert_lm_sampler_params_set_top_k');
  late final samplerParamsSetTopP =
      _lib.lookupFunction<Void Function(_Ptr, Float), void Function(_Ptr, double)>('litert_lm_sampler_params_set_top_p');
  late final samplerParamsSetTemperature = _lib
      .lookupFunction<Void Function(_Ptr, Float), void Function(_Ptr, double)>('litert_lm_sampler_params_set_temperature');
  late final samplerParamsDelete =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_sampler_params_delete');

  late final sessionConfigCreate = _lib.lookupFunction<_Ptr Function(), _Ptr Function()>('litert_lm_session_config_create');
  late final sessionConfigSetMaxOutputTokens = _lib.lookupFunction<Void Function(_Ptr, Int32),
      void Function(_Ptr, int)>('litert_lm_session_config_set_max_output_tokens');
  late final sessionConfigSetSamplerParams = _lib
      .lookupFunction<Void Function(_Ptr, _Ptr), void Function(_Ptr, _Ptr)>('litert_lm_session_config_set_sampler_params');
  late final sessionConfigDelete =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_session_config_delete');

  late final conversationConfigCreate =
      _lib.lookupFunction<_Ptr Function(), _Ptr Function()>('litert_lm_conversation_config_create');
  late final conversationConfigSetSessionConfig = _lib.lookupFunction<Void Function(_Ptr, _Ptr),
      void Function(_Ptr, _Ptr)>('litert_lm_conversation_config_set_session_config');
  late final conversationConfigSetSystemMessage = _lib.lookupFunction<Void Function(_Ptr, Pointer<Utf8>),
      void Function(_Ptr, Pointer<Utf8>)>('litert_lm_conversation_config_set_system_message');
  late final conversationConfigDelete =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_conversation_config_delete');

  late final conversationCreate =
      _lib.lookupFunction<_Ptr Function(_Ptr, _Ptr), _Ptr Function(_Ptr, _Ptr)>('litert_lm_conversation_create');
  late final conversationDelete =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_conversation_delete');
  late final conversationCancel =
      _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('litert_lm_conversation_cancel_process');

  // Прослойка из StreamShim.swift.
  late final streamStart = _lib.lookupFunction<_Ptr Function(_Ptr, Pointer<Utf8>, _Ptr),
      _Ptr Function(_Ptr, Pointer<Utf8>, _Ptr)>('znaika_llm_stream_start');
  late final streamPoll = _lib.lookupFunction<Int32 Function(_Ptr, Pointer<Pointer<Utf8>>),
      int Function(_Ptr, Pointer<Pointer<Utf8>>)>('znaika_llm_stream_poll');
  late final streamFree = _lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>('znaika_llm_stream_free');
  late final free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('znaika_llm_free');
}

const _logSeverityError = 4;
const _activationFloat32 = 0;
const _samplerTypeTopP = 2;

const _pollIdle = 0, _pollData = 1, _pollDone = 2, _pollError = 3;

/// Модель не ответила вовремя: внутренний таймаут LiteRT-LM на GPU
/// («DEADLINE_EXCEEDED … 20s» — видеокарта занята или не хватает памяти)
/// или долго не было ни одного куска ответа.
class LlmTimeout implements Exception {
  final String message;
  const LlmTimeout(this.message);

  @override
  String toString() => 'LiteRT-LM: $message';
}

/// Загруженная модель LiteRT-LM (.litertlm).
class LlmEngine {
  LlmEngine._(this._engine, this.backend) : _b = _Bindings();

  /// "gpu" или "cpu".
  final String backend;

  /// Скорость чтения входа (prefill), токенов в секунду: сначала осторожная оценка,
  /// потом — скользящее среднее по запросам. По ней [generate] понимает, сколько
  /// разумно ждать первого куска ответа.
  late double _prefillSpeed = backend == 'gpu' ? 300 : 60;

  final _Ptr _engine;
  final _Bindings _b;
  bool _disposed = false;

  /// Загружает модель в фоновом изоляте (это занимает секунды).
  /// [backend] — "gpu" или "cpu"; [maxTokens] — контекст (вход + ответ).
  /// [cacheDir] — куда кэшировать скомпилированные под GPU ядра.
  static Future<LlmEngine> load({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 16384,
    String? cacheDir,
  }) async {
    final address = await Isolate.run(() {
      final b = _Bindings();
      // Без этого LiteRT печатает сотни служебных строк при загрузке.
      b.setMinLogLevel(_logSeverityError);
      final path = modelPath.toNativeUtf8();
      final backendName = backend.toNativeUtf8();
      final cache = cacheDir?.toNativeUtf8();
      try {
        final settings = b.engineSettingsCreate(path, backendName, nullptr, nullptr);
        if (settings == nullptr) return 0;
        b.engineSettingsSetMaxNumTokens(settings, maxTokens);
        // На GPU по умолчанию float16, и на длинном входе Gemma портит текст: уже с ~1500
        // токенов путает цифры таймкодов и слова («Собеник1111», «[01:533]»), с ~4000 —
        // повторяет символы до упора. С float32 часть встречи в 11 000 токенов чистая
        // (и даже быстрее). Скомпилированные ядра у float32 свои — кэш держать отдельно.
        if (backend == 'gpu') b.engineSettingsSetActivationDataType(settings, _activationFloat32);
        if (cache != null) b.engineSettingsSetCacheDir(settings, cache);
        final engine = b.engineCreate(settings);
        b.engineSettingsDelete(settings);
        return engine.address;
      } finally {
        malloc.free(path);
        malloc.free(backendName);
        if (cache != null) malloc.free(cache);
      }
    });
    if (address == 0) throw StateError('LiteRT-LM: не удалось загрузить модель $modelPath ($backend)');
    return LlmEngine._(Pointer.fromAddress(address), backend);
  }

  /// Число токенов в тексте — для деления длинных расшифровок на части.
  int countTokens(String text) {
    _checkAlive();
    final native = text.toNativeUtf8();
    try {
      final result = _b.engineTokenize(_engine, native);
      if (result == nullptr) throw StateError('LiteRT-LM: tokenize вернул NULL');
      final n = _b.tokenizeResultNumTokens(result);
      _b.tokenizeResultDelete(result);
      return n;
    } finally {
      malloc.free(native);
    }
  }

  /// Новый диалог из одного сообщения; ответ приходит кусками текста.
  /// Отмена подписки останавливает генерацию.
  ///
  /// Зависание (модель молчит, хотя должна была ответить) — [LlmTimeout]. Сколько ждать,
  /// зависит от фазы: первого куска — в 10 раз дольше, чем по измеренной скорости
  /// займёт чтение входа (но не меньше минуты), следующих — до [pieceTimeout].
  /// Медленная, но живая модель так не обрывается: на загруженной машине растёт
  /// и измеренное время чтения.
  Stream<String> generate({
    required String prompt,
    String? system,
    int maxOutputTokens = 2048,
    double temperature = 0.3,
    int topK = 40,
    double topP = 0.9,
    Duration pieceTimeout = const Duration(minutes: 1),
  }) async* {
    _checkAlive();
    final conversation = _createConversation(system, maxOutputTokens, temperature, topK, topP);
    final message = jsonEncode({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': prompt},
      ],
    }).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    _Ptr handle = nullptr;
    var finished = false;
    var stuck = false;
    try {
      handle = _b.streamStart(conversation, message, nullptr);
      if (handle == nullptr) throw StateError('LiteRT-LM: не удалось начать генерацию');
      final inputTokens = countTokens('${system ?? ''}\n$prompt');
      final expected = Duration(milliseconds: (inputTokens / _prefillSpeed * 1000).round());
      final firstTimeout = expected * 10 > const Duration(minutes: 1) ? expected * 10 : const Duration(minutes: 1);
      final started = DateTime.now();
      var lastData = started;
      var gotFirst = false;
      while (true) {
        final status = _b.streamPoll(handle, out);
        if (status == _pollIdle) {
          final silent = DateTime.now().difference(lastData);
          if (!gotFirst && silent > firstTimeout) {
            throw LlmTimeout('нет ответа ${silent.inSeconds} с при ожидаемых ~${expected.inSeconds} с '
                'на чтение $inputTokens токенов');
          }
          if (gotFirst && silent > pieceTimeout) {
            throw LlmTimeout('ответ остановился: ${silent.inSeconds} с без новых слов');
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        } else if (status == _pollData) {
          lastData = DateTime.now();
          if (!gotFirst) {
            gotFirst = true;
            // Первый кусок ≈ конец чтения входа: уточняем скорость.
            final seconds = lastData.difference(started).inMilliseconds / 1000;
            if (seconds > 0.5 && inputTokens > 200) {
              _prefillSpeed = _prefillSpeed * 0.5 + inputTokens / seconds * 0.5;
            }
          }
          final chunks = jsonDecode(_takeString(out)) as List<dynamic>;
          for (final chunk in chunks) {
            final text = _textOf(chunk);
            if (text.isNotEmpty) yield text;
          }
        } else if (status == _pollDone) {
          finished = true;
          break;
        } else {
          finished = true;
          final error = _takeString(out);
          // Так же, как в Python-обёртке: упор в лимит токенов — обычный конец ответа.
          if (error.contains('Max number of tokens reached') || error.contains('CANCELLED')) break;
          if (error.contains('DEADLINE_EXCEEDED')) throw LlmTimeout(error.trim());
          throw StateError('LiteRT-LM: $error');
        }
      }
    } finally {
      if (handle != nullptr) {
        if (!finished) {
          // Подписку отменили посреди ответа: останавливаем модель и ждём,
          // пока колбэки закончатся, иначе освободим состояние под ними.
          _b.conversationCancel(conversation);
          var status = _b.streamPoll(handle, out);
          final giveUp = DateTime.now().add(const Duration(seconds: 30));
          while (status != _pollDone && status != _pollError) {
            if (status == _pollData) _takeString(out);
            // Модель не реагирует и на отмену: состояние не освобождаем — колбэк
            // может прийти позже и обратиться к нему. Лучше утечка, чем падение.
            if (DateTime.now().isAfter(giveUp)) {
              stuck = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
            status = _b.streamPoll(handle, out);
          }
          if (status == _pollError) _takeString(out);
        }
        if (!stuck) _b.streamFree(handle);
      }
      if (!stuck) _b.conversationDelete(conversation);
      malloc.free(message);
      calloc.free(out);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.engineDelete(_engine);
  }

  _Ptr _createConversation(String? system, int maxOutputTokens, double temperature, int topK, double topP) {
    final sampler = _b.samplerParamsCreate(_samplerTypeTopP);
    _b.samplerParamsSetTopK(sampler, topK);
    _b.samplerParamsSetTopP(sampler, topP);
    _b.samplerParamsSetTemperature(sampler, temperature);
    final session = _b.sessionConfigCreate();
    _b.sessionConfigSetMaxOutputTokens(session, maxOutputTokens);
    _b.sessionConfigSetSamplerParams(session, sampler);
    _b.samplerParamsDelete(sampler);

    final config = _b.conversationConfigCreate();
    _b.conversationConfigSetSessionConfig(config, session);
    _b.sessionConfigDelete(session);
    if (system != null) {
      final native = system.toNativeUtf8();
      _b.conversationConfigSetSystemMessage(config, native);
      malloc.free(native);
    }
    final conversation = _b.conversationCreate(_engine, config);
    _b.conversationConfigDelete(config);
    if (conversation == nullptr) throw StateError('LiteRT-LM: не удалось создать диалог');
    return conversation;
  }

  String _takeString(Pointer<Pointer<Utf8>> out) {
    final pointer = out.value;
    if (pointer == nullptr) return '';
    final value = pointer.toDartString();
    _b.free(pointer);
    out.value = nullptr;
    return value;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('LlmEngine уже освобождён');
  }
}

/// Текст из куска ответа: {"role":"assistant","content":[{"type":"text","text":"..."}]}.
String _textOf(dynamic chunk) {
  if (chunk is! Map) return '';
  final content = chunk['content'];
  final items = content is List ? content : [content];
  return items
      .whereType<Map<dynamic, dynamic>>()
      .where((item) => item['type'] == 'text')
      .map((item) => item['text'] as String? ?? '')
      .join();
}
