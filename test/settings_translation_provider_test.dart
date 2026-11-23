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
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => SettingsTranslationProvider(providerId: providerId),
      ),
      GoRoute(
        path: '/rooms/settings/translation',
        builder: (_, _) => const Scaffold(body: Text('Saved')),
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

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
