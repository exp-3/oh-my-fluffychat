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
  static const _providersKey = 'chat.fluffy.translation.providers';
  static const _selectedProviderKey =
      'chat.fluffy.translation.selected_provider';
  static const _privacyAcceptedKey = 'chat.fluffy.translation.privacy_accepted';
  static const _roomSelectionPrefix = 'chat.fluffy.translation.selected_room.';
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
  TranslationScope get scope => _enumValue(
    TranslationScope.values,
    store.getString(_scopeKey),
    TranslationScope.manualOnly,
  );
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
  String? get targetLanguage => store.getString(_targetLanguageKey);
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

  bool roomSelected(String userId, String roomId) =>
      store.getBool(_roomKey(userId, roomId)) ?? false;

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
  Future<void> setTargetLanguage(String value) =>
      store.setString(_targetLanguageKey, value);
  Future<void> acceptPrivacyNotice() =>
      store.setBool(_privacyAcceptedKey, true);
  Future<void> selectProvider(String? id) => id == null
      ? store.remove(_selectedProviderKey)
      : store.setString(_selectedProviderKey, id);
  Future<void> saveProviders(List<TranslationProviderConfig> value) => store
      .setString(_providersKey, TranslationProviderConfig.encodeList(value));
  Future<void> setRoomSelected(String userId, String roomId, bool value) =>
      store.setBool(_roomKey(userId, roomId), value);

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
}
