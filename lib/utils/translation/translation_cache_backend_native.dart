// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'translation_cache_backend_interface.dart';

TranslationCacheBackend createTranslationCacheBackend() =>
    NativeTranslationCacheBackend();

class NativeTranslationCacheBackend implements TranslationCacheBackend {
  Database? _database;
  String? _path;
  final DatabaseFactory _factory;
  final Map<String, Set<String>> _columns = {};
  NativeTranslationCacheBackend({
    String? databasePath,
    DatabaseFactory? factory,
  }) : _path = databasePath,
       _factory = factory ?? createDatabaseFactoryFfi();

  Future<String> get _databasePath async => _path ??= path.join(
    (await getApplicationSupportDirectory()).path,
    'fluffychat_translation_cache.db',
  );
  @override
  Stream<void> get externalChanges => const Stream.empty();
  @override
  void signalInvalidation() {}
  @override
  Future<bool> exists() async => _factory.databaseExists(await _databasePath);
  @override
  Future<T> coordinated<T>(Future<T> Function() action) => action();
  @override
  Future<bool> openExisting(String databaseKey, {bool migrate = false}) async {
    if (!await exists()) {
      await close();
      return false;
    }
    if (_database != null) {
      if (!migrate || await _database!.getVersion() >= 3) return true;
      await close();
    }
    try {
      await _open(databaseKey, create: false, migrate: migrate);
      return true;
    } on _CacheAbsent {
      return false;
    }
  }

  @override
  Future<void> openOrCreate(String databaseKey) async {
    if (_database != null &&
        await exists() &&
        await _database!.getVersion() >= 3) {
      return;
    }
    await close();
    await _open(databaseKey, create: true, migrate: true);
  }

  Future<void> _open(
    String databaseKey, {
    required bool create,
    required bool migrate,
  }) async {
    final databasePath = await _databasePath;
    if (!create && !await File(databasePath).exists()) {
      throw const _CacheAbsent();
    }
    final helper = SQfLiteEncryptionHelper(
      factory: _factory,
      path: databasePath,
      cipher: databaseKey,
    );
    if (migrate && (create || await exists())) {
      await helper.ensureDatabaseFileEncrypted();
    }
    _database = await _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: migrate ? 3 : null,
        singleInstance: false,
        onConfigure: (db) async {
          await helper.applyPragmaKey(db);
          if (!create && await db.getVersion() == 0) {
            final tables = await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'translations'",
            );
            if (tables.isNotEmpty) {
              // Older plaintext-to-SQLCipher exports can lose user_version.
              // Infer it from the sealed legacy schema only when migration
              // is enabled. Safety cleanup does not alter schema metadata.
              if (migrate) {
                final columns = await db.rawQuery(
                  'PRAGMA table_info(translations)',
                );
                await db.setVersion(
                  columns.any((row) => row['name'] == 'source_binding') ? 2 : 1,
                );
              }
              return;
            }
            // Never delete a path after an open/probe failure: another
            // process may have replaced or populated it in the meantime.
            throw StateError('Translation cache schema is unavailable');
          }
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: migrate ? (db, _) => _schema(db, 0) : null,
        onUpgrade: migrate
            ? (db, oldVersion, _) => _schema(db, oldVersion)
            : null,
      ),
    );
    final tables = (await _database!.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name']! as String).toSet();
    for (final store in CacheStore.values.where(
      (store) => tables.contains(store.name),
    )) {
      _columns[store.name] = (await _database!.rawQuery(
        'PRAGMA table_info(${store.name})',
      )).map((row) => row['name']! as String).toSet();
    }
  }

  static Future<void> _schema(Database db, int oldVersion) async {
    if (oldVersion == 0) {
      await db.execute(
        '''CREATE TABLE translations (
cache_key TEXT PRIMARY KEY, room_id TEXT NOT NULL, event_id TEXT NOT NULL,
nonce TEXT NOT NULL, ciphertext TEXT NOT NULL, source_binding TEXT NOT NULL, aad TEXT NOT NULL)''',
      );
    } else if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE translations ADD COLUMN source_binding TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE translations ADD COLUMN aad TEXT NOT NULL DEFAULT ''",
      );
    }
    await db.execute('''CREATE TABLE IF NOT EXISTS contents (
cache_key TEXT PRIMARY KEY, user_id TEXT NOT NULL, source_binding TEXT NOT NULL,
nonce TEXT NOT NULL, ciphertext TEXT NOT NULL, aad TEXT NOT NULL,
generation TEXT NOT NULL, legacy INTEGER NOT NULL, rank TEXT NOT NULL,
room_id TEXT NOT NULL, event_id TEXT NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS refs (
cache_key TEXT PRIMARY KEY, user_id TEXT NOT NULL, room_id TEXT NOT NULL,
event_id TEXT NOT NULL, source_binding TEXT NOT NULL, content_key TEXT NOT NULL,
original_event_id TEXT NOT NULL)''');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS generations (cache_key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS metadata (cache_key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    for (final store in cacheIndexes.entries) {
      for (final index in store.value.entries) {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS ${store.key.name}_${index.key}_idx ON ${store.key.name}(${index.value.join(',')})',
        );
      }
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(TranslationCacheTransaction tx) action, {
    bool write = false,
    bool notify = false,
  }) =>
      _database!.transaction((tx) => action(_NativeTransaction(tx, _columns)));
  @override
  Future<void> deleteIfExists() async {
    await close();
    if (await exists()) await _factory.deleteDatabase(await _databasePath);
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _columns.clear();
  }

  @override
  Future<void> dispose() => close();
}

class _NativeTransaction implements TranslationCacheTransaction {
  final DatabaseExecutor db;
  final Map<String, Set<String>> columns;
  _NativeTransaction(this.db, this.columns);
  @override
  bool hasStore(CacheStore store) => columns.containsKey(store.name);
  @override
  Future<CacheRow?> get(CacheStore store, String key) async {
    if (!hasStore(store)) return null;
    final rows = await db.query(
      store.name,
      where: 'cache_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : Map.of(rows.single);
  }

  @override
  Future<void> put(CacheStore store, CacheRow row) async {
    await db.insert(
      store.name,
      Map.of(row)..remove('_cursor'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(CacheStore store, String key) async {
    if (!hasStore(store)) return;
    await db.delete(store.name, where: 'cache_key = ?', whereArgs: [key]);
  }

  @override
  Future<List<CacheRow>> query(
    CacheStore store, {
    String? index,
    List<String>? equals,
    Object? after,
    int limit = 200,
  }) async {
    if (!hasStore(store)) return [];
    final order = store == CacheStore.translations ? 'rowid' : 'cache_key';
    final conditions = <String>[];
    final arguments = <Object?>[];
    if (index != null) {
      final fields = cacheIndexes[store]![index]!;
      // v1 may predate source bindings. Event/room cleanup still works.
      if (!columns[store.name]!.containsAll(fields)) {
        return [];
      }
      conditions.addAll(fields.map((field) => '$field = ?'));
      arguments.addAll(equals!);
    }
    if (after != null) {
      conditions.add('$order > ?');
      arguments.add(after);
    }
    return (await db.query(
      store.name,
      columns: ['*', '$order AS _cursor'],
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: arguments,
      orderBy: order,
      limit: limit,
    )).map(Map<String, Object?>.of).toList();
  }

  @override
  Future<int> count(CacheStore store) async {
    if (!hasStore(store)) return 0;
    return (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM ${store.name}',
        )).single['n']!
        as int;
  }
}

class _CacheAbsent implements Exception {
  const _CacheAbsent();
}
