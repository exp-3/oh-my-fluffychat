// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/input_bar.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:fluffychat/pages/chat/utils/clipboard_image_to_x_file.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() async {
    await AppSettings.store.clear();
    await AppSettings.imageMaxDimension.setItem(32);
  });

  Uint8List picture({int width = 80, int height = 40}) =>
      img.encodePng(img.Image(width: width, height: height));

  Future<void> showPreview(
    WidgetTester tester,
    _SendingRoom room,
    List<XFile> files,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SendFileDialog(
                  room: room,
                  files: files,
                  outerContext: context,
                  threadRootEventId: 'thread-root',
                  threadLastEventId: 'thread-last',
                ),
              ),
              child: const Text('Open preview'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    final action = tester.widget<AdaptiveDialogAction>(
      find.widgetWithText(AdaptiveDialogAction, 'Send'),
    );
    // Isolate workers need real async time; await the actual send callback.
    await tester.runAsync(action.onPressed! as Future<void> Function());
    await tester.pumpAndSettle();
  }

  void expectSize(MatrixFile file, int width, int height) {
    expect(file, isA<MatrixImageFile>());
    final image = img.decodeImage(file.bytes)!;
    expect((image.width, image.height), (width, height));
    expect((file.info['w'], file.info['h']), (width, height));
  }

  for (final source in [
    'picker',
    'clipboard',
    'windows-clipboard',
    'generic-share',
  ]) {
    testWidgets('$source preview sends pixels within the saved maximum', (
      tester,
    ) async {
      final bytes = source == 'windows-clipboard'
          ? img.encodeBmp(img.Image(width: 80, height: 40))
          : picture();
      final file = switch (source) {
        'clipboard' => clipboardImageToXFile(bytes, isWindows: false),
        'windows-clipboard' => clipboardImageToXFile(bytes, isWindows: true),
        'generic-share' => XFile.fromData(
          bytes,
          path: 'shared-content',
          mimeType: 'application/octet-stream',
        ),
        _ => XFile.fromData(bytes, path: 'photo.png'),
      };
      final room = _SendingRoom();
      await showPreview(tester, room, [file]);
      expect(find.byType(Switch), findsOneWidget);
      await send(tester);
      expect(room.sent, hasLength(1));
      expectSize(room.sent.single, 32, 16);
    });
  }

  testWidgets('mixed batches and rate-limit retries retain resized files', (
    tester,
  ) async {
    final room = _SendingRoom(retryFirstSend: true);
    await showPreview(tester, room, [
      XFile.fromData(picture(), path: 'landscape.png'),
      XFile.fromData(picture(width: 40, height: 80), path: 'portrait.png'),
      XFile.fromData(Uint8List.fromList([1, 2, 3]), path: 'notes.txt'),
    ]);
    await send(tester);
    expect(room.sent, hasLength(4));
    expectSize(room.sent[0], 32, 16);
    expect(room.sent[1], same(room.sent[0]));
    expectSize(room.sent[2], 16, 32);
    expect(room.sent[3].mimeType, 'text/plain');
    for (final call in room.calls) {
      expect(call.namedArguments[#threadRootEventId], 'thread-root');
      expect(call.namedArguments[#threadLastEventId], 'thread-last');
      expect(call.namedArguments[#shrinkImageMaxDimension], isNull);
    }
  });

  testWidgets('preview uses the current limit instead of a hardcoded 1600', (
    tester,
  ) async {
    final room = _SendingRoom();
    await showPreview(tester, room, [
      XFile.fromData(picture(width: 2000, height: 2), path: 'wide.png'),
    ]);
    await AppSettings.imageMaxDimension.setItem(1800);
    await send(tester);
    expectSize(room.sent.single, 1800, 2);
  });

  testWidgets('disabling preview compression sends the original pixels', (
    tester,
  ) async {
    final bytes = picture();
    final room = _SendingRoom();
    await showPreview(tester, room, [XFile.fromData(bytes, path: 'photo.png')]);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await send(tester);
    expect(room.sent.single.bytes, bytes);
    expect(img.decodeImage(room.sent.single.bytes)!.width, 80);
  });

  testWidgets('unnamed clipboard images can enable compression locally', (
    tester,
  ) async {
    await AppSettings.compressImagesByDefault.setItem(false);
    final room = _SendingRoom();
    await showPreview(tester, room, [
      clipboardImageToXFile(picture(), isWindows: false),
    ]);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await send(tester);
    expectSize(room.sent.single, 32, 16);
    expect(AppSettings.compressImagesByDefault.value, isFalse);
  });

  for (final mime in ['image/png', 'application/octet-stream']) {
    testWidgets('keyboard insertion applies the saved maximum for $mime', (
      tester,
    ) async {
      final room = _SendingRoom();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: InputBar(
              room: room,
              decoration: const InputDecoration(),
              suggestionEmojis: const [],
              autofocus: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(find.byType(TextField));
      final insert =
          input.contentInsertionConfiguration!.onContentInserted
              as Future<void> Function(KeyboardInsertedContent);
      await tester.runAsync(
        () => insert(
          KeyboardInsertedContent(
            mimeType: mime,
            uri: 'content://keyboard/picture',
            data: picture(),
          ),
        ),
      );
      expectSize(room.sent.single, 32, 16);
    });
  }
}

class _SendingRoom implements Room {
  final bool retryFirstSend;
  final sent = <MatrixFile>[];
  final calls = <Invocation>[];
  final _client = _SendingClient();

  _SendingRoom({this.retryFirstSend = false});

  @override
  Object? noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #encrypted:
        return false;
      case #client:
        return _client;
      case #sendFileEvent:
        sent.add(invocation.positionalArguments.single as MatrixFile);
        calls.add(invocation);
        if (retryFirstSend && sent.length == 1) {
          return Future<String?>.error(
            MatrixException.fromJson({
              'errcode': 'M_LIMIT_EXCEEDED',
              'retry_after_ms': -1000,
            }),
          );
        }
        return Future<String?>.value('event-id');
      default:
        throw StateError('Unexpected room call: ${invocation.memberName}');
    }
  }
}

class _SendingClient implements Client {
  @override
  Object? noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getConfig) {
      return Future.value(MediaConfig());
    }
    throw StateError('Unexpected client call: ${invocation.memberName}');
  }
}
