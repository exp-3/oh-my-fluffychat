// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/settings_translation/roaming_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('test stays at the trailing edge and receives taps', (tester) async {
    var testsStarted = 0;
    for (final direction in TextDirection.values) {
      await _showActions(
        tester,
        width: 400,
        direction: direction,
        onTest: () => testsStarted++,
      );

      final bounds = tester.getRect(find.byType(RoamingActions));
      final generate = tester.getRect(find.byKey(const Key('generate')));
      final copy = tester.getRect(find.byKey(const Key('copy')));
      final test = tester.getRect(find.byKey(const Key('test')));
      expect(test.center.dy, generate.center.dy);
      expect(copy.center.dy, generate.center.dy);
      expect(test.width, 80);
      if (direction == TextDirection.ltr) {
        expect(generate.left, bounds.left);
        expect(test.right, bounds.right);
      } else {
        expect(generate.right, bounds.right);
        expect(test.left, bounds.left);
      }
      _expectDrySize(tester, bounds.size);

      await tester.tap(find.byKey(const Key('test')));
      await tester.pump();
    }
    expect(testsStarted, 2);
  });

  testWidgets('only the test moves to a full-width row when necessary', (
    tester,
  ) async {
    for (final width in [250.0, 150.0]) {
      await _showActions(tester, width: width);
      final bounds = tester.getRect(find.byType(RoamingActions));
      final generate = tester.getRect(find.byKey(const Key('generate')));
      final copy = tester.getRect(find.byKey(const Key('copy')));
      final test = tester.getRect(find.byKey(const Key('test')));

      expect(test.left, bounds.left);
      expect(test.right, bounds.right);
      expect(test.top, copy.bottom + 8);
      expect(
        copy.top,
        width == 250 ? generate.top : generate.bottom + 8,
      );
      _expectDrySize(tester, bounds.size);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('actual scaled button text decides when the test wraps', (
    tester,
  ) async {
    Future<double> naturalWidth(double textScale) async {
      await _showActions(
        tester,
        width: 700,
        textScale: textScale,
        fixedSizes: false,
      );
      return tester.getSize(find.byKey(const Key('generate'))).width +
          tester.getSize(find.byKey(const Key('copy'))).width +
          tester.getSize(find.byKey(const Key('test'))).width +
          16;
    }

    final normalWidth = await naturalWidth(1);
    final scaledWidth = await naturalWidth(2);
    expect(scaledWidth, greaterThan(normalWidth));
    final availableWidth = (normalWidth + scaledWidth) / 2;

    await _showActions(tester, width: availableWidth, fixedSizes: false);
    expect(
      tester.getCenter(find.byKey(const Key('test'))).dy,
      tester.getCenter(find.byKey(const Key('generate'))).dy,
    );

    await _showActions(
      tester,
      width: availableWidth,
      textScale: 2,
      fixedSizes: false,
    );
    final test = tester.getRect(find.byKey(const Key('test')));
    expect(test.width, availableWidth);
    expect(
      test.top,
      greaterThan(tester.getRect(find.byKey(const Key('copy'))).bottom),
    );
    _expectDrySize(tester, tester.getSize(find.byType(RoamingActions)));
    expect(tester.takeException(), isNull);
  });
}

void _expectDrySize(WidgetTester tester, Size expected) {
  final box = tester.renderObject<RenderBox>(find.byType(RoamingActions));
  expect(
    box.getDryLayout(BoxConstraints.tightFor(width: expected.width)),
    expected,
  );
}

Future<void> _showActions(
  WidgetTester tester, {
  required double width,
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  bool fixedSizes = true,
  VoidCallback? onTest,
}) async {
  Widget action(String key, String label, double fixedWidth) {
    final button = OutlinedButton(
      onPressed: onTest ?? () {},
      child: Text(label),
    );
    return SizedBox(
      key: Key(key),
      width: fixedSizes ? fixedWidth : null,
      height: fixedSizes ? 40 : null,
      child: button,
    );
  }

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: RoamingActions(
                  keyActions: [
                    action('generate', fixedSizes ? 'Key' : 'Generate key', 100),
                    action('copy', 'Copy', 100),
                  ],
                  testAction: action('test', 'Test', 80),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
