// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_translation/settings_translation.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/translation_test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final runtime = TranslationRuntime.instance;
  final secrets = _PreviewSecrets();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.translation.enabled': true,
      'chat.fluffy.translation.privacy_accepted': true,
      'chat.fluffy.translation.input.source_language': 'auto',
      'chat.fluffy.translation.input.target_language': 'en',
      TranslationRoamingPreferences.configKey: jsonEncode(
        const TranslationRoamingConfig(host: 'redis.example.invalid').toJson(),
      ),
    });
    await runtime.initialize(
      await SharedPreferences.getInstance(),
      secrets: secrets,
      cache: TranslationCache(secrets, MemoryTranslationBackend()),
    );
  });

  tearDownAll(runtime.dispose);

  testWidgets('input preview follows both input translation switches', (
    tester,
  ) async {
    await _showSettings(tester);
    final l10n = L10n.of(tester.element(find.byType(SettingsTranslation)));
    final entry = _entry(l10n.inputTranslation);

    for (final mode in InputTranslationMode.values) {
      await runtime.setInputMode(mode);
      await tester.pumpAndSettle();
      final subtitle = tester.widget<ListTile>(entry).subtitle! as Text;
      expect(
        subtitle.data,
        mode == InputTranslationMode.disabled
            ? l10n.roomTranslationAlwaysOff
            : '${l10n.translationAutoDetect} → English',
        reason: 'Input mode: $mode',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('roaming preview follows the saved switch and connection type', (
    tester,
  ) async {
    await tester.runAsync(() => runtime.setRoamingEnabled(false));
    await _showSettings(tester);
    final l10n = L10n.of(tester.element(find.byType(SettingsTranslation)));
    final entry = _entry(l10n.translationRoaming);
    expect(
      (tester.widget<ListTile>(entry).subtitle! as Text).data,
      l10n.roomTranslationAlwaysOff,
    );

    final roamingSecrets = TranslationRoamingSecrets(
      restToken: 'test-token',
      preSharedKey: TranslationRoamingCrypto.generatePreSharedKey(),
    );
    for (final type in TranslationRoamingType.values) {
      await tester.runAsync(
        () => runtime.saveRoaming(
          runtime.roamingConfig.copyWith(
            enabled: true,
            type: type,
            endpoint: 'https://cache.example.invalid',
          ),
          roamingSecrets,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (tester.widget<ListTile>(entry).subtitle! as Text).data,
        type == TranslationRoamingType.redis
            ? l10n.translationRoamingNative
            : l10n.translationRoamingUpstash,
      );
    }

    await tester.runAsync(() => runtime.setRoamingEnabled(false));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<ListTile>(entry).subtitle! as Text).data,
      l10n.roomTranslationAlwaysOff,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic translation scopes fit a narrow settings page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _showSettings(tester);
    final l10n = L10n.of(tester.element(find.byType(SettingsTranslation)));
    final dropdown = find.byType(DropdownButtonFormField<TranslationScope>);
    expect(tester.takeException(), isNull);

    for (final (scope, label) in [
      (TranslationScope.none, l10n.translationScopeNone),
      (TranslationScope.allRooms, l10n.translationScopeAllRooms),
      (
        TranslationScope.unencryptedRooms,
        l10n.translationScopeUnencryptedRooms,
      ),
    ]) {
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Open scope: $scope');
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(runtime.scope, scope);
      expect(tester.takeException(), isNull, reason: 'Selected scope: $scope');
    }
  });
}

Future<void> _showSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      locale: const Locale('en'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: const SettingsTranslation(),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _entry(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is ListTile &&
      widget.title is Text &&
      (widget.title! as Text).data == title,
);

class _PreviewSecrets implements TranslationSecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
