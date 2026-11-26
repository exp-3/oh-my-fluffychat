// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'translation_test_backend.dart';

const _masterKeyName = 'chat.fluffy.translation.cache_master_key';
const _config = TranslationRoamingConfig(
  enabled: true,
  host: 'redis.example.invalid',
  retentionDays: 30,
);
const _secrets = TranslationRoamingSecrets(
  preSharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
final _clock = DateTime.utc(2026, 11, 26, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'remaining lifetime uses exact age boundaries and clamps future age',
    () {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final session = harness.session;
      expect(session.remainingSeconds(_clock), 37 * 86400);
      expect(
        session.remainingSeconds(_clock.add(const Duration(days: 1))),
        37 * 86400,
      );
      expect(
        session.remainingSeconds(_clock.subtract(const Duration(days: 20))),
        17 * 86400,
      );
      expect(
        session.remainingSeconds(
          _clock
              .subtract(const Duration(days: 37))
              .add(const Duration(seconds: 1)),
        ),
        1,
      );
      expect(
        session.remainingSeconds(
          _clock
              .subtract(const Duration(days: 37))
              .add(const Duration(milliseconds: 999)),
        ),
        0,
      );
      expect(
        session.remainingSeconds(_clock.subtract(const Duration(days: 37))),
        0,
      );
      expect(
        session.remainingSeconds(_clock.subtract(const Duration(days: 38))),
        -86400,
      );
    },
  );

  test(
    'scan traverses pages and includes every cached target language',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final writes = <TranslationCacheKey, String>{};
      for (var i = 0; i < 205; i++) {
        final key = _key(event: 'event-$i', source: 'source-$i');
        writes[key] = 'translated-$i';
        harness.addSource(key);
      }
      for (final target in ['zh', 'fr']) {
        final key = _key(event: 'other-$target', target: target);
        writes[key] = 'translated-$target';
        harness.addSource(key);
      }
      await harness.cache.writeAll(writes);
      await harness.session.scan();
      expect(harness.session.phase, TranslationRoamingUploadPhase.ready);
      expect(harness.session.rooms.single.count, 207);
      expect(harness.resolutions, 207);
      expect(harness.service.calls, isEmpty);
    },
  );

  test(
    'scan filters expired, inaccessible, missing and obsolete messages',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.seed(_key(event: 'valid'));
      await harness.seed(
        _key(event: 'expired', source: 'expired'),
        sentAt: _clock.subtract(const Duration(days: 37)),
      );
      final missing = _key(event: 'missing', source: 'missing');
      await harness.cache.write(missing, 'translated');
      final obsolete = _key(event: 'obsolete', source: 'obsolete');
      await harness.seed(obsolete);
      harness.sources[_sourceId(obsolete)] = TranslationLocalSource.obsolete;
      final noTimestamp = _key(event: 'no-time', source: 'no-time');
      await harness.seed(noTimestamp);
      harness.sources[_sourceId(noTimestamp)] =
          const TranslationLocalSource.valid('no-time');
      await harness.seed(_key(event: 'unknown-language', target: 'system'));
      await harness.seed(_key(event: 'denied', room: '!denied:test'));
      harness.deniedRooms.add('!denied:test');
      await harness.session.scan();
      expect(harness.session.rooms, hasLength(1));
      expect(harness.session.rooms.single.roomId, '!room:test');
      expect(harness.session.rooms.single.count, 1);
    },
  );

  test(
    'room counts merge accounts and uploads deduplicate selected rooms',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.seed(_key(event: 'a', room: '!a:test'));
      await harness.seed(_key(event: 'b', room: '!a:test', user: '@bob:test'));
      await harness.seed(_key(event: 'c', room: '!b:test'));
      await harness.seed(_key(event: 'd', room: '!a:test', target: 'fr'));
      await harness.seed(
        _key(event: 'unselected', room: '!c:test', source: 'unselected'),
      );
      await harness.session.scan();
      final rooms = {
        for (final room in harness.session.rooms) room.roomId: room,
      };
      expect(rooms['!a:test']!.count, 2);
      expect(rooms['!a:test']!.userIds, {'@alice:test', '@bob:test'});
      expect(rooms['!b:test']!.count, 1);
      await harness.session.upload({'!a:test', '!b:test'});
      expect(harness.session.phase, TranslationRoamingUploadPhase.complete);
      expect(harness.session.total, 2);
      expect(harness.session.uploaded, 2);
      expect(harness.service.calls, hasLength(2));
      expect(harness.service.calls.map((call) => call.targetLanguage).toSet(), {
        'en',
        'fr',
      });
      expect(
        harness.service.calls.every((call) => call.source == 'source'),
        isTrue,
      );
    },
  );

  test(
    'newest cached translation and longest remaining TTL are independent',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final recentMessage = _key(event: 'recent', room: '!a:test');
      final recentTranslation = _key(
        event: 'older',
        room: '!b:test',
        sourceLanguage: 'fr',
      );
      await harness.seed(
        recentMessage,
        translation: 'older translation',
        sentAt: _clock.subtract(const Duration(days: 1)),
        writtenAt: DateTime.utc(2026, 11, 20),
      );
      await harness.seed(
        recentTranslation,
        translation: 'newest translation',
        sentAt: _clock.subtract(const Duration(days: 20)),
        writtenAt: DateTime.utc(2026, 11, 25),
      );
      await harness.session.scan();
      await harness.session.upload({'!a:test', '!b:test'});
      final call = harness.service.calls.single;
      expect(call.translation, 'newest translation');
      expect(call.ttlSeconds, 36 * 86400);
    },
  );

  test('upload rereads retranslated cache contents after selection', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    final key = _key();
    await harness.seed(key, translation: 'scan-time translation');
    await harness.session.scan();
    await harness.cache.write(key, 'fresh translation');
    await harness.session.upload({'!room:test'});
    expect(harness.service.calls.single.translation, 'fresh translation');
  });

  test(
    'expired or invalidated selections are skipped before network upload',
    () async {
      for (final expire in [true, false]) {
        final harness = _Harness();
        addTearDown(harness.dispose);
        final key = _key();
        await harness.seed(key);
        await harness.session.scan();
        if (expire) {
          harness.now = _clock.add(const Duration(days: 37));
        } else {
          await harness.cache.invalidateEventIfExists(key.roomId, key.eventId);
        }
        await harness.session.upload({'!room:test'});
        expect(harness.session.phase, TranslationRoamingUploadPhase.complete);
        expect(harness.session.skipped, 1);
        expect(harness.session.processed, 1);
        expect(harness.service.calls, isEmpty);
      }
    },
  );

  test(
    'existing remote entries and recoverable failures retain real counts',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      for (var i = 0; i < 3; i++) {
        await harness.seed(_key(event: 'event-$i', source: 'source-$i'));
      }
      harness.service.results.addAll([
        const TranslationRoamingUploadResult(
          TranslationRoamingUploadStatus.existing,
        ),
        const TranslationRoamingUploadResult(
          TranslationRoamingUploadStatus.failed,
          error: TranslationRoamingException(
            TranslationRoamingError.connection,
          ),
        ),
        const TranslationRoamingUploadResult(
          TranslationRoamingUploadStatus.uploaded,
        ),
      ]);
      await harness.session.scan();
      await harness.session.upload({'!room:test'});
      expect(harness.session.phase, TranslationRoamingUploadPhase.complete);
      expect(harness.session.total, 3);
      expect(harness.session.processed, 3);
      expect(harness.session.existing, 1);
      expect(harness.session.failed, 1);
      expect(harness.session.uploaded, 1);
      expect(harness.service.disposed, isTrue);
    },
  );

  test(
    'authentication and configuration failures stop remaining entries',
    () async {
      for (final error in [
        TranslationRoamingError.authentication,
        TranslationRoamingError.configuration,
      ]) {
        final harness = _Harness();
        addTearDown(harness.dispose);
        await harness.seed(_key(event: 'a', source: 'a'));
        await harness.seed(_key(event: 'b', source: 'b'));
        harness.service.results.add(
          TranslationRoamingUploadResult(
            TranslationRoamingUploadStatus.failed,
            error: TranslationRoamingException(error),
          ),
        );
        await harness.session.scan();
        await harness.session.upload({'!room:test'});
        expect(harness.session.phase, TranslationRoamingUploadPhase.failed);
        expect(harness.session.processed, 1);
        expect(harness.session.failed, 1);
        expect(harness.session.error?.error, error);
        expect(harness.service.calls, hasLength(1));
        expect(harness.service.disposed, isTrue);
      }
    },
  );

  test('cancel and lifecycle changes stop further uploads', () async {
    for (final reason in ['cancel', 'configuration', 'account', 'room']) {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.seed(_key(event: 'a', source: 'a'));
      await harness.seed(_key(event: 'b', source: 'b'));
      await harness.session.scan();
      harness.service.afterUpload = () {
        switch (reason) {
          case 'cancel':
            harness.session.cancel();
          case 'configuration':
            harness.current = false;
          case 'account':
            harness.deniedUsers.add('@alice:test');
          case 'room':
            harness.deniedRooms.add('!room:test');
        }
        harness.lifecycle.changed();
      };
      await harness.session.upload({'!room:test'});
      expect(harness.session.phase, TranslationRoamingUploadPhase.stopped);
      expect(harness.service.calls, hasLength(1));
      expect(harness.service.disposed, isTrue);
      expect(harness.session.processed, 1);
    }
  });

  test('configuration change after scanning prevents any upload', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.seed(_key());
    await harness.session.scan();
    harness.current = false;
    harness.lifecycle.changed();
    await harness.session.upload({'!room:test'});
    expect(harness.session.phase, TranslationRoamingUploadPhase.stopped);
    expect(harness.service.calls, isEmpty);
  });

  test(
    'cancellation during scanning discards the pending local result',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.seed(_key());
      final resolving = Completer<void>();
      final release = Completer<void>();
      harness.beforeResolve = () async {
        if (!resolving.isCompleted) resolving.complete();
        await release.future;
      };
      final scanning = harness.session.scan();
      await resolving.future;
      harness.session.cancel();
      release.complete();
      await scanning;
      expect(harness.session.phase, TranslationRoamingUploadPhase.stopped);
      expect(harness.session.rooms, isEmpty);
      expect(harness.service.disposed, isTrue);
      expect(harness.service.calls, isEmpty);
    },
  );

  test(
    'empty caches remain absent and scan errors close the import service',
    () async {
      final empty = _Harness();
      addTearDown(empty.dispose);
      await empty.session.scan();
      expect(empty.session.phase, TranslationRoamingUploadPhase.ready);
      expect(empty.session.rooms, isEmpty);
      expect(empty.backend.present, isFalse);
      expect(empty.backend.createCalls, 0);

      final unavailable = _Harness();
      addTearDown(unavailable.dispose);
      unavailable.backend.unavailable = true;
      await unavailable.session.scan();
      expect(unavailable.session.phase, TranslationRoamingUploadPhase.failed);
      expect(unavailable.service.disposed, isTrue);
    },
  );
}

TranslationCacheKey _key({
  String user = '@alice:test',
  String room = '!room:test',
  String event = 'event',
  String source = 'source',
  String sourceLanguage = 'auto',
  String target = 'en',
}) => TranslationCacheKey(
  userId: user,
  roomId: room,
  eventId: event,
  source: source,
  sourceLanguage: sourceLanguage,
  targetLanguage: target,
  messageType: 'm.text',
);

String _sourceId(TranslationCacheKey key) =>
    jsonEncode([key.userId, key.roomId, key.eventId]);

class _Harness {
  final backend = MemoryTranslationBackend();
  final secrets = _MemorySecrets();
  final lifecycle = _Lifecycle();
  final sources = <String, TranslationLocalSource>{};
  final deniedUsers = <String>{};
  final deniedRooms = <String>{};
  late final TranslationCache cache;
  late final _Service service;
  late final TranslationRoamingUploadSession session;
  var current = true;
  var resolutions = 0;
  DateTime now = _clock;
  Future<void> Function()? beforeResolve;

  _Harness() {
    cache = TranslationCache(secrets, backend);
    service = _Service();
    session = TranslationRoamingUploadSession(
      cache: cache,
      resolveSource: (user, room, event) async {
        resolutions++;
        await beforeResolve?.call();
        return sources[jsonEncode([user, room, event])] ??
            TranslationLocalSource.unavailable;
      },
      service: service,
      lifecycle: lifecycle,
      isCurrent: () => current,
      canAccess: (reference) =>
          !deniedUsers.contains(reference.userId) &&
          !deniedRooms.contains(reference.roomId),
      now: () => now,
    );
  }

  void addSource(TranslationCacheKey key, {DateTime? sentAt}) {
    sources[_sourceId(key)] = TranslationLocalSource.valid(
      key.source,
      messageTimestamp: sentAt ?? _clock,
    );
  }

  Future<void> seed(
    TranslationCacheKey key, {
    String translation = 'translated',
    DateTime? sentAt,
    DateTime? writtenAt,
  }) async {
    addSource(key, sentAt: sentAt);
    await cache.write(key, translation);
    if (writtenAt != null) {
      _setWrittenAt(backend, secrets, key, translation, writtenAt);
    }
  }

  Future<void> dispose() async {
    session.dispose();
    lifecycle.dispose();
    await cache.dispose();
  }
}

class _Lifecycle extends ChangeNotifier {
  void changed() => notifyListeners();
}

typedef _UploadCall = ({
  String source,
  String targetLanguage,
  String translation,
  int ttlSeconds,
});

class _Service extends TranslationRoamingService {
  final calls = <_UploadCall>[];
  final results = <TranslationRoamingUploadResult>[];
  VoidCallback? afterUpload;
  var disposed = false;

  _Service() : super(config: _config, secrets: _secrets);

  @override
  Future<TranslationRoamingUploadResult> uploadIfAbsent({
    required String source,
    required String targetLanguage,
    required String translation,
    required int Function() ttlSeconds,
    required bool Function() isValid,
  }) async {
    final remaining = ttlSeconds();
    if (!isValid() || remaining <= 0) {
      return const TranslationRoamingUploadResult(
        TranslationRoamingUploadStatus.skipped,
      );
    }
    calls.add((
      source: source,
      targetLanguage: targetLanguage,
      translation: translation,
      ttlSeconds: remaining,
    ));
    afterUpload?.call();
    return results.isEmpty
        ? const TranslationRoamingUploadResult(
            TranslationRoamingUploadStatus.uploaded,
          )
        : results.removeAt(0);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _MemorySecrets implements TranslationSecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Controls only the fixture's encrypted write time; message age comes from
/// the injected local-event resolver and session clock.
void _setWrittenAt(
  MemoryTranslationBackend backend,
  _MemorySecrets secrets,
  TranslationCacheKey key,
  String translation,
  DateTime writtenAt,
) {
  final reference = backend.rows[CacheStore.messageRefs]![key.referenceKey]!;
  final row =
      backend.rows[CacheStore.sharedContents]![reference['content_key']]!;
  final derivator = HKDFKeyDerivator(SHA256Digest())
    ..init(
      HkdfParameters(
        Uint8List.fromList(base64Url.decode(secrets.values[_masterKeyName]!)),
        32,
        Uint8List.fromList(sha256.convert(utf8.encode(key.source)).bytes),
        Uint8List.fromList(utf8.encode('fluffychat-translation-v1')),
      ),
    );
  final derived = Uint8List(32);
  derivator.deriveKey(null, 0, derived, 0);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(derived),
        128,
        Uint8List.fromList(base64Url.decode(row['nonce']! as String)),
        Uint8List.fromList(utf8.encode(row['aad']! as String)),
      ),
    );
  row['ciphertext'] = base64UrlEncode(
    cipher.process(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 3,
            'text': translation,
            'written_at': writtenAt.toUtc().toIso8601String(),
          }),
        ),
      ),
    ),
  );
}
