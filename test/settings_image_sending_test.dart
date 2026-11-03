// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:fluffychat/pages/settings_chat/settings_chat.dart';
import 'package:fluffychat/pages/settings_chat/settings_image_sending.dart';
import 'package:fluffychat/utils/image_send_options.dart';
import 'package:fluffychat/utils/image_send_preparation.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    // Finish native probes outside the widget tests' fake clock.
    await ImageSendPreparation.instance.supportedFormats();
  });

  setUp(() => AppSettings.store.clear());

  Future<void> showSettings(WidgetTester tester, {Widget? child}) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home:
            child ??
            Scaffold(
              body: SingleChildScrollView(
                child: SettingsImageSending(
                  preparation: ImageSendPreparation(
                    encoder: _NoOptionalCodecs(),
                  ),
                ),
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('defaults, conditional formats and persistence', (tester) async {
    await showSettings(tester);
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
      findsNothing,
    );

    await tester.tap(find.text('Use compression by default'));
    await tester.pumpAndSettle();
    expect(AppSettings.compressImagesByDefault.value, isFalse);

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

  testWidgets('compression group appears above custom emojis and stickers', (
    tester,
  ) async {
    await showSettings(tester, child: const SettingsChat());
    expect(
      tester.getTopLeft(find.text('Compress images when sending')).dy,
      lessThan(
        tester.getTopLeft(find.text('Custom emojis and stickers').first).dy,
      ),
    );
  });

  testWidgets(
    'mixed previews use the image default and allow a local override',
    (tester) async {
      await AppSettings.compressImagesByDefault.setItem(false);
      await showSettings(
        tester,
        child: Builder(
          builder: (context) => SendFileDialog(
            room: _PreviewRoom(),
            outerContext: context,
            threadRootEventId: null,
            threadLastEventId: null,
            files: [
              XFile.fromData(
                Uint8List(0),
                name: 'image.png',
                mimeType: 'image/png',
              ),
              XFile.fromData(
                Uint8List(0),
                name: 'video.mp4',
                mimeType: 'video/mp4',
              ),
            ],
          ),
        ),
      );
      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(PlatformInfos.isMobile ? 2 : 1));
      expect(tester.widget<Switch>(switches.first).value, isFalse);
      await tester.tap(switches.first);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(switches.first).value, isTrue);
      expect(AppSettings.compressImagesByDefault.value, isFalse);
    },
  );
}

class _NoOptionalCodecs implements ImageSendEncoder {
  @override
  Future<Uint8List> encode(Uint8List png, ImageOutputFormat format) async =>
      throw UnsupportedError('Optional format unavailable');
}

class _PreviewRoom implements Room {
  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw StateError('Preview must not access room state');
}
