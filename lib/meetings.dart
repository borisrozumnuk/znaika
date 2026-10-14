import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import 'database.dart';
import 'echo_filter.dart';

/// Встреча = папка записи: transcript.md, summary.md и meeting.json; system.wav и mic.wav —
/// только пока встреча не обработана (после обработки звук удаляется, см. [MeetingStore.deleteAudio]).
class Meeting {
  final Directory dir;
  final String title;

  /// Локальные дата и время начала записи.
  final DateTime startedAt;
  final double? durationSeconds;

  const Meeting({required this.dir, required this.title, required this.startedAt, this.durationSeconds});

  File get summaryFile => File('${dir.path}/summary.md');
  File get transcriptFile => File('${dir.path}/transcript.md');

  /// Выжимка без служебного заголовка «# Заметки по встрече».
  Future<String?> readSummary() async {
    if (!await summaryFile.exists()) return null;
    final text = await summaryFile.readAsString();
    return text.replaceFirst(RegExp(r'^# Заметки по встрече\s*'), '').trim();
  }

  /// Заметки написаны до того, как собеседники получили имена: их стоит пересоздать.
  Future<bool> notesOutdated() async {
    final file = File('${dir.path}/meeting.json');
    if (!await file.exists()) return false;
    try {
      return (jsonDecode(await file.readAsString()) as Map)['notesOutdated'] == true;
    } on FormatException {
      return false;
    }
  }

  /// Реплики расшифровки «[мм:сс] Кто: текст».
  Future<List<String>> readTranscript() async {
    if (!await transcriptFile.exists()) return [];
    final lines = await transcriptFile.readAsLines();
    return lines.where((line) => line.startsWith('[')).toList();
  }
}

/// Встречи: папки в recordings (основное хранилище) и их индекс в SQLite.
///
/// Папка — источник правды: звук, расшифровка, выжимка и meeting.json лежат в ней.
/// База — индекс для списка; при запуске [sync] сверяет её с диском, так что
/// папку можно скопировать, удалить или поправить meeting.json руками.
class MeetingStore {
  MeetingStore(this.recordingsDir, this.db);

  final Directory recordingsDir;
  final AppDatabase db;

  /// Новая встреча: папка по локальному времени начала и meeting.json без заголовка.
  /// В базу встреча попадает в [finish] — прерванный старт без звука там не нужен.
  Future<Directory> create(DateTime startedAt) async {
    final stamp = startedAt.toIso8601String().replaceAll(':', '-').split('.').first;
    final dir = Directory('${recordingsDir.path}/$stamp');
    await dir.create(recursive: true);
    await _writeMeta(dir, {'startedAt': startedAt.toIso8601String()});
    return dir;
  }

  /// Дописывает заголовок и длительность после окончания встречи — в meeting.json и в базу.
  Future<void> finish(Directory dir, {required String title, double? durationSeconds}) async {
    final meta = await _readMeta(dir) ?? {};
    meta['title'] = title;
    if (durationSeconds != null) meta['durationSeconds'] = durationSeconds;
    await _writeMeta(dir, meta);
    final meeting = await _fromDisk(dir);
    if (meeting != null) {
      await _upsert(meeting);
      await _index(meeting);
    }
  }

  /// Новый заголовок — в meeting.json, базу и поисковый индекс.
  Future<void> rename(Meeting meeting, String title) => finish(meeting.dir, title: title.trim());

  /// Собеседник получает имя во всей встрече: в репликах расшифровки и в заметках
  /// («Собеседник 1», «к Собеседнику 1» → «Анна»). Имя другого собеседника
  /// объединяет их реплики — так исправляется один голос, принятый за два.
  Future<void> renameSpeaker(Meeting meeting, String from, String to) async {
    final name = cleanSpeakerName(to);
    if (name == null) throw ArgumentError('Недопустимое имя собеседника: «$to»');
    if (name == from) return;
    if (await meeting.transcriptFile.exists()) {
      final text = await meeting.transcriptFile.readAsString();
      await meeting.transcriptFile.writeAsString(renameSpeakerInTranscript(text, from, name));
    }
    if (await meeting.summaryFile.exists()) {
      final text = await meeting.summaryFile.readAsString();
      await meeting.summaryFile.writeAsString(renameSpeakerInSummary(text, from, name));
      // Замена не склоняет имя и не согласует род — заметки лучше написать заново.
      await _updateMeta(meeting.dir, {'notesOutdated': true});
    }
    await _index(meeting);
  }

  /// Заметки пересозданы (summary.md уже записан): снять пометку и обновить поиск.
  Future<void> notesRegenerated(Meeting meeting) async {
    await _updateMeta(meeting.dir, {'notesOutdated': null});
    await _index(meeting);
  }

  /// Пометка «встреча ещё обрабатывается»: ставится после «Стоп», снимается, когда
  /// обработка закончена (или остановлена, или не удалась). Осталась при запуске —
  /// приложение закрыли посреди обработки, её надо продолжить.
  Future<void> setProcessing(Directory dir, bool processing) =>
      _updateMeta(dir, {'processing': processing ? true : null});

  /// Встречи, обработку которых прервало закрытие приложения, сначала старые.
  Future<List<Meeting>> unfinished() async => [
        for (final meeting in (await list()).reversed)
          if ((await _readMeta(meeting.dir))?['processing'] == true) meeting,
      ];

  /// Дописывает поля в meeting.json; null — убрать поле.
  Future<void> _updateMeta(Directory dir, Map<String, Object?> changes) async {
    final meta = await _readMeta(dir) ?? {};
    changes.forEach((key, value) => value == null ? meta.remove(key) : meta[key] = value);
    await _writeMeta(dir, meta);
  }

  /// Удаляет встречу: папку — через [moveToTrash] (в приложении — в Корзину macOS,
  /// чтобы её можно было вернуть), запись — из базы и поискового индекса.
  Future<void> delete(Meeting meeting, {required Future<void> Function(Directory dir) moveToTrash}) async {
    // В Корзину — только папка встречи прямо внутри recordings, никакой другой путь.
    final parent = meeting.dir.absolute.parent.path;
    if (parent != recordingsDir.absolute.path || _folderOf(meeting.dir).startsWith('.')) {
      throw StateError('Не папка встречи: ${meeting.dir.path}');
    }
    await moveToTrash(meeting.dir);
    final folder = _folderOf(meeting.dir);
    await (db.delete(db.meetings)..where((m) => m.folder.equals(folder))).go();
    await db.customStatement('DELETE FROM meetings_fts WHERE folder = ?', [folder]);
  }

  /// Сверяет базу с папками: новые папки добавляет, исчезнувшие (или без звука) удаляет.
  /// Возвращает, сколько встреч добавлено и удалено.
  Future<({int added, int removed})> sync() async {
    final onDisk = <String, Directory>{};
    if (await recordingsDir.exists()) {
      await for (final entry in recordingsDir.list()) {
        if (entry is Directory) onDisk[_folderOf(entry)] = entry;
      }
    }
    final known = {for (final row in await db.select(db.meetings).get()) row.folder};

    var added = 0;
    for (final MapEntry(key: folder, value: dir) in onDisk.entries) {
      if (known.contains(folder)) continue;
      final meeting = await _fromDisk(dir);
      if (meeting == null) continue;
      await _upsert(meeting);
      added++;
    }

    final gone = <String>[];
    for (final folder in known) {
      final dir = onDisk[folder];
      if (dir == null || !await _isMeeting(dir)) gone.add(folder);
    }
    if (gone.isNotEmpty) await (db.delete(db.meetings)..where((m) => m.folder.isIn(gone))).go();

    // Поисковый индекс: убрать исчезнувшие встречи, проиндексировать ещё не попавшие в него
    // (в том числе все встречи после обновления базы до версии с поиском).
    await db.customStatement('DELETE FROM meetings_fts WHERE folder NOT IN (SELECT folder FROM meetings)');
    final unindexed = await db
        .customSelect('SELECT folder FROM meetings WHERE folder NOT IN (SELECT folder FROM meetings_fts)')
        .map((row) => row.read<String>('folder'))
        .get();
    for (final meeting in await list()) {
      if (unindexed.contains(_folderOf(meeting.dir))) await _index(meeting);
    }
    return (added: added, removed: gone.length);
  }

  /// Встречи, где все слова запроса встречаются в заголовке, выжимке или расшифровке.
  /// Сверху новые; у каждой — фрагмент текста вокруг совпадения.
  Future<List<SearchHit>> search(String query) async {
    final match = searchExpression(query);
    if (match == null) return [];
    final rows = await db.customSelect(
      // snippet: столбец -1 — тот, где нашлось; совпадения обрамлены \u0001…\u0002.
      "SELECT m.folder, snippet(meetings_fts, -1, char(1), char(2), '…', 12) AS snippet "
      'FROM meetings_fts JOIN meetings m ON m.folder = meetings_fts.folder '
      'WHERE meetings_fts MATCH ? ORDER BY m.started_at DESC',
      variables: [Variable.withString(match)],
    ).get();
    final byFolder = {for (final m in await list()) _folderOf(m.dir): m};
    return [
      for (final row in rows)
        if (byFolder[row.read<String>('folder')] case final meeting?)
          SearchHit(meeting, row.read<String>('snippet')),
    ];
  }

  /// Встречи, где есть хоть одно из [words], самые подходящие первыми (bm25: заголовок
  /// весит больше заметок, заметки — больше расшифровки). Для чата по встречам.
  Future<List<Meeting>> rank(List<String> words, {int limit = 10}) async {
    final terms = [for (final w in words) ?searchExpression(w)];
    if (terms.isEmpty) return [];
    final rows = await db.customSelect(
      'SELECT folder FROM meetings_fts WHERE meetings_fts MATCH ? '
      'ORDER BY bm25(meetings_fts, 0, 5.0, 3.0, 1.0) LIMIT ?',
      variables: [Variable.withString(terms.join(' OR ')), Variable.withInt(limit)],
    ).get();
    final byFolder = {for (final m in await list()) _folderOf(m.dir): m};
    return [for (final row in rows) ?byFolder[row.read<String>('folder')]];
  }

  /// Текст встречи — в поисковый индекс (заменяя прежний).
  Future<void> _index(Meeting meeting) async {
    final summary = (await meeting.readSummary() ?? '').replaceAll(RegExp(r'[#*]|\[[ xX]\]'), ' ');
    final transcript = (await meeting.readTranscript())
        .map((line) => line.replaceFirst(RegExp(r'^\[[\d:]+\]\s*'), ''))
        .join('\n');
    final folder = _folderOf(meeting.dir);
    await db.transaction(() async {
      await db.customStatement('DELETE FROM meetings_fts WHERE folder = ?', [folder]);
      await db.customStatement(
        'INSERT INTO meetings_fts (folder, title, summary, transcript) VALUES (?, ?, ?, ?)',
        [folder, normalizeForSearch(meeting.title), normalizeForSearch(summary), normalizeForSearch(transcript)],
      );
    });
  }

  /// Все встречи из базы, сверху самые новые.
  Future<List<Meeting>> list() async {
    final rows = await (db.select(db.meetings)..orderBy([(m) => OrderingTerm.desc(m.startedAt)])).get();
    return [
      for (final row in rows)
        Meeting(
          dir: Directory('${recordingsDir.path}/${row.folder}'),
          title: row.title,
          startedAt: row.startedAt,
          durationSeconds: row.durationSeconds,
        ),
    ];
  }

  Future<void> _upsert(Meeting meeting) => db.into(db.meetings).insert(
        MeetingsCompanion.insert(
          folder: _folderOf(meeting.dir),
          title: Value(meeting.title),
          startedAt: meeting.startedAt,
          durationSeconds: Value(meeting.durationSeconds),
        ),
        onConflict: DoUpdate.withExcluded(
          (old, excluded) => MeetingsCompanion.custom(
            title: excluded.title,
            startedAt: excluded.startedAt,
            durationSeconds: excluded.durationSeconds,
          ),
          target: [db.meetings.folder],
        ),
      );

  /// Встреча по содержимому папки; null — не встреча (ни звука, ни расшифровки, или нет даты).
  Future<Meeting?> _fromDisk(Directory dir) async {
    if (!await _isMeeting(dir)) return null;
    final meta = await _readMeta(dir) ?? {};
    final startedAt = DateTime.tryParse(meta['startedAt'] as String? ?? '') ?? _parseStamp(dir);
    if (startedAt == null) return null;
    final meeting = Meeting(
      dir: dir,
      title: meta['title'] as String? ?? '',
      startedAt: startedAt,
      durationSeconds: (meta['durationSeconds'] as num?)?.toDouble(),
    );
    if (meeting.title.isNotEmpty) return meeting;
    // Записи без заголовка (в том числе до появления meeting.json): первая фраза выжимки.
    return Meeting(
      dir: dir,
      title: await _titleFromSummary(meeting) ?? 'Встреча без заметок',
      startedAt: startedAt,
      durationSeconds: meeting.durationSeconds,
    );
  }

  /// Встреча — если есть расшифровка (обработанная, звук уже удалён) или звук (ещё не
  /// обработанная). Ни того ни другого — прерванный старт.
  Future<bool> _isMeeting(Directory dir) async =>
      await File('${dir.path}/transcript.md').exists() ||
      await File('${dir.path}/mic.wav').exists() ||
      await File('${dir.path}/system.wav').exists();

  /// Звук встречи больше не нужен: расшифровка и заметки готовы, всё остальное
  /// (заметки заново, имена, поиск, экспорт) работает по расшифровке. Звук занимает
  /// ~230 МБ на час встречи, поэтому после обработки удаляется.
  Future<void> deleteAudio(Directory dir) async {
    for (final name in ['mic.wav', 'system.wav']) {
      final file = File('${dir.path}/$name');
      if (await file.exists()) await file.delete();
    }
  }

  String _folderOf(Directory dir) => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;

  Future<String?> _titleFromSummary(Meeting meeting) async {
    final summary = await meeting.readSummary();
    if (summary == null) return null;
    final firstLine = summary.split('\n').map((l) => l.trim()).firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('#'),
          orElse: () => '',
        );
    if (firstLine.isEmpty) return null;
    final sentence = firstLine.split(RegExp(r'(?<=[.!?])\s')).first;
    return sentence.length > 80 ? '${sentence.substring(0, 77)}…' : sentence;
  }

  /// Имя папки «2026-10-13T01-10-47» → локальное время.
  DateTime? _parseStamp(Directory dir) {
    final match = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})$').firstMatch(_folderOf(dir));
    if (match == null) return null;
    return DateTime.tryParse('${match[1]}T${match[2]}:${match[3]}:${match[4]}');
  }

  Future<Map<String, Object?>?> _readMeta(Directory dir) async {
    final file = File('${dir.path}/meeting.json');
    if (!await file.exists()) return null;
    try {
      return (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeMeta(Directory dir, Map<String, Object?> meta) =>
      File('${dir.path}/meeting.json').writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
}

/// Найденная встреча и фрагмент текста; совпадения в нём обрамлены \u0001…\u0002.
class SearchHit {
  final Meeting meeting;
  final String snippet;

  const SearchHit(this.meeting, this.snippet);
}

/// ё → е: в расшифровках и запросах встречаются оба написания.
String normalizeForSearch(String text) => text.replaceAll('ё', 'е').replaceAll('Ё', 'Е');

/// Запрос пользователя → выражение FTS5: все слова обязательны, каждое — по основе
/// с префиксом. У FTS5 нет русской морфологии, поэтому окончание отрезается грубо:
/// «пятница» → «пятниц*» найдёт и «пятницу», и «пятницы». null — искать нечего.
String? searchExpression(String query) {
  final words = normalizeForSearch(query.toLowerCase())
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .map((w) {
    final cut = w.length >= 6 ? 2 : (w.length >= 4 && RegExp(r'^\p{L}+$', unicode: true).hasMatch(w) ? 1 : 0);
    return '"${w.substring(0, w.length - cut)}"*';
  }).toList();
  return words.isEmpty ? null : words.join(' ');
}

const _months = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

/// «Сегодня, 01:57», «Вчера, 23:10», «12 октября, 09:30», «5 марта 2025, 14:00».
String formatMeetingTime(DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final time = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final day = DateTime(at.year, at.month, at.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  final daysAgo = todayDay.difference(day).inDays;
  if (daysAgo == 0) return 'Сегодня, $time';
  if (daysAgo == 1) return 'Вчера, $time';
  final date = '${at.day} ${_months[at.month - 1]}';
  return at.year == today.year ? '$date, $time' : '$date ${at.year}, $time';
}

/// Встреча одним Markdown-файлом: заголовок, дата и длительность, заметки, расшифровка.
String meetingMarkdown(Meeting meeting, {String? summary, List<String> transcript = const []}) {
  final buffer = StringBuffer('# ${meeting.title}\n\n');
  final when = [
    formatMeetingTime(meeting.startedAt, now: DateTime(0)),
    if (meeting.durationSeconds != null) formatDuration(meeting.durationSeconds!),
  ].join(' · ');
  buffer.write('_${when}_\n\n');
  if (summary != null && summary.isNotEmpty) buffer.write('$summary\n\n');
  if (transcript.isNotEmpty) {
    buffer.write('## Расшифровка\n\n');
    buffer.writeAll(transcript, '\n\n');
    buffer.write('\n');
  }
  return buffer.toString();
}

/// «2026-10-13 Перенос демо.md»: дата для сортировки в Finder, без символов, запрещённых в именах.
String exportFileName(Meeting meeting) {
  final d = meeting.startedAt;
  final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final title = meeting.title.replaceAll(RegExp(r'[/:\\?*"<>|\n]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = title.length > 80 ? title.substring(0, 80).trim() : title;
  return '$date ${short.isEmpty ? 'Встреча' : short}.md';
}

/// «12 мин», «1 ч 05 мин», «45 с».
String formatDuration(double seconds) {
  final s = seconds.round();
  if (s < 60) return '$s с';
  final minutes = s ~/ 60;
  if (minutes < 60) return '$minutes мин';
  return '${minutes ~/ 60} ч ${(minutes % 60).toString().padLeft(2, '0')} мин';
}

final _speakerLine = RegExp(r'^\[[\d:]+\]\s+([^:]+):');

/// Собеседники встречи (все, кроме «Я») в порядке первой реплики.
List<String> speakersOf(List<String> transcript) => {
      for (final line in transcript)
        if (_speakerLine.firstMatch(line)?[1]?.trim() case final speaker? when speaker != meLabel) speaker,
    }.toList();

/// Имя собеседника без лишних пробелов; null — пустое или недопустимое:
/// двоеточие и перевод строки ломают формат реплики, «Я» занято микрофоном.
String? cleanSpeakerName(String name) {
  final clean = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty || clean.length > 40 || clean.contains(':') || clean.startsWith('[') || clean == meLabel) {
    return null;
  }
  return clean;
}

/// Расшифровка, где реплики [from] подписаны [to].
String renameSpeakerInTranscript(String text, String from, String to) => text.replaceAllMapped(
      RegExp('^(\\[[\\d:]+\\]\\s+)${RegExp.escape(from)}:', multiLine: true),
      (m) => '${m[1]}$to:',
    );

/// Заметки, где [from] заменён на [to]. Метки «Собеседник N» и «Собеседники» Gemma
/// склоняет («Собеседнику 1», «Собеседников») — заменяются и эти формы.
/// Имя подставляется как есть, без склонения.
String renameSpeakerInSummary(String text, String from, String to) {
  const noLetterBefore = r'(?<![\p{L}\p{N}])';
  final numbered = RegExp(r'^Собеседник (\d+)$').firstMatch(from);
  final pattern = numbered != null
      ? '$noLetterBeforeСобеседник(?:а|у|ом|е)?\\s+${numbered[1]}(?!\\d)'
      : from == othersLabel
          ? '$noLetterBeforeСобеседник(?:и|ов|ам|ами|ах)(?![\\p{L}])'
          : '$noLetterBefore${RegExp.escape(from)}(?![\\p{L}\\p{N}])';
  return text.replaceAll(RegExp(pattern, unicode: true), to);
}
