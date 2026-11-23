// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/settings_translation/roaming_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('test stays at the trailing edge and receives taps', (
    tester,
  ) async {
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
      final test = tester.getRect(find.byKey(const Key('test')));
      expect(test.center.dy, generate.center.dy);
      if (direction == TextDirection.ltr) {
        expect(generate.left, bounds.left);
        expect(test.right, bounds.right);
      } else {
        expect(generate.right, bounds.right);
        expect(test.left, bounds.left);
      }
      await tester.tap(find.byKey(const Key('test')));
      await tester.pump();
    }
    expect(testsStarted, 2);
  });

  testWidgets('test moves to a full-width row when necessary', (tester) async {
    for (final width in [250.0, 150.0]) {
      await _showActions(tester, width: width);
      final bounds = tester.getRect(find.byType(RoamingActions));
      final copy = tester.getRect(find.byKey(const Key('copy')));
      final test = tester.getRect(find.byKey(const Key('test')));

      expect(test.left, bounds.left);
      expect(test.right, bounds.right);
      expect(test.top, greaterThan(copy.bottom));
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _showActions(
  WidgetTester tester, {
  required double width,
  TextDirection direction = TextDirection.ltr,
  VoidCallback? onTest,
}) async {
  Widget action(String key, String label, double fixedWidth) {
    final button = OutlinedButton(
      onPressed: onTest ?? () {},
      child: Text(label),
    );
    return SizedBox(
      key: Key(key),
      width: fixedWidth,
      height: 40,
      child: button,
    );
  }

  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: RoamingActions(
                keyActions: [
                  action('generate', 'Key', 100),
                  action('copy', 'Copy', 100),
                ],
                testAction: action('test', 'Test', 80),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
