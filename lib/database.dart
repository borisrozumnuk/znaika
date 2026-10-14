import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'database.g.dart';

/// Индекс встреч. Основное хранилище — папки встреч с файлами; база строится
/// по ним и сверяется с диском при запуске (MeetingStore.sync).
/// Строка — MeetingRow: имя Meeting занято моделью встречи в meetings.dart.
@DataClassName('MeetingRow')
class Meetings extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Имя папки встречи в recordings, например «2026-10-13T02-18-02».
  TextColumn get folder => text().unique()();

  /// Пустой, если заголовок ещё не придуман.
  TextColumn get title => text().withDefault(const Constant(''))();

  /// Локальное время начала записи.
  DateTimeColumn get startedAt => dateTime()();

  RealColumn get durationSeconds => real().nullable()();
}

@DriftDatabase(tables: [Meetings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// База в файле; запросы идут в фоновом изоляте.
  factory AppDatabase.open(File file) => AppDatabase(NativeDatabase.createInBackground(file));

  /// 2 — полнотекстовый индекс meetings_fts для поиска.
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createSearchIndex();
        },
        onUpgrade: (m, from, to) async {
          // Индекс заполнит MeetingStore.sync при следующем запуске.
          if (from < 2) await _createSearchIndex();
        },
      );

  /// FTS5 по заголовку, выжимке и расшифровке; folder — ключ встречи, не индексируется.
  /// unicode61 приводит регистр, в том числе кириллицы; ё → е приводим сами.
  Future<void> _createSearchIndex() => customStatement(
        'CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5('
        'folder UNINDEXED, title, summary, transcript, '
        "tokenize = 'unicode61 remove_diacritics 2')",
      );
}
