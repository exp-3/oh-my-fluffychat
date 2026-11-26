// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_translation/translation_roaming_upload_page.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'utils/translation_test_backend.dart';

void main() {
  testWidgets('rooms start unselected and search preserves selected chats', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await fixture.add('!first:test', 'first');
      await fixture.add('!second:test', 'second');
      await _show(tester, fixture.runtime);
      await tester.pumpAndSettle();
      final l10n = L10n.of(
        tester.element(find.byType(TranslationRoamingUploadPage)),
      );
      final upload = _uploadButton(l10n);
      expect(tester.widget<FilledButton>(upload).onPressed, isNull);
      expect(
        find.text(l10n.translationRoamingUploadCount(1)),
        findsNWidgets(2),
      );

      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump();
      expect(find.text('!first:test'), findsNothing);
      await tester.tap(find.text('!second:test'));
      await tester.pump();
      expect(tester.widget<FilledButton>(upload).onPressed, isNotNull);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const ValueKey('!first:test')))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('!second:test')),
            )
            .value,
        isTrue,
      );

      await tester.tap(find.text(l10n.translationRoamingUploadSelectAll));
      await tester.pump();
      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.translationRoamingUploadResult(2, 0, 0, 0)),
        findsOneWidget,
      );
      expect(fixture.store.writes, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await fixture.dispose();
    }
  });

  testWidgets('upload progress can be cancelled without leaving the page', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await fixture.add('!first:test', 'first');
      fixture.store.pending = Completer<bool>();
      await _show(tester, fixture.runtime);
      await tester.pumpAndSettle();
      final l10n = L10n.of(
        tester.element(find.byType(TranslationRoamingUploadPage)),
      );
      await tester.tap(find.text('!first:test'));
      await tester.pump();
      await tester.tap(_uploadButton(l10n));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(l10n.translationRoamingUploadProgress(0, 1)),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n.cancel));
      await tester.pump();
      expect(find.text(l10n.translationRoamingUploadStopped), findsOneWidget);
      expect(fixture.store.disposed, isTrue);
      fixture.store.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await fixture.dispose();
    }
  });

  testWidgets('an empty local archive offers a rescan', (tester) async {
    final fixture = _Fixture();
    try {
      await _show(tester, fixture.runtime);
      await tester.pumpAndSettle();
      final l10n = L10n.of(
        tester.element(find.byType(TranslationRoamingUploadPage)),
      );
      expect(find.text(l10n.translationRoamingUploadEmpty), findsOneWidget);
      await fixture.add('!first:test', 'first');
      await tester.tap(find.text(l10n.tryAgain));
      await tester.pumpAndSettle();
      expect(find.text('!first:test'), findsOneWidget);
      expect(fixture.runtime.created, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await fixture.dispose();
    }
  });

  testWidgets('a configuration failure can be retried with a fresh session', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      fixture.runtime.unavailable = true;
      await _show(tester, fixture.runtime);
      await tester.pumpAndSettle();
      final l10n = L10n.of(
        tester.element(find.byType(TranslationRoamingUploadPage)),
      );
      expect(
        find.text(l10n.translationRoamingUploadUnavailable),
        findsOneWidget,
      );
      fixture.runtime.unavailable = false;
      await tester.tap(find.text(l10n.tryAgain));
      await tester.pumpAndSettle();
      expect(find.text(l10n.translationRoamingUploadEmpty), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await fixture.dispose();
    }
  });

  testWidgets('disposal stops a pending upload and ignores late completion', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await fixture.add('!first:test', 'first');
      fixture.store.pending = Completer<bool>();
      await _show(tester, fixture.runtime);
      await tester.pumpAndSettle();
      final l10n = L10n.of(
        tester.element(find.byType(TranslationRoamingUploadPage)),
      );
      await tester.tap(find.text('!first:test'));
      await tester.pump();
      await tester.tap(_uploadButton(l10n));
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(fixture.store.disposed, isTrue);
      fixture.store.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await fixture.dispose();
    }
  });
}

Future<void> _show(WidgetTester tester, TranslationRuntime runtime) =>
    tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: TranslationRoamingUploadPage(runtime: runtime),
      ),
    );

Finder _uploadButton(L10n l10n) => find.ancestor(
  of: find.text(l10n.translationRoamingUploadLocal),
  matching: find.byWidgetPredicate((widget) => widget is FilledButton),
);

class _UploadRuntime extends TranslationRuntime {
  final TranslationRoamingUploadSession Function() createSession;
  bool unavailable = false;
  int created = 0;

  _UploadRuntime(this.createSession) : super.forTesting();

  @override
  Future<TranslationRoamingUploadSession> createRoamingUploadSession() async {
    if (unavailable) {
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
    created++;
    return createSession();
  }

  @override
  Room? roamingUploadRoom(String userId, String roomId) => null;
}

class _Fixture {
  final backend = MemoryTranslationBackend();
  final secrets = _Secrets();
  final lifecycle = ValueNotifier(0);
  final store = _Store();
  final sources = <String, String>{};
  late final cache = TranslationCache(secrets, backend);
  late final runtime = _UploadRuntime(
    () => TranslationRoamingUploadSession(
      cache: cache,
      resolveSource: (_, _, eventId) async => TranslationLocalSource.valid(
        sources[eventId]!,
        messageTimestamp: DateTime.utc(2026, 1, 1),
      ),
      service: TranslationRoamingService(
        config: const TranslationRoamingConfig(
          enabled: true,
          host: 'redis.example.invalid',
        ),
        secrets: TranslationRoamingSecrets(
          preSharedKey: TranslationRoamingCrypto.generatePreSharedKey(),
        ),
        store: store,
      ),
      lifecycle: lifecycle,
      isCurrent: () => true,
      canAccess: (_) => true,
      now: () => DateTime.utc(2026, 1, 2),
    ),
  );

  Future<void> add(String roomId, String source) async {
    sources[source] = source;
    await cache.write(
      TranslationCacheKey(
        userId: '@alice:test',
        roomId: roomId,
        eventId: source,
        source: source,
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        messageType: 'm.text',
      ),
      'translated $source',
    );
  }

  Future<void> dispose() async {
    runtime.dispose();
    lifecycle.dispose();
    await cache.dispose();
  }
}

class _Secrets implements TranslationSecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class _Store implements TranslationRoamingStore {
  int writes = 0;
  bool disposed = false;
  Completer<bool>? pending;

  @override
  Future<bool> setIfAbsent(String key, String value, int ttlSeconds) async {
    writes++;
    return pending?.future ?? Future.value(true);
  }

  @override
  Future<String?> get(String key) async => null;

  @override
  Future<String?> getEx(String key, int ttlSeconds) async => null;

  @override
  Future<void> set(String key, String value, int ttlSeconds) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  void reset() {}

  @override
  void dispose() => disposed = true;
}
