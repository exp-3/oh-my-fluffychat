// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'translation_cache_test.dart'
    show MemorySecrets, key, legacyEnvelope, masterKeyName;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String dbPath, databaseKey;
  late MemorySecrets secrets;
  late NativeTranslationCacheBackend backend;
  late TranslationCache cache;
  late Uint8List master;
  final factory = createDatabaseFactoryFfi();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'translation-cache-test-',
    );
    dbPath = '${directory.path}/cache.db';
    secrets = MemorySecrets();
    master = Uint8List.fromList(List.generate(32, (i) => i));
    secrets.values[masterKeyName] = base64UrlEncode(master);
    databaseKey = sha256.convert(master + utf8.encode('database')).toString();
    backend = NativeTranslationCacheBackend(
      databasePath: dbPath,
      factory: factory,
    );
    cache = TranslationCache(secrets, backend);
  });
  tearDown(() async {
    await backend.close();
    await directory.delete(recursive: true);
  });

  Future<void> seedV2(List<CacheRow> rows) async {
    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) => db.execute(
          '''CREATE TABLE translations (
cache_key TEXT PRIMARY KEY, room_id TEXT NOT NULL, event_id TEXT NOT NULL,
nonce TEXT NOT NULL, ciphertext TEXT NOT NULL, source_binding TEXT NOT NULL, aad TEXT NOT NULL)''',
        ),
      ),
    );
    for (final row in rows) {
      await db.insert('translations', row);
    }
    await db.close();
    await SQfLiteEncryptionHelper(
      factory: factory,
      path: dbPath,
      cipher: databaseKey,
    ).ensureDatabaseFileEncrypted();
  }

  test('native missing-store probes never create a file', () async {
    expect(await cache.read(key()), isNull);
    await cache.invalidateEventIfExists('!room:test', r'$event');
    expect(await File(dbPath).exists(), isFalse);
    expect(secrets.readCalls, 0);
  });

  test('native safety cleanup opens v2 without schema migration', () async {
    await seedV2([legacyEnvelope(master)]);
    expect(await backend.openExisting(databaseKey), isTrue);
    expect(
      await backend.transaction((tx) async => tx.hasStore(CacheStore.contents)),
      isFalse,
    );
    await cache.invalidateEventIfExists('!room:test', r'$event');
    expect(
      await backend.transaction((tx) => tx.count(CacheStore.translations)),
      0,
    );
    expect(
      await backend.transaction((tx) async => tx.hasStore(CacheStore.contents)),
      isFalse,
    );
  });

  test(
    'native transaction rollback and generation protect deleted source',
    () async {
      await cache.write(key(), 'old');
      final ticket = (await cache.lookup(key())).ticket!;
      await cache.invalidateEventIfExists('!room:test', r'$event');
      await expectLater(
        cache.write(key(), 'late', ticket: ticket),
        throwsStateError,
      );
      expect(
        await backend.transaction((tx) => tx.count(CacheStore.contents)),
        0,
      );
    },
  );
}
