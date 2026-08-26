// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

const cacheKey = TranslationCacheKey(
  roomId: '!room:example.test',
  eventId: r'$event',
  source: 'private source text',
  sourceLanguage: 'auto',
  targetLanguage: 'en',
  semanticRevision: 'provider:responses:model:1',
  messageType: 'm.text',
);

const secondCacheKey = TranslationCacheKey(
  roomId: '!room:example.test',
  eventId: r'$second-event',
  source: 'another private source',
  sourceLanguage: 'auto',
  targetLanguage: 'en',
  semanticRevision: 'provider:responses:model:1',
  messageType: 'm.notice',
);

void main() {
  test(
    'absent cache reads and invalidations create no storage or key',
    () async {
      final secrets = _MemorySecrets();
      final backend = _MemoryBackend();
      final cache = TranslationCache(secrets, backend);
      expect(await cache.read(cacheKey), isNull);
      await cache.invalidateEventIfExists(cacheKey.roomId, cacheKey.eventId);
      await cache.invalidateRoomIfExists(cacheKey.roomId);
      await cache.deleteIfExists();
      expect(backend.openExistingCalls, 0);
      expect(backend.createCalls, 0);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'first write creates key and encrypted record, then round trips',
    () async {
      final secrets = _MemorySecrets();
      final backend = _MemoryBackend();
      final cache = TranslationCache(secrets, backend);
      await cache.write(cacheKey, 'translated text');
      expect(backend.createCalls, 1);
      expect(secrets.values, hasLength(1));
      final record = backend.records.single;
      expect(record.toMap().values, isNot(contains(cacheKey.source)));
      expect(record.toMap().values, isNot(contains('translated text')));
      expect(await cache.read(cacheKey), 'translated text');
    },
  );

  test('tampered cache metadata is rejected and removed', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);
    await cache.write(cacheKey, 'translated text');
    final record = backend.records.single;
    backend.records.first = TranslationCacheRecord(
      cacheKey: record.cacheKey,
      roomId: record.roomId,
      eventId: record.eventId,
      nonce: record.nonce,
      ciphertext: record.ciphertext,
      sourceBinding: record.sourceBinding,
      aad: '${record.aad}tampered',
    );

    expect(await cache.read(cacheKey), isNull);
    expect(backend.records, isEmpty);
  });

  test(
    'cleanup validates local source binding and removes changed source',
    () async {
      final secrets = _MemorySecrets();
      final backend = _MemoryBackend();
      final cache = TranslationCache(secrets, backend);
      await cache.write(cacheKey, 'translated text');
      final result = await cache.cleanInvalid((_, _) async => 'edited source');
      expect(result.checked, 1);
      expect(result.deleted, 1);
      expect(backend.records, isEmpty);
    },
  );

  test('cleanup retains a locally valid encrypted record', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);
    await cache.write(cacheKey, 'translated text');

    final result = await cache.cleanInvalid((_, _) async => cacheKey.source);
    expect(result.checked, 1);
    expect(result.retained, 1);
    expect(result.deleted, 0);
    expect(backend.records, hasLength(1));
  });

  test('cleanup removes records with inconsistent indexed metadata', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);
    await cache.write(cacheKey, 'translated text');
    final record = backend.records.single;
    backend.records.first = TranslationCacheRecord(
      cacheKey: record.cacheKey,
      roomId: '!other-room:example.test',
      eventId: record.eventId,
      nonce: record.nonce,
      ciphertext: record.ciphertext,
      sourceBinding: record.sourceBinding,
      aad: record.aad,
    );

    final result = await cache.cleanInvalid((_, _) async => cacheKey.source);
    expect(result.checked, 1);
    expect(result.retained, 0);
    expect(result.deleted, 1);
    expect(backend.records, isEmpty);
  });

  test('cleanup removes records with malformed encrypted fields', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);
    await cache.write(cacheKey, 'translated text');
    final record = backend.records.single;
    backend.records.first = TranslationCacheRecord.fromMap({
      'cache_key': record.cacheKey,
      'room_id': record.roomId,
      'event_id': record.eventId,
      'nonce': 1234,
      'ciphertext': record.ciphertext,
      'source_binding': record.sourceBinding,
      'aad': record.aad,
    });

    final result = await cache.cleanInvalid((_, _) async => cacheKey.source);
    expect(result.checked, 1);
    expect(result.retained, 0);
    expect(result.deleted, 1);
    expect(backend.records, isEmpty);
  });

  test(
    'concurrent first writes create one database and one master key',
    () async {
      final secrets = _MemorySecrets();
      final backend = _MemoryBackend();
      final cache = TranslationCache(secrets, backend);

      await Future.wait([
        cache.write(cacheKey, 'first translation'),
        cache.write(secondCacheKey, 'second translation'),
      ]);

      expect(backend.createCalls, 1);
      expect(secrets.writeCalls, 1);
      expect(secrets.values, hasLength(1));
      expect(backend.records, hasLength(2));
      expect(await cache.read(cacheKey), 'first translation');
      expect(await cache.read(secondCacheKey), 'second translation');
    },
  );

  test('already invalid write creates neither database nor key', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);

    await expectLater(
      cache.write(cacheKey, 'late translation', isValid: () => false),
      throwsA(isA<StateError>()),
    );

    expect(backend.createCalls, 0);
    expect(backend.present, isFalse);
    expect(secrets.values, isEmpty);
    expect(secrets.writeCalls, 0);
  });

  test('invalid first write rolls back its new database and key', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);
    var valid = true;
    backend.afterOpenOrCreate = () => valid = false;

    await expectLater(
      cache.write(cacheKey, 'late translation', isValid: () => valid),
      throwsA(isA<StateError>()),
    );

    expect(backend.present, isFalse);
    expect(backend.records, isEmpty);
    expect(secrets.values, isEmpty);
    expect(secrets.deleteCalls, 1);
  });

  test('failed first database creation removes its new key and file', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend()..failOpenAfterCreate = true;
    final cache = TranslationCache(secrets, backend);

    await expectLater(
      cache.write(cacheKey, 'translated text'),
      throwsA(isA<StateError>()),
    );

    expect(backend.present, isFalse);
    expect(backend.records, isEmpty);
    expect(secrets.values, isEmpty);
    expect(secrets.deleteCalls, 1);
  });

  test(
    'invalid committed write is removed from an existing database',
    () async {
      final secrets = _MemorySecrets();
      final backend = _MemoryBackend();
      final cache = TranslationCache(secrets, backend);
      await cache.write(cacheKey, 'retained translation');

      var valid = true;
      backend.afterPutAll = () => valid = false;
      await expectLater(
        cache.write(secondCacheKey, 'late translation', isValid: () => valid),
        throwsA(isA<StateError>()),
      );

      expect(backend.present, isTrue);
      expect(backend.records, hasLength(1));
      expect(await cache.read(cacheKey), 'retained translation');
      expect(await cache.read(secondCacheKey), isNull);
      expect(secrets.values, hasLength(1));
    },
  );

  test('invalid replacement restores the prior encrypted record', () async {
    final secrets = _MemorySecrets();
    final backend = _MemoryBackend();
    final cache = TranslationCache(secrets, backend);
    await cache.write(cacheKey, 'original translation');

    var valid = true;
    backend.afterPutAll = () => valid = false;
    await expectLater(
      cache.write(cacheKey, 'late replacement', isValid: () => valid),
      throwsA(isA<StateError>()),
    );

    expect(await cache.read(cacheKey), 'original translation');
  });

  test(
    'delete waits for an active write and removes its key and database',
    () async {
      final secrets = _MemorySecrets();
      final backend = _MemoryBackend();
      final cache = TranslationCache(secrets, backend);
      final putStarted = Completer<void>();
      final releasePut = Completer<void>();
      backend.beforePutAll = () async {
        putStarted.complete();
        await releasePut.future;
      };

      final write = cache.write(cacheKey, 'translated text');
      await putStarted.future;
      final delete = cache.deleteIfExists();
      await Future<void>.delayed(Duration.zero);
      expect(backend.deleteCalls, 0);

      releasePut.complete();
      await Future.wait([write, delete]);
      expect(backend.present, isFalse);
      expect(backend.records, isEmpty);
      expect(secrets.values, isEmpty);
    },
  );
}

class _MemorySecrets implements TranslationSecretStore {
  final values = <String, String>{};
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<void> delete(String key) async {
    deleteCalls++;
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writeCalls++;
    values[key] = value;
  }
}

class _MemoryBackend implements TranslationCacheBackend {
  final records = <TranslationCacheRecord>[];
  bool present = false;
  int openExistingCalls = 0;
  int createCalls = 0;
  int deleteCalls = 0;
  bool failOpenAfterCreate = false;
  void Function()? afterOpenOrCreate;
  Future<void> Function()? beforePutAll;
  void Function()? afterPutAll;

  @override
  Future<bool> exists() async => present;
  @override
  Future<bool> openExisting(String databaseKey) async {
    openExistingCalls++;
    return present;
  }

  @override
  Future<void> openOrCreate(String databaseKey) async {
    createCalls++;
    present = true;
    afterOpenOrCreate?.call();
    if (failOpenAfterCreate) {
      throw StateError('Database creation failed');
    }
  }

  @override
  Future<TranslationCacheRecord?> get(String key) async {
    for (final record in records) {
      if (record.cacheKey == key) return record;
    }
    return null;
  }

  @override
  Future<void> putAll(List<TranslationCacheRecord> value) async {
    await beforePutAll?.call();
    for (final record in value) {
      records.removeWhere((item) => item.cacheKey == record.cacheKey);
      records.add(record);
    }
    afterPutAll?.call();
  }

  @override
  Future<int> deleteByEvent(String roomId, String eventId) async {
    final before = records.length;
    records.removeWhere(
      (record) => record.roomId == roomId && record.eventId == eventId,
    );
    return before - records.length;
  }

  @override
  Future<int> deleteByRoom(String roomId) async {
    final before = records.length;
    records.removeWhere((record) => record.roomId == roomId);
    return before - records.length;
  }

  @override
  Future<int> deleteKeys(List<String> keys) async {
    final before = records.length;
    records.removeWhere((record) => keys.contains(record.cacheKey));
    return before - records.length;
  }

  @override
  Future<List<TranslationCacheRecord>> page(int offset, int limit) async {
    final end = (offset + limit).clamp(offset, records.length);
    return records.sublist(offset.clamp(0, records.length), end);
  }

  @override
  Future<int> count() async => records.length;
  @override
  Future<void> deleteIfExists() async {
    deleteCalls++;
    present = false;
    records.clear();
  }

  @override
  Future<void> close() async {}
}
