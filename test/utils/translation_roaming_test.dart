// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate;
import 'package:crypto/crypto.dart' show sha512;
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_store_rest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _psk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _config = TranslationRoamingConfig(
  enabled: true,
  host: 'redis.example.invalid',
);
const _secrets = TranslationRoamingSecrets(
  redisPassword: 'redis-authentication',
  restToken: 'rest-authentication',
  preSharedKey: _psk,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('portable ciphertext requires the original source and matching PSK', () {
    // RFC 4231, test case 2. Zero-padding Jefe to 32 bytes does not change
    // HMAC's block-padded key, so this is an independent protocol K vector.
    final reference = TranslationRoamingCrypto(
      base64UrlEncode([
        ...utf8.encode('Jefe'),
        ...List<int>.filled(28, 0),
      ]).replaceAll('=', ''),
    );
    addTearDown(reference.dispose);
    expect(
      reference.storageKey(
        source: 'what do ya want for nothing?',
        targetLanguage: 'en',
        keyPrefix: 'translations',
      ),
      'translations:v1:en:W9zBRr9gdU5qBCQmCJV1x1oAPwidJzmDnexYuWTsOEM',
    );
    final first = TranslationRoamingCrypto(_psk);
    final second = TranslationRoamingCrypto(_psk);
    final other = TranslationRoamingCrypto(
      TranslationRoamingCrypto.generatePreSharedKey(),
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(other.dispose);
    const source = ' Source\r\nwith formatting ';
    final key = first.storageKey(
      source: source,
      targetLanguage: 'zh-Hant',
      keyPrefix: 'translations',
    );
    expect(key, matches(r'^translations:v1:zh-Hant:[A-Za-z0-9_-]{43}$'));
    expect(
      second.storageKey(
        source: source,
        targetLanguage: 'zh-Hant',
        keyPrefix: 'translations',
      ),
      key,
    );
    expect(
      other.storageKey(
        source: source,
        targetLanguage: 'zh-Hant',
        keyPrefix: 'translations',
      ),
      isNot(key),
    );
    final envelope = first.encrypt(
      source: source,
      targetLanguage: 'zh-Hant',
      key: key,
      translation: '翻譯\n🙂',
    );
    expect(envelope, matches(r'^A[A-Za-z0-9_-]+$'));
    final payload = base64Url.decode(
      base64Url.normalize(envelope.substring(1)),
    );
    expect(payload.length, 12 + utf8.encode('翻譯\n🙂').length + 16);
    expect(base64UrlEncode(payload.sublist(0, 12)), envelope.substring(1, 17));
    expect(envelope, isNot(contains(source)));
    expect(envelope, isNot(contains(_psk)));
    expect(
      second.decrypt(
        source: source,
        targetLanguage: 'zh-Hant',
        key: key,
        envelope: envelope,
      ),
      '翻譯\n🙂',
    );
    expect(
      () => second.decrypt(
        source: source.trim(),
        targetLanguage: 'zh-Hant',
        key: key,
        envelope: envelope,
      ),
      throwsA(isA<TranslationRoamingException>()),
    );
    expect(
      () => second.decrypt(
        source: source,
        targetLanguage: 'en',
        key: key,
        envelope: envelope,
      ),
      throwsA(isA<TranslationRoamingException>()),
    );
    expect(
      () => other.decrypt(
        source: source,
        targetLanguage: 'zh-Hant',
        key: key,
        envelope: envelope,
      ),
      throwsA(isA<TranslationRoamingException>()),
    );
    expect(
      () => second.decrypt(
        source: source,
        targetLanguage: 'zh-Hant',
        key: '$key:other',
        envelope: envelope,
      ),
      throwsA(isA<TranslationRoamingException>()),
    );
    for (final offset in [0, 12, payload.length - 1]) {
      final tampered = Uint8List.fromList(payload)..[offset] ^= 1;
      expect(
        () => second.decrypt(
          source: source,
          targetLanguage: 'zh-Hant',
          key: key,
          envelope: 'A${_encode(tampered)}',
        ),
        throwsA(isA<TranslationRoamingException>()),
      );
    }
  });

  test('compression preserves Unicode and only reduces stored size', () {
    final crypto = TranslationRoamingCrypto(_psk);
    addTearDown(crypto.dispose);
    final key = crypto.storageKey(
      source: 'source',
      targetLanguage: 'en',
      keyPrefix: _config.keyPrefix,
    );
    final random = Random(7);
    final fixtures = [
      List.filled(255, 'a').join(),
      List.filled(256, 'a').join(),
      List.filled(86, '界').join(),
      List.filled(64, '翻譯\r\n🙂 ').join(),
      String.fromCharCodes(List.generate(256, (_) => random.nextInt(128))),
    ];
    for (final translation in fixtures) {
      final bytes = utf8.encode(translation);
      final compressed = Deflate(bytes, level: 6).getBytes();
      final envelope = crypto.encrypt(
        source: 'source',
        targetLanguage: 'en',
        key: key,
        translation: translation,
      );
      expect(
        envelope[0],
        bytes.length >= 256 && compressed.length < bytes.length ? 'B' : 'A',
      );
      expect(
        envelope.length,
        lessThanOrEqualTo(1 + _encode(Uint8List(bytes.length + 28)).length),
      );
      expect(
        crypto.decrypt(
          source: 'source',
          targetLanguage: 'en',
          key: key,
          envelope: envelope,
        ),
        translation,
      );
    }
  });

  test('invalid envelopes and authenticated invalid payloads are rejected', () {
    final crypto = TranslationRoamingCrypto(_psk);
    addTearDown(crypto.dispose);
    final key = crypto.storageKey(
      source: 'source',
      targetLanguage: 'en',
      keyPrefix: _config.keyPrefix,
    );
    final valid = crypto.encrypt(
      source: 'source',
      targetLanguage: 'en',
      key: key,
      translation: 'translated',
    );
    // A fixed raw DEFLATE vector also verifies that these independently sealed
    // payloads use the same key/AAD, so failures below reach the payload decoder.
    expect(
      crypto.decrypt(
        source: 'source',
        targetLanguage: 'en',
        key: key,
        envelope: _sealPayload(
          [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00],
          key: key,
          header: 'B',
        ),
      ),
      'hello',
    );
    final invalid = [
      '',
      'A',
      'AAAA',
      'C${valid.substring(1)}',
      'I${valid.substring(1)}',
      '$valid=',
      jsonEncode({'v': 1, 'nonce': 'AA', 'ciphertext': 'AA'}),
      _sealPayload([0xff], key: key),
      // BTYPE=3 is reserved and invalid on both native and Web decoders.
      _sealPayload([0x07], key: key, header: 'B'),
      _sealPayload(Deflate([0xff]).getBytes(), key: key, header: 'B'),
    ];
    for (final envelope in invalid) {
      expect(
        () => crypto.decrypt(
          source: 'source',
          targetLanguage: 'en',
          key: key,
          envelope: envelope,
        ),
        throwsA(isA<TranslationRoamingException>()),
      );
    }
  });

  test('roaming requires both size limits and rejects legacy values', () async {
    final store = _MemoryStore();
    final service = TranslationRoamingService(
      config: _config,
      secrets: _secrets,
      store: store,
    );
    addTearDown(service.dispose);
    final largeTranslation = List.filled(
      TranslationRoamingCrypto.maxTranslationBytes,
      'a',
    ).join();
    await service.upload(
      source: 'source',
      targetLanguage: 'en',
      translation: largeTranslation,
      isValid: () => true,
    );
    expect(store.writes, 1);
    final restored = await service.lookup(
      source: 'source',
      targetLanguage: 'en',
    );
    expect(restored.status, TranslationRoamingLookupStatus.hit);
    expect(restored.translation, largeTranslation);

    await service.upload(
      source: 'too-large',
      targetLanguage: 'en',
      translation: '${largeTranslation}a',
      isValid: () => true,
    );
    expect(store.writes, 1);

    final random = Random(7);
    final incompressible = String.fromCharCodes(
      List.generate(1024 * 1024, (_) => random.nextInt(128)),
    );
    expect(
      Deflate(utf8.encode(incompressible), level: 6).getBytes().length,
      greaterThanOrEqualTo(
        TranslationRoamingCrypto.maxCompressedTranslationBytes,
      ),
    );
    await service.upload(
      source: 'incompressible',
      targetLanguage: 'en',
      translation: incompressible,
      isValid: () => true,
    );
    expect(store.writes, 1);
    final crypto = TranslationRoamingCrypto(_psk);
    addTearDown(crypto.dispose);
    final key = crypto.storageKey(
      source: 'source',
      targetLanguage: 'en',
      keyPrefix: _config.keyPrefix,
    );
    expect(
      () => crypto.decrypt(
        source: 'source',
        targetLanguage: 'en',
        key: key,
        envelope: _sealPayload(
          Deflate(utf8.encode('${largeTranslation}a'), level: 6).getBytes(),
          key: key,
          header: 'B',
        ),
      ),
      throwsA(isA<TranslationRoamingException>()),
    );
    store.records[key] = jsonEncode({
      'v': 1,
      'nonce': 'AA',
      'ciphertext': 'AA',
    });
    final result = await service.lookup(source: 'source', targetLanguage: 'en');
    expect(result.status, TranslationRoamingLookupStatus.unavailable);
    expect(result.translation, isNull);
  });

  test(
    'REST sends only authentication, encrypted values and sliding TTL',
    () async {
      final records = <String, String>{};
      final commands = <List<Object?>>[];
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], 'Bearer rest-authentication');
        expect(request.body, isNot(contains(_psk)));
        expect(request.body, isNot(contains('private source text')));
        expect(request.body, isNot(contains('private translated text')));
        final command = (jsonDecode(request.body) as List).cast<Object?>();
        commands.add(command);
        final key = command[1]! as String;
        switch (command.first) {
          case 'SET':
            records[key] = command[2]! as String;
            return http.Response(jsonEncode({'result': 'OK'}), 200);
          case 'GETEX':
            return http.Response(jsonEncode({'result': records[key]}), 200);
          case 'DEL':
            return http.Response(
              jsonEncode({'result': records.remove(key) == null ? 0 : 1}),
              200,
            );
          default:
            throw StateError('Unexpected test command');
        }
      });
      final config = _config.copyWith(
        type: TranslationRoamingType.upstash,
        endpoint: 'https://redis.example.invalid',
      );
      final service = TranslationRoamingService(
        config: config,
        secrets: _secrets,
        store: RestTranslationRoamingStore(
          endpoint: Uri.parse(config.endpoint),
          token: _secrets.restToken,
          clientFactory: () => client,
        ),
      );
      addTearDown(service.dispose);
      await service.upload(
        source: 'private source text',
        targetLanguage: 'zh',
        translation: 'private translated text',
        isValid: () => true,
      );
      final result = await service.lookup(
        source: 'private source text',
        targetLanguage: 'zh',
      );
      expect(result.translation, 'private translated text');
      expect(commands.first.sublist(3), ['EX', '2592000']);
      expect(commands[1].sublist(2), ['EX', '2592000']);
      await service.testConnection();
      expect(commands[2].sublist(3), ['EX', '60']);
      expect(commands[3].sublist(2), ['EX', '60']);
      expect(commands.last.first, 'DEL');
      expect(records, hasLength(1));
    },
  );

  test(
    'REST imports atomically preserve existing ciphertext and expiry',
    () async {
      final records = <String, String>{};
      final lifetimes = <String, int>{};
      final commands = <List<String>>[];
      final config = _config.copyWith(
        type: TranslationRoamingType.upstash,
        endpoint: 'https://redis.example.invalid',
      );
      final service = TranslationRoamingService(
        config: config,
        secrets: _secrets,
        store: RestTranslationRoamingStore(
          endpoint: Uri.parse(config.endpoint),
          token: _secrets.restToken,
          clientFactory: () => MockClient((request) async {
            expect(request.body, isNot(contains('private source text')));
            expect(request.body, isNot(contains('private translated text')));
            expect(request.body, isNot(contains(_psk)));
            final command = (jsonDecode(request.body) as List).cast<String>();
            commands.add(command);
            final key = command[1];
            if (command.first == 'SET') {
              expect(command.sublist(3, 4), ['EX']);
              expect(command.last, 'NX');
              if (records.containsKey(key)) {
                return http.Response(jsonEncode({'result': null}), 200);
              }
              records[key] = command[2];
              lifetimes[key] = int.parse(command[4]);
              return http.Response(jsonEncode({'result': 'OK'}), 200);
            }
            expect(command.first, 'GETEX');
            lifetimes[key] = int.parse(command[3]);
            return http.Response(jsonEncode({'result': records[key]}), 200);
          }),
        ),
      );
      addTearDown(service.dispose);
      final first = await service.uploadIfAbsent(
        source: 'private source text',
        targetLanguage: 'zh',
        translation: 'private translated text',
        ttlSeconds: () => 123,
        isValid: () => true,
      );
      expect(first.status, TranslationRoamingUploadStatus.uploaded);
      final ciphertext = records.values.single;
      final second = await service.uploadIfAbsent(
        source: 'private source text',
        targetLanguage: 'zh',
        translation: 'replacement',
        ttlSeconds: () => 3,
        isValid: () => true,
      );
      expect(second.status, TranslationRoamingUploadStatus.existing);
      expect(records.values.single, ciphertext);
      expect(lifetimes.values.single, 123);
      expect(commands.map((command) => command.first), ['SET', 'SET']);
      expect(commands[0].sublist(3), ['EX', '123', 'NX']);
      expect(commands[1].sublist(3), ['EX', '3', 'NX']);

      final restored = await service.lookup(
        source: 'private source text',
        targetLanguage: 'zh',
      );
      expect(restored.translation, 'private translated text');
      expect(lifetimes.values.single, config.ttlSeconds);
    },
  );

  test('REST imports reject unexpected NX response types', () async {
    for (final response in [false, 1, 'unexpected']) {
      final store = RestTranslationRoamingStore(
        endpoint: Uri.parse('https://redis.example.invalid'),
        token: _secrets.restToken,
        clientFactory: () => MockClient(
          (_) async => http.Response(jsonEncode({'result': response}), 200),
        ),
      );
      addTearDown(store.dispose);
      await expectLater(
        store.setIfAbsent('key', 'encrypted', 60),
        throwsA(
          isA<TranslationRoamingException>().having(
            (error) => error.error,
            'classification',
            TranslationRoamingError.protocol,
          ),
        ),
      );
    }
  });

  test('imports recalculate remaining lifetime before retrying', () async {
    final store = _MemoryStore()..failedWritesRemaining = 1;
    var remaining = 120;
    final service = TranslationRoamingService(
      config: _config,
      secrets: _secrets,
      store: store,
      delay: (_) async {
        remaining = 60;
      },
    );
    addTearDown(service.dispose);
    final result = await service.uploadIfAbsent(
      source: 'source',
      targetLanguage: 'en',
      translation: 'translated',
      ttlSeconds: () => remaining,
      isValid: () => true,
    );
    expect(result.status, TranslationRoamingUploadStatus.uploaded);
    expect(store.conditionalLifetimes, [120, 60]);
    expect(store.lifetimes.values.single, 60);
    expect(store.reads, 0);
  });

  test('imports stop on expiry or invalidation before a retry', () async {
    for (final expire in [true, false]) {
      final store = _MemoryStore()..failWrites = true;
      var remaining = 60;
      var valid = true;
      final service = TranslationRoamingService(
        config: _config,
        secrets: _secrets,
        store: store,
        delay: (_) async {
          if (expire) {
            remaining = 0;
          } else {
            valid = false;
          }
        },
      );
      addTearDown(service.dispose);
      final result = await service.uploadIfAbsent(
        source: 'source',
        targetLanguage: 'en',
        translation: 'translated',
        ttlSeconds: () => remaining,
        isValid: () => valid,
      );
      expect(result.status, TranslationRoamingUploadStatus.skipped);
      expect(store.writes, 1);
    }
  });

  test('imports report sanitized failures and skip oversized entries', () async {
    final store = _MemoryStore()
      ..failWrites = true
      ..writeError = TranslationRoamingException(
        TranslationRoamingError.authentication,
        diagnosticDetails:
            'denied $_psk ${_secrets.restToken} private-source private-result',
      );
    final service = TranslationRoamingService(
      config: _config,
      secrets: _secrets,
      store: store,
      delay: (_) async {},
    );
    addTearDown(service.dispose);
    final result = await service.uploadIfAbsent(
      source: 'private-source',
      targetLanguage: 'en',
      translation: 'private-result',
      ttlSeconds: () => 60,
      isValid: () => true,
    );
    expect(result.status, TranslationRoamingUploadStatus.failed);
    expect(result.error?.error, TranslationRoamingError.authentication);
    expect(
      result.error?.diagnosticDetails,
      allOf(
        contains('denied'),
        isNot(contains(_psk)),
        isNot(contains(_secrets.restToken)),
        isNot(contains('private-source')),
        isNot(contains('private-result')),
      ),
    );
    expect(store.writes, 2);
    final oversized = await service.uploadIfAbsent(
      source: 'source',
      targetLanguage: 'en',
      translation: List.filled(
        TranslationRoamingCrypto.maxTranslationBytes + 1,
        'a',
      ).join(),
      ttlSeconds: () => 60,
      isValid: () => true,
    );
    expect(oversized.status, TranslationRoamingUploadStatus.skipped);
    final invalidTtl = await service.uploadIfAbsent(
      source: 'source',
      targetLanguage: 'en',
      translation: 'translated',
      ttlSeconds: () => 9007199254740992,
      isValid: () => true,
    );
    expect(invalidTtl.status, TranslationRoamingUploadStatus.failed);
    expect(invalidTtl.error?.error, TranslationRoamingError.configuration);
    expect(store.writes, 2);
  });

  test(
    'REST diagnostics retain errors without tokens or command arguments',
    () async {
      const key = 'private-record-key';
      const value = 'private-encrypted-envelope';
      final store = RestTranslationRoamingStore(
        endpoint: Uri.parse('https://redis.example.invalid'),
        token: _secrets.restToken,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error':
                  'NOPERM SET denied for ${_secrets.restToken}; $key $value',
              'request': 'unselected private data',
            }),
            403,
          ),
        ),
      );
      addTearDown(store.dispose);
      await expectLater(
        store.set(key, value, 60),
        throwsA(
          isA<TranslationRoamingException>()
              .having(
                (error) => error.error,
                'classification',
                TranslationRoamingError.authentication,
              )
              .having(
                (error) => error.toString(),
                'safe default description',
                isNot(contains('NOPERM')),
              )
              .having(
                (error) => error.diagnosticDetails,
                'diagnostic details',
                allOf(
                  contains('HTTP 403'),
                  contains('NOPERM'),
                  isNot(contains(_secrets.restToken)),
                  isNot(contains(key)),
                  isNot(contains(value)),
                  isNot(contains('unselected private data')),
                ),
              ),
        ),
      );
    },
  );

  test(
    'concurrent lookups share GETEX and reject a late disposed result',
    () async {
      final gate = Completer<String?>();
      final store = _MemoryStore()..readGate = gate;
      final service = TranslationRoamingService(
        config: _config,
        secrets: _secrets,
        store: store,
      );
      final first = service.lookup(source: 'source', targetLanguage: 'en');
      final second = service.lookup(source: 'source', targetLanguage: 'en');
      expect(store.reads, 1);
      service.dispose();
      gate.complete(null);
      expect((await first).status, TranslationRoamingLookupStatus.unavailable);
      expect((await second).status, TranslationRoamingLookupStatus.unavailable);
      expect(store.disposed, isTrue);
    },
  );

  test('uploads retry once and stop when the task becomes invalid', () async {
    final store = _MemoryStore()..failWrites = true;
    var valid = true;
    var delays = 0;
    final service = TranslationRoamingService(
      config: _config,
      secrets: _secrets,
      store: store,
      delay: (_) async {
        delays++;
        valid = false;
      },
    );
    addTearDown(service.dispose);
    await service.upload(
      source: 'source',
      targetLanguage: 'en',
      translation: 'translated',
      isValid: () => valid,
    );
    expect(store.writes, 1);
    expect(delays, 1);
    await service.upload(
      source: 'another',
      targetLanguage: 'en',
      translation: 'translated',
      isValid: () => true,
    );
    expect(store.writes, 3);
    expect(delays, 2);
  });

  test(
    'the enabled flag preserves configuration and never accesses secrets',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferences.getInstance();
      final secrets = _MemorySecrets();
      final preferences = TranslationRoamingPreferences(store, secrets);
      final config = _config.copyWith(
        enabled: true,
        tls: false,
        database: 3,
        username: 'configured-user',
        keyPrefix: 'configured-prefix',
        retentionDays: 12,
      );
      await preferences.save(config, _secrets);
      final savedSecrets = Map<String, String>.of(secrets.values);
      final reads = secrets.reads;
      secrets.failAccess = true;

      await preferences.saveEnabled(false);
      expect(
        preferences.config.toJson(),
        config.copyWith(enabled: false).toJson(),
      );
      await preferences.saveEnabled(true);
      expect(preferences.config.toJson(), config.toJson());
      expect(secrets.values, savedSecrets);
      expect(secrets.reads, reads);

      await store.setString(
        TranslationRoamingPreferences.configKey,
        jsonEncode(
          config
              .copyWith(endpoint: 'https://user:password@example.test')
              .toJson(),
        ),
      );
      await expectLater(
        preferences.saveEnabled(false),
        throwsA(isA<TranslationRoamingException>()),
      );
    },
  );

  test(
    'preferences keep credentials out of ordinary storage and read lazily',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferences.getInstance();
      final secrets = _MemorySecrets();
      final preferences = TranslationRoamingPreferences(store, secrets);
      expect(preferences.config.enabled, isFalse);
      expect(preferences.config.keyPrefix, 'fluffy:trans');
      expect(TranslationRoamingConfig.fromJson({}).keyPrefix, 'fluffy:trans');
      for (final prefix in ['fluffychat:translation', 'custom-prefix']) {
        await store.setString(
          TranslationRoamingPreferences.configKey,
          jsonEncode(_config.copyWith(keyPrefix: prefix).toJson()),
        );
        expect(preferences.config.keyPrefix, prefix);
      }
      expect(secrets.reads, 0);
      await preferences.save(_config, _secrets);
      final encoded = store.getString(TranslationRoamingPreferences.configKey)!;
      expect(encoded, isNot(contains(_psk)));
      expect(encoded, isNot(contains(_secrets.redisPassword)));
      expect(encoded, isNot(contains(_secrets.restToken)));
      expect((await preferences.readSecrets()).preSharedKey, _psk);
      expect(
        _secrets.copyWith(redisPassword: _psk).isValidFor(_config),
        isFalse,
      );
      await preferences.save(
        const TranslationRoamingConfig(),
        const TranslationRoamingSecrets(),
      );
      expect(preferences.config.enabled, isFalse);
      await expectLater(
        preferences.save(
          const TranslationRoamingConfig(
            endpoint:
                'https://user:password@redis.example.invalid?token=secret',
          ),
          const TranslationRoamingSecrets(),
        ),
        throwsA(isA<TranslationRoamingException>()),
      );
      expect(
        store.getString(TranslationRoamingPreferences.configKey),
        isNot(contains('password')),
      );
    },
  );
}

String _encode(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

// Seal arbitrary payloads so malformed UTF-8 and compressed data reach the
// decoder after successful GCM authentication, rather than failing tag checks.
String _sealPayload(
  List<int> bytes, {
  required String key,
  String header = 'A',
}) {
  final derivator = HKDFKeyDerivator(SHA256Digest())
    ..init(
      HkdfParameters(
        Uint8List(32),
        32,
        Uint8List.fromList(sha512.convert(utf8.encode('source')).bytes),
        Uint8List.fromList(
          utf8.encode(jsonEncode(['fluffychat.translation.roaming', 1, 'en'])),
        ),
      ),
    );
  final derived = Uint8List(32);
  derivator.deriveKey(null, 0, derived, 0);
  try {
    final nonce = Uint8List(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(derived),
          128,
          nonce,
          Uint8List.fromList(utf8.encode(key)),
        ),
      );
    final payload = [...nonce, ...cipher.process(Uint8List.fromList(bytes))];
    return '$header${_encode(payload)}';
  } finally {
    derived.fillRange(0, derived.length, 0);
  }
}

class _MemoryStore implements TranslationRoamingStore {
  final records = <String, String>{};
  final lifetimes = <String, int>{};
  final conditionalLifetimes = <int>[];
  Completer<String?>? readGate;
  var reads = 0;
  var writes = 0;
  var failWrites = false;
  var failedWritesRemaining = 0;
  TranslationRoamingException? writeError;
  var disposed = false;

  @override
  Future<String?> getEx(String key, int ttlSeconds) async {
    reads++;
    final gate = readGate;
    return gate == null ? records[key] : await gate.future;
  }

  @override
  Future<void> set(String key, String value, int ttlSeconds) async {
    writes++;
    if (failWrites) {
      throw const TranslationRoamingException(
        TranslationRoamingError.connection,
      );
    }
    records[key] = value;
    lifetimes[key] = ttlSeconds;
  }

  @override
  Future<bool> setIfAbsent(String key, String value, int ttlSeconds) async {
    writes++;
    conditionalLifetimes.add(ttlSeconds);
    if (failWrites || failedWritesRemaining > 0) {
      if (failedWritesRemaining > 0) failedWritesRemaining--;
      throw writeError ??
          const TranslationRoamingException(TranslationRoamingError.connection);
    }
    if (records.containsKey(key)) return false;
    records[key] = value;
    lifetimes[key] = ttlSeconds;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    records.remove(key);
  }

  @override
  void reset() {}

  @override
  void dispose() => disposed = true;
}

class _MemorySecrets implements TranslationSecretStore {
  final values = <String, String>{};
  var reads = 0;
  var failAccess = false;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (failAccess) throw StateError('Secrets must not be read');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failAccess) throw StateError('Secrets must not be written');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failAccess) throw StateError('Secrets must not be deleted');
    values.remove(key);
  }
}
