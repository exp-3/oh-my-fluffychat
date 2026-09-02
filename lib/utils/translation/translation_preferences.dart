// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'translation_models.dart';

abstract interface class TranslationSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureTranslationSecretStore implements TranslationSecretStore {
  final FlutterSecureStorage storage;

  const SecureTranslationSecretStore([
    this.storage = const FlutterSecureStorage(),
  ]);

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class TranslationPreferences {
  static const _enabledKey = 'chat.fluffy.translation.enabled';
  static const _scopeKey = 'chat.fluffy.translation.scope';
  static const _displayModeKey = 'chat.fluffy.translation.display_mode';
  static const _bilingualColorKey = 'chat.fluffy.translation.bilingual_color';
  static const _bilingualStyleKey = 'chat.fluffy.translation.bilingual_layout';
  static const _legacyBilingualStyleKey =
      'chat.fluffy.translation.bilingual_style';
  static const _targetLanguageKey = 'chat.fluffy.translation.target_language';
  static const _sourceLanguageKey = 'chat.fluffy.translation.source_language';
  static const _preferRoomLanguageForSourceKey =
      'chat.fluffy.translation.prefer_room_language_source';
  static const _preferRoomLanguageForInputTargetKey =
      'chat.fluffy.translation.prefer_room_language_input_target';
  static const _inputModeKey = 'chat.fluffy.translation.input.mode';
  static const _inputScopeKey = 'chat.fluffy.translation.input.scope';
  static const _inputSourceLanguageKey =
      'chat.fluffy.translation.input.source_language';
  static const _inputTargetLanguageKey =
      'chat.fluffy.translation.input.target_language';
  static const _inputTriggerKey = 'chat.fluffy.translation.input.trigger';
  static const _inputSendModeKey = 'chat.fluffy.translation.input.send_mode';
  static const _providersKey = 'chat.fluffy.translation.providers';
  static const _selectedProviderKey =
      'chat.fluffy.translation.selected_provider';
  static const _privacyAcceptedKey = 'chat.fluffy.translation.privacy_accepted';
  static const _roomSelectionPrefix = 'chat.fluffy.translation.selected_room.';
  static const _roomLanguagePrefix = 'chat.fluffy.translation.room_language.';
  static const _mergeWindowKey = 'chat.fluffy.translation.batch.merge_ms';
  static const _maxMessagesKey = 'chat.fluffy.translation.batch.max_messages';
  static const _maxCharactersKey =
      'chat.fluffy.translation.batch.max_characters';
  static const _retryKey = 'chat.fluffy.translation.batch.structure_retries';
  static const _apiKeyPrefix = 'chat.fluffy.translation.provider_api_key.';

  final SharedPreferences store;
  final TranslationSecretStore secrets;

  const TranslationPreferences(this.store, this.secrets);

  bool get enabled => store.getBool(_enabledKey) ?? false;
  TranslationScope get scope {
    final saved = _enumValue(
      TranslationScope.values,
      store.getString(_scopeKey),
      TranslationScope.none,
    );
    return switch (saved) {
      TranslationScope.allRooms => TranslationScope.allRooms,
      TranslationScope.unencryptedRooms => TranslationScope.unencryptedRooms,
      TranslationScope.none => TranslationScope.none,
    };
  }

  TranslationDisplayMode get displayMode => _enumValue(
    TranslationDisplayMode.values,
    store.getString(_displayModeKey),
    TranslationDisplayMode.bilingual,
  );
  TranslationBilingualColor get bilingualColor => _enumValue(
    TranslationBilingualColor.values,
    store.getString(_bilingualColorKey) ??
        store.getString(_legacyBilingualStyleKey),
    TranslationBilingualColor.tertiary,
  );
  TranslationBilingualStyle get bilingualStyle {
    final saved = store.getString(_bilingualStyleKey);
    if (saved != null) {
      return _enumValue(
        TranslationBilingualStyle.values,
        saved,
        TranslationBilingualStyle.divider,
      );
    }
    return store.getString(_legacyBilingualStyleKey) == 'background'
        ? TranslationBilingualStyle.background
        : TranslationBilingualStyle.divider;
  }

  String get sourceLanguage => store.getString(_sourceLanguageKey) ?? 'auto';
  bool get preferRoomLanguageForSource =>
      store.getBool(_preferRoomLanguageForSourceKey) ?? false;
  bool get preferRoomLanguageForInputTarget =>
      store.getBool(_preferRoomLanguageForInputTargetKey) ?? true;
  String? get targetLanguage => store.getString(_targetLanguageKey);
  InputTranslationMode get inputMode => _enumValue(
    InputTranslationMode.values,
    store.getString(_inputModeKey),
    InputTranslationMode.disabled,
  );
  TranslationInputMode get inputTranslationMode => inputMode;
  InputTranslationScope get inputScope => _enumValue(
    InputTranslationScope.values,
    store.getString(_inputScopeKey),
    InputTranslationScope.automaticRooms,
  );
  TranslationInputScope get inputTranslationScope => inputScope;
  String get inputSourceLanguage =>
      store.getString(_inputSourceLanguageKey) ?? 'auto';
  String get inputTranslationSourceLanguage => inputSourceLanguage;
  String? get inputTargetLanguage => store.getString(_inputTargetLanguageKey);
  String? get inputTranslationTargetLanguage => inputTargetLanguage;
  InputTranslationTrigger get inputTrigger => _enumValue(
    InputTranslationTrigger.values,
    store.getString(_inputTriggerKey),
    InputTranslationTrigger.button,
  );
  TranslationInputTrigger get inputTranslationTrigger => inputTrigger;
  InputTranslationSendMode get inputSendMode => _enumValue(
    InputTranslationSendMode.values,
    store.getString(_inputSendModeKey),
    InputTranslationSendMode.shortOriginalLongTranslated,
  );
  TranslationInputSendMode get inputTranslationSendMode => inputSendMode;
  InputTranslationAutoSendMode get inputTranslationAutoSendMode =>
      inputSendMode;
  bool get privacyAccepted => store.getBool(_privacyAcceptedKey) ?? false;
  String? get selectedProviderId => store.getString(_selectedProviderKey);
  List<TranslationProviderConfig> get providers =>
      TranslationProviderConfig.decodeList(store.getString(_providersKey));

  TranslationBatchSettings get batchSettings => TranslationBatchSettings(
    mergeWindowMs:
        store.getInt(_mergeWindowKey) ??
        TranslationBatchSettings.defaults.mergeWindowMs,
    maxMessages:
        store.getInt(_maxMessagesKey) ??
        TranslationBatchSettings.defaults.maxMessages,
    maxCharacters:
        store.getInt(_maxCharactersKey) ??
        TranslationBatchSettings.defaults.maxCharacters,
    malformedResponseRetries:
        store.getInt(_retryKey) ??
        TranslationBatchSettings.defaults.malformedResponseRetries,
  );

  /// The per-room automatic translation override. Null means follow default.
  bool? roomTranslationOverride(String userId, String roomId) =>
      store.getBool(_roomKey(userId, roomId));

  @Deprecated('Use roomTranslationOverride')
  bool roomSelected(String userId, String roomId) =>
      roomTranslationOverride(userId, roomId) ?? false;

  String? roomLanguage(String userId, String roomId) =>
      store.getString(_roomLanguageKey(userId, roomId));

  Future<void> setEnabled(bool value) => store.setBool(_enabledKey, value);
  Future<void> setScope(TranslationScope value) =>
      store.setString(_scopeKey, value.name);
  Future<void> setDisplayMode(TranslationDisplayMode value) =>
      store.setString(_displayModeKey, value.name);
  Future<void> setBilingualColor(TranslationBilingualColor value) =>
      store.setString(_bilingualColorKey, value.name);
  Future<void> setBilingualStyle(TranslationBilingualStyle value) =>
      store.setString(_bilingualStyleKey, value.name);
  Future<void> setSourceLanguage(String value) =>
      store.setString(_sourceLanguageKey, value);
  Future<void> setPreferRoomLanguageForSource(bool value) =>
      store.setBool(_preferRoomLanguageForSourceKey, value);
  Future<void> setPreferRoomLanguageForInputTarget(bool value) =>
      store.setBool(_preferRoomLanguageForInputTargetKey, value);
  Future<void> setTargetLanguage(String value) =>
      store.setString(_targetLanguageKey, value);
  Future<void> setInputMode(InputTranslationMode value) =>
      store.setString(_inputModeKey, value.name);
  Future<void> setInputScope(InputTranslationScope value) =>
      store.setString(_inputScopeKey, value.name);
  Future<void> setInputSourceLanguage(String value) =>
      store.setString(_inputSourceLanguageKey, value);
  Future<void> setInputTargetLanguage(String value) =>
      store.setString(_inputTargetLanguageKey, value);
  Future<void> setInputTrigger(InputTranslationTrigger value) =>
      store.setString(_inputTriggerKey, value.name);
  Future<void> setInputSendMode(InputTranslationSendMode value) =>
      store.setString(_inputSendModeKey, value.name);
  Future<void> setInputTranslationSendMode(TranslationInputSendMode value) =>
      setInputSendMode(value);
  Future<void> acceptPrivacyNotice() =>
      store.setBool(_privacyAcceptedKey, true);
  Future<void> selectProvider(String? id) => id == null
      ? store.remove(_selectedProviderKey)
      : store.setString(_selectedProviderKey, id);
  Future<void> saveProviders(List<TranslationProviderConfig> value) => store
      .setString(_providersKey, TranslationProviderConfig.encodeList(value));
  Future<void> setRoomSelected(String userId, String roomId, bool value) =>
      store.setBool(_roomKey(userId, roomId), value);

  Future<void> setRoomTranslationOverride(
    String userId,
    String roomId,
    bool? value,
  ) => value == null
      ? store.remove(_roomKey(userId, roomId))
      : store.setBool(_roomKey(userId, roomId), value);

  Future<void> setRoomLanguage(String userId, String roomId, String? value) =>
      value == null || value.trim().isEmpty
      ? store.remove(_roomLanguageKey(userId, roomId))
      : store.setString(_roomLanguageKey(userId, roomId), value.trim());

  Future<void> saveBatchSettings(TranslationBatchSettings value) async {
    if (!value.isValid) throw ArgumentError.value(value, 'value');
    await Future.wait([
      store.setInt(_mergeWindowKey, value.mergeWindowMs),
      store.setInt(_maxMessagesKey, value.maxMessages),
      store.setInt(_maxCharactersKey, value.maxCharacters),
      store.setInt(_retryKey, value.malformedResponseRetries),
    ]);
  }

  Future<String?> readApiKey(String providerId) =>
      secrets.read('$_apiKeyPrefix$providerId');
  Future<void> writeApiKey(String providerId, String value) =>
      secrets.write('$_apiKeyPrefix$providerId', value);
  Future<void> deleteApiKey(String providerId) =>
      secrets.delete('$_apiKeyPrefix$providerId');

  static T _enumValue<T extends Enum>(
    List<T> values,
    String? name,
    T fallback,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  static String _roomKey(String userId, String roomId) =>
      '$_roomSelectionPrefix${base64UrlEncode(utf8.encode(jsonEncode([userId, roomId])))}';

  static String _roomLanguageKey(String userId, String roomId) =>
      '$_roomLanguagePrefix${base64UrlEncode(utf8.encode(jsonEncode([userId, roomId])))}';
}
