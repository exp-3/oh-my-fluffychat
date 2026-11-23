// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cupertino_ui/cupertino_ui.dart'
    show GlobalCupertinoLocalizations;
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_search/chat_search_status_controller.dart';
import 'package:fluffychat/pages/chat_search/search_status.dart';
import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late ChatSearchStatusController status;
  late ScrollController scroll;

  setUp(() {
    status = ChatSearchStatusController();
    scroll = ScrollController();
  });

  tearDown(() {
    scroll.dispose();
    status.dispose();
  });

  testWidgets('user scrolling changes visibility without resizing the list', (
    tester,
  ) async {
    await _showSearch(tester, status, scroll);
    final listRect = tester.getRect(find.byType(ListView));
    final inset = status.bottomInset;
    expect(inset, greaterThan(0));

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(status.collapsed, isTrue);
    expect(status.bottomInset, inset);
    expect(tester.getRect(find.byType(ListView)), listRect);
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      EdgeInsets.only(bottom: inset),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(status.collapsed, isFalse);
    expect(tester.getRect(find.byType(ListView)), listRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the handle restores the bar and leaves the list interactive', (
    tester,
  ) async {
    var resultTaps = 0;
    await _showSearch(tester, status, scroll, onResultTap: () => resultTaps++);
    final handle = find.byIcon(Icons.expand_less_outlined);
    final panel = tester.getRect(find.byKey(const ValueKey('search-panel')));
    expect(tester.getRect(find.byType(ChatSearchStatus)).bottom, panel.bottom);
    status.collapse();
    await tester.pumpAndSettle();

    // This point is inside the hidden full bar, to the left of its handle.
    final listPoint = Offset(
      panel.left + 24,
      panel.bottom - status.bottomInset / 2,
    );
    await tester.tapAt(listPoint);
    expect(resultTaps, 1);
    await tester.dragFrom(listPoint, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(status.collapsed, isTrue);

    expect(handle, findsOneWidget);
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(status.collapsed, isFalse);
    expect(handle, findsNothing);
    await tester.drag(find.byType(ChatSearchStatus), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(status.collapsed, isTrue);
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(status.collapsed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small separate wheel ticks accumulate in both directions', (
    tester,
  ) async {
    await _showSearch(tester, status, scroll);
    scroll.jumpTo(120);
    await tester.pumpAndSettle();
    final position = tester.getCenter(find.byType(ListView));
    for (var tick = 0; tick < 3; tick++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: position, scrollDelta: const Offset(0, 8)),
      );
      await tester.pumpAndSettle();
      expect(status.collapsed, tick == 2);
    }
    for (var tick = 0; tick < 3; tick++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: position,
          scrollDelta: const Offset(0, -8),
        ),
      );
      await tester.pumpAndSettle();
      expect(status.collapsed, tick < 2);
    }

    // A user returning to the top expands even before crossing the threshold.
    scroll.jumpTo(8);
    status.collapse();
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, -8)),
    );
    await tester.pumpAndSettle();
    expect(status.collapsed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('programmatic restoration and progress preserve visibility', (
    tester,
  ) async {
    await _showSearch(
      tester,
      status,
      scroll,
      runState: ChatSearchRunState.running,
      reducedMotion: true,
    );
    scroll.jumpTo(120);
    await tester.pumpAndSettle();
    expect(status.collapsed, isFalse);
    status.collapse();
    await tester.pumpAndSettle();

    scroll.jumpTo(180);
    final restoration = scroll.animateTo(
      240,
      duration: const Duration(milliseconds: 60),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();
    await restoration;
    await _showSearch(
      tester,
      status,
      scroll,
      runState: ChatSearchRunState.running,
      itemCount: 50,
      searchedUntil: DateTime.utc(2026, 1, 1),
      reducedMotion: true,
    );
    expect(status.collapsed, isTrue);

    status.updateSearch(
      query: 'needle',
      queryRevision: 2,
      runState: ChatSearchRunState.paused,
    );
    expect(status.collapsed, isFalse);
    for (final terminal in [
      ChatSearchRunState.failed,
      ChatSearchRunState.exhausted,
    ]) {
      status.collapse();
      status.updateSearch(
        query: 'needle',
        queryRevision: 2,
        runState: terminal,
      );
      expect(status.collapsed, isFalse);
      status.collapse();
      status.updateSearch(
        query: 'needle',
        queryRevision: 2,
        runState: terminal,
      );
      expect(status.collapsed, isTrue);
    }
    status.selectTab(1);
    expect(status.collapsed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the active primary vertical scroll affects the bar', (
    tester,
  ) async {
    await _showSearch(tester, status, scroll);
    final context = tester.element(find.byType(Scrollable));
    final metrics = _metrics(AxisDirection.down);
    status.onScrollNotification(
      0,
      UserScrollNotification(
        metrics: metrics,
        context: context,
        direction: ScrollDirection.reverse,
      ),
    );
    status.onScrollNotification(
      1,
      ScrollUpdateNotification(
        metrics: metrics,
        context: context,
        scrollDelta: 40,
      ),
    );
    status.onScrollNotification(
      0,
      ScrollUpdateNotification(
        metrics: _metrics(AxisDirection.right),
        context: context,
        scrollDelta: 40,
      ),
    );
    status.onScrollNotification(
      0,
      _NestedScrollUpdate(metrics: metrics, context: context),
    );
    await tester.pump();
    expect(status.collapsed, isFalse);

    status.onScrollNotification(
      0,
      ScrollUpdateNotification(
        metrics: metrics,
        context: context,
        scrollDelta: 24,
      ),
    );
    // Visibility changes are deferred until layout has finished.
    expect(status.collapsed, isFalse);
    status.updateSearch(
      query: 'new query',
      queryRevision: 2,
      runState: ChatSearchRunState.running,
    );
    await tester.pump();
    expect(status.collapsed, isFalse);

    status.onScrollNotification(
      0,
      ScrollUpdateNotification(
        metrics: metrics,
        context: context,
        scrollDelta: 100,
      ),
    );
    await tester.pump();
    expect(status.collapsed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last result can scroll above the expanded bar', (
    tester,
  ) async {
    await _showSearch(tester, status, scroll);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final lastResult = tester.getRect(find.byKey(const ValueKey('result-39')));
    final bar = tester.getRect(find.byType(ChatSearchStatus));
    final extent = scroll.position.maxScrollExtent;
    expect(lastResult.bottom, lessThanOrEqualTo(bar.top + 0.5));
    status.collapse();
    await tester.pumpAndSettle();
    expect(scroll.position.maxScrollExtent, extent);
    expect(tester.getRect(find.byKey(const ValueKey('result-39'))), lastResult);
    expect(tester.takeException(), isNull);
  });

  for (final layout in [
    (width: 320.0, textScale: 1.0, stacked: false),
    (width: 240.0, textScale: 1.0, stacked: true),
    (width: 320.0, textScale: 2.0, stacked: true),
  ]) {
    testWidgets(
      'status layout adapts at width ${layout.width} '
      'and scale ${layout.textScale}',
      (tester) async {
        for (final textDirection in TextDirection.values) {
          await _showSearch(
            tester,
            status,
            scroll,
            runState: ChatSearchRunState.failed,
            searchedUntil: DateTime.utc(2026, 1, 1),
            textDirection: textDirection,
            width: layout.width,
            textScale: layout.textScale,
            reducedMotion: true,
          );
          final bar = find.byType(ChatSearchStatus);
          final panel = tester.getRect(
            find.byKey(const ValueKey('search-panel')),
          );
          final details = tester.getRect(
            find.descendant(of: bar, matching: find.byType(Wrap)),
          );
          final action = tester.getRect(
            find.byWidgetPredicate((widget) => widget is TextButton),
          );
          expect(action.left, greaterThanOrEqualTo(panel.center.dx));
          expect(action.right, closeTo(panel.right - 16, 0.5));
          expect(action.top, greaterThanOrEqualTo(panel.top));
          expect(action.bottom, lessThanOrEqualTo(panel.bottom));
          if (layout.stacked) {
            expect(details.width, closeTo(panel.width - 32, 0.5));
            expect(action.top, greaterThanOrEqualTo(details.bottom));
          } else {
            expect(details.right, lessThanOrEqualTo(action.left));
            expect(action.top, lessThan(details.bottom));
            expect(action.bottom, greaterThan(details.top));
          }

          final inset = status.bottomInset;
          final listRect = tester.getRect(find.byType(ListView));
          final extent = scroll.position.maxScrollExtent;
          expect(inset, closeTo(tester.getSize(bar).height, 0.5));
          expect(
            tester.widget<ListView>(find.byType(ListView)).padding,
            EdgeInsets.only(bottom: inset),
          );
          status.collapse();
          await tester.pumpAndSettle();
          expect(status.bottomInset, inset);
          expect(tester.getRect(find.byType(ListView)), listRect);
          expect(scroll.position.maxScrollExtent, extent);
          status.expand();
          await tester.pumpAndSettle();
          expect(status.bottomInset, inset);
          expect(tester.getRect(find.byType(ListView)), listRect);
          expect(scroll.position.maxScrollExtent, extent);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('large text keeps actions right with reduced motion', (
    tester,
  ) async {
    for (final textDirection in TextDirection.values) {
      status.expand();
      await _showSearch(
        tester,
        status,
        scroll,
        runState: ChatSearchRunState.failed,
        searchedUntil: DateTime.utc(2026, 1, 1),
        textDirection: textDirection,
        width: 240,
        textScale: 2,
        reducedMotion: true,
      );
      final context = tester.element(find.byType(ChatSearchStatus));
      final l10n = L10n.of(context);
      expect(Directionality.of(context), textDirection);
      final panel = tester.getRect(find.byKey(const ValueKey('search-panel')));
      final action = tester.getRect(
        find.byWidgetPredicate((widget) => widget is TextButton),
      );
      final details = tester.getRect(
        find.descendant(
          of: find.byType(ChatSearchStatus),
          matching: find.byType(Wrap),
        ),
      );
      expect(details.width, closeTo(panel.width - 32, 0.5));
      expect(action.top, greaterThanOrEqualTo(details.bottom));
      expect(action.left, greaterThanOrEqualTo(panel.center.dx));
      expect(action.right, lessThanOrEqualTo(panel.right));
      expect(action.top, greaterThanOrEqualTo(panel.top));
      expect(action.bottom, lessThanOrEqualTo(panel.bottom));
      expect(find.semantics.byLabel(l10n.tryAgain), findsOne);
      expect(find.semantics.byLabel(l10n.showMore), findsNothing);
      status.collapse();
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.semantics.byLabel(l10n.tryAgain), findsNothing);
      expect(find.semantics.byLabel(l10n.showMore), findsOne);
      status.expand();
      await tester.pump();
      expect(status.collapsed, isFalse);
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.semantics.byLabel(l10n.tryAgain), findsOne);
      expect(find.semantics.byLabel(l10n.showMore), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _showSearch(
  WidgetTester tester,
  ChatSearchStatusController status,
  ScrollController scroll, {
  ChatSearchRunState runState = ChatSearchRunState.paused,
  int itemCount = 40,
  DateTime? searchedUntil,
  TextDirection textDirection = TextDirection.ltr,
  double width = 320,
  double textScale = 1,
  bool reducedMotion = false,
  VoidCallback? onResultTap,
}) async {
  const locale = Locale('en');
  final localizations = await tester.runAsync(() => L10n.delegate.load(locale));
  expect(localizations, isNotNull);
  status.updateSearch(query: 'needle', queryRevision: 1, runState: runState);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: [
        _LoadedL10nDelegate(locale, localizations!),
        ...L10n.localizationsDelegates,
        ...GlobalMaterialLocalizations.delegates,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      supportedLocales: L10n.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: Directionality(textDirection: textDirection, child: child!),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const ValueKey('search-panel'),
            width: width,
            height: 480,
            child: ListenableBuilder(
              listenable: status,
              builder: (context, _) => Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: (notification) =>
                        status.onScrollNotification(0, notification),
                    child: ListView.builder(
                      controller: scroll,
                      padding: EdgeInsets.only(bottom: status.bottomInset),
                      itemExtent: 48,
                      itemCount: itemCount,
                      itemBuilder: (context, index) => GestureDetector(
                        key: ValueKey('result-$index'),
                        behavior: HitTestBehavior.opaque,
                        onTap: onResultTap,
                        child: Text('Result $index'),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ChatSearchStatus(
                      query: 'needle',
                      runState: runState,
                      searchedUntil: searchedUntil,
                      undecryptableCount: 3,
                      onPause: () {},
                      onResume: () {},
                      collapsed: status.collapsed,
                      onExpand: status.expand,
                      onCollapse: status.collapse,
                      onHeightChanged: status.updateExpandedHeight,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// Deferred language resources must finish loading outside the fake test clock.
class _LoadedL10nDelegate extends LocalizationsDelegate<L10n> {
  final Locale locale;
  final L10n localizations;

  const _LoadedL10nDelegate(this.locale, this.localizations);

  @override
  bool isSupported(Locale locale) => locale == this.locale;

  @override
  Future<L10n> load(Locale locale) => SynchronousFuture(localizations);

  @override
  bool shouldReload(_LoadedL10nDelegate old) => locale != old.locale;
}

FixedScrollMetrics _metrics(AxisDirection direction) => FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: 1000,
  pixels: 100,
  viewportDimension: 480,
  axisDirection: direction,
  devicePixelRatio: 1,
);

class _NestedScrollUpdate extends ScrollUpdateNotification {
  _NestedScrollUpdate({required super.metrics, required super.context})
    : super(scrollDelta: 40);

  @override
  int get depth => 1;
}
