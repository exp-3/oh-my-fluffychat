// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'translation_test_backend.dart';

const masterKeyName = 'chat.fluffy.translation.cache_master_key';
TranslationCacheKey key({
  String user = '@alice:test',
  String room = '!room:test',
  String event = r'$event',
  String source = 'private source',
  String target = 'en',
  String type = 'm.text',
  String model = 'first-model',
  String? originalId,
}) => TranslationCacheKey(
  userId: user,
  roomId: room,
  eventId: event,
  source: source,
  sourceLanguage: 'auto',
  targetLanguage: target,
  messageType: type,
  model: model,
  originalEventId: originalId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemorySecrets secrets;
  late MemoryTranslationBackend backend;
  late TranslationCache cache;
  setUp(() {
    secrets = MemorySecrets();
    backend = MemoryTranslationBackend();
    cache = TranslationCache(secrets, backend);
  });

  test(
    'never-used cache creates no database, key, or secure-storage reads',
    () async {
      expect(
        (await cache.lookup(key())).status,
        TranslationCacheLookupStatus.miss,
      );
      await cache.invalidateEventIfExists('!room:test', r'$event');
      await cache.invalidateRoomIfExists('!room:test');
      final result = await cache.cleanInvalid(
        (_, _, _) async => throw StateError('must not resolve source'),
      );
      expect(result.cacheExisted, isFalse);
      expect(backend.createCalls, 0);
      expect(backend.openExistingCalls, 0);
      expect(secrets.readCalls, 0);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'content shares across rooms and models; accounts, languages and types isolate',
    () async {
      await cache.write(key(), 'translated');
      expect(
        await cache.read(
          key(room: '!other:test', event: r'$alias', model: 'new-model'),
        ),
        'translated',
      );
      expect(backend.records, hasLength(1));
      expect(backend.rows[CacheStore.refs], hasLength(2));
      expect(await cache.read(key(user: '@bob:test')), isNull);
      expect(await cache.read(key(target: 'de')), isNull);
      expect(await cache.read(key(type: 'm.notice')), isNull);
      final persisted = jsonEncode(backend.records);
      expect(persisted, isNot(contains('private source')));
      expect(persisted, isNot(contains('translated')));
      expect(persisted, isNot(contains('first-model')));
    },
  );

  test(
    'edit deletes all shared variants and loser references, even after restart',
    () async {
      await cache.write(key(), 'translated');
      await cache.read(key(room: '!other:test', event: r'$alias'));
      await cache.write(key(target: 'de'), 'übersetzt');
      await cache.write(key(type: 'm.notice'), 'notice');
      final restarted = TranslationCache(secrets, backend);
      await restarted.invalidateEventIfExists('!other:test', r'$alias');
      expect(backend.records, isEmpty);
      expect(backend.rows[CacheStore.refs], isEmpty);
      expect(backend.rows[CacheStore.generations], hasLength(1));
      expect(await restarted.read(key()), isNull);
    },
  );

  test(
    'disk generations prevent a late write from a different cache instance',
    () async {
      await cache.write(key(), 'old');
      final other = TranslationCache(secrets, backend);
      final ticket = (await other.lookup(key())).ticket!;
      await cache.invalidateEventIfExists('!room:test', r'$event');
      await expectLater(
        other.write(key(), 'late', ticket: ticket),
        throwsStateError,
      );
      expect(await cache.read(key()), isNull);
      final fresh = (await cache.lookup(key())).ticket!;
      await cache.write(key(), 'new', ticket: fresh);
      expect(await cache.read(key()), 'new');
    },
  );

  test(
    'redacting an edit destroys original and every historical edit binding',
    () async {
      await cache.write(key(), 'original translation');
      await cache.write(
        key(event: r'$edit1', source: 'first edit', originalId: r'$event'),
        'first edit translation',
      );
      await cache.write(
        key(event: r'$edit2', source: 'latest edit', originalId: r'$event'),
        'latest edit translation',
      );
      await TranslationCache(
        secrets,
        backend,
      ).invalidateEventIfExists('!room:test', r'$edit1');
      expect(backend.records, isEmpty);
      expect(backend.rows[CacheStore.refs], isEmpty);
      expect(backend.rows[CacheStore.generations], hasLength(3));
    },
  );

  test(
    'a missing database still invalidates a relevant in-flight memory ticket',
    () async {
      final ticket = (await cache.lookup(key())).ticket!;
      await cache.invalidateEventIfExists(
        '!room:test',
        r'$event',
        sources: [key().source],
      );
      await expectLater(
        cache.write(key(), 'late', ticket: ticket),
        throwsStateError,
      );
      expect(backend.createCalls, 0);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'missing or locked master key preserves the existing encrypted database',
    () async {
      await cache.write(key(), 'old');
      secrets.values.clear();
      final restarted = TranslationCache(secrets, backend);
      expect(
        (await restarted.lookup(key())).status,
        TranslationCacheLookupStatus.unavailable,
      );
      await expectLater(
        restarted.write(key(), 'replacement'),
        throwsStateError,
      );
      await restarted.invalidateEventIfExists('!room:test', r'$event');
      expect(backend.records, hasLength(1));
      expect(backend.deleteCalls, 0);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'locked storage queues minimal cleanup and replays before another hit',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = TranslationPreferences(
        await SharedPreferences.getInstance(),
        secrets,
      );
      cache.safetyPreferences = preferences;
      await cache.write(key(), 'old');
      backend.unavailable = true;
      await cache.invalidateEventIfExists('!room:test', r'$event');
      expect(
        (await cache.lookup(key())).status,
        TranslationCacheLookupStatus.unavailable,
      );
      expect(preferences.pendingCacheCleanup, hasLength(1));
      final queue = jsonEncode(preferences.pendingCacheCleanup);
      expect(queue, isNot(contains(key().source)));
      expect(queue, isNot(contains('old')));
      backend.unavailable = false;
      final restarted = TranslationCache(secrets, backend)
        ..safetyPreferences = preferences;
      expect(await restarted.read(key()), isNull);
      expect(preferences.pendingCacheCleanup, isEmpty);
    },
  );

  test(
    'temporarily unavailable local source is retained; confirmed obsolete is deleted',
    () async {
      await cache.write(key(), 'old');
      final unavailable = await cache.cleanInvalid(
        (_, _, _) async => TranslationLocalSource.unavailable,
      );
      expect(unavailable.deleted, 0);
      expect(await cache.read(key()), 'old');
      final obsolete = await cache.cleanInvalid(
        (_, _, _) async => TranslationLocalSource.obsolete,
      );
      expect(obsolete.deleted, 1);
      expect(await cache.read(key()), isNull);
    },
  );

  test('corrupt row is isolated from other valid entries', () async {
    await cache.write(key(), 'old');
    await cache.write(key(source: 'another source', event: r'$other'), 'valid');
    backend.rows[CacheStore.contents]!.values.first['nonce'] = 123;
    expect(await cache.read(key()), isNull);
    expect(
      await cache.read(key(source: 'another source', event: r'$other')),
      'valid',
    );
  });

  test(
    'transaction cancellation aborts every record without restoring obsolete snapshots',
    () async {
      await cache.write(key(), 'old');
      var valid = true;
      backend.afterPutAll = () => valid = false;
      await expectLater(
        cache.write(key(), 'replacement', isValid: () => valid),
        throwsStateError,
      );
      backend.afterPutAll = null;
      expect(await cache.read(key()), 'old');
    },
  );

  test(
    'canceled first write removes its empty new database and master key',
    () async {
      var valid = true;
      backend.afterOpenOrCreate = () => valid = false;
      await expectLater(
        cache.write(key(), 'late', isValid: () => valid),
        throwsStateError,
      );
      expect(backend.present, isFalse);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'legacy reduction is deterministic, restartable, and retains every reference',
    () async {
      await cache.write(
        key(source: 'bootstrap', event: r'$bootstrap'),
        'bootstrap',
      );
      backend.rows[CacheStore.contents]!.clear();
      backend.rows[CacheStore.refs]!.clear();
      final master = Uint8List.fromList(
        base64Url.decode(secrets.values[masterKeyName]!),
      );
      final old = legacyEnvelope(
        master,
        event: r'$loser',
        text: 'first',
        revision: 'a',
      );
      final latest = legacyEnvelope(
        master,
        event: r'$winner',
        text: 'last',
        revision: 'b',
      );
      // Memory/Web deterministic order is cache_key, independent of insertion.
      final ordered = [old, latest]
        ..sort(
          (a, b) => cacheString(
            a,
            'cache_key',
          ).compareTo(cacheString(b, 'cache_key')),
        );
      for (final row in [latest, old]) {
        backend.rows[CacheStore.translations]![cacheString(row, 'cache_key')] =
            row;
      }
      await cache.migrateLegacy(
        owners: (_) => ['@alice:test'],
        localSource: (_, _, _) async => TranslationLocalSource.unavailable,
        isEnabled: () => true,
        pageSize: 1,
      );
      expect(backend.rows[CacheStore.translations], isEmpty);
      expect(backend.records, hasLength(1));
      expect(backend.rows[CacheStore.refs], hasLength(2));
      final expected = ordered.last['event_id'] == r'$winner'
          ? 'last'
          : 'first';
      expect(await TranslationCache(secrets, backend).read(key()), expected);
      await cache.invalidateEventIfExists(
        '!room:test',
        cacheString(ordered.first, 'event_id'),
      );
      expect(await cache.read(key()), isNull);
    },
  );

  test(
    'fresh content beats legacy backfill and unresolved ownership remains sealed',
    () async {
      await cache.write(key(), 'fresh');
      final master = Uint8List.fromList(
        base64Url.decode(secrets.values[masterKeyName]!),
      );
      final row = legacyEnvelope(master, event: r'$legacy', text: 'old');
      backend.rows[CacheStore.translations]![cacheString(row, 'cache_key')] =
          row;
      await cache.migrateLegacy(
        owners: (_) => [],
        localSource: (_, _, _) async => TranslationLocalSource.unavailable,
        isEnabled: () => true,
      );
      expect(backend.rows[CacheStore.translations], hasLength(1));
      await cache.migrateLegacy(
        owners: (_) => ['@alice:test'],
        localSource: (_, _, _) async => TranslationLocalSource.unavailable,
        isEnabled: () => true,
      );
      expect(await cache.read(key()), 'fresh');
      expect(backend.rows[CacheStore.refs], hasLength(2));
    },
  );

  test(
    'disabled migration does not open storage or resolve local messages',
    () async {
      await cache.migrateLegacy(
        owners: (_) => throw StateError('disabled'),
        localSource: (_, _, _) async => throw StateError('disabled'),
        isEnabled: () => false,
      );
      expect(backend.openExistingCalls, 0);
      expect(secrets.readCalls, 0);
    },
  );
}

class MemorySecrets implements TranslationSecretStore {
  final values = <String, String>{};
  int readCalls = 0;
  @override
  Future<String?> read(String key) async {
    readCalls++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Exact v1 encryption, independent of the new cache implementation.
CacheRow legacyEnvelope(
  Uint8List master, {
  String event = r'$event',
  String text = 'legacy',
  String revision = 'provider:protocol:model:endpoint:1',
}) {
  const source = 'private source';
  final aad = jsonEncode([
    1,
    '!room:test',
    event,
    'auto',
    'en',
    revision,
    'm.text',
  ]);
  final digest = sha256.convert(utf8.encode(source)).bytes;
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(
      HkdfParameters(
        master,
        32,
        Uint8List.fromList(digest),
        Uint8List.fromList(utf8.encode('fluffychat-translation-v1')),
      ),
    );
  final derived = Uint8List(32);
  hkdf.deriveKey(null, 0, derived, 0);
  final nonce = Uint8List.fromList(List.generate(12, (i) => i));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(derived),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(aad)),
      ),
    );
  return {
    'cache_key': base64UrlEncode(
      Hmac(sha256, master).convert(utf8.encode(aad) + digest).bytes,
    ),
    'room_id': '!room:test',
    'event_id': event,
    'source_binding': base64UrlEncode(
      Hmac(sha256, master).convert(utf8.encode('source-binding:$source')).bytes,
    ),
    'aad': aad,
    'nonce': base64UrlEncode(nonce),
    'ciphertext': base64UrlEncode(
      cipher.process(Uint8List.fromList(utf8.encode(text))),
    ),
  };
}
