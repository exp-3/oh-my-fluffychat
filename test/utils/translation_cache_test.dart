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
    'content shares across accounts, rooms and models; languages and types isolate',
    () async {
      await cache.write(key(), 'translated');
      expect(
        await cache.read(
          key(room: '!other:test', event: r'$alias', model: 'new-model'),
        ),
        'translated',
      );
      expect(await cache.read(key(user: '@bob:test')), 'translated');
      expect(backend.records, hasLength(1));
      expect(backend.rows[CacheStore.messageRefs], hasLength(3));
      expect(await cache.read(key(target: 'de')), isNull);
      expect(await cache.read(key(type: 'm.notice')), isNull);
      final persisted = jsonEncode(backend.records);
      expect(persisted, isNot(contains('private source')));
      expect(persisted, isNot(contains('translated')));
      expect(persisted, isNot(contains('first-model')));
      expect(persisted, isNot(contains('user_id')));
      expect(persisted, isNot(contains('@alice:test')));
      expect(persisted, isNot(contains('@bob:test')));
    },
  );

  test(
    'redaction removes the message for all accounts but retains other references',
    () async {
      await cache.write(key(), 'translated');
      await cache.read(key(user: '@bob:test'));
      await cache.read(key(room: '!other:test', event: r'$alias'));
      await cache.write(key(target: 'de'), 'übersetzt');
      await cache.write(key(type: 'm.notice'), 'notice');
      final restarted = TranslationCache(secrets, backend);
      await restarted.invalidateEventIfExists('!room:test', r'$event');
      expect(backend.records, hasLength(1));
      expect(
        backend.rows[CacheStore.messageRefs]!.values.every(
          (row) => row['room_id'] == '!other:test',
        ),
        isTrue,
      );
      expect(
        await restarted.read(key(room: '!other:test', event: r'$alias')),
        'translated',
      );
      await restarted.invalidateEventIfExists('!other:test', r'$alias');
      expect(backend.records, isEmpty);
      expect(backend.rows[CacheStore.messageRefs], isEmpty);
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

  test('logout retains content until the final account reference', () async {
    await cache.write(key(), 'shared');
    final bob = key(user: '@bob:test', room: '!other:test');
    expect(await cache.read(bob), 'shared');

    await cache.invalidateUserIfExists('@alice:test');
    expect(backend.records, hasLength(1));
    expect(
      backend.rows[CacheStore.messageRefs]!.values.every(
        (row) => row['user_id'] == '@bob:test',
      ),
      isTrue,
    );
    expect(await cache.read(bob), 'shared');

    await cache.invalidateUserIfExists('@bob:test');
    expect(backend.records, isEmpty);
    expect(backend.rows[CacheStore.messageRefs], isEmpty);
  });

  test(
    'changing a mapped source retains another message translation',
    () async {
      await cache.write(key(), 'old');
      final alias = key(user: '@bob:test', room: '!other:test');
      expect(await cache.read(alias), 'old');

      expect(await cache.read(key(source: 'edited source')), isNull);
      await cache.write(key(source: 'edited source'), 'new');
      expect(await cache.read(key(source: 'edited source')), 'new');
      expect(await cache.read(alias), 'old');
      expect(backend.records, hasLength(2));
    },
  );

  test('deleted message cannot write late while shared content survives', () async {
    await cache.write(key(), 'shared');
    final alias = key(user: '@bob:test', room: '!other:test');
    expect(await cache.read(alias), 'shared');
    final other = TranslationCache(secrets, backend);
    final ticket = (await other.lookup(key())).ticket!;
    final survivingTicket = (await other.lookup(alias)).ticket!;

    await cache.invalidateEventIfExists('!room:test', r'$event');
    await expectLater(
      other.write(key(), 'late', ticket: ticket),
      throwsStateError,
    );
    expect(await cache.read(alias), 'shared');
    await other.write(alias, 'fresh', ticket: survivingTicket);
    expect(await cache.read(alias), 'fresh');
    expect(backend.records, hasLength(1));
    expect(
      backend.rows[CacheStore.messageRefs]!.values.every(
        (row) => row['user_id'] == '@bob:test',
      ),
      isTrue,
    );
  });

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
      expect(backend.rows[CacheStore.messageRefs], isEmpty);
    },
  );

  test('a mapped hit records an edit relationship learned later', () async {
    final edit = key(event: r'$edit', source: 'edited source');
    await cache.write(edit, 'edit translation');
    expect(
      await cache.read(
        key(
          event: r'$edit',
          source: 'edited source',
          originalId: r'$original',
        ),
      ),
      'edit translation',
    );

    await cache.invalidateEventIfExists('!room:test', r'$original');
    expect(backend.rows[CacheStore.messageRefs], isEmpty);
    expect(backend.records, isEmpty);
  });

  test('redaction discovers edit roots from every account mapping', () async {
    await cache.write(
      key(event: r'$original', source: 'original source'),
      'original translation',
    );
    await cache.write(
      key(event: r'$edit', source: 'edited source'),
      'edit translation',
    );
    expect(
      await cache.read(
        key(
          user: '@bob:test',
          event: r'$edit',
          source: 'edited source',
          originalId: r'$original',
        ),
      ),
      'edit translation',
    );
    await cache.write(
      key(
        event: r'$sibling',
        source: 'another edit',
        originalId: r'$original',
      ),
      'another translation',
    );

    await TranslationCache(
      secrets,
      backend,
    ).invalidateEventIfExists('!room:test', r'$edit');
    expect(backend.rows[CacheStore.messageRefs], isEmpty);
    expect(backend.records, isEmpty);
  });

  test(
    'redacting a root rejects a pending edit with a learned relationship',
    () async {
      await cache.write(
        key(event: r'$edit1', source: 'first edit', originalId: r'$original'),
        'first translation',
      );
      final edit = key(event: r'$edit2', source: 'second edit');
      await cache.write(edit, 'second translation');
      expect(
        await cache.read(
          key(
            event: r'$edit2',
            source: 'second edit',
            originalId: r'$original',
          ),
        ),
        'second translation',
      );
      final other = TranslationCache(secrets, backend);
      final ticket = (await other.lookup(edit)).ticket!;

      await cache.invalidateEventIfExists('!room:test', r'$original');
      await expectLater(
        other.write(edit, 'late', ticket: ticket),
        throwsStateError,
      );
      expect(backend.rows[CacheStore.messageRefs], isEmpty);
      expect(backend.records, isEmpty);
    },
  );

  test(
    'a missing database still invalidates a relevant in-flight memory ticket',
    () async {
      final ticket = (await cache.lookup(key())).ticket!;
      await cache.invalidateEventIfExists(
        '!room:test',
        r'$event',
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
    backend.rows[CacheStore.sharedContents]!.values.first['nonce'] = 123;
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
    'startup upgrade merges account copies using the latest valid write',
    () async {
      final master = Uint8List.fromList(List.generate(32, (i) => i));
      secrets.values[masterKeyName] = base64UrlEncode(master);
      seedAccountCache(backend, master, [
        accountEnvelope(master, text: 'older', writtenAt: '2026-01-01T00:00:00Z'),
        accountEnvelope(
          master,
          user: '@bob:test',
          text: 'latest',
          writtenAt: '2026-02-01T00:00:00Z',
        ),
      ]);

      expect(await cache.needsUpgrade(), isTrue);
      await cache.upgrade(
        (_, _, _) async => const TranslationLocalSource.valid('private source'),
        pageSize: 1,
      );

      expect(await cache.needsUpgrade(), isFalse);
      expect(await cache.read(key()), 'latest');
      expect(await cache.read(key(user: '@bob:test')), 'latest');
      expect(backend.records, hasLength(1));
      expect(backend.rows[CacheStore.messageRefs], hasLength(2));
      expect(backend.rows[CacheStore.contents], isEmpty);
      expect(backend.rows[CacheStore.refs], isEmpty);
      final persisted = jsonEncode(backend.records);
      expect(persisted, isNot(contains('user_id')));
      expect(persisted, isNot(contains('@alice:test')));
      expect(persisted, isNot(contains('@bob:test')));
    },
  );

  test('startup upgrade discards missing originals and invalid ciphertext', () async {
    final master = Uint8List.fromList(List.generate(32, (i) => i));
    secrets.values[masterKeyName] = base64UrlEncode(master);
    final corrupt = accountEnvelope(
      master,
      event: r'$corrupt',
      source: 'corrupt source',
    )
      ..['ciphertext'] = 'invalid';
    seedAccountCache(backend, master, [
      accountEnvelope(master),
      accountEnvelope(master, event: r'$missing', source: 'missing source'),
      corrupt,
    ]);

    await cache.upgrade((_, _, event) async {
      if (event == r'$missing') return TranslationLocalSource.unavailable;
      return TranslationLocalSource.valid(
        event == r'$corrupt' ? 'corrupt source' : 'private source',
      );
    });

    expect(await cache.needsUpgrade(), isFalse);
    expect(await cache.read(key()), 'legacy account translation');
    expect(backend.records, hasLength(1));
    expect(backend.rows[CacheStore.contents], isEmpty);
  });

  test('failed startup upgrade preserves old data and can be retried', () async {
    final master = Uint8List.fromList(List.generate(32, (i) => i));
    secrets.values[masterKeyName] = base64UrlEncode(master);
    seedAccountCache(backend, master, [accountEnvelope(master)]);
    backend.beforePutAll = () async => throw StateError('disk full');
    await expectLater(
      cache.upgrade(
        (_, _, _) async => const TranslationLocalSource.valid('private source'),
      ),
      throwsStateError,
    );
    expect(await cache.needsUpgrade(), isTrue);
    expect(backend.rows[CacheStore.contents], hasLength(1));

    backend.beforePutAll = null;
    await TranslationCache(secrets, backend).upgrade(
      (_, _, _) async => const TranslationLocalSource.valid('private source'),
    );
    expect(await cache.read(key()), 'legacy account translation');
    expect(await cache.needsUpgrade(), isFalse);
  });
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

void seedAccountCache(
  MemoryTranslationBackend backend,
  Uint8List master,
  List<CacheRow> envelopes,
) {
  backend.present = true;
  backend.rows[CacheStore.metadata]!['format'] = {
    'cache_key': 'format',
    'value': 'pending',
  };
  for (final envelope in envelopes) {
    final contentKey = cacheString(envelope, 'cache_key');
    backend.rows[CacheStore.contents]![contentKey] = envelope;
    final reference = {
      'cache_key': base64UrlEncode(
        Hmac(sha256, master).convert(utf8.encode(jsonEncode([
          envelope['user_id'],
          '!room:test',
          envelope['event_id'],
          contentKey,
        ]))).bytes,
      ),
      'user_id': envelope['user_id'],
      'room_id': '!room:test',
      'event_id': envelope['event_id'],
      'source_binding': envelope['source_binding'],
      'content_key': contentKey,
      'original_event_id': envelope['event_id'],
    };
    backend.rows[CacheStore.refs]![cacheString(reference, 'cache_key')] = reference;
  }
}

/// Account-bound v2 envelope produced independently of the current cache.
CacheRow accountEnvelope(
  Uint8List master, {
  String user = '@alice:test',
  String event = r'$event',
  String source = 'private source',
  String text = 'legacy account translation',
  String writtenAt = '2026-01-01T00:00:00Z',
}) {
  final binding = base64UrlEncode(
    Hmac(sha256, master).convert(utf8.encode('source-binding:$source')).bytes,
  );
  final identity = [user, binding, 'auto', 'en', 'm.text'];
  final aad = jsonEncode([2, ...identity]);
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
  final payload = jsonEncode({
    'v': 2,
    'text': text,
    'model': 'old-model',
    'written_at': writtenAt,
  });
  final nonce = Uint8List.fromList(
    sha256.convert(utf8.encode('$user:$source:$payload')).bytes.take(12).toList(),
  );
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
      Hmac(sha256, master).convert(utf8.encode(jsonEncode(identity))).bytes,
    ),
    'user_id': user,
    'source_binding': binding,
    'nonce': base64UrlEncode(nonce),
    'ciphertext': base64UrlEncode(
      cipher.process(Uint8List.fromList(utf8.encode(payload))),
    ),
    'aad': aad,
    'generation': '',
    'legacy': 0,
    'rank': '',
    'room_id': '',
    'event_id': event,
  };
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
