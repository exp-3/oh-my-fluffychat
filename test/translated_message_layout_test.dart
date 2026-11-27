// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/html_message.dart';
import 'package:fluffychat/pages/chat/events/translated_message.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/translation_test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bubbleKey = ValueKey('bubble');
  const availableKey = ValueKey('available');
  final runtime = TranslationRuntime.instance;
  final room = Room(id: '!layout:test', client: _LayoutClient());
  var nextId = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.translation.enabled': true,
      'chat.fluffy.translation.privacy_accepted': true,
    });
    await AppSettings.init(loadWebConfigFile: false);
    final secrets = _LayoutSecrets();
    await runtime.initialize(
      AppSettings.store,
      secrets: secrets,
      cache: TranslationCache(
        secrets,
        MemoryTranslationBackend()..unavailable = true,
      ),
    );
  });

  setUp(() async {
    await AppSettings.messagePreviewMaxLines.setItem(0);
  });

  tearDownAll(runtime.dispose);

  _LayoutEvent event(String body, {bool own = false}) => _LayoutEvent(
    room: room,
    body: body,
    eventId: 'layout-${nextId++}',
    senderId: own ? '@self:test' : '@sender:test',
  );

  void setTranslation(Event event, String? translation) {
    final state =
        runtime.stateForEvent(event) as ValueNotifier<TranslationResultState>;
    state.value = translation == null
        ? TranslationResultState.idle
        : TranslationResultState.translated(translation);
  }

  Future<void> showMessage(
    WidgetTester tester,
    Event event, {
    String? translation,
    TranslationBilingualStyle style = TranslationBilingualStyle.divider,
    TranslationDisplayMode mode = TranslationDisplayMode.bilingual,
    double width = 480,
    double textScale = 1,
    Widget? originalChild,
    VoidCallback? onOutsideLongPress,
    VoidCallback? onBubbleDoubleTap,
  }) async {
    await runtime.setDisplayMode(mode);
    await runtime.setBilingualStyle(style);
    setTranslation(event, translation);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(
              child: SizedBox(
                key: availableKey,
                width: width,
                child: Align(
                  alignment: event.senderId == '@self:test'
                      ? Alignment.topRight
                      : Alignment.topLeft,
                  child: DefaultTextStyle(
                    style: const TextStyle(fontFamily: 'Ahem', height: 1),
                    child: OutsideBubbleTranslation(
                      event: event,
                      timeline: _LayoutTimeline(),
                      onLongPress: onOutsideLongPress,
                      child: GestureDetector(
                        onDoubleTap: onBubbleDoubleTap,
                        child: DecoratedBox(
                          key: bubbleKey,
                          decoration: const BoxDecoration(color: Colors.blue),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: FluffyThemes.columnWidth * 1.5,
                            ),
                            child: TranslatedMessage(
                              event: event,
                              originalHtml: event.body,
                              originalChild: originalChild,
                              textColor: Colors.black,
                              linkColor: Colors.blue,
                              originalFontSize: 16,
                              timeline: _LayoutTimeline(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(tester.takeException(), isNull);
  }

  for (final style in TranslationBilingualStyle.values) {
    for (final originalWider in [true, false]) {
      testWidgets(
        '${style.name} uses the wider visible text ($originalWider)',
        (tester) async {
          final source = originalWider ? 'original' : 'short';
          final translation = originalWider ? 'brief' : 'translated';
          await showMessage(
            tester,
            event(source),
            translation: translation,
            style: style,
          );

          expect(
            tester.getSize(find.byKey(bubbleKey)).width,
            closeTo(
              (originalWider ? source.length : translation.length) * 16 + 32,
              1,
            ),
          );
        },
      );
    }
  }

  testWidgets('translated-only width ignores the hidden original', (
    tester,
  ) async {
    await showMessage(
      tester,
      event('A considerably longer original message'),
      translation: 'brief',
      mode: TranslationDisplayMode.translatedOnly,
    );

    expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(112, 1));
    expect(find.byType(HtmlMessage), findsOneWidget);
  });

  for (final own in [false, true]) {
    testWidgets('outside translation shares the bubble edges (own: $own)', (
      tester,
    ) async {
      await showMessage(
        tester,
        event('short', own: own),
        translation: 'translated',
        style: TranslationBilingualStyle.outsideBubble,
      );

      final bubble = tester.getRect(find.byKey(bubbleKey));
      final available = tester.getRect(find.byKey(availableKey));
      final translation = tester.getRect(find.byType(HtmlMessage).last);
      expect(translation.left, closeTo(bubble.left + 16, 1));
      expect(translation.right, closeTo(bubble.right - 16, 1));
      expect(
        own ? bubble.right : bubble.left,
        closeTo(own ? available.right : available.left, 1),
      );
    });
  }

  testWidgets('missing or identical translations preserve the original width', (
    tester,
  ) async {
    final message = event('short');
    for (final translation in [null, 'short', ' short ']) {
      await showMessage(
        tester,
        message,
        translation: translation,
        style: TranslationBilingualStyle.outsideBubble,
      );

      expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(112, 1));
      expect(find.byType(HtmlMessage), findsOneWidget);
    }
  });

  testWidgets('clearing an outside translation shrinks the existing bubble', (
    tester,
  ) async {
    final message = event('short');
    await showMessage(
      tester,
      message,
      translation: 'translated',
      style: TranslationBilingualStyle.outsideBubble,
    );
    expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(192, 1));

    setTranslation(message, null);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(112, 1));
    expect(find.byType(HtmlMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching styles keeps the shared content width', (
    tester,
  ) async {
    await showMessage(tester, event('short'), translation: 'translated');
    for (final style in TranslationBilingualStyle.values) {
      await runtime.setBilingualStyle(style);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(192, 1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('outside layout changes preserve the bubble state', (
    tester,
  ) async {
    final message = event('short');
    var mounts = 0;
    var disposals = 0;
    await runtime.setDisplayMode(TranslationDisplayMode.bilingual);
    await runtime.setBilingualStyle(TranslationBilingualStyle.outsideBubble);
    setTranslation(message, null);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: OutsideBubbleTranslation(
            event: message,
            timeline: _LayoutTimeline(),
            child: _TrackedBubble(
              onMount: () => mounts++,
              onDispose: () => disposals++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    for (final translation in ['translated', null, 'translated']) {
      setTranslation(message, translation);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(mounts, 1);
      expect(disposals, 0);
    }
    for (final style in [
      TranslationBilingualStyle.plain,
      TranslationBilingualStyle.outsideBubble,
    ]) {
      await runtime.setBilingualStyle(style);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(mounts, 1);
      expect(disposals, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('outside long press and bubble double tap remain independent', (
    tester,
  ) async {
    var longPresses = 0;
    var doubleTaps = 0;
    await showMessage(
      tester,
      event('short'),
      translation: 'translated',
      style: TranslationBilingualStyle.outsideBubble,
      onOutsideLongPress: () => longPresses++,
      onBubbleDoubleTap: () => doubleTaps++,
    );

    await tester.longPress(find.byType(HtmlMessage).last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(longPresses, 1);
    expect(doubleTaps, 0);

    await tester.tap(find.byKey(bubbleKey));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(bubbleKey));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(longPresses, 1);
    expect(doubleTaps, 1);
    expect(tester.takeException(), isNull);
  });

  for (final style in [
    TranslationBilingualStyle.divider,
    TranslationBilingualStyle.outsideBubble,
  ]) {
    testWidgets('${style.name} respects narrow width and text scaling', (
      tester,
    ) async {
      await showMessage(
        tester,
        event('short'),
        translation: 'A much longer translation that needs several lines',
        style: style,
        width: 240,
        textScale: 1.5,
      );

      expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(240, 1));
      expect(
        tester.getSize(find.byType(OutsideBubbleTranslation)).height,
        greaterThan(40),
      );
    });

    testWidgets(
      '${style.name} retains the bubble width limit on wide screens',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await showMessage(
          tester,
          event('short'),
          translation: List.filled(30, 'translated').join(' '),
          style: style,
          width: 1000,
        );

        expect(
          tester.getSize(find.byKey(bubbleKey)).width,
          closeTo(FluffyThemes.columnWidth * 1.5, 1),
        );
      },
    );
  }

  testWidgets('rich text and a scrollable table support shared width', (
    tester,
  ) async {
    await showMessage(
      tester,
      event('<p><b>Bold</b> and <code>code</code></p>'),
      translation: '<table><tr><td>Translated</td><td>cell</td></tr></table>',
      width: 240,
    );

    expect(find.byType(Table), findsOneWidget);
    expect(tester.getSize(find.byKey(bubbleKey)).width, lessThanOrEqualTo(240));
  });

  testWidgets('folding and unfolding retain a valid translated layout', (
    tester,
  ) async {
    await AppSettings.messagePreviewMaxLines.setItem(2);
    await showMessage(
      tester,
      event('first<br>second<br>third<br>fourth'),
      translation: 'brief',
    );
    final initialHeight = tester.getSize(find.byKey(bubbleKey)).height;
    await tester.tap(find.widgetWithText(TextButton, 'Show more'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(
      tester.getSize(find.byKey(bubbleKey)).height,
      greaterThan(initialHeight),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Show less'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(
      tester.getSize(find.byKey(bubbleKey)).height,
      closeTo(initialHeight, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('outside translation preserves an existing fixed content width', (
    tester,
  ) async {
    await showMessage(
      tester,
      event('caption'),
      translation: 'brief',
      style: TranslationBilingualStyle.outsideBubble,
      originalChild: const SizedBox(width: 256, height: 100),
    );

    expect(tester.getSize(find.byKey(bubbleKey)).width, closeTo(288, 1));
  });
}

class _TrackedBubble extends StatefulWidget {
  final VoidCallback onMount;
  final VoidCallback onDispose;

  const _TrackedBubble({required this.onMount, required this.onDispose});

  @override
  State<_TrackedBubble> createState() => _TrackedBubbleState();
}

class _TrackedBubbleState extends State<_TrackedBubble> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 160, height: 40);
}

class _LayoutEvent implements Event {
  @override
  final Room room;
  @override
  final String body;
  @override
  final String eventId;
  @override
  final String senderId;

  _LayoutEvent({
    required this.room,
    required this.body,
    required this.eventId,
    required this.senderId,
  });

  @override
  String get type => EventTypes.Message;
  @override
  String get messageType => MessageTypes.Text;
  @override
  bool get redacted => false;
  @override
  bool get isRichMessage => false;
  @override
  String? get relationshipType => null;

  @override
  Object? noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #aggregatedEvents) return <Event>{};
    throw StateError('Unexpected event call: ${invocation.memberName}');
  }
}

class _LayoutClient implements Client {
  @override
  String get userID => '@self:test';

  @override
  bool isLogged() => false;

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected client call: ${invocation.memberName}');
}

class _LayoutTimeline implements Timeline {
  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected timeline call: ${invocation.memberName}');
}

class _LayoutSecrets implements TranslationSecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
