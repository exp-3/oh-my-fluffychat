// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_translation/settings_translation.dart';
import 'package:fluffychat/utils/translation/translation_api_client.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/translation_test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final runtime = TranslationRuntime.instance;
  late final _ProviderApiClient api;
  final secrets = _ProviderSecrets();
  final existing = TranslationProviderConfig(
    id: 'existing-provider',
    name: 'Existing Anthropic proxy',
    endpoint: Uri.parse('https://proxy.example.invalid/v1/messages'),
    protocol: TranslationProtocol.anthropicMessages,
    model: 'claude-example',
    reasoningEffort: TranslationReasoningEffort.high,
  );

  setUpAll(() async {
    api = _ProviderApiClient();
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.translation.providers': TranslationProviderConfig.encodeList(
        [existing],
      ),
    });
    await runtime.initialize(
      await SharedPreferences.getInstance(),
      secrets: secrets,
      apiClient: api,
      cache: TranslationCache(secrets, MemoryTranslationBackend()),
    );
  });

  tearDownAll(runtime.dispose);

  tearDown(() {
    secrets.failWrites = false;
    secrets.pendingRead = null;
  });

  for (final systemBack in [false, true]) {
    testWidgets(
      '${systemBack ? 'system' : 'toolbar'} back leaves a reverted draft directly',
      (tester) async {
        await _showProvider(tester);
        await tester.enterText(find.byType(TextField).at(0), 'Temporary name');
        await tester.enterText(find.byType(TextField).at(0), '');
        await _back(tester, systemBack: systemBack);
        expect(find.text('Saved'), findsOneWidget);
        expect(find.byKey(const Key('translation_unsaved_save')), findsNothing);
      },
    );

    testWidgets(
      '${systemBack ? 'system' : 'toolbar'} back prompts and dismissal keeps edits',
      (tester) async {
        await _showProvider(tester);
        await tester.enterText(find.byType(TextField).at(0), 'Unsaved draft');
        await _back(tester, systemBack: systemBack);
        expect(
          find.byKey(const Key('translation_unsaved_save')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('translation_unsaved_discard')),
          findsOneWidget,
        );

        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translation_unsaved_save')), findsNothing);
        expect(find.byType(SettingsTranslationProvider), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(0))
              .controller!
              .text,
          'Unsaved draft',
        );

        await _back(tester, systemBack: systemBack);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translation_unsaved_save')), findsNothing);
        expect(find.byType(SettingsTranslationProvider), findsOneWidget);

        await _back(tester, systemBack: systemBack);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translation_unsaved_save')), findsNothing);
        expect(find.byType(SettingsTranslationProvider), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(0))
              .controller!
              .text,
          'Unsaved draft',
        );

        await _back(tester, systemBack: systemBack);
        await tester.tap(find.byKey(const Key('translation_unsaved_discard')));
        await tester.pumpAndSettle();
        expect(find.text('Saved'), findsOneWidget);
        expect(
          runtime.providers.where(
            (provider) => provider.name == 'Unsaved draft',
          ),
          isEmpty,
        );
      },
    );
  }

  testWidgets('saving an incomplete draft from the exit prompt stays put', (
    tester,
  ) async {
    await _showProvider(tester);
    await tester.enterText(find.byType(TextField).at(0), 'Incomplete draft');
    final l10n = L10n.of(
      tester.element(find.byType(SettingsTranslationProvider)),
    );
    await _back(tester);
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTranslationProvider), findsOneWidget);
    expect(find.text(l10n.translationProviderRequired), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'Incomplete draft',
    );
  });

  testWidgets('exit prompt saves a complete provider and returns', (
    tester,
  ) async {
    await _showProvider(tester);
    await _fillProvider(tester, name: 'Saved from exit prompt');
    await _back(tester);
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    final saved = runtime.providers.singleWhere(
      (provider) => provider.name == 'Saved from exit prompt',
    );
    expect(await runtime.preferences.readApiKey(saved.id), 'test-key');
  });

  testWidgets('failed exit save keeps the draft and prompts on the next back', (
    tester,
  ) async {
    await _showProvider(tester);
    await _fillProvider(tester, name: 'Failed exit save');
    secrets.failWrites = true;
    await _back(tester);
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTranslationProvider), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'Failed exit save',
    );
    await _back(tester);
    expect(find.byKey(const Key('translation_unsaved_save')), findsOneWidget);
    secrets.failWrites = false;
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets(
    'loading a stored key does not mark an unchanged provider dirty',
    (tester) async {
      await runtime.preferences.writeApiKey(existing.id, 'existing-key');
      await _showProvider(tester, providerId: existing.id);
      await _back(tester);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.byKey(const Key('translation_unsaved_save')), findsNothing);
    },
  );

  testWidgets('a delayed key load preserves earlier edits in the dirty check', (
    tester,
  ) async {
    final pendingRead = secrets.pendingRead = Completer<void>();
    await _showProvider(tester, providerId: existing.id);
    await tester.enterText(
      find.byType(TextField).at(0),
      'Edited during key load',
    );
    pendingRead.complete();
    await tester.pumpAndSettle();
    await _back(tester);
    expect(find.byKey(const Key('translation_unsaved_save')), findsOneWidget);
  });

  testWidgets('exit save during key loading reports waiting and can retry', (
    tester,
  ) async {
    await runtime.preferences.writeApiKey(existing.id, 'existing-key');
    final secretsBefore = Map<String, String>.of(secrets.values);
    final pendingRead = secrets.pendingRead = Completer<void>();
    await _showProvider(tester, providerId: existing.id);
    final l10n = L10n.of(
      tester.element(find.byType(SettingsTranslationProvider)),
    );
    final editedName = '${existing.name} ';
    await tester.enterText(find.byType(TextField).at(0), editedName);
    await _back(tester);
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTranslationProvider), findsOneWidget);
    expect(find.text(l10n.loadingPleaseWait), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      editedName,
    );
    expect(secrets.values, secretsBefore);
    expect(
      runtime.providers
          .singleWhere((provider) => provider.id == existing.id)
          .name,
      existing.name,
    );

    pendingRead.complete();
    await tester.pumpAndSettle();
    await _back(tester);
    expect(find.byKey(const Key('translation_unsaved_save')), findsOneWidget);
    await tester.tap(find.byKey(const Key('translation_unsaved_save')));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(await runtime.preferences.readApiKey(existing.id), 'existing-key');
  });

  testWidgets('Anthropic selection preserves an existing provider effort', (
    tester,
  ) async {
    await _showProvider(tester);
    expect(
      tester
          .widget<DropdownButton<TranslationReasoningEffort>>(
            find.byType(DropdownButton<TranslationReasoningEffort>),
          )
          .value,
      TranslationReasoningEffort.unspecified,
    );
    await _choose<TranslationProtocol>(tester, 'Anthropic Messages');
    expect(
      tester
          .widget<DropdownButton<TranslationProtocol>>(
            find.byType(DropdownButton<TranslationProtocol>),
          )
          .value,
      TranslationProtocol.anthropicMessages,
    );

    await _showProvider(tester, providerId: existing.id);
    expect(
      tester
          .widget<DropdownButton<TranslationProtocol>>(
            find.byType(DropdownButton<TranslationProtocol>),
          )
          .value,
      TranslationProtocol.anthropicMessages,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<TranslationReasoningEffort>>(
            find.byType(DropdownButtonFormField<TranslationReasoningEffort>),
          )
          .initialValue,
      TranslationReasoningEffort.high,
    );
  });

  testWidgets('provider test and save use the selected protocol and effort', (
    tester,
  ) async {
    await _showProvider(tester);
    await tester.enterText(find.byType(TextField).at(0), 'New Anthropic proxy');
    await tester.enterText(
      find.byType(TextField).at(1),
      'https://proxy.example.invalid/v1',
    );
    await tester.enterText(find.byType(TextField).at(2), 'claude-example');
    await tester.enterText(find.byType(TextField).at(3), 'test-key');
    await _choose<TranslationProtocol>(tester, 'Anthropic Messages');
    await _choose<TranslationReasoningEffort>(tester, 'xhigh');

    final testButton = find.text('Test');
    await tester.ensureVisible(testButton);
    api.pending = Completer<void>();
    await tester.tap(testButton);
    await tester.pump();
    await tester.pump();

    final tested = api.providers.last;
    expect(tested.protocol, TranslationProtocol.anthropicMessages);
    expect(tested.reasoningEffort, TranslationReasoningEffort.xhigh);
    expect(
      tested.requestEndpoint,
      Uri.parse('https://proxy.example.invalid/v1/messages'),
    );
    expect(
      tester
          .widget<DropdownButtonFormField<TranslationProtocol>>(
            find.byType(DropdownButtonFormField<TranslationProtocol>),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<TranslationReasoningEffort>>(
            find.byType(DropdownButtonFormField<TranslationReasoningEffort>),
          )
          .onChanged,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(find.byType(SettingsTranslationProvider), findsOneWidget);
    expect(find.byKey(const Key('translation_unsaved_save')), findsNothing);
    api.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Provider test passed'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    final saved = runtime.providers.singleWhere(
      (provider) => provider.name == 'New Anthropic proxy',
    );
    expect(saved.protocol, TranslationProtocol.anthropicMessages);
    expect(saved.reasoningEffort, TranslationReasoningEffort.xhigh);
    expect(await runtime.preferences.readApiKey(saved.id), 'test-key');
  });

  for (final saveFromExit in [false, true]) {
    testWidgets(
      'new HTTP provider confirmation via ${saveFromExit ? 'exit' : 'toolbar'} save',
      (tester) async {
        await _showProvider(tester);
        await _fillProvider(
          tester,
          name: 'New HTTP provider',
          endpoint: 'http://proxy.example.invalid/v1',
        );
        final controller = tester.state<SettingsTranslationProviderController>(
          find.byType(SettingsTranslationProvider),
        );
        addTearDown(() => runtime.deleteProvider(controller.providerId));
        final providersBefore = runtime.providers
            .map((provider) => provider.toJson())
            .toList();
        final secretsBefore = Map<String, String>.of(secrets.values);
        final l10n = L10n.of(controller.context);
        final saveButton = find.widgetWithText(FilledButton, l10n.save);
        expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);

        switch (saveFromExit) {
          case true:
            await _back(tester);
            await tester.tap(find.byKey(const Key('translation_unsaved_save')));
          case false:
            await tester.tap(saveButton);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text(l10n.translationProviderHttpSaveAnyway),
          findsOneWidget,
        );
        await controller.save();
        await controller.requestExit();
        expect(
          find.text(l10n.translationProviderHttpSaveAnyway),
          findsOneWidget,
        );
        expect(
          runtime.providers.map((provider) => provider.toJson()).toList(),
          providersBefore,
        );
        expect(secrets.values, secretsBefore);

        await tester.tap(
          find.byKey(const Key('ok_cancel_alert_dialog_cancel_button')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SettingsTranslationProvider), findsOneWidget);
        expect(controller.endpoint.text, 'http://proxy.example.invalid/v1');
        expect(controller.apiKey.text, 'test-key');
        expect(controller.canSave, isTrue);
        expect(
          runtime.providers.map((provider) => provider.toJson()).toList(),
          providersBefore,
        );
        expect(secrets.values, secretsBefore);

        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text(l10n.translationProviderHttpSaveAnyway),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('ok_cancel_alert_dialog_ok_button')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Saved'), findsOneWidget);
        final saved = runtime.providers.singleWhere(
          (provider) => provider.id == controller.providerId,
        );
        expect(
          saved.requestEndpoint,
          Uri.parse('http://proxy.example.invalid/v1/chat/completions'),
        );
        expect(await runtime.preferences.readApiKey(saved.id), 'test-key');
      },
    );
  }

  for (final change in ['https', 'http', 'protocol', 'endpoint mode']) {
    testWidgets('changed $change request URL requires HTTP confirmation', (
      tester,
    ) async {
      final provider = TranslationProviderConfig(
        id: 'changed-http-url-$change',
        name: 'Saved provider',
        endpoint: Uri.parse(
          '${change == 'https' ? 'https' : 'http'}://proxy.example.invalid/v1',
        ),
        useFullEndpoint: false,
        protocol: TranslationProtocol.chatCompletions,
        model: 'test-model',
      );
      await runtime.saveProvider(provider, apiKey: 'saved-key');
      addTearDown(() => runtime.deleteProvider(provider.id));
      await _showProvider(tester, providerId: provider.id);
      final controller = tester.state<SettingsTranslationProviderController>(
        find.byType(SettingsTranslationProvider),
      );
      switch (change) {
        case 'protocol':
          controller.changeProtocol(TranslationProtocol.responses);
        case 'endpoint mode':
          controller.changeUseFullEndpoint(true);
        default:
          await tester.enterText(
            find.byType(TextField).at(1),
            'http://other.example.invalid/v2',
          );
      }
      await tester.pump();
      final l10n = L10n.of(controller.context);
      await tester.tap(find.widgetWithText(FilledButton, l10n.save));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(l10n.translationProviderHttpSaveAnyway), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsTranslationProvider), findsOneWidget);
      expect(controller.canSave, isTrue);
      expect(
        runtime.providers
            .singleWhere((item) => item.id == provider.id)
            .toJson(),
        provider.toJson(),
      );
      expect(await runtime.preferences.readApiKey(provider.id), 'saved-key');
    });
  }

  for (final useEquivalentUrl in [false, true]) {
    testWidgets(
      'unchanged HTTP request URL saves without confirmation (equivalent URL: $useEquivalentUrl)',
      (tester) async {
        final provider = TranslationProviderConfig(
          id: 'unchanged-http-url-$useEquivalentUrl',
          name: 'Saved HTTP provider',
          endpoint: Uri.parse('http://proxy.example.invalid/v1'),
          useFullEndpoint: false,
          protocol: TranslationProtocol.chatCompletions,
          model: 'test-model',
        );
        await runtime.saveProvider(provider, apiKey: 'saved-key');
        addTearDown(() => runtime.deleteProvider(provider.id));
        await _showProvider(tester, providerId: provider.id);
        final controller = tester.state<SettingsTranslationProviderController>(
          find.byType(SettingsTranslationProvider),
        );
        await tester.enterText(
          find.byType(TextField).at(0),
          'Renamed provider',
        );
        await tester.enterText(find.byType(TextField).at(2), 'updated-model');
        await tester.enterText(find.byType(TextField).at(3), 'updated-key');
        if (useEquivalentUrl) {
          await tester.enterText(
            find.byType(TextField).at(1),
            provider.requestEndpoint.toString(),
          );
          controller.changeUseFullEndpoint(true);
          await tester.pump();
        }
        final l10n = L10n.of(controller.context);
        await tester.tap(find.widgetWithText(FilledButton, l10n.save));
        await tester.pumpAndSettle();
        expect(find.text(l10n.translationProviderHttpSaveAnyway), findsNothing);
        expect(find.text('Saved'), findsOneWidget);
        final saved = runtime.providers.singleWhere(
          (item) => item.id == provider.id,
        );
        expect(saved.requestEndpoint, provider.requestEndpoint);
        expect(saved.name, 'Renamed provider');
        expect(saved.model, 'updated-model');
        expect(
          await runtime.preferences.readApiKey(provider.id),
          'updated-key',
        );
      },
    );
  }
}

Future<void> _back(WidgetTester tester, {bool systemBack = false}) async {
  switch (systemBack) {
    case true:
      await tester.binding.handlePopRoute();
    case false:
      await tester.tap(find.byType(BackButton));
  }
  await tester.pumpAndSettle();
}

Future<void> _fillProvider(
  WidgetTester tester, {
  required String name,
  String endpoint = 'https://proxy.example.invalid/v1',
}) async {
  await tester.enterText(find.byType(TextField).at(0), name);
  await tester.enterText(find.byType(TextField).at(1), endpoint);
  await tester.enterText(find.byType(TextField).at(2), 'test-model');
  await tester.enterText(find.byType(TextField).at(3), 'test-key');
  await tester.pump();
}

Future<void> _choose<T>(WidgetTester tester, String label) async {
  final finder = find.byType(DropdownButtonFormField<T>);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _showProvider(WidgetTester tester, {String? providerId}) async {
  final router = GoRouter(
    initialLocation: '/rooms/settings/translation/provider',
    routes: [
      GoRoute(
        path: '/rooms/settings/translation',
        builder: (_, _) => const Scaffold(body: Text('Saved')),
        routes: [
          GoRoute(
            path: 'provider',
            builder: (_, _) =>
                SettingsTranslationProvider(providerId: providerId),
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
    ),
  );
  await tester.pumpAndSettle();
}

class _ProviderApiClient extends TranslationApiClient {
  final providers = <TranslationProviderConfig>[];
  Completer<void>? pending;

  @override
  Future<Map<String, String>> translate({
    required TranslationProviderConfig provider,
    required String apiKey,
    required Map<String, TranslationRequestMessage> messages,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    providers.add(provider);
    await pending?.future;
    return {for (final id in messages.keys) id: 'Bonjour'};
  }
}

class _ProviderSecrets implements TranslationSecretStore {
  final values = <String, String>{};
  bool failWrites = false;
  Completer<void>? pendingRead;

  @override
  Future<String?> read(String key) async {
    await pendingRead?.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('Could not write credentials');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}
