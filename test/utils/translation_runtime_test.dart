// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/translation/translation_api_client.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_client.dart';

final _provider = TranslationProviderConfig(
  id: 'provider',
  name: 'Test provider',
  endpoint: Uri.parse('https://llm.example.invalid/v1/responses'),
  protocol: TranslationProtocol.responses,
  model: 'test-model',
);

const _enabledPreference = 'chat.fluffy.translation.enabled';
const _privacyPreference = 'chat.fluffy.translation.privacy_accepted';
const _providersPreference = 'chat.fluffy.translation.providers';
const _selectedProviderPreference = 'chat.fluffy.translation.selected_provider';
const _scopePreference = 'chat.fluffy.translation.scope';
const _sourceLanguagePreference = 'chat.fluffy.translation.source_language';
const _targetLanguagePreference = 'chat.fluffy.translation.target_language';
const _bilingualColorPreference = 'chat.fluffy.translation.bilingual_color';
const _bilingualLayoutPreference = 'chat.fluffy.translation.bilingual_layout';
const _legacyBilingualStylePreference =
    'chat.fluffy.translation.bilingual_style';
const _inputModePreference = 'chat.fluffy.translation.input.mode';
const _inputScopePreference = 'chat.fluffy.translation.input.scope';
const _inputSourceLanguagePreference =
    'chat.fluffy.translation.input.source_language';
const _inputTargetLanguagePreference =
    'chat.fluffy.translation.input.target_language';
const _inputTriggerPreference = 'chat.fluffy.translation.input.trigger';
const _inputSendModePreference = 'chat.fluffy.translation.input.send_mode';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('provider semantic revisions remain distinct with colon fields', () {
    final first = TranslationProviderConfig(
      id: 'a',
      name: 'First',
      endpoint: Uri.parse('https://llm.example.invalid/v1'),
      protocol: TranslationProtocol.chatCompletions,
      model: 'responses:foo',
    );
    final second = TranslationProviderConfig(
      id: 'a:chatCompletions',
      name: 'Second',
      endpoint: Uri.parse('https://llm.example.invalid/v1'),
      protocol: TranslationProtocol.responses,
      model: 'foo',
    );

    expect(first.isValid, isTrue);
    expect(second.isValid, isTrue);
    expect(
      TranslationRuntime.semanticRevisionForProvider(first),
      isNot(TranslationRuntime.semanticRevisionForProvider(second)),
    );
  });

  test(
    'room preferences use nullable overrides and account-scoped languages',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferences.getInstance();
      final preferences = TranslationPreferences(store, _MemorySecrets());

      expect(preferences.roomTranslationOverride('@a:test', '!r:test'), isNull);
      await preferences.setRoomTranslationOverride('@a:test', '!r:test', true);
      expect(preferences.roomTranslationOverride('@a:test', '!r:test'), isTrue);
      await preferences.setRoomTranslationOverride('@a:test', '!r:test', false);
      expect(
        preferences.roomTranslationOverride('@a:test', '!r:test'),
        isFalse,
      );
      await preferences.setRoomTranslationOverride('@a:test', '!r:test', null);
      expect(preferences.roomTranslationOverride('@a:test', '!r:test'), isNull);

      await preferences.setRoomLanguage('@a:test', '!r:test', 'de');
      expect(preferences.roomLanguage('@a:test', '!r:test'), 'de');
      expect(preferences.roomLanguage('@b:test', '!r:test'), isNull);
      await preferences.setRoomLanguage('@a:test', '!r:test', null);
      expect(preferences.roomLanguage('@a:test', '!r:test'), isNull);
    },
  );

  test(
    'language defaults use automatic source and the system target',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferences.getInstance();
      final secrets = _MemorySecrets();
      final runtime = TranslationRuntime.forTesting();

      await runtime.initialize(
        store,
        defaultTargetLanguage: 'zh-Hant',
        secrets: secrets,
        cache: TranslationCache(secrets, _MemoryBackend()),
      );

      expect(runtime.sourceLanguage, 'auto');
      expect(runtime.targetLanguage, systemTranslationLanguageCode);
    },
  );

  test(
    'valid saved languages win and unknown values use system default',
    () async {
      SharedPreferences.setMockInitialValues({
        _sourceLanguagePreference: 'unknown-source',
        _targetLanguagePreference: 'unknown-target',
      });
      final store = await SharedPreferences.getInstance();
      final secrets = _MemorySecrets();
      final runtime = TranslationRuntime.forTesting();

      await runtime.initialize(
        store,
        defaultTargetLanguage: 'ja',
        secrets: secrets,
        cache: TranslationCache(secrets, _MemoryBackend()),
      );

      expect(runtime.sourceLanguage, 'auto');
      expect(runtime.targetLanguage, systemTranslationLanguageCode);

      await runtime.setLanguages(source: 'de', target: 'fr');
      expect(runtime.sourceLanguage, 'de');
      expect(runtime.targetLanguage, 'fr');
    },
  );

  test('system target language follows the resolved app locale', () async {
    SharedPreferences.setMockInitialValues({
      _targetLanguagePreference: systemTranslationLanguageCode,
    });
    final store = await SharedPreferences.getInstance();
    final secrets = _MemorySecrets();
    final runtime = TranslationRuntime.forTesting();

    await runtime.initialize(
      store,
      defaultTargetLanguage: 'zh-Hant',
      secrets: secrets,
      cache: TranslationCache(secrets, _MemoryBackend()),
    );

    expect(runtime.targetLanguage, systemTranslationLanguageCode);
    await runtime.setLanguages(source: 'auto', target: 'fr');
    expect(runtime.targetLanguage, 'fr');
    await runtime.setLanguages(
      source: 'auto',
      target: systemTranslationLanguageCode,
    );
    expect(runtime.targetLanguage, systemTranslationLanguageCode);
  });

  test('bilingual color and style persist independently', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    final secrets = _MemorySecrets();
    final runtime = TranslationRuntime.forTesting();

    await runtime.initialize(
      store,
      secrets: secrets,
      cache: TranslationCache(secrets, _MemoryBackend()),
    );

    expect(runtime.bilingualColor, TranslationBilingualColor.tertiary);
    expect(runtime.bilingualStyle, TranslationBilingualStyle.divider);

    await runtime.setBilingualColor(TranslationBilingualColor.accent);
    await runtime.setBilingualStyle(TranslationBilingualStyle.background);

    expect(store.getString(_bilingualColorPreference), 'accent');
    expect(store.getString(_bilingualLayoutPreference), 'background');
  });

  test(
    'legacy background selection migrates without losing its layout',
    () async {
      SharedPreferences.setMockInitialValues({
        _legacyBilingualStylePreference: 'background',
      });
      final store = await SharedPreferences.getInstance();
      final secrets = _MemorySecrets();
      final runtime = TranslationRuntime.forTesting();

      await runtime.initialize(
        store,
        secrets: secrets,
        cache: TranslationCache(secrets, _MemoryBackend()),
      );

      expect(runtime.bilingualColor, TranslationBilingualColor.tertiary);
      expect(runtime.bilingualStyle, TranslationBilingualStyle.background);
    },
  );

  test(
    'does not restore enabled before the privacy notice is accepted',
    () async {
      SharedPreferences.setMockInitialValues({
        _enabledPreference: true,
        _privacyPreference: false,
        _providersPreference: TranslationProviderConfig.encodeList([_provider]),
        _selectedProviderPreference: _provider.id,
      });
      final store = await SharedPreferences.getInstance();
      final secrets = _MemorySecrets()
        ..values['chat.fluffy.translation.provider_api_key.${_provider.id}'] =
            'secret';
      final runtime = TranslationRuntime.forTesting();

      await runtime.initialize(
        store,
        secrets: secrets,
        cache: TranslationCache(secrets, _MemoryBackend()),
      );

      expect(runtime.privacyAccepted, isFalse);
      expect(runtime.enabled, isFalse);
      expect(store.getBool(_enabledPreference), isFalse);
    },
  );

  test(
    'room controls combine global defaults with nullable overrides',
    () async {
      final fixture = await _RuntimeFixture.create();
      final unencrypted = Room(
        id: '!plain:example.invalid',
        client: fixture.client,
      );
      final encrypted =
          Room(id: '!encrypted:example.invalid', client: fixture.client)
            ..setState(
              StrippedStateEvent(
                type: EventTypes.Encryption,
                content: {'algorithm': 'm.megolm.v1.aes-sha2'},
                senderId: fixture.client.userID!,
                stateKey: '',
              ),
            );

      await fixture.runtime.setScope(TranslationScope.allRooms);
      _expectControl(
        fixture.runtime.roomControl(unencrypted),
        value: true,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );
      _expectControl(
        fixture.runtime.roomControl(encrypted),
        value: true,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );

      await fixture.runtime.setScope(TranslationScope.unencryptedRooms);
      _expectControl(
        fixture.runtime.roomControl(unencrypted),
        value: true,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );
      _expectControl(
        fixture.runtime.roomControl(encrypted),
        value: false,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );

      await fixture.runtime.setScope(TranslationScope.none);
      _expectControl(
        fixture.runtime.roomControl(unencrypted),
        value: false,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );
      await fixture.runtime.setRoomTranslationOverride(unencrypted, true);
      _expectControl(
        fixture.runtime.roomControl(unencrypted),
        value: true,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );

      await fixture.runtime.setRoomTranslationOverride(unencrypted, false);
      _expectControl(
        fixture.runtime.roomControl(unencrypted),
        value: false,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );
      await fixture.runtime.setRoomTranslationOverride(unencrypted, null);
      expect(fixture.runtime.roomControl(unencrypted).value, isFalse);

      final otherClient = await prepareTestClient(loggedIn: true, id: 'other');
      otherClient.setUserId('@bob:example.invalid');
      final sameRoomForOtherUser = Room(
        id: unencrypted.id,
        client: otherClient,
      );
      _expectControl(
        fixture.runtime.roomControl(sameRoomForOtherUser),
        value: false,
        canChange: true,
        reason: RoomTranslationLockReason.none,
      );

      await fixture.runtime.setEnabled(false);
      _expectControl(
        fixture.runtime.roomControl(unencrypted),
        value: false,
        canChange: false,
        reason: RoomTranslationLockReason.globallyDisabled,
      );
    },
  );

  test('input translation settings persist independently', () async {
    final fixture = await _RuntimeFixture.create();
    expect(fixture.runtime.preferRoomLanguageForSource, isFalse);
    expect(fixture.runtime.preferRoomLanguageForInputTarget, isTrue);
    expect(fixture.runtime.inputMode, InputTranslationMode.disabled);
    expect(fixture.runtime.inputScope, InputTranslationScope.automaticRooms);
    expect(fixture.runtime.inputSourceLanguage, 'auto');
    expect(fixture.runtime.inputTargetLanguage, 'en');
    expect(
      fixture.runtime.inputSendMode,
      InputTranslationSendMode.shortOriginalLongTranslated,
    );

    await fixture.runtime.setInputMode(InputTranslationMode.manual);
    await fixture.runtime.setInputScope(InputTranslationScope.allRooms);
    await fixture.runtime.setInputLanguages(source: 'de', target: 'fr');
    await fixture.runtime.setInputTrigger(InputTranslationTrigger.doubleTap);
    await fixture.runtime.setInputSendMode(
      InputTranslationSendMode.shortTranslatedLongOriginal,
    );

    expect(
      fixture.runtime.preferences.store.getString(_inputModePreference),
      'manual',
    );
    expect(
      fixture.runtime.preferences.store.getString(_inputScopePreference),
      'allRooms',
    );
    expect(
      fixture.runtime.preferences.store.getString(
        _inputSourceLanguagePreference,
      ),
      'de',
    );
    expect(
      fixture.runtime.preferences.store.getString(
        _inputTargetLanguagePreference,
      ),
      'fr',
    );
    expect(
      fixture.runtime.preferences.store.getString(_inputTriggerPreference),
      'doubleTap',
    );
    expect(
      fixture.runtime.preferences.store.getString(_inputSendModePreference),
      'shortTranslatedLongOriginal',
    );
  });

  test(
    'input translation eligibility follows mode, scope, and global state',
    () async {
      final fixture = await _RuntimeFixture.create();
      final room = Room(id: '!input:example.invalid', client: fixture.client);
      final encrypted =
          Room(id: '!input-encrypted:example.invalid', client: fixture.client)
            ..setState(
              StrippedStateEvent(
                type: EventTypes.Encryption,
                content: {'algorithm': 'm.megolm.v1.aes-sha2'},
                senderId: fixture.client.userID!,
                stateKey: '',
              ),
            );

      expect(fixture.runtime.canTranslateInput(room), isFalse);
      await fixture.runtime.setInputMode(InputTranslationMode.automatic);
      expect(fixture.runtime.canTranslateInput(room), isFalse);

      await fixture.runtime.setInputScope(InputTranslationScope.allRooms);
      expect(fixture.runtime.canTranslateInput(room), isTrue);
      expect(fixture.runtime.canTranslateInput(encrypted), isTrue);
      expect(fixture.runtime.shouldAutoTranslateInput(room), isTrue);
      expect(fixture.runtime.canManuallyTranslateInput(room), isFalse);

      await fixture.runtime.setInputSendMode(
        InputTranslationSendMode.shortTranslatedLongOriginal,
      );

      await fixture.runtime.setInputMode(InputTranslationMode.manual);
      expect(fixture.runtime.canManuallyTranslateInput(room), isTrue);
      expect(fixture.runtime.shouldAutoTranslateInput(room), isFalse);
      expect(
        fixture.runtime.inputSendMode,
        InputTranslationSendMode.shortTranslatedLongOriginal,
      );

      await fixture.runtime.setEnabled(false);
      expect(fixture.runtime.canTranslateInput(room), isFalse);
      expect(
        fixture.runtime.inputSendMode,
        InputTranslationSendMode.shortTranslatedLongOriginal,
      );
    },
  );

  test('input translation uses no event translation cache', () async {
    final api = _RecordingApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    final room = Room(
      id: '!input-cache:example.invalid',
      client: fixture.client,
    );
    await fixture.runtime.setInputMode(InputTranslationMode.manual);
    await fixture.runtime.setInputScope(InputTranslationScope.allRooms);

    expect(
      await fixture.runtime.translateInputText(room, 'hello'),
      'translated',
    );
    expect(api.calls, 1);
    expect(fixture.backend.present, isFalse);
    expect(
      fixture.secrets.values,
      isNot(contains('chat.fluffy.translation.cache_master_key')),
    );
  });

  test('input translation response expires after a runtime change', () async {
    final api = _ControlledApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    final room = Room(
      id: '!input-race:example.invalid',
      client: fixture.client,
    );
    await fixture.runtime.setInputMode(InputTranslationMode.manual);
    await fixture.runtime.setInputScope(InputTranslationScope.allRooms);

    final translation = fixture.runtime.translateInputText(room, 'hello');
    final call = await api.waitForCall(0);
    await fixture.runtime.setInputLanguages(source: 'de', target: 'fr');
    call.complete('late');
    await expectLater(translation, throwsA(isA<StateError>()));
    expect(fixture.backend.present, isFalse);
  });

  test(
    'logout uses recorded rooms and a reattached client preserves local references',
    () async {
      final fixture = await _RuntimeFixture.create();
      final secondClient = await prepareTestClient(
        loggedIn: true,
        id: 'second',
      );
      secondClient.setUserId('@bob:example.invalid');
      const roomId = '!shared:example.invalid';
      final firstRoom = Room(id: roomId, client: fixture.client);
      final secondRoom = Room(id: roomId, client: secondClient);
      fixture.client.rooms = [firstRoom];
      secondClient.rooms = [secondRoom];
      fixture.runtime.attachClient(fixture.client);
      fixture.runtime.attachClient(secondClient);

      final event = Event(
        content: {'msgtype': MessageTypes.Text, 'body': 'source'},
        type: EventTypes.Message,
        eventId: r'$event',
        senderId: fixture.client.userID!,
        originServerTs: DateTime.utc(2026),
        room: firstRoom,
      );
      final stateBeforeLogout = fixture.runtime.stateForEvent(event);
      expect(stateBeforeLogout.value.status, TranslationStatus.idle);

      const key = TranslationCacheKey(
        roomId: roomId,
        eventId: r'$event',
        source: 'source',
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        semanticRevision: 'provider:responses:model:endpoint:1',
        messageType: MessageTypes.Text,
      );
      await fixture.runtime.cache.write(key, 'translation');

      // Matrix clears Client.rooms during logout. The runtime must retain the
      // snapshot captured by attachClient, while respecting another client
      // that still has a readable local room.
      fixture.client.rooms = [];
      await fixture.runtime.detachLoggedOutClient(fixture.client);
      expect(await fixture.runtime.cache.read(key), 'translation');
      final stateAfterLogout = fixture.runtime.stateForEvent(event);
      expect(identical(stateAfterLogout, stateBeforeLogout), isFalse);
      expect(stateAfterLogout.value.status, TranslationStatus.idle);

      // The newly attached client must itself have a recorded snapshot, so its
      // later logout invalidates the room even after its room list is cleared.
      secondClient.rooms = [];
      await fixture.runtime.detachLoggedOutClient(secondClient);
      expect(await fixture.runtime.cache.read(key), isNull);
      expect(fixture.backend.deletedRoomIds, [roomId]);
    },
  );

  test('disabling while the API key is loading prevents the request', () async {
    final keyReadStarted = Completer<void>();
    final releaseKeyRead = Completer<void>();
    final secrets =
        _MemorySecrets(
            delayedReadNumber: 2,
            readStarted: keyReadStarted,
            releaseRead: releaseKeyRead,
          )
          ..values['chat.fluffy.translation.provider_api_key.${_provider.id}'] =
              'secret';
    final api = _RecordingApiClient();
    final fixture = await _RuntimeFixture.create(
      secrets: secrets,
      apiClient: api,
      mergeWindowMs: 0,
    );
    final room = Room(id: '!race:example.invalid', client: fixture.client);
    final event = Event(
      content: {'msgtype': MessageTypes.Text, 'body': 'hello'},
      type: EventTypes.Message,
      eventId: r'$race',
      senderId: fixture.client.userID!,
      originServerTs: DateTime.utc(2026),
      room: room,
    );

    final translation = fixture.runtime.translateEvent(event, manual: true);
    final failedTranslation = expectLater(
      translation,
      throwsA(isA<StateError>()),
    );
    await keyReadStarted.future;
    await fixture.runtime.setEnabled(false);
    releaseKeyRead.complete();

    await failedTranslation;
    expect(api.calls, 0);
    expect(fixture.backend.present, isFalse);
    expect(
      secrets.values,
      isNot(contains('chat.fluffy.translation.cache_master_key')),
    );
  });

  test(
    'an in-place Event edit expires the old request and uses the new source',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final room = Room(id: '!edit:example.invalid', client: fixture.client);
      final event = Event(
        content: {'msgtype': MessageTypes.Text, 'body': 'before'},
        type: EventTypes.Message,
        eventId: r'$edit',
        senderId: fixture.client.userID!,
        originServerTs: DateTime.utc(2026),
        room: room,
      );

      final oldTranslation = fixture.runtime.translateEvent(
        event,
        manual: true,
      );
      final firstCall = await api.waitForCall(0);
      expect(firstCall.messages.values.single.text, 'before');

      // Matrix may update the existing Event instance rather than replacing
      // it. The request must compare its captured source with this new value.
      event.content['body'] = 'after';
      firstCall.complete('old translation');
      await expectLater(oldTranslation, throwsA(isA<StateError>()));
      expect(fixture.backend.present, isFalse);

      final newTranslation = fixture.runtime.translateEvent(
        event,
        manual: true,
      );
      final secondCall = await api.waitForCall(1);
      expect(secondCall.messages.values.single.text, 'after');
      secondCall.complete('new translation');
      expect(await newTranslation, 'new translation');
      expect(fixture.backend.records, hasLength(1));
    },
  );
}

void _expectControl(
  RoomTranslationControl control, {
  required bool value,
  required bool canChange,
  required RoomTranslationLockReason reason,
}) {
  expect(control.value, value);
  expect(control.canChange, canChange);
  expect(control.reason, reason);
}

class _RuntimeFixture {
  final TranslationRuntime runtime;
  final Client client;
  final _MemoryBackend backend;
  final _MemorySecrets secrets;

  const _RuntimeFixture(this.runtime, this.client, this.backend, this.secrets);

  static Future<_RuntimeFixture> create({
    _MemorySecrets? secrets,
    TranslationApiClient? apiClient,
    int mergeWindowMs = 100,
  }) async {
    SharedPreferences.setMockInitialValues({
      _enabledPreference: true,
      _privacyPreference: true,
      _providersPreference: TranslationProviderConfig.encodeList([_provider]),
      _selectedProviderPreference: _provider.id,
      _scopePreference: TranslationScope.none.name,
      'chat.fluffy.translation.batch.merge_ms': mergeWindowMs,
    });
    final store = await SharedPreferences.getInstance();
    final memorySecrets = secrets ?? _MemorySecrets();
    memorySecrets.values.putIfAbsent(
      'chat.fluffy.translation.provider_api_key.${_provider.id}',
      () => 'secret',
    );
    final backend = _MemoryBackend();
    final runtime = TranslationRuntime.forTesting();
    await runtime.initialize(
      store,
      secrets: memorySecrets,
      apiClient: apiClient,
      cache: TranslationCache(memorySecrets, backend),
    );
    final client = await prepareTestClient(loggedIn: true);
    return _RuntimeFixture(runtime, client, backend, memorySecrets);
  }
}

class _RecordingApiClient extends TranslationApiClient {
  int calls = 0;

  @override
  Future<Map<String, String>> translate({
    required TranslationProviderConfig provider,
    required String apiKey,
    required Map<String, TranslationRequestMessage> messages,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    calls++;
    return {for (final id in messages.keys) id: 'translated'};
  }
}

class _PendingTranslation {
  final Map<String, TranslationRequestMessage> messages;
  final result = Completer<Map<String, String>>();

  _PendingTranslation(this.messages);

  void complete(String value) {
    result.complete({for (final id in messages.keys) id: value});
  }
}

class _ControlledApiClient extends TranslationApiClient {
  final firstStarted = Completer<void>();
  final pending = <_PendingTranslation>[];

  Future<_PendingTranslation> waitForCall(int index) async {
    while (pending.length <= index) {
      await Future<void>.delayed(Duration.zero);
    }
    return pending[index];
  }

  @override
  Future<Map<String, String>> translate({
    required TranslationProviderConfig provider,
    required String apiKey,
    required Map<String, TranslationRequestMessage> messages,
    required String sourceLanguage,
    required String targetLanguage,
  }) {
    final call = _PendingTranslation(messages);
    pending.add(call);
    if (!firstStarted.isCompleted) firstStarted.complete();
    return call.result.future;
  }
}

class _MemorySecrets implements TranslationSecretStore {
  final values = <String, String>{};
  final int? delayedReadNumber;
  final Completer<void>? readStarted;
  final Completer<void>? releaseRead;
  int readCalls = 0;

  _MemorySecrets({this.delayedReadNumber, this.readStarted, this.releaseRead});

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async {
    readCalls++;
    if (readCalls == delayedReadNumber) {
      readStarted?.complete();
      await releaseRead?.future;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _MemoryBackend implements TranslationCacheBackend {
  final records = <TranslationCacheRecord>[];
  final deletedRoomIds = <String>[];
  bool present = false;

  @override
  Future<bool> exists() async => present;

  @override
  Future<bool> openExisting(String databaseKey) async => present;

  @override
  Future<void> openOrCreate(String databaseKey) async => present = true;

  @override
  Future<TranslationCacheRecord?> get(String cacheKey) async {
    for (final record in records) {
      if (record.cacheKey == cacheKey) return record;
    }
    return null;
  }

  @override
  Future<void> putAll(List<TranslationCacheRecord> value) async {
    for (final record in value) {
      records.removeWhere((item) => item.cacheKey == record.cacheKey);
      records.add(record);
    }
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
    deletedRoomIds.add(roomId);
    final before = records.length;
    records.removeWhere((record) => record.roomId == roomId);
    return before - records.length;
  }

  @override
  Future<int> deleteKeys(List<String> cacheKeys) async {
    final before = records.length;
    records.removeWhere((record) => cacheKeys.contains(record.cacheKey));
    return before - records.length;
  }

  @override
  Future<List<TranslationCacheRecord>> page(int offset, int limit) async {
    final start = offset.clamp(0, records.length);
    final end = (offset + limit).clamp(start, records.length);
    return records.sublist(start, end);
  }

  @override
  Future<int> count() async => records.length;

  @override
  Future<void> deleteIfExists() async {
    present = false;
    records.clear();
  }

  @override
  Future<void> close() async {}
}
