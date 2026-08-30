// SPDX-FileCopyrightText: 2026 OMF Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqfl_cipher;

import '../platform_infos.dart';
import 'translation_cache_backend_interface.dart';

TranslationCacheBackend createTranslationCacheBackend() =>
    NativeTranslationCacheBackend();

class NativeTranslationCacheBackend implements TranslationCacheBackend {
  Database? _database;
  String? _path;

  Future<String> get _databasePath async => _path ??= path.join(
    (await getApplicationSupportDirectory()).path,
    'fluffychat_translation_cache.db',
  );

  DatabaseFactory get _factory {
    if (PlatformInfos.isMobile) return sqfl_cipher.databaseFactory;
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  @override
  Future<bool> exists() async => _factory.databaseExists(await _databasePath);

  @override
  Future<bool> openExisting(String databaseKey) async {
    if (_database != null) return true;
    if (!await exists()) return false;
    try {
      _database = await _open(databaseKey);
      return true;
    } catch (error, stackTrace) {
      // Translation results are a disposable cache. Match the main Matrix
      // database recovery strategy and replace a file that cannot be opened
      // (for example one created by the former, too-late PRAGMA key flow).
      Logs().w(
        'Unable to open translation cache database; rebuilding it',
        error,
        stackTrace,
      );
      await deleteIfExists();
      return false;
    }
  }

  @override
  Future<void> openOrCreate(String databaseKey) async {
    _database ??= await _open(databaseKey);
  }

  Future<Database> _open(String databaseKey) async {
    final databasePath = await _databasePath;
    final options = OpenDatabaseOptions(
      version: 2,
      onConfigure: (database) async {
        await database.rawQuery('PRAGMA foreign_keys = ON');
      },
      onCreate: (database, _) async {
        await database.execute('''
CREATE TABLE translations (
  cache_key TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  source_binding TEXT NOT NULL,
  aad TEXT NOT NULL
)''');
        await database.execute(
          'CREATE INDEX translations_room_idx ON translations(room_id)',
        );
        await database.execute(
          'CREATE INDEX translations_event_idx ON translations(room_id, event_id)',
        );
      },
      onUpgrade: (database, oldVersion, _) async {
        if (oldVersion < 2) {
          await database.execute(
            "ALTER TABLE translations ADD COLUMN source_binding TEXT NOT NULL DEFAULT ''",
          );
          await database.execute(
            "ALTER TABLE translations ADD COLUMN aad TEXT NOT NULL DEFAULT ''",
          );
        }
      },
    );

    // On Android/iOS the SQLCipher plugin must receive the password as part
    // of the native open call. Applying `PRAGMA key` from onConfigure is too
    // late: Android may execute PRAGMA journal_mode before that callback,
    // causing an existing encrypted database to be reported as "not a
    // database" after an app restart.
    if (PlatformInfos.isMobile) {
      return sqfl_cipher.openDatabase(
        databasePath,
        password: databaseKey,
        version: options.version,
        onConfigure: options.onConfigure,
        onCreate: options.onCreate,
        onUpgrade: options.onUpgrade,
        onDowngrade: options.onDowngrade,
        onOpen: options.onOpen,
        singleInstance: true,
      );
    }

    // Desktop uses the FFI factory. Keep its behavior aligned with the main
    // Matrix database: migrate an existing plaintext file to SQLCipher, then
    // apply the key during the factory's configure callback. This also means
    // the translation database is encrypted at rest on Windows, Linux and
    // macOS instead of relying only on per-record encryption.
    final factory = _factory;
    final helper = SQfLiteEncryptionHelper(
      factory: factory,
      path: databasePath,
      cipher: databaseKey,
    );
    await helper.ensureDatabaseFileEncrypted();
    return factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: options.version,
        onConfigure: helper.applyPragmaKey,
        onCreate: options.onCreate,
        onUpgrade: options.onUpgrade,
        onDowngrade: options.onDowngrade,
        onOpen: options.onOpen,
        singleInstance: true,
      ),
    );
  }

  Database get _db =>
      _database ?? (throw StateError('Translation cache is not open'));

  @override
  Future<TranslationCacheRecord?> get(String cacheKey) async {
    final rows = await _db.query(
      'translations',
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    return rows.isEmpty ? null : TranslationCacheRecord.fromMap(rows.first);
  }

  @override
  Future<void> putAll(List<TranslationCacheRecord> records) async {
    await _db.transaction((transaction) async {
      final batch = transaction.batch();
      for (final record in records) {
        batch.insert(
          'translations',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<int> deleteByEvent(String roomId, String eventId) => _db.delete(
    'translations',
    where: 'room_id = ? AND event_id = ?',
    whereArgs: [roomId, eventId],
  );

  @override
  Future<int> deleteByRoom(String roomId) =>
      _db.delete('translations', where: 'room_id = ?', whereArgs: [roomId]);

  @override
  Future<int> deleteKeys(List<String> cacheKeys) async {
    if (cacheKeys.isEmpty) return 0;
    var deleted = 0;
    await _db.transaction((transaction) async {
      for (final key in cacheKeys) {
        deleted += await transaction.delete(
          'translations',
          where: 'cache_key = ?',
          whereArgs: [key],
        );
      }
    });
    return deleted;
  }

  @override
  Future<List<TranslationCacheRecord>> page(int offset, int limit) async =>
      (await _db.query(
        'translations',
        limit: limit,
        offset: offset,
      )).map(TranslationCacheRecord.fromMap).toList(growable: false);

  @override
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) FROM translations');
    return rows.first.values.first as int? ?? 0;
  }

  @override
  Future<void> deleteIfExists() async {
    await close();
    final databasePath = await _databasePath;
    if (await _factory.databaseExists(databasePath)) {
      await _factory.deleteDatabase(databasePath);
    }
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
