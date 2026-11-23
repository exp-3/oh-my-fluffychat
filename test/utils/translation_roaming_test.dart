// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_store_rest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
      translation: '翻譯',
    );
    final json = (jsonDecode(envelope) as Map).cast<String, Object?>();
    expect(json.keys, unorderedEquals(['v', 'nonce', 'ciphertext']));
    expect(envelope, isNot(contains(source)));
    expect(envelope, isNot(contains(_psk)));
    expect(
      second.decrypt(
        source: source,
        targetLanguage: 'zh-Hant',
        key: key,
        envelope: envelope,
      ),
      '翻譯',
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
    final nonce = json['nonce']! as String;
    final tampered = jsonEncode({
      ...json,
      'nonce': '${nonce.startsWith('A') ? 'B' : 'A'}${nonce.substring(1)}',
    });
    expect(
      () => second.decrypt(
        source: source,
        targetLanguage: 'zh-Hant',
        key: key,
        envelope: tampered,
      ),
      throwsA(isA<TranslationRoamingException>()),
    );
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
              'error': 'NOPERM SET denied for ${_secrets.restToken}; $key $value',
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
      delay: (duration) async {
        expect(duration, TranslationRoamingService.retryDelay);
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
          config.copyWith(endpoint: 'https://user:password@example.test').toJson(),
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

class _MemoryStore implements TranslationRoamingStore {
  final records = <String, String>{};
  Completer<String?>? readGate;
  var reads = 0;
  var writes = 0;
  var failWrites = false;
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
