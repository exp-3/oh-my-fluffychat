// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'translation_preferences.dart';
import 'translation_roaming_models.dart';

class TranslationRoamingPreferences {
  static const configKey = 'chat.fluffy.translation.roaming.config';
  static const secretsKey = 'chat.fluffy.translation.roaming.secrets';

  final SharedPreferences store;
  final TranslationSecretStore secrets;
  late final TranslationRoamingReadState readState =
      TranslationRoamingReadState(store);

  TranslationRoamingPreferences(this.store, this.secrets);

  TranslationRoamingConfig get config {
    try {
      final encoded = store.getString(configKey);
      if (encoded == null) return const TranslationRoamingConfig();
      return TranslationRoamingConfig.fromJson(
        (jsonDecode(encoded) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return const TranslationRoamingConfig();
    }
  }

  Future<TranslationRoamingSecrets> readSecrets() async {
    try {
      final encoded = await secrets.read(secretsKey);
      if (encoded == null) return const TranslationRoamingSecrets();
      final json = (jsonDecode(encoded) as Map).cast<String, Object?>();
      return TranslationRoamingSecrets(
        redisPassword: json['redisPassword'] is String
            ? json['redisPassword']! as String
            : '',
        restToken: json['restToken'] is String
            ? json['restToken']! as String
            : '',
        preSharedKey: json['preSharedKey'] is String
            ? json['preSharedKey']! as String
            : '',
      );
    } catch (_) {
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
  }

  /// Changes only the ordinary configuration; enabling may precede setup.
  Future<TranslationRoamingConfig> saveEnabled(bool enabled) async {
    final value = config.copyWith(enabled: enabled);
    if (!value.hasSafeEndpoint) {
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
    try {
      if (!await store.setString(configKey, jsonEncode(value.toJson()))) {
        throw const TranslationRoamingException(
          TranslationRoamingError.configuration,
        );
      }
    } catch (_) {
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
    await readState.reset();
    return value;
  }

  Future<void> save(
    TranslationRoamingConfig config,
    TranslationRoamingSecrets value,
  ) async {
    if (!config.hasSafeEndpoint ||
        (config.enabled &&
            (!config.isValid ||
                !config.supportedOnPlatform ||
                !value.isValidFor(config)))) {
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
    String? previous;
    var written = false;
    try {
      previous = await secrets.read(secretsKey);
      await secrets.write(
        secretsKey,
        jsonEncode({
          'redisPassword': value.redisPassword,
          'restToken': value.restToken,
          'preSharedKey': value.preSharedKey.trim(),
        }),
      );
      written = true;
      if (!await store.setString(configKey, jsonEncode(config.toJson()))) {
        throw const TranslationRoamingException(
          TranslationRoamingError.configuration,
        );
      }
    } catch (_) {
      if (written) {
        try {
          await (previous == null
              ? secrets.delete(secretsKey)
              : secrets.write(secretsKey, previous));
        } catch (_) {
          // Do not reactivate an old connection with partially saved secrets.
          try {
            await store.remove(configKey);
          } catch (_) {
            // Report only the classified failure below, never plugin details.
          }
        }
      }
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
    await readState.reset();
  }
}

class TranslationRoamingReadState {
  static const _disabledKey = 'chat.fluffy.translation.roaming.getex_disabled';

  final SharedPreferences? _store;
  int _failures = 0;
  int _generation = 0;
  bool _getExDisabled = false;
  Future<void> _writeTail = Future.value();

  TranslationRoamingReadState([this._store]) {
    try {
      _getExDisabled = _store?.getBool(_disabledKey) ?? false;
    } catch (_) {
      _getExDisabled = false;
    }
  }

  bool get getExDisabled => _getExDisabled;
  int get generation => _generation;

  Future<void> recordFallback(int generation) {
    if (generation != _generation || _getExDisabled) return _writeTail;
    _failures++;
    if (_failures < 10) return _writeTail;
    _getExDisabled = true;
    return _persist(true);
  }

  Future<void> reset() {
    _generation++;
    _failures = 0;
    _getExDisabled = false;
    return _persist(false);
  }

  Future<void> _persist(bool disabled) {
    final store = _store;
    if (store == null) return Future.value();
    final operation = _writeTail.then((_) async {
      if (disabled) {
        await store.setBool(_disabledKey, true);
        return;
      }
      await store.remove(_disabledKey);
    });
    return _writeTail = operation.catchError((Object _) {});
  }
}
