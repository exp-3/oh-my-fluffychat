// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/settings_translation/roaming_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('actions start a new equal-width row after the divider', (
    tester,
  ) async {
    var testsStarted = 0;
    var uploadsStarted = 0;
    for (final direction in TextDirection.values) {
      await _showActions(
        tester,
        width: 400,
        direction: direction,
        onTest: () => testsStarted++,
        onUpload: () => uploadsStarted++,
      );

      final bounds = tester.getRect(find.byType(RoamingActions));
      final generate = tester.getRect(find.byKey(const Key('generate')));
      final divider = tester.getRect(find.byType(Divider));
      final test = tester.getRect(find.byKey(const Key('test')));
      final upload = tester.getRect(find.byKey(const Key('upload')));
      expect(divider.top, greaterThanOrEqualTo(generate.bottom));
      expect(test.top, greaterThanOrEqualTo(divider.bottom));
      expect(test.center.dy, upload.center.dy);
      expect(test.width, upload.width);
      if (direction == TextDirection.ltr) {
        expect(test.left, bounds.left);
        expect(upload.right, bounds.right);
      } else {
        expect(test.right, bounds.right);
        expect(upload.left, bounds.left);
      }
      await tester.tap(find.byKey(const Key('test')));
      await tester.tap(find.byKey(const Key('upload')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(testsStarted, 2);
    expect(uploadsStarted, 2);
  });

  testWidgets('narrow screens use full-width action buttons', (tester) async {
    for (final direction in TextDirection.values) {
      for (final width in [250.0, 150.0]) {
        await _showActions(tester, width: width, direction: direction);
        final bounds = tester.getRect(find.byType(RoamingActions));
        final divider = tester.getRect(find.byType(Divider));
        final test = tester.getRect(find.byKey(const Key('test')));
        final upload = tester.getRect(find.byKey(const Key('upload')));

        expect(test.left, bounds.left);
        expect(test.right, bounds.right);
        expect(test.top, greaterThanOrEqualTo(divider.bottom));
        expect(upload.left, bounds.left);
        expect(upload.right, bounds.right);
        expect(upload.top, greaterThan(test.bottom));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('large text stacks the action buttons without layout mutations', (
    tester,
  ) async {
    await _showActions(tester, width: 400, textScale: 2);
    final test = tester.getRect(find.byKey(const Key('test')));
    final upload = tester.getRect(find.byKey(const Key('upload')));
    expect(upload.top, greaterThan(test.bottom));
    expect(test.width, 400);
    expect(upload.width, 400);
    expect(tester.takeException(), isNull);

    await _showActions(tester, width: 400);
    expect(
      tester.getRect(find.byKey(const Key('test'))).top,
      tester.getRect(find.byKey(const Key('upload'))).top,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _showActions(
  WidgetTester tester, {
  required double width,
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  VoidCallback? onTest,
  VoidCallback? onUpload,
}) async {
  Widget action(
    String key,
    String label, {
    double? fixedWidth,
    VoidCallback? onPressed,
  }) => SizedBox(
    key: Key(key),
    width: fixedWidth,
    height: 40 * textScale,
    child: OutlinedButton(onPressed: onPressed ?? () {}, child: Text(label)),
  );

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
                    action('generate', 'Key', fixedWidth: 100),
                    action('copy', 'Copy', fixedWidth: 100),
                  ],
                  testAction: action('test', 'Test', onPressed: onTest),
                  uploadAction: action('upload', 'Upload', onPressed: onUpload),
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
