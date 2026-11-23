// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'translation_roaming_models.dart';
import 'translation_roaming_store.dart';
import 'translation_roaming_store_native.dart'
    if (dart.library.js_interop) 'translation_roaming_store_web.dart';
import 'translation_roaming_store_rest.dart';

TranslationRoamingStore createTranslationRoamingStore(
  TranslationRoamingConfig config, {
  required String redisPassword,
  required String restToken,
}) => switch (config.type) {
  TranslationRoamingType.redis => NativeTranslationRoamingStore(
    config,
    redisPassword,
  ),
  TranslationRoamingType.upstash => RestTranslationRoamingStore(
    endpoint: Uri.parse(config.endpoint.trim()),
    token: restToken,
  ),
};
