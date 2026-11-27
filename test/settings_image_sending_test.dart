// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_chat/settings_image_sending.dart';
import 'package:fluffychat/utils/image_send_options.dart';
import 'package:fluffychat/utils/image_send_preparation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() => AppSettings.store.clear());

  Future<void> showSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsImageSending(
              preparation: ImageSendPreparation(encoder: _NoOptionalCodecs()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('defaults, conditional formats and persistence', (tester) async {
    await showSettings(tester);
    expect(AppSettings.imageFormatPolicy.value, 'legacyOnly');
    expect(
      ImageSendOptions.fromSettings().formatPolicy,
      ImageFormatPolicy.legacyOnly,
    );
    expect(find.text('When the image format is outdated'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1600',
    );
    expect(
      find.byType(DropdownButtonFormField<ImageOutputFormat>),
      findsOneWidget,
    );

    await tester.tap(find.text('Use compression by default'));
    await tester.pumpAndSettle();
    expect(AppSettings.compressImagesByDefault.value, isFalse);

    await tester.tap(find.byType(DropdownButtonFormField<ImageFormatPolicy>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always use the original format').last);
    await tester.pumpAndSettle();
    expect(AppSettings.imageFormatPolicy.value, 'preserve');
    expect(
      find.byType(DropdownButtonFormField<ImageOutputFormat>),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester);
    expect(AppSettings.imageFormatPolicy.value, 'preserve');
    expect(find.text('Always use the original format'), findsOneWidget);
    expect(
      find.byType(DropdownButtonFormField<ImageOutputFormat>),
      findsNothing,
    );

    await tester.tap(find.byType(DropdownButtonFormField<ImageFormatPolicy>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('When the image format is outdated').last);
    await tester.pumpAndSettle();
    expect(AppSettings.imageFormatPolicy.value, 'legacyOnly');
    expect(
      find.byType(DropdownButtonFormField<ImageOutputFormat>),
      findsOneWidget,
    );
    await tester.tap(find.byType(DropdownButtonFormField<ImageOutputFormat>));
    await tester.pumpAndSettle();
    expect(find.text('AVIF'), findsNothing);
    expect(find.text('HEIC'), findsNothing);
    await tester.tap(find.text('JPEG').last);
    await tester.pumpAndSettle();
    expect(AppSettings.preferredImageFormat.value, 'jpeg');

    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(find.text('JPEG'), findsOneWidget);
  });

  testWidgets('invalid format preference uses the default', (tester) async {
    await AppSettings.imageFormatPolicy.setItem(
      ImageFormatPolicy.legacyOnly.name,
    );
    await AppSettings.preferredImageFormat.setItem('invalid-format');
    await showSettings(tester);
    expect(
      ImageSendOptions.fromSettings().preferredFormat,
      ImageOutputFormat.webp,
    );
    expect(find.text('WEBP'), findsOneWidget);
  });

  testWidgets('maximum dimension accepts positive integers on submit or blur', (
    tester,
  ) async {
    await showSettings(tester);
    final field = find.byType(TextField);
    for (final text in ['0', '-5', '1.5', '', 'abc']) {
      await tester.enterText(field, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(AppSettings.imageMaxDimension.value, 1600);
      expect(find.text('Invalid input!'), findsOneWidget);
    }
    await tester.enterText(field, '2048');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(AppSettings.imageMaxDimension.value, 2048);
    expect(find.text('Invalid input!'), findsNothing);

    await tester.enterText(field, '1024');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(AppSettings.imageMaxDimension.value, 1024);
  });
}

class _NoOptionalCodecs implements ImageSendEncoder {
  @override
  Future<Uint8List> encode(Uint8List png, ImageOutputFormat format) async =>
      throw UnsupportedError('Optional format unavailable');
}
