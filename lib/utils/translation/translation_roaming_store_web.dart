// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'translation_roaming_models.dart';
import 'translation_roaming_store.dart';

// Used by the Web conditional import; native unused-code scans miss this class.
// ignore: unused-code
class NativeTranslationRoamingStore implements TranslationRoamingStore {
  NativeTranslationRoamingStore(
    TranslationRoamingConfig config,
    String password,
  );

  Never _unsupported() => throw const TranslationRoamingException(
    TranslationRoamingError.unsupportedPlatform,
  );

  @override
  Future<String?> get(String key) async => _unsupported();

  @override
  Future<String?> getEx(String key, int ttlSeconds) async => _unsupported();

  @override
  Future<void> set(String key, String value, int ttlSeconds) async =>
      _unsupported();

  @override
  Future<bool> setIfAbsent(String key, String value, int ttlSeconds) async =>
      _unsupported();

  @override
  Future<void> delete(String key) async => _unsupported();

  @override
  void reset() {}

  @override
  void dispose() {}
}
