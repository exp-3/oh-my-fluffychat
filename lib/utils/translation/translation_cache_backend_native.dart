// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'translation_cache_backend_interface.dart';

TranslationCacheBackend createTranslationCacheBackend() =>
    NativeTranslationCacheBackend();

class NativeTranslationCacheBackend implements TranslationCacheBackend {
  static final _coordination = <String, Future<void>>{};
  Database? _database;
  int? _openedVersion;
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
  bool get supported => true;
  @override
  Stream<void> get externalChanges => const Stream.empty();
  @override
  void signalInvalidation() {}
  @override
  Future<bool> exists() async {
    final databasePath = await _databasePath;
    return await _factory.databaseExists(databasePath) ||
        await File('$databasePath.pre-encryption').exists();
  }
  @override
  Future<T> coordinated<T>(Future<T> Function() action) async {
    final lockPath = File('${await _databasePath}.lock').absolute.path;
    final previous = _coordination[lockPath];
    final completed = Completer<void>();
    _coordination[lockPath] = completed.future;
    RandomAccessFile? lock;
    try {
      await previous;
      await File(lockPath).parent.create(recursive: true);
      lock = await File(lockPath).open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      await _recoverEncryptionReplacement();
      return await action();
    } finally {
      try {
        if (lock != null) await lock.close();
      } finally {
        completed.complete();
        if (identical(_coordination[lockPath], completed.future)) {
          _coordination.remove(lockPath);
        }
      }
    }
  }
  @override
  Future<bool> openExisting(String databaseKey, {bool migrate = false}) async {
    if (!await exists()) {
      await close();
      return false;
    }
    if (_database != null) {
      final version = await _database!.getVersion();
      if (version == _openedVersion &&
          (!migrate || version >= cacheFormatVersion)) {
        return true;
      }
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
    if (_database != null && await exists()) {
      final version = await _database!.getVersion();
      if (version == _openedVersion && version >= cacheFormatVersion) return;
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
    await _recoverEncryptionReplacement();
    if (!create && !await File(databasePath).exists()) {
      throw const _CacheAbsent();
    }
    var plaintext = await _isPlaintext(File(databasePath));
    if (migrate && plaintext) {
      await _encryptPlaintext(databaseKey);
      plaintext = false;
    }
    final helper = SQfLiteEncryptionHelper(
      factory: _factory,
      path: databasePath,
      cipher: databaseKey,
    );
    _database = await _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: migrate ? cacheFormatVersion : null,
        singleInstance: false,
        onConfigure: (db) async {
          // A safety probe must also read old plaintext archives without
          // rewriting them. Applying a SQLCipher key makes SQLite headers
          // unreadable, so encryption is deferred to the actual upgrade.
          if (!plaintext) await helper.applyPragmaKey(db);
          if (!create && await db.getVersion() == 0) {
            final tables = await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('translations', 'contents')",
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
                  tables.any((row) => row['name'] == 'contents')
                      ? 3
                      : columns.any((row) => row['name'] == 'source_binding')
                      ? 2
                      : 1,
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
    _openedVersion = await _database!.getVersion();
    final tables = (await _database!.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name']! as String).toSet();
    for (final store in CacheStore.values.where(
      (store) => tables.contains(store.tableName),
    )) {
      _columns[store.tableName] = (await _database!.rawQuery(
        'PRAGMA table_info(${store.tableName})',
      )).map((row) => row['name']! as String).toSet();
    }
    await _removeEncryptionBackup();
  }

  static Future<bool> _isPlaintext(File file) async {
    if (!await file.exists()) return false;
    final handle = await file.open();
    try {
      final header = await handle.read(16);
      return String.fromCharCodes(header) == 'SQLite format 3\u0000';
    } finally {
      await handle.close();
    }
  }

  Future<void> _recoverEncryptionReplacement() async {
    final databasePath = await _databasePath;
    final original = File(databasePath);
    final backup = File('$databasePath.pre-encryption');
    // Renaming the original aside and installing the verified encrypted file
    // each preserve a complete database. Recover a crash between those moves.
    if (!await original.exists() && await backup.exists()) {
      await backup.rename(databasePath);
    }
  }

  Future<void> _removeEncryptionBackup() async {
    final backup = File('${await _databasePath}.pre-encryption');
    if (!await backup.exists()) return;
    try {
      await backup.delete();
    } catch (_) {
      // The active database has already been verified. A stale backup can be
      // retried on the next open without failing an otherwise safe upgrade.
    }
  }

  Future<void> _encryptPlaintext(String databaseKey) async {
    final databasePath = await _databasePath;
    final original = File(databasePath);
    final backup = File('$databasePath.pre-encryption');
    final temporaryPath = '$databasePath.encrypting';
    Database? plaintextDatabase;
    Database? encryptedDatabase;
    try {
      // Failed exports never touch the original. Clear their private staging
      // files before retrying, rather than exporting over partial old tables.
      await _factory.deleteDatabase(temporaryPath);
      plaintextDatabase = await _factory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      if ((await plaintextDatabase.rawQuery('PRAGMA cipher_version')).isEmpty) {
        throw StateError('SQLCipher library is not available');
      }
      final checkpoint = await plaintextDatabase.rawQuery(
        'PRAGMA wal_checkpoint(TRUNCATE)',
      );
      if (checkpoint.any((row) => row['busy'] != 0)) {
        throw StateError('Translation cache is busy during encryption');
      }
      final version = await plaintextDatabase.getVersion();
      final escapedPath = temporaryPath.replaceAll("'", "''");
      final escapedKey = databaseKey.replaceAll("'", "''");
      await plaintextDatabase.execute(
        "ATTACH DATABASE '$escapedPath' AS encrypted KEY '$escapedKey'",
      );
      await plaintextDatabase.execute("SELECT sqlcipher_export('encrypted')");
      // sqlcipher_export omits user_version. Preserve it explicitly, including
      // zero, so normal schema inference remains available for older exports.
      await plaintextDatabase.execute(
        'PRAGMA encrypted.user_version = $version',
      );
      await plaintextDatabase.execute('DETACH DATABASE encrypted');
      await plaintextDatabase.close();
      plaintextDatabase = null;
      final helper = SQfLiteEncryptionHelper(
        factory: _factory,
        path: temporaryPath,
        cipher: databaseKey,
      );
      encryptedDatabase = await _factory.openDatabase(
        temporaryPath,
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: helper.applyPragmaKey,
        ),
      );
      final integrity = await encryptedDatabase.rawQuery(
        'PRAGMA integrity_check',
      );
      if (await encryptedDatabase.getVersion() != version ||
          integrity.length != 1 ||
          integrity.single.values.single != 'ok') {
        throw StateError('Encrypted translation cache verification failed');
      }
      await encryptedDatabase.close();
      encryptedDatabase = null;
      if (await backup.exists()) await backup.delete();
      await original.rename(backup.path);
      try {
        await File(temporaryPath).rename(databasePath);
      } catch (_) {
        // If restoration also fails, leave the complete backup in place for
        // the next coordinated operation instead of deleting the only copy.
        await _recoverEncryptionReplacement();
        rethrow;
      }
    } finally {
      await plaintextDatabase?.close();
      await encryptedDatabase?.close();
      try {
        await _factory.deleteDatabase(temporaryPath);
      } catch (_) {
        // Cleanup failure cannot invalidate either the original or the
        // verified replacement; a later export will clear these files.
      }
    }
  }

  static Future<void> _schema(Database db, int oldVersion) async {
    for (final store in activeCacheStores) {
      final fields = cacheColumns[store]!
          .map(
            (field) => field == 'cache_key'
                ? '$field TEXT PRIMARY KEY'
                : '$field TEXT NOT NULL',
          )
          .join(', ');
      await db.execute(
        'CREATE TABLE IF NOT EXISTS ${store.tableName} ($fields)',
      );
      for (final index
          in (cacheIndexes[store] ?? const <String, List<String>>{}).entries) {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS ${store.tableName}_${index.key}_idx ON ${store.tableName}(${index.value.join(',')})',
        );
      }
    }
    await db.insert('metadata', {
      'cache_key': 'format',
      'value': oldVersion == 0 ? '$cacheFormatVersion' : 'pending',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> needsUpgrade() async {
    final database = _database;
    if (database == null) throw StateError('Translation cache is not open');
    final version = await database.getVersion();
    if (version > cacheFormatVersion || version < 0) {
      throw StateError('Unsupported translation cache version: $version');
    }
    if (version < cacheFormatVersion) {
      final legacy = _columns[CacheStore.translations.tableName];
      final contents = _columns[CacheStore.contents.tableName];
      final references = _columns[CacheStore.refs.tableName];
      final recognized = version < 3 && contents == null
          ? legacy?.containsAll({
            'cache_key',
            'room_id',
            'event_id',
            'nonce',
            'ciphertext',
          }) == true
          : contents?.containsAll({
            'cache_key',
            'user_id',
            'source_binding',
            'nonce',
            'ciphertext',
            'aad',
            'generation',
          }) == true &&
              references?.containsAll({
                'cache_key',
                'user_id',
                'room_id',
                'event_id',
                'content_key',
                'original_event_id',
              }) == true &&
              _columns[CacheStore.generations.tableName]?.containsAll({
                'cache_key',
                'value',
              }) == true &&
              _columns[CacheStore.metadata.tableName]?.containsAll({
                'cache_key',
                'value',
              }) == true;
      if (recognized) return true;
      throw StateError('Unrecognized translation cache schema');
    }
    for (final store in activeCacheStores) {
      final columns = _columns[store.tableName];
      final required = cacheColumns[store]!;
      if (columns == null ||
          columns.length != required.length ||
          !columns.containsAll(required)) {
        throw StateError('Invalid translation cache table: ${store.tableName}');
      }
      final definitions = await database.rawQuery(
        'PRAGMA table_info(${store.tableName})',
      );
      if (definitions.any(
        (column) =>
            column['type'] != 'TEXT' ||
            (column['name'] == 'cache_key'
                ? column['pk'] != 1
                : column['notnull'] != 1),
      )) {
        throw StateError('Invalid translation cache columns: ${store.tableName}');
      }
      for (final index
          in (cacheIndexes[store] ?? const <String, List<String>>{}).entries) {
        final name = '${store.tableName}_${index.key}_idx';
        final fields = (await database.rawQuery('PRAGMA index_info($name)'))
            .map((row) => row['name'])
            .toList();
        if (fields.length != index.value.length ||
            !List.generate(
              fields.length,
              (i) => fields[i] == index.value[i],
            ).every((equal) => equal)) {
          throw StateError('Invalid translation cache index: $name');
        }
      }
    }
    final marker = await transaction(
      (tx) => tx.get(CacheStore.metadata, 'format'),
    );
    if (marker?['value'] == '$cacheFormatVersion') return false;
    if (marker?['value'] == 'pending') return true;
    throw StateError('Invalid translation cache format marker');
  }

  @override
  Future<void> finishUpgrade() async {
    await _database!.transaction((tx) async {
      for (final store in legacyCacheStores) {
        await tx.execute('DROP TABLE IF EXISTS ${store.tableName}');
      }
      await tx.insert('metadata', {
        'cache_key': 'format',
        'value': '$cacheFormatVersion',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    for (final store in legacyCacheStores) {
      _columns.remove(store.tableName);
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
    final backup = File('${await _databasePath}.pre-encryption');
    if (await backup.exists()) await backup.delete();
    if (await exists()) await _factory.deleteDatabase(await _databasePath);
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _openedVersion = null;
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
  bool hasStore(CacheStore store) => columns.containsKey(store.tableName);
  @override
  Future<CacheRow?> get(CacheStore store, String key) async {
    if (!hasStore(store)) return null;
    final rows = await db.query(
      store.tableName,
      where: 'cache_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : Map.of(rows.single);
  }

  @override
  Future<void> put(CacheStore store, CacheRow row) async {
    await db.insert(
      store.tableName,
      Map.of(row)..remove('_cursor'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(CacheStore store, String key) async {
    if (!hasStore(store)) return;
    await db.delete(store.tableName, where: 'cache_key = ?', whereArgs: [key]);
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
      if (!columns[store.tableName]!.containsAll(fields)) {
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
      store.tableName,
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
          'SELECT COUNT(*) AS n FROM ${store.tableName}',
        )).single['n']!
        as int;
  }
}

class _CacheAbsent implements Exception {
  const _CacheAbsent();
}
