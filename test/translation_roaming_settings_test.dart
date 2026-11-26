// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_translation/translation_roaming_settings.dart';
import 'package:fluffychat/pages/settings_translation/translation_settings_layout.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/translation_test_backend.dart';

void main() {
  testWidgets('read-only checkbox leads its label above the action divider', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    for (final direction in TextDirection.values) {
      await _showRoaming(
        tester,
        fixture.runtime,
        width: 500,
        direction: direction,
      );
      final l10n = _l10n(tester);
      final generate = tester.getRect(
        _outlinedButton(l10n.translationRoamingGenerateKey),
      );
      final copy = tester.getRect(_outlinedButton(l10n.copyToClipboard));
      final readOnly = tester.getRect(find.byType(CheckboxListTile));
      final checkbox = tester.getRect(find.byType(Checkbox));
      final label = tester.getRect(find.text(l10n.translationRoamingReadOnly));
      final divider = tester.getRect(find.byType(Divider));
      final test = tester.getRect(_outlinedButton(l10n.test));
      final upload = tester.getRect(
        _outlinedButton(l10n.translationRoamingUploadLocal),
      );
      expect(readOnly.top, greaterThanOrEqualTo(generate.bottom));
      expect(readOnly.top, greaterThanOrEqualTo(copy.bottom));
      expect(divider.top, greaterThanOrEqualTo(readOnly.bottom));
      final labelGap = switch (direction) {
        TextDirection.ltr => label.left - checkbox.right,
        TextDirection.rtl => checkbox.left - label.right,
      };
      expect(labelGap, inInclusiveRange(0.0, 8.0));
      expect(test.top, greaterThanOrEqualTo(divider.bottom));
      expect(test.top, upload.top);
      expect(test.width, upload.width);
      final (left, right) = switch (direction) {
        TextDirection.ltr => (test, upload),
        TextDirection.rtl => (upload, test),
      };
      expect(left.left, divider.left);
      expect(right.right, divider.right);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrow pages stack full-width action buttons', (tester) async {
    final fixture = await _Fixture.create();
    for (final direction in TextDirection.values) {
      for (final width in [300.0, 250.0]) {
        await _showRoaming(
          tester,
          fixture.runtime,
          width: width,
          direction: direction,
        );
        final l10n = _l10n(tester);
        final divider = tester.getRect(find.byType(Divider));
        final test = tester.getRect(_outlinedButton(l10n.test));
        final upload = tester.getRect(
          _outlinedButton(l10n.translationRoamingUploadLocal),
        );
        final checkbox = tester.getRect(find.byType(Checkbox));
        final label = tester.getRect(
          find.text(l10n.translationRoamingReadOnly),
        );
        final labelGap = switch (direction) {
          TextDirection.ltr => label.left - checkbox.right,
          TextDirection.rtl => checkbox.left - label.right,
        };
        expect(labelGap, inInclusiveRange(0.0, 8.0));
        expect(test.left, divider.left);
        expect(test.right, divider.right);
        expect(test.top, greaterThanOrEqualTo(divider.bottom));
        expect(upload.left, divider.left);
        expect(upload.right, divider.right);
        expect(upload.top, greaterThan(test.bottom));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('large text stacks actions without layout mutations', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime, width: 500, textScale: 2);
    final l10n = _l10n(tester);
    final testFinder = _outlinedButton(l10n.test);
    final actions = tester.getRect(
      find.ancestor(
        of: testFinder,
        matching: find.byType(TranslationSettingsLayout),
      ),
    );
    final test = tester.getRect(testFinder);
    final upload = tester.getRect(
      _outlinedButton(l10n.translationRoamingUploadLocal),
    );
    expect(upload.top, greaterThan(test.bottom));
    expect(test.width, actions.width);
    expect(upload.width, actions.width);
    expect(tester.takeException(), isNull);

    await _showRoaming(tester, fixture.runtime, width: 500);
    expect(
      tester.getRect(_outlinedButton(l10n.test)).top,
      tester.getRect(_outlinedButton(l10n.translationRoamingUploadLocal)).top,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial disabled form stays visible without saving a key', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);

    expect(find.byType(TextField), findsWidgets);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.enabled, isFalse);
    }
    expect(find.byIcon(Icons.science_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    expect(find.text(l10n.invalidInput), findsNothing);
    expect(fixture.secrets.roamingWrites, 0);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
  });

  testWidgets('switch and fields only persist after explicitly saving', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);

    await _toggle(tester);
    await _enter(tester, l10n.translationRoamingHost, 'redis.example.invalid');
    expect(fixture.runtime.roamingConfig.enabled, isFalse);
    expect(fixture.runtime.roamingConfig.host, isEmpty);
    expect(fixture.secrets.roamingWrites, 0);
    expect(find.text(l10n.invalidInput), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, l10n.save));
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(fixture.runtime.roamingConfig.enabled, isTrue);
    expect(fixture.runtime.roamingConfig.host, 'redis.example.invalid');
    expect(fixture.secrets.roamingWrites, 1);
    expect(
      (await fixture.runtime.readRoamingSecrets()).preSharedKey,
      isNotEmpty,
    );
  });

  testWidgets('read-only draft blocks upload before saving and persists', (
    tester,
  ) async {
    final fixture = await _Fixture.create(configured: true);
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    final upload = _outlinedButton(l10n.translationRoamingUploadLocal);

    await _toggleReadOnly(tester);
    expect(fixture.runtime.roamingConfig.readOnly, isFalse);
    expect(tester.widget<OutlinedButton>(upload).onPressed, isNull);
    await tester.ensureVisible(upload);
    await tester.tap(upload);
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.translationRoamingReadOnlyUploadUnavailable),
      findsOneWidget,
    );
    expect(find.text(l10n.translationSaveBeforeUse), findsNothing);
    expect(find.text('Upload page'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, l10n.save));
    await tester.pumpAndSettle();
    expect(fixture.runtime.roamingConfig.readOnly, isTrue);
    expect(fixture.runtime.canUploadLocalTranslations, isFalse);
    expect(find.text('Translation settings'), findsOneWidget);

    await _showRoaming(tester, fixture.runtime);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    expect(tester.widget<OutlinedButton>(upload).onPressed, isNull);
  });

  testWidgets('read-only changes can dismiss the exit prompt or be discarded', (
    tester,
  ) async {
    final fixture = await _Fixture.create(configured: true);
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggleReadOnly(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translation_unsaved_discard')));
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(fixture.runtime.roamingConfig.readOnly, isFalse);
    expect(fixture.runtime.canUploadLocalTranslations, isTrue);
    expect(fixture.secrets.roamingWrites, 0);
  });

  testWidgets('restoring the read-only value avoids an exit prompt', (
    tester,
  ) async {
    final fixture = await _Fixture.create(configured: true);
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggleReadOnly(tester);
    await _toggleReadOnly(tester);

    expect(
      tester
          .widget<OutlinedButton>(
            _outlinedButton(l10n.translationRoamingUploadLocal),
          )
          .onPressed,
      isNotNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
    expect(fixture.secrets.roamingWrites, 0);
  });

  testWidgets('dirty back can dismiss the prompt or discard without writing', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggle(tester);
    await _enter(
      tester,
      l10n.translationRoamingHost,
      'unsaved.example.invalid',
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
    expect(find.byType(TranslationRoamingSettings), findsOneWidget);
    expect(
      _text(tester, l10n.translationRoamingHost),
      'unsaved.example.invalid',
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
    expect(find.byType(TranslationRoamingSettings), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translation_unsaved_discard')));
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(fixture.runtime.roamingConfig.enabled, isFalse);
    expect(fixture.runtime.roamingConfig.host, isEmpty);
    expect(fixture.secrets.roamingWrites, 0);
  });

  testWidgets('save from back prompt persists and returns to settings', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggle(tester);
    await _enter(tester, l10n.translationRoamingHost, 'saved.example.invalid');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(fixture.runtime.roamingConfig.host, 'saved.example.invalid');
    expect(fixture.runtime.roamingConfig.enabled, isTrue);
  });

  testWidgets('restoring values and switch avoids an exit prompt', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggle(tester);
    await _enter(tester, l10n.translationRoamingHost, 'temporary.invalid');
    await _enter(tester, l10n.translationRoamingHost, '');
    await _toggle(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
    expect(fixture.secrets.roamingWrites, 0);
  });

  testWidgets(
    'disabled save accepts empty fields and restores numeric defaults',
    (tester) async {
      final fixture = await _Fixture.create(configured: true);
      await _showRoaming(tester, fixture.runtime);
      final l10n = _l10n(tester);
      await _enter(tester, l10n.translationRoamingHost, '');
      await _enter(tester, l10n.translationRoamingPort, '');
      await _enter(tester, l10n.translationRoamingDatabase, '-1');
      await _enter(tester, l10n.translationRoamingRetentionDays, 'invalid');
      await _enter(tester, l10n.translationRoamingKeyPrefix, '');
      await _enter(tester, l10n.translationRoamingPreSharedKey, '');
      expect(find.text(l10n.invalidInput), findsNothing);
      await _toggle(tester);
      expect(fixture.runtime.roamingConfig.enabled, isTrue);
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.enabled, isFalse);
      }
      expect(
        tester.widget<OutlinedButton>(_outlinedButton(l10n.test)).onPressed,
        isNull,
      );

      await tester.tap(find.widgetWithText(FilledButton, l10n.save));
      await tester.pumpAndSettle();
      final config = fixture.runtime.roamingConfig;
      expect(config.enabled, isFalse);
      expect(config.host, isEmpty);
      expect(config.keyPrefix, isEmpty);
      expect(config.port, 6379);
      expect(config.database, 0);
      expect(config.retentionDays, 30);
      expect(
        (await fixture.runtime.readRoamingSecrets()).preSharedKey,
        isEmpty,
      );
      expect(find.text('Translation settings'), findsOneWidget);
    },
  );

  testWidgets('invalid enabled save from prompt preserves draft and page', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggle(tester);
    await _enter(tester, l10n.translationRoamingPort, '');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();

    expect(find.byType(TranslationRoamingSettings), findsOneWidget);
    expect(find.text(l10n.invalidInput), findsWidgets);
    expect(_text(tester, l10n.translationRoamingPort), isEmpty);
    expect(fixture.secrets.roamingWrites, 0);
    expect(fixture.runtime.roamingConfig.enabled, isFalse);
  });

  testWidgets('failed save keeps changes available for another exit decision', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    await _toggle(tester);
    await _enter(
      tester,
      l10n.translationRoamingHost,
      'unsaved.example.invalid',
    );
    fixture.secrets.failRoamingWrites = true;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.byType(TranslationRoamingSettings), findsOneWidget);
    expect(
      _text(tester, l10n.translationRoamingHost),
      'unsaved.example.invalid',
    );
    expect(find.text(l10n.oopsSomethingWentWrong), findsWidgets);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationUnsavedChanges), findsOneWidget);
  });

  testWidgets(
    'dirty upload looks disabled and explains that saving is required',
    (tester) async {
      final fixture = await _Fixture.create(configured: true);
      await _showRoaming(tester, fixture.runtime);
      final l10n = _l10n(tester);
      final upload = _outlinedButton(l10n.translationRoamingUploadLocal);
      expect(tester.widget<OutlinedButton>(upload).onPressed, isNotNull);
      await tester.ensureVisible(upload);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(upload));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(l10n.translationSaveBeforeUse), findsNothing);
      await mouse.moveTo(Offset.zero);

      await _enter(
        tester,
        l10n.translationRoamingHost,
        'changed.example.invalid',
      );
      expect(tester.widget<OutlinedButton>(upload).onPressed, isNull);
      await tester.ensureVisible(upload);
      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(find.text(l10n.translationSaveBeforeUse), findsOneWidget);
      expect(find.text('Upload page'), findsNothing);
      expect(fixture.runtime.roamingConfig.host, 'redis.example.invalid');
    },
  );

  testWidgets('an initially generated key blocks upload until it is saved', (
    tester,
  ) async {
    final fixture = await _Fixture.create(configured: true, savedKey: false);
    await _showRoaming(tester, fixture.runtime);
    final l10n = _l10n(tester);
    final upload = _outlinedButton(l10n.translationRoamingUploadLocal);
    expect(tester.widget<OutlinedButton>(upload).onPressed, isNull);
    await tester.ensureVisible(upload);
    await tester.tap(upload);
    await tester.pumpAndSettle();
    expect(find.text(l10n.translationSaveBeforeUse), findsOneWidget);
    expect(fixture.secrets.roamingWrites, 0);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Translation settings'), findsOneWidget);
    expect(find.text(l10n.translationUnsavedChanges), findsNothing);
  });

  testWidgets('connection test uses the draft and never saves it', (
    tester,
  ) async {
    final runtime = _TestingRuntime();
    final fixture = await _Fixture.create(runtime: runtime);
    await _showRoaming(tester, runtime);
    final l10n = _l10n(tester);
    await _toggle(tester);
    await _enter(tester, l10n.translationRoamingHost, 'draft.example.invalid');
    await _toggleReadOnly(tester);
    final button = _outlinedButton(l10n.test);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(find.text(l10n.test), findsOneWidget);
    expect(find.byIcon(Icons.science_outlined), findsNothing);
    expect(runtime.testedConfig!.host, 'draft.example.invalid');
    expect(runtime.testedConfig!.readOnly, isTrue);
    expect(runtime.roamingConfig.enabled, isFalse);
    expect(runtime.roamingConfig.readOnly, isFalse);
    expect(fixture.secrets.roamingWrites, 0);
    expect(
      find.descendant(
        of: button,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    runtime.completed.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.science_outlined), findsOneWidget);
    expect(find.text(l10n.test), findsOneWidget);
    expect(fixture.secrets.roamingWrites, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _showRoaming(
  WidgetTester tester,
  TranslationRuntime runtime, {
  double? width,
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
}) async {
  final router = GoRouter(
    initialLocation: '/rooms/settings/translation/roaming',
    routes: [
      GoRoute(
        path: '/rooms/settings/translation',
        builder: (_, _) => const Scaffold(body: Text('Translation settings')),
        routes: [
          GoRoute(
            path: 'roaming',
            builder: (_, _) => AnimatedBuilder(
              animation: runtime,
              builder: (_, _) => TranslationRoamingSettings(runtime: runtime),
            ),
            routes: [
              GoRoute(
                path: 'upload',
                builder: (_, _) => const Scaffold(body: Text('Upload page')),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      key: UniqueKey(),
      routerConfig: router,
      locale: const Locale('en'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Directionality(
          textDirection: direction,
          child: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

L10n _l10n(WidgetTester tester) =>
    L10n.of(tester.element(find.byType(TranslationRoamingSettings)));

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

Finder _outlinedButton(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
);

Future<void> _toggle(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(SwitchListTile));
  await tester.tap(find.byType(SwitchListTile));
  await tester.pumpAndSettle();
}

Future<void> _toggleReadOnly(WidgetTester tester) async {
  final label = find.text(_l10n(tester).translationRoamingReadOnly);
  await tester.ensureVisible(label);
  await tester.tap(label);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final field = _field(label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

class _Fixture {
  final TranslationRuntime runtime;
  final _RoamingSecrets secrets;

  const _Fixture(this.runtime, this.secrets);

  static Future<_Fixture> create({
    bool configured = false,
    bool savedKey = true,
    TranslationRuntime? runtime,
  }) async {
    const config = TranslationRoamingConfig(
      enabled: true,
      host: 'redis.example.invalid',
    );
    SharedPreferences.setMockInitialValues({
      if (configured) ...{
        TranslationRoamingPreferences.configKey: jsonEncode(config.toJson()),
        'chat.fluffy.translation.enabled': true,
        'chat.fluffy.translation.privacy_accepted': true,
      },
    });
    final secrets = _RoamingSecrets();
    if (configured && savedKey) {
      secrets.values[TranslationRoamingPreferences.secretsKey] = jsonEncode({
        'redisPassword': '',
        'restToken': '',
        'preSharedKey': TranslationRoamingCrypto.generatePreSharedKey(),
      });
    }
    final activeRuntime = runtime ?? TranslationRuntime.forTesting();
    addTearDown(activeRuntime.dispose);
    await activeRuntime.initialize(
      await SharedPreferences.getInstance(),
      secrets: secrets,
      cache: TranslationCache(secrets, MemoryTranslationBackend()),
    );
    return _Fixture(activeRuntime, secrets);
  }
}

class _RoamingSecrets implements TranslationSecretStore {
  final values = <String, String>{};
  int roamingWrites = 0;
  bool failRoamingWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == TranslationRoamingPreferences.secretsKey) {
      if (failRoamingWrites) throw StateError('Secret store unavailable');
      roamingWrites++;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _TestingRuntime extends TranslationRuntime {
  final completed = Completer<void>();
  TranslationRoamingConfig? testedConfig;

  _TestingRuntime() : super.forTesting();

  @override
  Future<void> testRoaming(
    TranslationRoamingConfig config,
    TranslationRoamingSecrets secrets,
  ) {
    testedConfig = config;
    return completed.future;
  }
}
