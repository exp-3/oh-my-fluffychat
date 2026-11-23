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
          if (previous == null) {
            await secrets.delete(secretsKey);
          } else {
            await secrets.write(secretsKey, previous);
          }
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
  }
}
