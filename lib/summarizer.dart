import 'dart:async';
import 'dart:io';

import 'package:litert_lm/litert_lm.dart';

import 'log.dart';

/// Выжимка встречи встроенной Gemma 4 E4B на LiteRT-LM.
/// Повторяет asr-proto/summarize.py: те же промпты, два прохода, map-reduce.

const gemmaModelFile = 'gemma-4-E4B-it.litertlm';

/// Как модель заметок называется в интерфейсе.
const gemmaModelName = 'Gemma 4 E4B';

/// Контекст 8192, а не 16 384: на GPU модель считается во float32 (см. LlmEngine.load),
/// и кэш внимания на 16 384 токена на Mac с 16 ГБ упирается в память — запросы
/// зависают по таймауту LiteRT-LM (20 с) уже на второй части длинной встречи.
const _contextTokens = 8192;
const _maxOutputTokens = 2048;

/// Сколько токенов расшифровки отдаём в один запрос: остальное — промпт и ответ.
/// 3000, а не больше: во float32 Gemma читает вход на GPU ~190 токенов/с, и часть
/// в 5000 токенов (~28 с) иногда упирается во внутренний таймаут LiteRT-LM (20 с
/// на операцию видеокарты) — особенно когда видеокарта занята другими программами.
const _chunkTokens = 3000;

const _system = '''Ты помощник, который делает заметки по встречам. Пишешь по-русски, кратко и по делу.

Правила:
- Опирайся только на расшифровку. Ничего не додумывай; если чего-то нет — так и пиши.
- Расшифровка сделана автоматически и может содержать ошибки распознавания:
  восстанавливай смысл по контексту, но не выдумывай факты. Особенно часто
  искажаются числа: «версия 20» рядом с «версией 2.1» — это, скорее всего, «2.0».
- «Я» — это пользователь, для которого ты пишешь заметки. «Собеседник 1»,
  «Собеседник 2» и т. д. — разные участники, различённые по голосу (метка
  «Собеседники» — все остальные участники вместе). Если имена звучат в разговоре
  и понятно, к кому они относятся, используй имена.
- Реплика может быть подписана именем («Анна: …») — это участник с этим именем.
  Называй его так же, склоняй имя и согласуй с ним род («Анна сообщила», «к Анне»).
- Сохраняй точные цифры, даты, сроки, названия и термины.
- После утверждения ставь таймкод из расшифровки в формате [мм:сс].''';

// Выжимка делается в два прохода, как у Foresight: маленькая модель в одном
// запросе на всё теряет задачи собеседников и открытые вопросы.
String _summaryPrompt(String source) => '''Сделай заметки по встрече в Markdown строго по шаблону:

## Кратко
2–4 предложения: о чём встреча и чем закончилась.

## Обсуждение
Ключевые темы списком; под каждой — главное, что сказали.

## Решения
Что решили. Если решений не было — «Нет».

$source''';

String _actionsPrompt(String source) => '''Найди в материалах встречи задачи и открытые вопросы.

Как искать задачи: пройди по каждой реплике по порядку. Задача — это когда
участник обещает что-то сделать, соглашается на просьбу, называет срок своей
работы или его просят что-то сделать к сроку. Учитывай задачи ВСЕХ участников:
и «Я», и собеседников, и тех, кого только упомянули.

Добровольцы: если на вопрос «кто сделает…?» участник отвечает «могу я»,
«возьму на себя», «сделаю» — это его задача, даже с оговоркой («но мне нужны
данные…»). Оговорку запиши как условие задачи.

Упомянутые люди: если о человеке говорят «X сделает…», «попрошу X…», «если X
поднимет / подготовит / пришлёт … до …», — это отдельная задача X, даже если
X на встрече нет. Запиши её на X со сроком или условием.

Имена: если «Я» обращается к собеседнику по имени («Анна, начнёшь…?»), то
следующая реплика собеседников — от этого человека. Его задачи подписывай
именем, а не «Собеседники» или «Собеседник N».

Проверка в конце: выпиши для себя все имена из расшифровки. Для каждого имени
ещё раз проверь, нет ли у этого человека задачи, — и добавь её, если пропустил.

Как искать открытые вопросы: что не решили, в чём участники сомневаются, что
зависит от чужих неподтверждённых сроков или данных.

Ответь в Markdown строго по шаблону, без вступления:

## Задачи
- [ ] Кто — что — срок или условие, если названы [мм:сс]

## Открытые вопросы
- Вопрос [мм:сс]

Если чего-то нет — напиши «Нет» в соответствующем разделе.

$source''';

String _chunkPrompt(int index, int total, String text) =>
    '''Это часть $index из $total расшифровки встречи. Выпиши подробные заметки
по этой части: темы, факты, цифры, решения, задачи (кто, что, срок), открытые
вопросы. Сохраняй таймкоды [мм:сс]. Только то, что есть в этой части.

<расшифровка>
$text
</расшифровка>''';

String _mergePrompt(String notes) => '''Это заметки по нескольким идущим подряд частям встречи.
Объедини их в одни заметки: темы, факты, цифры, решения, задачи (кто, что, срок),
открытые вопросы. Ничего не теряй из задач и решений, повторы убери. Сохраняй таймкоды.

$notes''';

String _titlePrompt(String summary) => '''Придумай заголовок для этой встречи: 3–7 слов, о чём она.
Ответь только заголовком — без кавычек, без точки в конце, без пояснений.

<заметки>
$summary
</заметки>''';

/// Чистит ответ одного прохода: оставляет только его разделы [sections] (первый
/// проход иногда сам дописывает «## Задачи» — их пишет второй, и они повторялись),
/// повторы пунктов внутри раздела убирает, служебные «(Часть 3–6)» от сжатия
/// по частям вырезает.
String cleanSummary(String raw, {required List<String> sections}) {
  final out = StringBuffer();
  final seenSections = <String>{};
  var seenItems = <String>{};
  var skip = false;
  for (final line in raw.split('\n')) {
    final heading = RegExp(r'^##\s+(.+?)\s*$').firstMatch(line);
    if (heading != null) {
      final name = heading[1]!;
      skip = !sections.contains(name) || !seenSections.add(name);
      seenItems = {};
      if (!skip) out.writeln(line);
      continue;
    }
    if (skip) continue;
    final item = RegExp(r'^\s*[-*]\s+(?:\[[ xX]\]\s+)?(.+)$').firstMatch(line);
    if (item != null && !seenItems.add(item[1]!.trim().toLowerCase())) continue;
    out.writeln(line.replaceAll(RegExp(r'\s*\(Част[ьи]\s*[\d–-][^)]*\)'), ''));
  }
  return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// Первая строка ответа без Markdown, кавычек и точки в конце.
String cleanTitle(String raw) {
  var title = raw.trim().split('\n').first.trim();
  title = title.replaceFirst(RegExp(r'^(#+\s*|заголовок\s*:\s*)', caseSensitive: false), '');
  // Кавычки, выделение и точка в конце могут идти в любом порядке: «…».
  return title.replaceAll(RegExp(r'^[«"“*_\s]+|[»"”*_.\s]+$'), '');
}

/// Остановка заметок по кнопке: [stop] прерывает текущий запрос к модели,
/// и summarize завершается с [NotesStopped].
class NotesStop {
  bool _stopped = false;
  void Function()? _onStop;

  bool get stopped => _stopped;

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _onStop?.call();
  }
}

class NotesStopped implements Exception {
  const NotesStopped();

  @override
  String toString() => 'Заметки остановлены';
}

/// Модель занята одним запросом за раз. Ждущие — по порядку; срочные ([urgent], чат) —
/// впереди обычных (частей заметок), но после уже начатого запроса. «Остановить», пока
/// запрос ждёт, убирает его из очереди сразу ([NotesStopped]).
class ModelLock {
  bool _busy = false;
  final _waiters = <({Completer<void> ready, bool urgent})>[];

  bool get busy => _busy;

  Future<T> run<T>(Future<T> Function() body, {bool urgent = false, NotesStop? stop}) async {
    await _acquire(urgent: urgent, stop: stop);
    try {
      return await body();
    } finally {
      _release();
    }
  }

  Future<void> _acquire({required bool urgent, NotesStop? stop}) async {
    if (stop?.stopped ?? false) throw const NotesStopped();
    if (!_busy) {
      _busy = true;
      return;
    }
    final waiter = (ready: Completer<void>(), urgent: urgent);
    final at = urgent ? _waiters.indexWhere((w) => !w.urgent) : -1;
    at < 0 ? _waiters.add(waiter) : _waiters.insert(at, waiter);
    stop?._onStop = () {
      if (_waiters.remove(waiter)) waiter.ready.completeError(const NotesStopped());
    };
    try {
      await waiter.ready.future;
    } finally {
      stop?._onStop = null;
    }
  }

  /// Модель свободна — передать её следующему ждущему (занятость не снимается).
  void _release() {
    if (_waiters.isEmpty) {
      _busy = false;
    } else {
      _waiters.removeAt(0).ready.complete();
    }
  }
}

/// Держит модель загруженной между встречами: загрузка занимает секунды.
/// Один на всё приложение (app_globals): вторая копия Gemma (3,7 ГБ) не поместится
/// в память. Очередь двухуровневая:
/// - задачи заметок (заметки, заголовок) идут по одной ([_exclusive]) — выжимка после
///   записи подождёт, пока пересоздаются заметки другой встречи, и наоборот;
/// - сама модель занята одним запросом за раз ([_locked]); вопрос чата встаёт к ней
///   первым и проходит между частями заметок — ждёт не всех заметок, а одного запроса.
class Summarizer {
  Summarizer({
    required this.modelsDir,
    required this.cacheDir,
    this.staleCacheDirs = const [],
    String Function()? modelFile,
  }) : modelFile = modelFile ?? (() => gemmaModelFile);

  final String modelsDir;
  final String cacheDir;

  /// Файл выбранной модели в [modelsDir]. Читается в начале каждой задачи
  /// (заметки, заголовок): смена модели не переключает её посреди заметок.
  final String Function() modelFile;

  /// Модель текущей задачи и та, что загружена сейчас.
  String? _jobModel;
  String? _loadedModel;

  /// Кэши прежних версий (~2 ГБ) — удаляются при загрузке модели.
  final List<String> staleCacheDirs;
  LlmEngine? _engine;

  /// ZNAIKA_GEMMA_CPU=1 — всё на процессоре (самопроверка запасного пути).
  static final _forceCpu = Platform.environment['ZNAIKA_GEMMA_CPU'] == '1';

  /// Модель загружена на процессор: видеокарта не уложилась в таймаут.
  bool _onCpu = _forceCpu;

  /// Когда снова попробовать видеокарту. Таймауты на MacBook Air похожи на перегрев:
  /// после пары минут нагрузки видеокарта замедляется. Пока процессор считает,
  /// она остывает; не справилась снова — пауза вдвое длиннее.
  DateTime? _gpuRetryAt;
  Duration _gpuCooldown = _initialCooldown;
  static const _initialCooldown = Duration(seconds: 90);
  Future<void> _queue = Future.value();
  int _jobs = 0;

  /// Модель занята одним запросом за раз; чат — впереди частей заметок.
  final _model = ModelLock();

  Future<T> _locked<T>(Future<T> Function() body, {bool urgent = false, NotesStop? stop}) =>
      _model.run(body, urgent: urgent, stop: stop);

  Future<T> _exclusive<T>(Future<T> Function() job) {
    _jobs++;
    final result = _queue.then((_) {
      _jobModel = modelFile();
      return job();
    }).whenComplete(() => _jobs--);
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// [file] — модель запроса (у чата своя, иначе — модель текущей задачи заметок).
  Future<LlmEngine> _ensureEngine([String? file]) async {
    final model = '$modelsDir/${file ?? _jobModel ?? modelFile()}';
    final existing = _engine;
    if (existing != null && _loadedModel == model) return existing;
    // Выбрали другую модель — прежнюю выгружаем: две в память не поместятся.
    existing?.dispose();
    _engine = null;
    if (!File(model).existsSync()) throw StateError('Модель не найдена: $model');
    await Directory(cacheDir).create(recursive: true);
    for (final stale in staleCacheDirs) {
      final dir = Directory(stale);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _loadedModel = model;
    return _engine = await LlmEngine.load(
      modelPath: model,
      backend: _onCpu ? 'cpu' : 'gpu',
      maxTokens: _contextTokens,
      cacheDir: cacheDir,
    );
  }

  /// Один запрос к модели с запасным путём. На GPU LiteRT-LM ждёт каждую операцию
  /// видеокарты не дольше 20 с; когда видеокарта не успевает, запрос падает по
  /// таймауту, и модель на GPU после этого неработоспособна. Тогда она выгружается
  /// и запрос повторяется на процессоре: там медленнее, но ответ тот же.
  /// На GPU модель вернётся при следующих заметках.
  /// Ждёт модель ([_locked]); [urgent] — без очереди за частями заметок (чат),
  /// [onStart] — модель дошла до запроса, [file] — модель запроса.
  Future<String> _ask(
    String prompt, {
    String system = _system,
    int maxOutputTokens = _maxOutputTokens,
    double temperature = 0.3,
    void Function(String stage)? onProgress,
    void Function(String textSoFar)? onText,
    NotesStop? stop,
    bool urgent = false,
    void Function()? onStart,
    String? file,
  }) =>
      _locked(urgent: urgent, stop: stop, () {
        onStart?.call();
        return _askNow(
          prompt,
          system: system,
          maxOutputTokens: maxOutputTokens,
          temperature: temperature,
          onProgress: onProgress,
          onText: onText,
          stop: stop,
          file: file,
        );
      });

  Future<String> _askNow(
    String prompt, {
    required String system,
    required int maxOutputTokens,
    required double temperature,
    void Function(String stage)? onProgress,
    void Function(String textSoFar)? onText,
    NotesStop? stop,
    String? file,
  }) async {
    for (var attempt = 1;; attempt++) {
      if (stop?.stopped ?? false) throw const NotesStopped();
      final retryAt = _gpuRetryAt;
      if (_onCpu && !_forceCpu && retryAt != null && DateTime.now().isAfter(retryAt)) {
        logLine('Gemma: пробую снова видеокарту');
        _engine?.dispose();
        _engine = null;
        _onCpu = false;
        _gpuRetryAt = null;
      }
      final engine = await _ensureEngine(file);
      final buffer = StringBuffer();
      final watch = Stopwatch()..start();
      Duration? firstPiece;
      final inputTokens = engine.countTokens('$system\n$prompt');
      logLine('Gemma ${engine.backend}: запрос $inputTokens токенов (попытка $attempt)');
      final done = Completer<String>();
      final subscription = engine
          .generate(prompt: prompt, system: system, maxOutputTokens: maxOutputTokens, temperature: temperature)
          .listen(
            (piece) {
              firstPiece ??= watch.elapsed;
              buffer.write(piece);
              onText?.call(buffer.toString());
            },
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
            onDone: () {
              if (!done.isCompleted) done.complete(buffer.toString());
            },
          );
      // Отмена подписки останавливает генерацию в LiteRT-LM.
      stop?._onStop = () {
        subscription.cancel();
        if (!done.isCompleted) done.completeError(const NotesStopped());
      };
      try {
        final answer = await done.future;
        logLine('Gemma ${engine.backend}: первый кусок через ${firstPiece?.inMilliseconds} мс, '
            'ответ ${answer.length} символов за ${watch.elapsedMilliseconds} мс');
        // ZNAIKA_LOG_ANSWERS=1 — полный ответ в журнал (разбор промптов).
        if (Platform.environment['ZNAIKA_LOG_ANSWERS'] == '1') logLine('Gemma ответ:\n$answer');
        return answer;
      } on NotesStopped {
        rethrow;
      } catch (e) {
        logLine('Gemma ${engine.backend}: ошибка через ${watch.elapsedMilliseconds} мс (попытка $attempt): $e');
        // После таймаута видеокарты модель на ней сломана: следующий запрос падает
        // с «buffer already has an outstanding map pending». Повторять на GPU
        // бесполезно — выгружаем и продолжаем на процессоре.
        final gpuBroken = e is LlmTimeout || '$e'.contains('outstanding map pending');
        if (_onCpu || !gpuBroken) rethrow;
        onProgress?.call('Видеокарта не успевает — пока продолжаю на процессоре…');
        _engine?.dispose();
        _engine = null;
        _onCpu = true;
        _gpuRetryAt = DateTime.now().add(_gpuCooldown);
        logLine('Gemma: на процессоре, видеокарта — снова через ${_gpuCooldown.inSeconds} с');
        _gpuCooldown *= 2;
      } finally {
        stop?._onStop = null;
      }
    }
  }

  /// После заметок на процессоре — выгрузить его модель: следующие пойдут снова на GPU.
  void _backToGpu() {
    _gpuRetryAt = null;
    _gpuCooldown = _initialCooldown;
    if (!_onCpu || _forceCpu) return;
    _engine?.dispose();
    _engine = null;
    _onCpu = false;
  }

  /// Пишет выжимку по строкам расшифровки «[мм:сс] Кто: текст».
  /// [onProgress] получает этап («Сжимаю часть 2/3…»), [onText] — выжимку по мере генерации.
  /// Результат сохраняется в [outFile].
  Future<String> summarize(
    List<String> lines, {
    required File outFile,
    void Function(String stage)? onProgress,
    void Function(String textSoFar)? onText,
    NotesStop? stop,
  }) {
    if (_jobs > 0) onProgress?.call('Жду, пока Gemma допишет другие заметки…');
    return _exclusive(() async {
      if (stop?.stopped ?? false) throw const NotesStopped();
      try {
        return await _summarize(lines, outFile: outFile, onProgress: onProgress, onText: onText, stop: stop);
      } finally {
        await _locked(() async => _backToGpu());
      }
    });
  }

  Future<String> _summarize(
    List<String> lines, {
    required File outFile,
    void Function(String stage)? onProgress,
    void Function(String textSoFar)? onText,
    NotesStop? stop,
  }) async {
    onProgress?.call('Загрузка модели…');
    // Подсчёт токенов — тоже модель: между запросами её мог занять чат.
    final chunks = await _locked(stop: stop, () async => _splitByTokens(await _ensureEngine(), lines, _chunkTokens));
    final String source;
    if (chunks.length == 1) {
      source = '<расшифровка>\n${chunks.single}\n</расшифровка>';
    } else {
      final notes = <String>[];
      for (var i = 0; i < chunks.length; i++) {
        onProgress?.call('Сжимаю часть ${i + 1}/${chunks.length}…');
        final note = await _ask(_chunkPrompt(i + 1, chunks.length, chunks[i]), onProgress: onProgress, stop: stop);
        notes.add('### Часть ${i + 1}\n${note.trim()}');
      }
      // Очень длинная встреча: заметки частей сами не помещаются в запрос — сжимаем их группами.
      var parts = notes;
      while (parts.length > 1 &&
          await _locked(stop: stop, () async => (await _ensureEngine()).countTokens(parts.join('\n\n'))) >
              _chunkTokens) {
        final groups = await _locked(stop: stop, () async => _splitByTokens(await _ensureEngine(), parts, _chunkTokens));
        if (groups.length == parts.length) break;
        final merged = <String>[];
        for (var i = 0; i < groups.length; i++) {
          onProgress?.call('Объединяю заметки ${i + 1}/${groups.length}…');
          final note = await _ask(_mergePrompt(groups[i]), onProgress: onProgress, stop: stop);
          merged.add('### Части ${i + 1}\n${note.trim()}');
        }
        parts = merged;
      }
      source = 'Заметки по частям встречи (по порядку):\n\n${parts.join('\n\n')}';
    }

    final done = <String>[];
    for (final (stage, prompt, sections) in [
      ('Пишу выжимку…', _summaryPrompt(source), const ['Кратко', 'Обсуждение', 'Решения']),
      ('Ищу задачи и открытые вопросы…', _actionsPrompt(source), const ['Задачи', 'Открытые вопросы']),
    ]) {
      onProgress?.call(stage);
      final answer = await _ask(
        prompt,
        onProgress: onProgress,
        onText: (text) => onText?.call([...done, text].join('\n\n')),
        stop: stop,
      );
      done.add(cleanSummary(answer, sections: sections));
    }

    final summary = done.join('\n\n');
    await outFile.writeAsString('# Заметки по встрече\n\n$summary\n');
    return summary;
  }

  /// Модель сейчас отвечает на запрос — новый подождёт его (чат — только его).
  bool get busy => _model.busy;

  /// Ответ на вопрос в чате по встречам — без очереди за заметками: между их частями.
  /// [onStart] — модель дошла до вопроса, [onText] — ответ по мере генерации.
  /// «Остановить», пока вопрос ждёт, убирает его из очереди сразу.
  Future<String> answer(
    String prompt, {
    required String system,
    void Function()? onStart,
    void Function(String textSoFar)? onText,
    NotesStop? stop,
  }) async {
    try {
      return await _ask(
        prompt,
        system: system,
        maxOutputTokens: 1024,
        onText: onText,
        stop: stop,
        urgent: true,
        onStart: onStart,
        file: modelFile(),
      );
    } finally {
      // Заметки посреди работы (возможно, на процессоре после перегрева) — не вмешиваемся.
      if (_jobs == 0) await _locked(() async => _backToGpu());
    }
  }

  /// Короткий заголовок встречи (3–7 слов) по готовой выжимке.
  Future<String> makeTitle(String summary) => _exclusive(() async {
        try {
          return await _makeTitle(summary);
        } finally {
          await _locked(() async => _backToGpu());
        }
      });

  Future<String> _makeTitle(String summary) async {
    final raw = await _ask(
      _titlePrompt(summary),
      system: 'Ты придумываешь короткие заголовки для заметок по встречам. Пишешь по-русски.',
      maxOutputTokens: 32,
      temperature: 0.2,
    );
    return cleanTitle(raw);
  }

  void dispose() {
    _engine?.dispose();
    _engine = null;
  }
}

/// Режет расшифровку на части не длиннее [limit] токенов, не разрывая реплики.
List<String> _splitByTokens(LlmEngine engine, List<String> lines, int limit) {
  final chunks = <String>[];
  var current = <String>[];
  var size = 0;
  for (final line in lines) {
    final tokens = engine.countTokens(line) + 1;
    if (current.isNotEmpty && size + tokens > limit) {
      chunks.add(current.join('\n'));
      current = [];
      size = 0;
    }
    current.add(line);
    size += tokens;
  }
  if (current.isNotEmpty) chunks.add(current.join('\n'));
  return chunks;
}
