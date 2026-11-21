// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'translation_cache_test.dart'
    show MemorySecrets, key, legacyEnvelope, masterKeyName;

@JS('window.indexedDB')
external web.IDBFactory get factory;

void main() {
  late WebTranslationCacheBackend backend;
  late TranslationCache cache;
  late MemorySecrets secrets;
  setUp(() async {
    backend = WebTranslationCacheBackend();
    await backend.deleteIfExists();
    secrets = MemorySecrets();
    cache = TranslationCache(secrets, backend);
  });
  tearDown(() async {
    await backend.deleteIfExists();
    await backend.dispose();
  });

  test(
    'Web absent probes abort creation and leave secure storage untouched',
    () async {
      expect(await cache.read(key()), isNull);
      await cache.invalidateEventIfExists('!room:test', r'$event');
      expect(secrets.readCalls, 0);
      expect(secrets.values, isEmpty);
      expect(await backend.exists(), isFalse);
    },
  );

  test(
    'Web v2 safety opens do not upgrade; migration uses greatest legacy key',
    () async {
      final master = Uint8List.fromList(List.generate(32, (i) => i));
      secrets.values[masterKeyName] = base64UrlEncode(master);
      final rows = [
        legacyEnvelope(master, event: r'$old', text: 'first'),
        legacyEnvelope(master, event: r'$new', text: 'last'),
      ];
      rows.sort(
        (a, b) =>
            cacheString(a, 'cache_key').compareTo(cacheString(b, 'cache_key')),
      );
      final request = factory.open('fluffychat_translation_cache', 2);
      request.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
        final db = request.result as web.IDBDatabase;
        final store = db.createObjectStore(
          'translations',
          web.IDBObjectStoreParameters(keyPath: 'cache_key'.toJS),
        );
        store.createIndex('room_id', 'room_id'.toJS);
        store.createIndex('event_id', ['room_id'.toJS, 'event_id'.toJS].toJS);
        for (final row in rows) {
          store.put(row.jsify());
        }
      }).toJS;
      final db = await _opened(request);
      db.close();
      expect(await backend.openExisting('unused'), isTrue);
      expect(
        await backend.transaction(
          (tx) async => tx.hasStore(CacheStore.contents),
        ),
        isFalse,
      );
      await cache.migrateLegacy(
        owners: (_) => ['@alice:test'],
        localSource: (_, _, _) async => TranslationLocalSource.unavailable,
        isEnabled: () => true,
        pageSize: 1,
      );
      final expected = rows.last['event_id'] == r'$new' ? 'last' : 'first';
      expect(await cache.read(key()), expected);
      await cache.invalidateEventIfExists(
        '!room:test',
        cacheString(rows.first, 'event_id'),
      );
      expect(await cache.read(key()), isNull);
    },
  );

  test(
    'Web cross-context notification and disk tombstones reject late writes',
    () async {
      await cache.write(key(), 'old');
      final secondBackend = WebTranslationCacheBackend();
      final second = TranslationCache(secrets, secondBackend);
      final ticket = (await second.lookup(key())).ticket!;
      final changed = secondBackend.externalChanges.first;
      await cache.invalidateEventIfExists('!room:test', r'$event');
      await changed.timeout(const Duration(seconds: 5));
      await expectLater(
        second.write(key(), 'late', ticket: ticket),
        throwsStateError,
      );
      expect(await second.read(key()), isNull);
      await secondBackend.dispose();
    },
  );
}

Future<web.IDBDatabase> _opened(web.IDBOpenDBRequest request) {
  final result = Completer<web.IDBDatabase>();
  request.onsuccess = ((web.Event _) {
    result.complete(request.result as web.IDBDatabase);
  }).toJS;
  request.onerror = ((web.Event _) {
    result.completeError(StateError('fixture open failed'));
  }).toJS;
  return result.future;
}
