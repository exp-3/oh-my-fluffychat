// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_translation/translation_roaming_settings.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/translation_test_backend.dart';

void main() {
  testWidgets('roaming autosaves valid edits and closes with invalid input', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    final secrets = _RoamingSecrets();
    final runtime = TranslationRuntime.forTesting();
    addTearDown(runtime.dispose);
    await runtime.initialize(
      store,
      secrets: secrets,
      cache: TranslationCache(secrets, MemoryTranslationBackend()),
    );
    await _showRoaming(tester, runtime);
    await tester.pumpAndSettle();
    final l10n = L10n.of(
      tester.element(find.byType(TranslationRoamingSettings)),
    );
    final toggle = find.byType(SwitchListTile);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(runtime.roamingConfig.enabled, isTrue);
    expect(runtime.roamingConfig.isValid, isFalse);
    expect(find.text(l10n.translationRoamingGenerateKey), findsOneWidget);
    expect(find.text(l10n.test), findsOneWidget);

    await _enter(tester, l10n.translationRoamingHost, 'redis.example.invalid');
    expect(runtime.roamingConfig.host, 'redis.example.invalid');
    expect(runtime.roamingConfig.isValid, isTrue);
    final savedSecrets =
        secrets.values[TranslationRoamingPreferences.secretsKey];
    expect(savedSecrets, isNotNull);

    await _enter(tester, l10n.translationRoamingPort, '');
    await _enter(
      tester,
      l10n.translationRoamingHost,
      'changed.example.invalid',
    );
    expect(find.text(l10n.invalidInput), findsOneWidget);
    expect(runtime.roamingConfig.port, 6379);
    expect(runtime.roamingConfig.host, 'redis.example.invalid');

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(runtime.roamingConfig.enabled, isFalse);
    expect(find.byType(TextField), findsNothing);
    expect(find.text(l10n.test), findsNothing);
    expect(find.text(l10n.translationRoamingGenerateKey), findsNothing);
    expect(
      secrets.values[TranslationRoamingPreferences.secretsKey],
      savedSecrets,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(_field(l10n.translationRoamingPort))
          .controller!
          .text,
      isEmpty,
    );
    await _enter(tester, l10n.translationRoamingPort, '6380');
    expect(runtime.roamingConfig.port, 6380);
    expect(runtime.roamingConfig.host, 'changed.example.invalid');
    expect(find.text(l10n.invalidInput), findsNothing);

    final writeGate = Completer<void>();
    addTearDown(() {
      if (!writeGate.isCompleted) writeGate.complete();
    });
    secrets.writeGate = writeGate;
    await tester.ensureVisible(_field(l10n.translationRoamingHost));
    await tester.enterText(
      _field(l10n.translationRoamingHost),
      'reopened.example.invalid',
    );
    await tester.pump();
    await tester.ensureVisible(_field(l10n.password));
    await tester.enterText(_field(l10n.password), 'updated-password');
    await _showRoaming(tester, runtime);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(toggle);
    secrets.writeGate = null;
    writeGate.complete();
    await tester.pumpAndSettle();
    expect(runtime.roamingConfig.enabled, isFalse);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(_field(l10n.translationRoamingHost))
          .controller!
          .text,
      'reopened.example.invalid',
    );
    expect(
      tester.widget<TextField>(_field(l10n.password)).controller!.text,
      'updated-password',
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _showRoaming(
  WidgetTester tester,
  TranslationRuntime runtime,
) => tester.pumpWidget(
  MaterialApp(
    key: UniqueKey(),
    locale: const Locale('en'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: TranslationRoamingSettings(runtime: runtime),
      ),
    ),
  ),
);

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final field = _field(label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

class _RoamingSecrets implements TranslationSecretStore {
  final values = <String, String>{};
  Completer<void>? writeGate;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == TranslationRoamingPreferences.secretsKey) {
      await writeGate?.future;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}
