// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/html_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const messageKey = ValueKey('message');
  late final Room room;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    // The SDK creates an HTTP client, which requires an active test zone.
    room = Room(
      id: '!room:test',
      client: Client('collapse test', database: _UnusedDatabase()),
    );
  });

  setUp(() async {
    await AppSettings.store.clear();
    await AppSettings.messagePreviewMaxLines.setItem(4);
  });

  String lines(int count) =>
      List.generate(count, (index) => 'Line $index').join('<br>');

  String table(int count) {
    final rows = List.generate(
      count,
      (index) => '<tr><td>Row $index</td></tr>',
    ).join();
    return '<table>$rows</table>';
  }

  String code(int count) {
    final content = List.generate(
      count,
      (index) => 'code line $index',
    ).join('\n');
    return '<pre><code>$content</code></pre>';
  }

  Future<void> showMessage(
    WidgetTester tester,
    String html, {
    double width = 480,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      fontFamily: 'Ahem',
                      fontSize: 16,
                      height: 1,
                    ),
                    child: HtmlMessage(
                      key: messageKey,
                      html: html,
                      room: room,
                      fontSize: 16,
                      linkStyle: const TextStyle(color: Colors.blue),
                      onOpen: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> pressToggle(WidgetTester tester, String label) async {
    final toggle = find.widgetWithText(TextButton, label);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('short body does not offer expansion', (tester) async {
    await showMessage(tester, '<p>Short message</p>');

    expect(find.text('Show more'), findsNothing);
    expect(find.text('Show less'), findsNothing);
    expect(
      tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
      FluffyThemes.animationDuration,
    );
  });

  testWidgets('reply fallback does not contribute to body overflow', (
    tester,
  ) async {
    await showMessage(
      tester,
      '<mx-reply><blockquote>${lines(100)}</blockquote></mx-reply>'
      '<p>Short reply</p>',
    );

    expect(find.text('Show more'), findsNothing);
    expect(tester.getSize(find.byKey(messageKey)).height, lessThan(40));
  });

  testWidgets('long body expands and returns to its original preview height', (
    tester,
  ) async {
    await showMessage(tester, '<p>${lines(20)}</p>');
    final previewHeight = tester.getSize(find.byKey(messageKey)).height;
    expect(find.text('Show more'), findsOneWidget);
    expect(
      tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
      FluffyThemes.animationDuration,
    );
    final previewText = tester
        .widget<RichText>(
          find.byWidgetPredicate(
            (widget) =>
                widget is RichText &&
                widget.text.toPlainText().startsWith('Line 0'),
          ),
        )
        .text
        .toPlainText();
    expect(previewText, isNot(contains('Line 19')));
    expect(previewText.split('\n'), hasLength(4));

    await pressToggle(tester, 'Show more');
    expect(find.text('Show less'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(messageKey)).height,
      greaterThan(previewHeight + 100),
    );

    await pressToggle(tester, 'Show less');
    expect(find.text('Show more'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(messageKey)).height,
      closeTo(previewHeight, 0.01),
    );
  });

  testWidgets('body exactly at the line limit has no expansion button', (
    tester,
  ) async {
    await showMessage(tester, '<p>${lines(4)}</p>');

    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('heading height does not change its rendered line count', (
    tester,
  ) async {
    await showMessage(
      tester,
      '<h1>One</h1><h1>Two</h1><h1>Three</h1><h1>Four</h1>',
    );

    expect(find.text('Show more'), findsNothing);
  });

  for (final inline in ['code', 'link']) {
    testWidgets('four body lines containing inline $inline stay unfolded', (
      tester,
    ) async {
      final html = List.generate(
        4,
        (index) => inline == 'code'
            ? 'Line $index <code>code</code>'
            : 'Line $index <a href="https://example.com">link</a>',
      ).join('<br>');
      await showMessage(tester, html);

      expect(find.text('Show more'), findsNothing);
    });
  }

  for (final block in ['table', 'code']) {
    String content(int count) => block == 'table' ? table(count) : code(count);

    Finder blockFinder() => block == 'table'
        ? find.byType(Table)
        : find.byWidgetPredicate(
            (widget) =>
                widget is RichText &&
                widget.text.toPlainText().startsWith('code line 0'),
          );

    testWidgets('standalone long $block is not replaced by an empty preview', (
      tester,
    ) async {
      await showMessage(tester, content(20));

      expect(find.text('Show more'), findsNothing);
      expect(
        tester.getSize(find.byKey(messageKey)).height,
        greaterThanOrEqualTo(tester.getSize(blockFinder()).height),
      );
    });

    testWidgets('whitespace before long $block does not enable folding', (
      tester,
    ) async {
      await showMessage(tester, '<p>   </p>${content(20)}');

      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('reply fallback is not a visible prefix before long $block', (
      tester,
    ) async {
      await showMessage(
        tester,
        '<mx-reply><blockquote>Quoted text</blockquote></mx-reply>'
        '${content(20)}',
      );

      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('$block crossing the cut is hidden as a whole after a prefix', (
      tester,
    ) async {
      await showMessage(tester, '<p>Visible prefix</p>${content(20)}');
      expect(find.text('Show more'), findsOneWidget);
      final previewHeight = tester.getSize(find.byKey(messageKey)).height;
      expect(blockFinder(), findsNothing);

      await pressToggle(tester, 'Show more');
      expect(blockFinder(), findsOneWidget);
      final blockHeight = tester.getSize(blockFinder()).height;
      expect(previewHeight, lessThan(blockHeight));
      expect(
        tester.getSize(find.byKey(messageKey)).height,
        greaterThan(blockHeight),
      );

      await pressToggle(tester, 'Show less');
      expect(blockFinder(), findsNothing);
      expect(
        tester.getSize(find.byKey(messageKey)).height,
        closeTo(previewHeight, 0.01),
      );
    });

    testWidgets('inline text before long $block remains in the preview', (
      tester,
    ) async {
      await showMessage(tester, 'Visible prefix${content(20)}');

      expect(find.text('Show more'), findsOneWidget);
      expect(blockFinder(), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('Visible prefix'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('short leading $block is kept when following text overflows', (
      tester,
    ) async {
      await AppSettings.messagePreviewMaxLines.setItem(8);
      await showMessage(tester, '${content(1)}<p>${lines(20)}</p>');
      final endOfBody = find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains('Line 19'),
      );

      expect(find.text('Show more'), findsOneWidget);
      expect(blockFinder(), findsOneWidget);
      expect(endOfBody, findsNothing);

      await pressToggle(tester, 'Show more');
      expect(blockFinder(), findsOneWidget);
      expect(endOfBody, findsOneWidget);
    });

    testWidgets('short $block after a prefix does not offer expansion', (
      tester,
    ) async {
      await AppSettings.messagePreviewMaxLines.setItem(8);
      await showMessage(tester, '<p>Visible prefix</p>${content(1)}');

      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('three body lines and one $block line meet the limit exactly', (
      tester,
    ) async {
      await showMessage(tester, '${lines(3)}<br>${content(1)}');

      expect(find.text('Show more'), findsNothing);
      expect(blockFinder(), findsOneWidget);
    });
  }

  for (final entry in <String, String>{
    'plain text': List.filled(20, 'word').join(' '),
    'inline widgets': List.filled(
      12,
      '<code>x</code> <a href="https://example.com">link</a>',
    ).join(' '),
  }.entries) {
    testWidgets(
      'rendered width and text scale determine overflow for ${entry.key}',
      (tester) async {
        await showMessage(tester, entry.value, width: 640);
        expect(find.text('Show more'), findsNothing);

        await showMessage(tester, entry.value, width: 160);
        expect(find.text('Show more'), findsOneWidget);
        expect(find.text('Show less'), findsNothing);

        await showMessage(tester, entry.value, width: 640);
        expect(find.text('Show more'), findsNothing);

        await showMessage(tester, entry.value, width: 640, textScale: 2);
        expect(find.text('Show more'), findsOneWidget);
        expect(find.text('Show less'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('table columns share the rendered lines of their row', (
    tester,
  ) async {
    final rows = List.generate(
      3,
      (index) =>
          '<tr><td>Left $index</td><td>Middle $index</td><td>Right $index</td></tr>',
    ).join();
    await showMessage(tester, 'Prefix<br><table>$rows</table>');

    expect(find.text('Show more'), findsNothing);
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('opening and closing details updates the measured preview', (
    tester,
  ) async {
    final summary = find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          widget.text.toPlainText().contains('Details summary'),
    );
    final detailsEnd = find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains('Line 19'),
    );
    await showMessage(
      tester,
      '<p>Visible prefix</p><details><summary>Details summary</summary>'
      '<p>${lines(20)}</p></details>',
    );
    expect(find.text('Show more'), findsNothing);
    expect(summary, findsOneWidget);
    expect(detailsEnd, findsNothing);

    await tester.tapAt(tester.getTopLeft(summary) + const Offset(30, 8));
    await tester.pumpAndSettle();
    expect(find.text('Show more'), findsOneWidget);
    expect(summary, findsNothing);
    expect(detailsEnd, findsNothing);

    await pressToggle(tester, 'Show more');
    expect(summary, findsOneWidget);
    expect(detailsEnd, findsOneWidget);

    await tester.tapAt(tester.getTopLeft(summary) + const Offset(30, 8));
    await tester.pumpAndSettle();
    expect(find.text('Show more'), findsNothing);
    expect(find.text('Show less'), findsNothing);
    expect(summary, findsOneWidget);
    expect(detailsEnd, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final limit in [0, -1]) {
    testWidgets('preview limit $limit keeps long mixed content unfolded', (
      tester,
    ) async {
      await AppSettings.messagePreviewMaxLines.setItem(limit);
      await showMessage(tester, '<p>${lines(10)}</p>${table(20)}${code(20)}');

      expect(find.text('Show more'), findsNothing);
      expect(find.text('Show less'), findsNothing);
      expect(tester.getSize(find.byKey(messageKey)).height, greaterThan(600));
    });
  }
}

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Collapse tests must not access the SDK database');
}
