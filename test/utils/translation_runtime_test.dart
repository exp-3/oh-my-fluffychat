// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/translation/translation_api_client.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_client.dart';
import 'translation_test_backend.dart';

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

  test(
    'manual roaming imports require both enable switches and valid secrets',
    () async {
      final fixture = await _RuntimeFixture.create(
        roamingFactory: _ImmediateRoaming.new,
      );
      addTearDown(fixture.runtime.dispose);
      expect(fixture.runtime.canUploadLocalTranslations, isFalse);
      await expectLater(
        fixture.runtime.createRoamingUploadSession(),
        throwsA(isA<TranslationRoamingException>()),
      );
      await _enableRoaming(fixture.runtime);
      expect(fixture.runtime.canUploadLocalTranslations, isTrue);
      final session = await fixture.runtime.createRoamingUploadSession();
      addTearDown(session.dispose);
      await fixture.runtime.setEnabled(false);
      expect(session.phase, TranslationRoamingUploadPhase.stopped);
      expect(fixture.runtime.canUploadLocalTranslations, isFalse);
    },
  );

  test(
    'manual import snapshots stop on configuration and cache safety changes',
    () async {
      final fixture = await _RuntimeFixture.create(
        roamingFactory: _ImmediateRoaming.new,
      );
      addTearDown(fixture.runtime.dispose);
      await _enableRoaming(fixture.runtime);
      final first = await fixture.runtime.createRoamingUploadSession();
      addTearDown(first.dispose);
      await fixture.runtime.setRoamingEnabled(false);
      expect(first.phase, TranslationRoamingUploadPhase.stopped);

      await fixture.runtime.setRoamingEnabled(true);
      final second = await fixture.runtime.createRoamingUploadSession();
      addTearDown(second.dispose);
      await fixture.runtime.clearCache();
      expect(second.phase, TranslationRoamingUploadPhase.stopped);
      expect(fixture.backend.createCalls, 0);
    },
  );

  test(
    'manual import cannot export a cache reference without a local event',
    () async {
      final fixture = await _RuntimeFixture.create(
        roamingFactory: _ImmediateRoaming.new,
      );
      addTearDown(fixture.runtime.dispose);
      await _enableRoaming(fixture.runtime);
      final event = _event(fixture);
      fixture.client.rooms = [event.room];
      fixture.runtime.attachClient(fixture.client);
      await fixture.runtime.cache.write(_eventCacheKey(event), 'local only');
      final session = await fixture.runtime.createRoamingUploadSession();
      addTearDown(session.dispose);
      await session.scan();
      expect(session.phase, TranslationRoamingUploadPhase.ready);
      expect(session.rooms, isEmpty);
      expect(fixture.backend.records, hasLength(1));
    },
  );

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

  test(
    'manual and automatic input translation can be enabled together',
    () async {
      final fixture = await _RuntimeFixture.create();
      final room = Room(
        id: '!input-both:example.invalid',
        client: fixture.client,
      );
      await fixture.runtime.setInputScope(InputTranslationScope.allRooms);
      await fixture.runtime.setManualInputTranslationEnabled(true);
      await fixture.runtime.setAutomaticInputTranslationEnabled(true);
      await fixture.runtime.setInputSendMode(
        InputTranslationSendMode.shortTranslatedLongOriginal,
      );

      expect(fixture.runtime.canManuallyTranslateInput(room), isTrue);
      expect(fixture.runtime.shouldTranslateInputOnSend(room), isTrue);
      expect(
        fixture.runtime.shouldTranslateInputOnSend(room, requested: false),
        isFalse,
      );
      expect(
        fixture.runtime.preferences.inputMode,
        InputTranslationMode.manualAndAutomatic,
      );

      await fixture.runtime.setManualInputTranslationEnabled(false);
      expect(fixture.runtime.canManuallyTranslateInput(room), isFalse);
      expect(fixture.runtime.shouldTranslateInputOnSend(room), isTrue);

      await fixture.runtime.setManualInputTranslationEnabled(true);
      await fixture.runtime.setAutomaticInputTranslationEnabled(false);
      expect(fixture.runtime.canManuallyTranslateInput(room), isTrue);
      expect(fixture.runtime.shouldTranslateInputOnSend(room), isFalse);

      await fixture.runtime.setManualInputTranslationEnabled(false);
      expect(fixture.runtime.canTranslateInput(room), isFalse);
      expect(
        fixture.runtime.preferences.inputMode,
        InputTranslationMode.disabled,
      );
    },
  );

  for (final mode in InputTranslationMode.values) {
    test('restores saved input translation mode ${mode.name}', () async {
      final fixture = await _RuntimeFixture.create(inputMode: mode);
      expect(
        fixture.runtime.manualInputTranslationEnabled,
        mode == InputTranslationMode.manual ||
            mode == InputTranslationMode.manualAndAutomatic,
      );
      expect(
        fixture.runtime.automaticInputTranslationEnabled,
        mode == InputTranslationMode.automatic ||
            mode == InputTranslationMode.manualAndAutomatic,
      );
    });
  }

  test('disabled global translation bypasses every input send mode', () async {
    final fixture = await _RuntimeFixture.create();
    final room = Room(
      id: '!input-send:example.invalid',
      client: fixture.client,
    );
    await fixture.runtime.setInputMode(InputTranslationMode.automatic);
    await fixture.runtime.setInputScope(InputTranslationScope.allRooms);
    await fixture.runtime.setInputSendMode(
      InputTranslationSendMode.shortTranslatedLongOriginal,
    );

    expect(fixture.runtime.shouldTranslateInputOnSend(room), isTrue);
    expect(
      fixture.runtime.shouldTranslateInputOnSend(room, requested: false),
      isFalse,
    );

    await fixture.runtime.setEnabled(false);

    expect(fixture.runtime.shouldTranslateInputOnSend(room), isFalse);
    expect(
      fixture.runtime.shouldTranslateInputOnSend(room, requested: true),
      isFalse,
    );
  });

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
    'leaving a shared room removes only the leaving account references',
    () async {
      final fixture = await _RuntimeFixture.create();
      final secondClient = await prepareTestClient(loggedIn: true);
      secondClient.setUserId('@bob:example.invalid');
      const roomId = '!shared:example.invalid';
      fixture.client.rooms = [Room(id: roomId, client: fixture.client)];
      secondClient.rooms = [Room(id: roomId, client: secondClient)];
      fixture.runtime.attachClients([fixture.client, secondClient]);
      final first = TranslationCacheKey(
        userId: fixture.client.userID!,
        roomId: roomId,
        eventId: r'$event',
        source: 'source',
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        messageType: MessageTypes.Text,
      );
      final second = TranslationCacheKey(
        userId: secondClient.userID!,
        roomId: roomId,
        eventId: r'$event',
        source: 'source',
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        messageType: MessageTypes.Text,
      );
      await fixture.runtime.cache.write(first, 'shared');
      expect(await fixture.runtime.cache.read(second), 'shared');

      fixture.client.rooms = [];
      await fixture.runtime.invalidateRoomUnlessLocallyReferenced(
        roomId,
        excludingClient: fixture.client,
      );
      final references = fixture.backend.rows[CacheStore.messageRefs]!.values;
      expect(references, hasLength(1));
      expect(references.single['user_id'], secondClient.userID);
      expect(await fixture.runtime.cache.read(second), 'shared');
      expect(fixture.backend.records, hasLength(1));
      fixture.runtime.dispose();
    },
  );

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

      final key = TranslationCacheKey(
        userId: fixture.client.userID!,
        roomId: roomId,
        eventId: r'$event',
        source: 'source',
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        messageType: MessageTypes.Text,
      );
      await fixture.runtime.cache.write(key, 'translation');

      // Matrix clears Client.rooms during logout. The runtime must retain the
      // snapshot captured by attachClient, while respecting another client
      // that still has a readable local room.
      fixture.client.rooms = [];
      await fixture.runtime.detachLoggedOutClient(fixture.client);
      expect(await fixture.runtime.cache.read(key), isNull);
      final stateAfterLogout = fixture.runtime.stateForEvent(event);
      expect(identical(stateAfterLogout, stateBeforeLogout), isFalse);
      expect(stateAfterLogout.value.status, TranslationStatus.idle);

      // The newly attached client must itself have a recorded snapshot, so its
      // later logout invalidates the room even after its room list is cleared.
      secondClient.rooms = [];
      await fixture.runtime.detachLoggedOutClient(secondClient);
      expect(await fixture.runtime.cache.read(key), isNull);
      expect(fixture.backend.deletedRoomIds, contains(roomId));
    },
  );

  for (final (messageType, eventType) in const [
    (MessageTypes.Image, EventTypes.Message),
    (MessageTypes.File, EventTypes.Message),
    (MessageTypes.Video, EventTypes.Message),
    (MessageTypes.Audio, EventTypes.Message),
    (MessageTypes.Sticker, EventTypes.Message),
    (MessageTypes.Sticker, EventTypes.Sticker),
  ]) {
    test('$eventType/$messageType translates only its caption', () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final event = _mediaEvent(
        fixture,
        messageType: messageType,
        eventType: eventType,
        source: 'A caption to translate',
      );

      expect(fixture.runtime.canTranslateEvent(event), isTrue);
      expect(fixture.runtime.shouldAutoTranslate(event), isFalse);
      final translation = fixture.runtime.translateEvent(event, manual: true);
      final request = await api.waitForCall(0);
      expect(request.messages.values.single.text, 'A caption to translate');
      expect(request.messages.values.single.messageType, event.messageType);
      request.complete('Translated caption');
      expect(await translation, 'Translated caption');
      expect(
        fixture.runtime.stateForEvent(event).value.translation,
        'Translated caption',
      );
    });

    test('$eventType/$messageType skips noncaptions', () async {
      final api = _RecordingApiClient();
      final fixture = await _RuntimeFixture.create(apiClient: api);
      for (final (source, filename) in const [
        ('attachment.bin', 'attachment.bin'),
        ('Unidentified attachment', null),
        ('', 'attachment.bin'),
        ('   ', 'attachment.bin'),
      ]) {
        final event = _mediaEvent(
          fixture,
          messageType: messageType,
          eventType: eventType,
          source: source,
          filename: filename,
        );
        expect(fixture.runtime.canTranslateEvent(event), isFalse);
        expect(
          await fixture.runtime.translateEvent(event, manual: true),
          isNull,
        );
      }
      expect(api.calls, 0);
      expect(fixture.backend.present, isFalse);
    });
  }

  test('real stickers need no msgtype to expose an explicit caption', () async {
    final fixture = await _RuntimeFixture.create();
    final event = _mediaEvent(
      fixture,
      eventType: EventTypes.Sticker,
      source: 'Sticker caption',
    )..content.remove('msgtype');

    expect(fixture.runtime.canTranslateEvent(event), isTrue);
    expect(fixture.runtime.sourceForEvent(event), 'Sticker caption');
    await fixture.runtime.setEnabled(false);
    expect(fixture.runtime.canTranslateEvent(event), isFalse);
  });

  test('media captions stay plain and text messages stay rich', () async {
    final fixture = await _RuntimeFixture.create();
    for (final caption in const [
      'Look at this picture',
      '**literal** <caption> &amp; &\nsecond line',
    ]) {
      final event = _mediaEvent(
        fixture,
        source: caption,
        extraContent: {
          'format': 'org.matrix.custom.html',
          'formatted_body': '<strong>Look at this picture</strong>',
        },
      );

      expect(event.fileDescription, caption);
      expect(fixture.runtime.sourceForEvent(event), caption);
    }
    final text = _event(fixture, source: 'Look at this picture');
    text.content.addAll({
      'format': 'org.matrix.custom.html',
      'formatted_body': '<strong>Look at this picture</strong>',
    });
    expect(
      fixture.runtime.sourceForEvent(text),
      '<strong>Look at this picture</strong>',
    );
  });

  test('caption sources omit reply fallback text', () async {
    final fixture = await _RuntimeFixture.create();
    for (final richCaption in const [false, true]) {
      final event = _mediaEvent(
        fixture,
        source: '> <@sender:test> Quoted message\n\nReply caption',
        extraContent: {
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$replied-to'},
          },
          if (richCaption) ...{
            'format': 'org.matrix.custom.html',
            'formatted_body':
                '<mx-reply>Quoted message</mx-reply>'
                '<strong>Reply caption</strong>',
          },
        },
      );

      expect(fixture.runtime.sourceForEvent(event), 'Reply caption');
    }
  });

  test('automatic captions share cache independently of filenames', () async {
    final api = _RecordingApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    final event = _mediaEvent(fixture, source: 'A shared caption');
    await fixture.runtime.setScope(TranslationScope.allRooms);
    expect(fixture.runtime.shouldAutoTranslate(event), isTrue);
    expect(await fixture.runtime.restoreEvent(event), 'translated');
    await fixture.runtime.setScope(TranslationScope.none);
    final alias = _mediaEvent(
      fixture,
      id: r'$caption-alias',
      room: '!other-room:test',
      source: 'A shared caption',
      filename: 'different-name.png',
    );
    expect(fixture.runtime.shouldAutoTranslate(alias), isFalse);
    expect(await fixture.runtime.restoreEvent(alias), 'translated');
    expect(
      await fixture.runtime.restoreEvent(
        _event(fixture, source: 'A shared caption'),
      ),
      isNull,
    );
    expect(api.calls, 1);

    await fixture.runtime.deleteProvider(_provider.id);
    final restarted = TranslationRuntime.forTesting();
    await restarted.initialize(
      fixture.runtime.preferences.store,
      secrets: fixture.secrets,
      apiClient: api,
      cache: TranslationCache(fixture.secrets, fixture.backend),
    );
    expect(await restarted.restoreEvent(alias), 'translated');
    expect(api.calls, 1);
    restarted.dispose();

    await fixture.runtime.setEnabled(false);
    final reads = fixture.backend.openExistingCalls;
    expect(await fixture.runtime.restoreEvent(alias), isNull);
    expect(fixture.backend.openExistingCalls, reads);
  });

  test('raw media edits select captions and reject removed ones', () async {
    final api = _ControlledApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    final newContent = <String, Object?>{
      'msgtype': MessageTypes.Image,
      'filename': 'attachment.bin',
      'body': 'Replacement caption',
      'format': 'org.matrix.custom.html',
      'formatted_body': '<b>Replacement caption</b>',
    };
    final event = _mediaEvent(
      fixture,
      source: '* Replacement caption',
      extraContent: {
        'm.relates_to': {
          'rel_type': RelationshipTypes.edit,
          'event_id': r'$original',
        },
        'm.new_content': newContent,
      },
    );

    expect(fixture.runtime.sourceForEvent(event), 'Replacement caption');
    expect(event.fileDescription, 'Replacement caption');
    final translation = fixture.runtime.translateEvent(event, manual: true);
    final expired = expectLater(translation, throwsStateError);
    final request = await api.waitForCall(0);
    expect(request.messages.values.single.text, 'Replacement caption');

    newContent['body'] = 'attachment.bin';
    newContent.remove('formatted_body');
    expect(fixture.runtime.sourceForEvent(event), isEmpty);
    expect(event.fileDescription, isNull);
    expect(fixture.runtime.canTranslateEvent(event), isFalse);
    request.complete('Obsolete caption');
    await expired;
    expect(fixture.backend.present, isFalse);
    expect(await fixture.runtime.translateEvent(event, manual: true), isNull);
    expect(api.pending, hasLength(1));
  });

  test('caption edits expire requests and invalidate caches', () async {
    final api = _ControlledApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    final event = _mediaEvent(fixture, source: 'Before editing');
    final previous = fixture.runtime.translateEvent(event, manual: true);
    final expired = expectLater(previous, throwsStateError);
    final first = await api.waitForCall(0);
    event.content['body'] = 'After editing';
    first.complete('Outdated caption');
    await expired;
    expect(fixture.backend.present, isFalse);

    final current = fixture.runtime.translateEvent(event, manual: true);
    final second = await api.waitForCall(1);
    expect(second.messages.values.single.text, 'After editing');
    second.complete('Current caption');
    expect(await current, 'Current caption');
    expect(fixture.backend.records, hasLength(1));
    await fixture.runtime.invalidateEventIfExists(event.room.id, event.eventId);
    expect(fixture.runtime.stateForEvent(event).value.translation, isNull);
    expect(fixture.backend.records, isEmpty);
  });

  test('disabling while the API key is loading prevents the request', () async {
    final keyReadStarted = Completer<void>();
    final releaseKeyRead = Completer<void>();
    final secrets =
        _MemorySecrets(
            delayedReadNumber: 1,
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

  test(
    'room auto off restores shared cache after restart without a provider',
    () async {
      final api = _RecordingApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final first = _event(fixture, id: r'$first', room: '!first:test');
      expect(
        await fixture.runtime.translateEvent(first, manual: true),
        'translated',
      );
      await fixture.runtime.deleteProvider(_provider.id);
      expect(fixture.runtime.enabled, isTrue);
      final restarted = TranslationRuntime.forTesting();
      await restarted.initialize(
        fixture.runtime.preferences.store,
        secrets: fixture.secrets,
        apiClient: api,
        cache: TranslationCache(fixture.secrets, fixture.backend),
      );
      final alias = _event(fixture, id: r'$alias', room: '!other:test');
      expect(restarted.shouldAutoTranslate(alias), isFalse);
      expect(await restarted.restoreEvent(alias), 'translated');
      expect(restarted.stateForEvent(alias).value.translation, 'translated');
      expect(
        await restarted.restoreEvent(_event(fixture, source: 'uncached')),
        isNull,
      );
      expect(api.calls, 1);
      restarted.dispose();
    },
  );

  test(
    'a shared write clears another account cached miss without a second request',
    () async {
      final api = _RecordingApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final secondClient = await prepareTestClient(loggedIn: true);
      secondClient.setUserId('@bob:example.invalid');
      final first = _event(fixture);
      final second = Event(
        content: {'msgtype': MessageTypes.Text, 'body': 'hello'},
        type: EventTypes.Message,
        eventId: r'$other-account',
        senderId: secondClient.userID!,
        originServerTs: DateTime.utc(2026),
        room: Room(id: '!other-account:test', client: secondClient),
      );

      expect(fixture.runtime.shouldAutoTranslate(second), isFalse);
      expect(await fixture.runtime.restoreEvent(second), isNull);
      expect(api.calls, 0);
      expect(
        await fixture.runtime.translateEvent(first, manual: true),
        'translated',
      );
      expect(await fixture.runtime.restoreEvent(second), 'translated');
      expect(
        fixture.runtime.stateForEvent(second).value.translation,
        'translated',
      );
      expect(api.calls, 1);
      expect(fixture.backend.records, hasLength(1));
      fixture.runtime.dispose();
    },
  );

  test(
    'first manual click loads shared cache; next click forces one fresh request',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final event = _event(fixture);
      final initial = fixture.runtime.translateEvent(event, manual: true);
      (await api.waitForCall(0)).complete('old');
      expect(await initial, 'old');
      final alias = _event(fixture, id: r'$alias', room: '!alias:test');
      expect(await fixture.runtime.translateEvent(alias, manual: true), 'old');
      expect(api.pending, hasLength(1));
      final refresh = fixture.runtime.translateEvent(
        alias,
        manual: true,
        forceRefresh: true,
      );
      final request = await api.waitForCall(1);
      final duplicate = fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      );
      expect(fixture.runtime.stateForEvent(alias).value.translation, 'old');
      expect(
        fixture.runtime.stateForEvent(alias).value.status,
        TranslationStatus.loading,
      );
      request.complete('new');
      expect(await refresh, 'new');
      expect(await duplicate, 'new');
      expect(fixture.runtime.stateForEvent(event).value.translation, 'new');
      expect(api.pending, hasLength(2));
    },
  );

  test(
    'failed refresh retains previous translation; deletion overrides fallback',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final event = _event(fixture);
      final initial = fixture.runtime.translateEvent(event, manual: true);
      (await api.waitForCall(0)).complete('old');
      await initial;
      final refresh = fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      );
      final failed = expectLater(refresh, throwsStateError);
      (await api.waitForCall(
        1,
      )).result.completeError(StateError('network failed'));
      await failed;
      expect(fixture.runtime.stateForEvent(event).value.translation, 'old');
      expect(
        fixture.runtime.stateForEvent(event).value.status,
        TranslationStatus.failed,
      );
      final retry = fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      );
      final expired = expectLater(retry, throwsStateError);
      final call = await api.waitForCall(2);
      await fixture.runtime.invalidateEventIfExists(
        event.room.id,
        event.eventId,
      );
      call.complete('obsolete');
      await expired;
      expect(fixture.runtime.stateForEvent(event).value.translation, isNull);
      expect(fixture.backend.records, isEmpty);
    },
  );

  test('a runtime change rolls back an in-flight cache write', () async {
    final api = _ControlledApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    addTearDown(fixture.runtime.dispose);
    final event = _event(fixture);
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    addTearDown(() {
      if (!releaseWrite.isCompleted) releaseWrite.complete();
    });
    fixture.backend.beforePutAll = () async {
      writeStarted.complete();
      await releaseWrite.future;
    };

    final result = fixture.runtime.translateEvent(event, manual: true);
    final expectation = expectLater(result, throwsStateError);
    (await api.waitForCall(0)).complete('obsolete');
    await writeStarted.future;
    await fixture.runtime.setLanguages(source: 'de', target: 'fr');
    releaseWrite.complete();

    await expectation;
    expect(fixture.backend.records, isEmpty);
    expect(fixture.runtime.stateForEvent(event).value.translation, isNull);
  });

  test('forced refresh supersedes an older ordinary request', () async {
    final api = _ControlledApiClient();
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      mergeWindowMs: 0,
    );
    final event = _event(fixture);
    final ordinary = fixture.runtime.translateEvent(event, manual: true);
    final expired = expectLater(ordinary, throwsStateError);
    final old = await api.waitForCall(0);
    final fresh = fixture.runtime.translateEvent(
      event,
      manual: true,
      forceRefresh: true,
    );
    (await api.waitForCall(1)).complete('fresh');
    expect(await fresh, 'fresh');
    old.complete('stale');
    await expired;
    expect(fixture.runtime.stateForEvent(event).value.translation, 'fresh');
  });

  test(
    'provider/model changes retain completed states and new clicks use current model',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final event = _event(fixture);
      final initial = fixture.runtime.translateEvent(event, manual: true);
      (await api.waitForCall(0)).complete('old');
      await initial;
      final replacement = TranslationProviderConfig(
        id: _provider.id,
        name: 'Replacement',
        endpoint: _provider.endpoint,
        protocol: _provider.protocol,
        model: 'new-model',
      );
      await fixture.runtime.saveProvider(replacement);
      expect(fixture.runtime.stateForEvent(event).value.translation, 'old');
      expect(await fixture.runtime.restoreEvent(event), 'old');
      final refresh = fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      );
      (await api.waitForCall(1)).complete('improved');
      await refresh;
      expect(fixture.backend.records, hasLength(1));
    },
  );

  final replacement = TranslationProviderConfig(
    id: _provider.id,
    name: _provider.name,
    endpoint: _provider.endpoint,
    protocol: _provider.protocol,
    model: _provider.model,
    reasoningEffort: TranslationReasoningEffort.high,
  );

  test(
    'reasoning effort changes retain cache and expire old message requests',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      addTearDown(fixture.runtime.dispose);
      final event = _event(fixture);
      final initial = fixture.runtime.translateEvent(event, manual: true);
      (await api.waitForCall(0)).complete('cached');
      await initial;

      final stale = fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      );
      final expired = expectLater(stale, throwsStateError);
      final oldRequest = await api.waitForCall(1);
      await fixture.runtime.saveProvider(replacement);

      expect(fixture.runtime.stateForEvent(event).value.translation, 'cached');
      expect(await fixture.runtime.restoreEvent(event), 'cached');
      expect(api.pending, hasLength(2));
      final refresh = fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      );
      final currentRequest = await api.waitForCall(2);
      expect(
        currentRequest.provider.reasoningEffort,
        replacement.reasoningEffort,
      );
      currentRequest.complete('current');
      expect(await refresh, 'current');
      oldRequest.complete('obsolete');
      await expired;

      expect(await fixture.runtime.restoreEvent(event), 'current');
      expect(fixture.runtime.stateForEvent(event).value.translation, 'current');
      expect(fixture.backend.records, hasLength(1));
    },
  );

  test(
    'reasoning effort changes prevent sending a request waiting for credentials',
    () async {
      final keyReadStarted = Completer<void>();
      final releaseKeyRead = Completer<void>();
      final secrets = _MemorySecrets(
        delayedReadNumber: 1,
        readStarted: keyReadStarted,
        releaseRead: releaseKeyRead,
      );
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        secrets: secrets,
        apiClient: api,
        mergeWindowMs: 0,
      );
      addTearDown(fixture.runtime.dispose);
      final event = _event(fixture);
      final stale = fixture.runtime.translateEvent(event, manual: true);
      final expired = expectLater(stale, throwsStateError);
      await keyReadStarted.future;

      await fixture.runtime.saveProvider(replacement);
      releaseKeyRead.complete();
      await expired;
      expect(api.pending, isEmpty);
      expect(fixture.backend.present, isFalse);

      final current = fixture.runtime.translateEvent(event, manual: true);
      final request = await api.waitForCall(0);
      expect(request.provider.reasoningEffort, replacement.reasoningEffort);
      request.complete('current');
      expect(await current, 'current');
    },
  );

  test(
    'reasoning effort changes cancel queued and in-flight input translations',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      addTearDown(fixture.runtime.dispose);
      await fixture.runtime.setInputMode(InputTranslationMode.manual);
      await fixture.runtime.setInputScope(InputTranslationScope.allRooms);
      final room = Room(id: '!input-settings:test', client: fixture.client);

      final queued = fixture.runtime.translateInputText(room, 'queued');
      final cancelled = expectLater(queued, throwsStateError);
      await fixture.runtime.saveProvider(replacement);
      await cancelled;
      expect(api.pending, isEmpty);

      final stale = fixture.runtime.translateInputText(room, 'in-flight');
      final expired = expectLater(stale, throwsStateError);
      final request = await api.waitForCall(0);
      expect(request.provider.reasoningEffort, replacement.reasoningEffort);
      await fixture.runtime.saveProvider(_provider);
      request.complete('obsolete');
      await expired;

      final current = fixture.runtime.translateInputText(room, 'current');
      final currentRequest = await api.waitForCall(1);
      expect(
        currentRequest.provider.reasoningEffort,
        _provider.reasoningEffort,
      );
      currentRequest.complete('current');
      expect(await current, 'current');
      expect(fixture.backend.present, isFalse);
    },
  );

  test(
    'unavailable storage never causes automatic regeneration and global off bypasses lookups',
    () async {
      final api = _RecordingApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final event = _event(fixture);
      await fixture.runtime.setScope(TranslationScope.allRooms);
      fixture.backend.unavailable = true;
      expect(await fixture.runtime.restoreEvent(event), isNull);
      expect(api.calls, 0);
      fixture.backend.unavailable = false;
      await fixture.runtime.setEnabled(false);
      final opens = fixture.backend.openExistingCalls;
      expect(await fixture.runtime.restoreEvent(event), isNull);
      expect(await fixture.runtime.translateEvent(event, manual: true), isNull);
      expect(fixture.backend.openExistingCalls, opens);
      expect(fixture.backend.present, isFalse);
    },
  );

  test(
    'turning room auto off cancels generation and preserves displayed cache',
    () async {
      final api = _ControlledApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        mergeWindowMs: 0,
      );
      final event = _event(fixture);
      await fixture.runtime.setRoomTranslationOverride(event.room, true);
      final initial = fixture.runtime.restoreEvent(event);
      (await api.waitForCall(0)).complete('cached');
      await initial;
      await fixture.runtime.setRoomTranslationOverride(event.room, false);
      expect(fixture.runtime.stateForEvent(event).value.translation, 'cached');
      expect(await fixture.runtime.restoreEvent(event), 'cached');
      expect(api.pending, hasLength(1));
    },
  );

  test('enabling roaming before setup persists without a connection', () async {
    final fixture = await _RuntimeFixture.create(
      roamingFactory: (_, _) => fail('Incomplete roaming must stay offline'),
    );
    addTearDown(fixture.runtime.dispose);

    await fixture.runtime.setRoamingEnabled(true);
    expect(fixture.runtime.roamingConfig.enabled, isTrue);
    expect(fixture.runtime.roamingConfig.isValid, isFalse);
    expect(await fixture.runtime.restoreEvent(_event(fixture)), isNull);
    final preferences = TranslationRoamingPreferences(
      await SharedPreferences.getInstance(),
      fixture.secrets,
    );
    expect(preferences.config.enabled, isTrue);
    expect(
      fixture.secrets.values,
      isNot(contains(TranslationRoamingPreferences.secretsKey)),
    );
    await expectLater(
      fixture.runtime.saveRoaming(
        fixture.runtime.roamingConfig,
        const TranslationRoamingSecrets(),
      ),
      throwsArgumentError,
    );
  });

  test(
    'queued snapshots stay consistent and switch off follows delayed saves',
    () async {
      final services = <_ImmediateRoaming>[];
      final fixture = await _RuntimeFixture.create(
        roamingFactory: (config, secrets) {
          final service = _ImmediateRoaming(config, secrets);
          services.add(service);
          return service;
        },
      );
      addTearDown(fixture.runtime.dispose);
      await _enableRoaming(fixture.runtime);
      final secrets = await fixture.runtime.readRoamingSecrets();
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      var roamingWrites = 0;
      addTearDown(() {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });
      fixture.secrets.beforeWrite = (key) async {
        if (key != TranslationRoamingPreferences.secretsKey) return;
        roamingWrites++;
        if (roamingWrites == 1) {
          writeStarted.complete();
          await releaseWrite.future;
        }
      };
      final notifiedEnabled = <bool>[];
      fixture.runtime.addListener(() {
        notifiedEnabled.add(fixture.runtime.roamingConfig.enabled);
      });
      final config = fixture.runtime.roamingConfig.copyWith(
        host: 'updated-redis.example.invalid',
        retentionDays: 7,
      );
      final updatedSecrets = secrets.copyWith(
        redisPassword: 'updated-password',
      );
      final saving = fixture.runtime.saveRoaming(config, updatedSecrets);
      await writeStarted.future;
      final stale = fixture.runtime.saveRoaming(
        config.copyWith(host: 'obsolete-redis.example.invalid'),
        secrets,
        isCurrent: () => false,
      );
      final reading = fixture.runtime.readRoamingSettings();
      final disabling = fixture.runtime.setRoamingEnabled(false);
      expect(await fixture.runtime.restoreEvent(_event(fixture)), isNull);
      expect(services, isEmpty);
      notifiedEnabled.clear();
      releaseWrite.complete();
      await Future.wait([saving, stale, disabling]);
      final snapshot = await reading;

      expect(snapshot.config.toJson(), config.toJson());
      expect(snapshot.secrets.redisPassword, 'updated-password');
      expect(roamingWrites, 1);
      expect(notifiedEnabled, isNot(contains(true)));
      expect(
        fixture.runtime.roamingConfig.toJson(),
        config.copyWith(enabled: false).toJson(),
      );
      final preferences = TranslationRoamingPreferences(
        await SharedPreferences.getInstance(),
        fixture.secrets,
      );
      expect(
        preferences.config.toJson(),
        config.copyWith(enabled: false).toJson(),
      );
      expect(
        await fixture.runtime.restoreEvent(_event(fixture, id: r'$after-off')),
        isNull,
      );
      expect(services, isEmpty);
    },
  );

  test('roaming displays before the frame and delayed local save', () async {
    final api = _RecordingApiClient();
    final saves = <void Function()>[];
    late _ControlledRoaming roaming;
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      roamingFactory: (config, secrets) =>
          roaming = _ControlledRoaming(config, secrets),
      afterRoamingFrame: saves.add,
    );
    addTearDown(fixture.runtime.dispose);
    await _enableRoaming(fixture.runtime);
    final event = _event(fixture);
    final restored = fixture.runtime.restoreEvent(event);
    await Future<void>.delayed(Duration.zero);
    roaming.result.complete(
      const TranslationRoamingLookup(
        TranslationRoamingLookupStatus.hit,
        translation: 'cloud translation',
      ),
    );
    expect(await restored, 'cloud translation');
    expect(
      fixture.runtime.stateForEvent(event).value.translation,
      'cloud translation',
    );
    expect(fixture.backend.present, isFalse);
    expect(api.calls, 0);
    expect(saves, hasLength(1));
    expect(await fixture.runtime.restoreEvent(event), 'cloud translation');
    expect(roaming.reads, 1);

    final alias = _event(fixture, id: r'$cloud-alias');
    expect(await fixture.runtime.restoreEvent(alias), 'cloud translation');
    expect(roaming.reads, 1);
    expect(saves, hasLength(2));

    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    fixture.backend.beforePutAll = () async {
      writeStarted.complete();
      await releaseWrite.future;
    };
    saves.first();
    await writeStarted.future;
    expect(
      fixture.runtime.stateForEvent(event).value.translation,
      'cloud translation',
    );
    releaseWrite.complete();
    expect(
      await fixture.runtime.cache.read(_eventCacheKey(event)),
      'cloud translation',
    );
    fixture.backend.beforePutAll = null;
    saves.last();
    expect(
      await fixture.runtime.cache.read(_eventCacheKey(alias)),
      'cloud translation',
    );
    expect(roaming.uploads, isEmpty);
  });

  test('ordinary roaming save failure keeps the visible translation', () async {
    final saves = <void Function()>[];
    final fixture = await _RuntimeFixture.create(
      roamingFactory: _ImmediateRoaming.new,
      afterRoamingFrame: saves.add,
    );
    addTearDown(fixture.runtime.dispose);
    await _enableRoaming(fixture.runtime);
    final event = _event(fixture);
    expect(await fixture.runtime.restoreEvent(event), 'cloud translation');
    fixture.backend.failOpenAfterCreate = true;
    saves.single();
    // Reading joins the cache serialization queue behind the failed write.
    await fixture.runtime.cache.read(_eventCacheKey(event));
    expect(
      fixture.runtime.stateForEvent(event).value.translation,
      'cloud translation',
    );
  });

  test(
    'an obsolete save preserves completed text after auto mode changes',
    () async {
      final saves = <void Function()>[];
      final fixture = await _RuntimeFixture.create(
        roamingFactory: _ImmediateRoaming.new,
        afterRoamingFrame: saves.add,
      );
      addTearDown(fixture.runtime.dispose);
      await _enableRoaming(fixture.runtime);
      final event = _event(fixture);
      expect(await fixture.runtime.restoreEvent(event), 'cloud translation');
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      fixture.backend.beforePutAll = () async {
        writeStarted.complete();
        await releaseWrite.future;
      };
      saves.single();
      await writeStarted.future;
      await fixture.runtime.setRoomTranslationOverride(event.room, false);
      releaseWrite.complete();
      await fixture.runtime.cache.read(_eventCacheKey(event));
      expect(
        fixture.runtime.stateForEvent(event).value.translation,
        'cloud translation',
      );
    },
  );

  test('clearing after display cancels the deferred roaming save', () async {
    final saves = <void Function()>[];
    final fixture = await _RuntimeFixture.create(
      roamingFactory: _ImmediateRoaming.new,
      afterRoamingFrame: saves.add,
    );
    addTearDown(fixture.runtime.dispose);
    await _enableRoaming(fixture.runtime);
    final event = _event(fixture);
    expect(await fixture.runtime.restoreEvent(event), 'cloud translation');
    await fixture.runtime.clearCache();
    saves.single();
    expect(fixture.runtime.stateForEvent(event).value.translation, isNull);
    expect(fixture.backend.present, isFalse);
    expect(fixture.backend.createCalls, 0);
  });

  test('local hit stays offline and forced refresh replaces roaming', () async {
    final api = _RecordingApiClient();
    final services = <_ImmediateRoaming>[];
    final fixture = await _RuntimeFixture.create(
      apiClient: api,
      roamingFactory: (config, secrets) {
        final service = _ImmediateRoaming(config, secrets);
        services.add(service);
        return service;
      },
      mergeWindowMs: 0,
    );
    addTearDown(fixture.runtime.dispose);
    await _enableRoaming(fixture.runtime);
    final event = _event(fixture);
    await fixture.runtime.cache.write(_eventCacheKey(event), 'local');
    expect(await fixture.runtime.restoreEvent(event), 'local');
    expect(services, isEmpty);
    expect(
      await fixture.runtime.translateEvent(
        event,
        manual: true,
        forceRefresh: true,
      ),
      'translated',
    );
    await Future<void>.delayed(Duration.zero);
    expect(services.single.reads, 0);
    expect(services.single.uploads, ['translated']);
    expect(api.calls, 1);
  });

  test(
    'a late remote hit cannot undo clearing or unavailable storage',
    () async {
      late _ControlledRoaming roaming;
      final fixture = await _RuntimeFixture.create(
        roamingFactory: (config, secrets) =>
            roaming = _ControlledRoaming(config, secrets),
        afterRoamingFrame: (_) => fail('Invalidated result must not be saved'),
      );
      addTearDown(fixture.runtime.dispose);
      await _enableRoaming(fixture.runtime);
      final event = _event(fixture);
      final restored = fixture.runtime.restoreEvent(event);
      await Future<void>.delayed(Duration.zero);
      await fixture.runtime.clearCache();
      roaming.result.complete(
        const TranslationRoamingLookup(
          TranslationRoamingLookupStatus.hit,
          translation: 'obsolete',
        ),
      );
      expect(await restored, isNull);
      expect(fixture.runtime.stateForEvent(event).value.translation, isNull);
      fixture.backend.unavailable = true;
      expect(await fixture.runtime.restoreEvent(event), isNull);
      expect(roaming.reads, 1);
    },
  );

  test(
    'a manual click upgrades a pending roaming miss in an auto-off room',
    () async {
      late _ControlledRoaming roaming;
      final api = _RecordingApiClient();
      final fixture = await _RuntimeFixture.create(
        apiClient: api,
        roamingFactory: (config, secrets) =>
            roaming = _ControlledRoaming(config, secrets),
        mergeWindowMs: 0,
      );
      addTearDown(fixture.runtime.dispose);
      await _enableRoaming(fixture.runtime);
      final event = _event(fixture);
      final restoration = fixture.runtime.restoreEvent(event);
      await Future<void>.delayed(Duration.zero);
      final manual = fixture.runtime.translateEvent(event, manual: true);
      await Future<void>.delayed(Duration.zero);
      roaming.result.complete(TranslationRoamingLookup.miss);
      expect(await manual, 'translated');
      expect(await restoration, 'translated');
      expect(api.calls, 1);
      expect(roaming.reads, 1);
    },
  );
}

Future<void> _enableRoaming(TranslationRuntime runtime) => runtime.saveRoaming(
  const TranslationRoamingConfig(enabled: true, host: 'redis.example.invalid'),
  TranslationRoamingSecrets(
    preSharedKey: TranslationRoamingCrypto.generatePreSharedKey(),
  ),
);

TranslationCacheKey _eventCacheKey(Event event) => TranslationCacheKey(
  userId: event.room.client.userID!,
  roomId: event.room.id,
  eventId: event.eventId,
  source: event.body,
  sourceLanguage: 'auto',
  targetLanguage: 'en',
  messageType: event.messageType,
);

Event _event(
  _RuntimeFixture fixture, {
  String id = r'$event',
  String room = '!room:test',
  String source = 'hello',
}) => Event(
  content: {'msgtype': MessageTypes.Text, 'body': source},
  type: EventTypes.Message,
  eventId: id,
  senderId: fixture.client.userID!,
  originServerTs: DateTime.utc(2026),
  room: Room(id: room, client: fixture.client),
);

Event _mediaEvent(
  _RuntimeFixture fixture, {
  String id = r'$media',
  String room = '!room:test',
  String messageType = MessageTypes.Image,
  String eventType = EventTypes.Message,
  String source = 'A caption',
  String? filename = 'attachment.bin',
  Map<String, Object?> extraContent = const {},
}) => Event(
  content: {
    'msgtype': messageType,
    'body': source,
    'filename': ?filename,
    ...extraContent,
  },
  type: eventType,
  eventId: id,
  senderId: fixture.client.userID!,
  originServerTs: DateTime.utc(2026),
  room: Room(id: room, client: fixture.client),
);

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
    TranslationRoamingServiceFactory? roamingFactory,
    void Function(void Function())? afterRoamingFrame,
    int mergeWindowMs = 100,
    InputTranslationMode inputMode = InputTranslationMode.disabled,
  }) async {
    SharedPreferences.setMockInitialValues({
      _enabledPreference: true,
      _privacyPreference: true,
      _providersPreference: TranslationProviderConfig.encodeList([_provider]),
      _selectedProviderPreference: _provider.id,
      _scopePreference: TranslationScope.none.name,
      _inputModePreference: inputMode.name,
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
      roamingFactory: roamingFactory,
      afterRoamingFrame: afterRoamingFrame,
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
  final TranslationProviderConfig provider;
  final Map<String, TranslationRequestMessage> messages;
  final result = Completer<Map<String, String>>();

  _PendingTranslation(this.provider, this.messages);

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
    final call = _PendingTranslation(provider, messages);
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
  Future<void> Function(String key)? beforeWrite;

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
  Future<void> write(String key, String value) async {
    final before = beforeWrite;
    if (before != null) await before(key);
    values[key] = value;
  }
}

class _MemoryBackend extends MemoryTranslationBackend {}

class _ImmediateRoaming extends TranslationRoamingService {
  int reads = 0;
  final uploads = <String>[];

  _ImmediateRoaming(
    TranslationRoamingConfig config,
    TranslationRoamingSecrets secrets,
  ) : super(config: config, secrets: secrets);

  @override
  Future<TranslationRoamingLookup> lookup({
    required String source,
    required String targetLanguage,
  }) async {
    reads++;
    return const TranslationRoamingLookup(
      TranslationRoamingLookupStatus.hit,
      translation: 'cloud translation',
    );
  }

  @override
  Future<void> upload({
    required String source,
    required String targetLanguage,
    required String translation,
    required bool Function() isValid,
  }) async {
    if (isValid()) uploads.add(translation);
  }
}

class _ControlledRoaming extends _ImmediateRoaming {
  final result = Completer<TranslationRoamingLookup>();

  _ControlledRoaming(super.config, super.secrets);

  @override
  Future<TranslationRoamingLookup> lookup({
    required String source,
    required String targetLanguage,
  }) {
    reads++;
    return result.future;
  }
}
