// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:fluffychat/utils/translation/translation_api_client.dart';
import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/dialog_text_field.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/translation_test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final runtime = TranslationRuntime.instance;
  late final _CaptionApiClient api;
  final backend = MemoryTranslationBackend();

  setUpAll(() async {
    api = _CaptionApiClient();
    final provider = TranslationProviderConfig(
      id: 'caption-provider',
      name: 'Caption test provider',
      endpoint: Uri.parse('https://translation.example.invalid/v1/responses'),
      protocol: TranslationProtocol.responses,
      model: 'test-model',
    );
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.translation.enabled': true,
      'chat.fluffy.translation.privacy_accepted': true,
      'chat.fluffy.translation.providers': TranslationProviderConfig.encodeList(
        [provider],
      ),
      'chat.fluffy.translation.selected_provider': provider.id,
      'chat.fluffy.translation.batch.merge_ms': 0,
    });
    await AppSettings.init(loadWebConfigFile: false);
    final secrets = _CaptionSecrets()
      ..values['chat.fluffy.translation.provider_api_key.${provider.id}'] =
          'test-key';
    await runtime.initialize(
      AppSettings.store,
      secrets: secrets,
      apiClient: api,
      cache: TranslationCache(secrets, backend),
    );
  });

  setUp(() async {
    api.reset();
    await runtime.setEnabled(true);
    await runtime.setScope(TranslationScope.none);
    await runtime.setInputMode(InputTranslationMode.automatic);
    await runtime.setInputScope(InputTranslationScope.allRooms);
    await runtime.setInputLanguages(source: 'auto', target: 'fr');
    await runtime.setInputSendMode(
      InputTranslationSendMode.shortTranslatedLongOriginal,
    );
  });

  tearDownAll(runtime.dispose);

  testWidgets('send translates the caption before upload and keeps threading', (
    tester,
  ) async {
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: '  Hello <world>  ');
    await _send(tester);

    expect(api.requests.single.single.text, 'Hello <world>');
    expect(api.requests.single.single.messageType, MessageTypes.Text);
    expect(room.calls, hasLength(1));
    expect(room.calls.single.namedArguments[#extraContent], {
      'body': 'Translated caption',
    });
    expect(room.calls.single.namedArguments[#threadRootEventId], 'thread-root');
    expect(room.calls.single.namedArguments[#threadLastEventId], 'thread-last');
    expect(find.byType(SendFileDialog), findsNothing);
    expect(backend.createCalls, 0);
  });

  testWidgets('slash-prefixed captions are literal text for translation', (
    tester,
  ) async {
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: '/some caption');
    await _send(tester);

    expect(api.requests.single.single.text, '/some caption');
    expect(room.calls.single.namedArguments[#extraContent], {
      'body': 'Translated caption',
    });
  });

  testWidgets('default-original send preference keeps the caption unchanged', (
    tester,
  ) async {
    await runtime.setInputSendMode(
      InputTranslationSendMode.shortOriginalLongTranslated,
    );
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    await _send(tester);

    expect(api.requests, isEmpty);
    expect(room.calls.single.namedArguments[#extraContent], {
      'body': 'Original caption',
    });
  });

  for (final mode in [
    InputTranslationMode.disabled,
    InputTranslationMode.manual,
  ]) {
    testWidgets('${mode.name} input mode does not translate a sent caption', (
      tester,
    ) async {
      await runtime.setInputMode(mode);
      final room = _CaptionSendingRoom();
      await _showPreview(tester, room, caption: 'Original caption');
      await _send(tester);

      expect(api.requests, isEmpty);
      expect(room.calls.single.namedArguments[#extraContent], {
        'body': 'Original caption',
      });
    });
  }

  testWidgets('global disable bypasses caption translation', (tester) async {
    await runtime.setEnabled(false);
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    await _send(tester);

    expect(api.requests, isEmpty);
    expect(room.calls.single.namedArguments[#extraContent], {
      'body': 'Original caption',
    });
  });

  testWidgets('input scope follows automatic room eligibility', (tester) async {
    await runtime.setInputScope(InputTranslationScope.automaticRooms);
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    await _send(tester);

    expect(api.requests, isEmpty);
    expect(room.calls.single.namedArguments[#extraContent], {
      'body': 'Original caption',
    });

    await runtime.setScope(TranslationScope.allRooms);
    await _showPreview(tester, room, caption: 'Now eligible');
    await _send(tester);

    expect(api.requests.single.single.text, 'Now eligible');
    expect(room.calls.last.namedArguments[#extraContent], {
      'body': 'Translated caption',
    });
  });

  testWidgets('blank caption sends without a translation request', (
    tester,
  ) async {
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: '   ');
    await _send(tester);

    expect(api.requests, isEmpty);
    expect(room.calls.single.namedArguments[#extraContent], isNull);
  });

  for (final emptyResponse in [false, true]) {
    testWidgets(
      '${emptyResponse ? 'empty' : 'failed'} translation retains the draft and sends nothing',
      (tester) async {
        if (emptyResponse) {
          api.translation = '';
        } else {
          api.failure = StateError('Translation failed');
        }
        final room = _CaptionSendingRoom();
        await _showPreview(tester, room, caption: 'Original caption');
        await _send(tester);

        expect(api.requests, hasLength(1));
        expect(room.calls, isEmpty);
        expect(find.byType(SendFileDialog), findsOneWidget);
        expect(_captionField(tester).controller!.text, 'Original caption');
        expect(_captionField(tester).readOnly, isFalse);
        final l10n = L10n.of(tester.element(find.byType(SendFileDialog)));
        expect(find.text(l10n.translationFailed), findsOneWidget);

        api.failure = null;
        api.translation = 'Recovered caption';
        await _send(tester);
        expect(room.calls.single.namedArguments[#extraContent], {
          'body': 'Recovered caption',
        });
        final file = room.calls.single.positionalArguments.single as MatrixFile;
        expect(file.name, 'notes.txt');
        expect(file.bytes, [1, 2, 3]);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('in-flight translation blocks duplicate sends', (tester) async {
    api.reply = Completer<String>();
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    final callback = _sendCallback(tester);
    final sending = callback();
    await tester.pump();
    expect(api.started.isCompleted, isTrue);
    await callback();

    expect(_captionField(tester).readOnly, isTrue);
    expect(room.calls, isEmpty);
    expect(api.requests, hasLength(1));

    api.reply!.complete('Accepted caption');
    await sending;
    await tester.pumpAndSettle();
    expect(room.calls, hasLength(1));
    expect(room.calls.single.namedArguments[#extraContent], {
      'body': 'Accepted caption',
    });
  });

  testWidgets('configuration changes discard a pending translated send', (
    tester,
  ) async {
    api.reply = Completer<String>();
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    final sending = _sendCallback(tester)();
    await tester.pump();
    expect(api.started.isCompleted, isTrue);
    await runtime.setInputSendMode(
      InputTranslationSendMode.shortOriginalLongTranslated,
    );
    api.reply!.complete('Obsolete caption');
    await sending;
    await tester.pumpAndSettle();

    expect(room.calls, isEmpty);
    expect(find.byType(SendFileDialog), findsOneWidget);
    expect(_captionField(tester).controller!.text, 'Original caption');
    expect(_captionField(tester).readOnly, isFalse);
  });

  testWidgets('caption replacement discards a pending translation', (
    tester,
  ) async {
    api.reply = Completer<String>();
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    final sending = _sendCallback(tester)();
    await tester.pump();
    expect(api.started.isCompleted, isTrue);
    _captionField(tester).controller!.text = 'Replacement caption';
    api.reply!.complete('Obsolete caption');
    await sending;
    await tester.pumpAndSettle();

    expect(room.calls, isEmpty);
    expect(_captionField(tester).controller!.text, 'Replacement caption');
  });

  testWidgets('cancelling the dialog discards a pending translation', (
    tester,
  ) async {
    api.reply = Completer<String>();
    final room = _CaptionSendingRoom();
    await _showPreview(tester, room, caption: 'Original caption');
    final sending = _sendCallback(tester)();
    await tester.pump();
    expect(api.started.isCompleted, isTrue);
    await tester.tap(find.widgetWithText(AdaptiveDialogAction, 'Cancel'));
    await tester.pumpAndSettle();
    api.reply!.complete('Cancelled caption');
    await sending;
    await tester.pumpAndSettle();

    expect(find.byType(SendFileDialog), findsNothing);
    expect(room.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rate-limit retry reuses the translated caption', (tester) async {
    final room = _CaptionSendingRoom(retryFirstSend: true);
    await _showPreview(tester, room, caption: 'Original caption');
    await _send(tester);

    expect(api.requests, hasLength(1));
    expect(room.calls, hasLength(2));
    for (final call in room.calls) {
      expect(call.namedArguments[#extraContent], {
        'body': 'Translated caption',
      });
    }
    expect(
      room.calls.first.positionalArguments.single,
      same(room.calls.last.positionalArguments.single),
    );
  });
}

Future<void> _showPreview(
  WidgetTester tester,
  _CaptionSendingRoom room, {
  required String caption,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
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
                files: [
                  XFile.fromData(
                    Uint8List.fromList([1, 2, 3]),
                    name: 'notes.txt',
                    path: 'notes.txt',
                    mimeType: 'text/plain',
                  ),
                ],
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
  await tester.enterText(find.byType(TextField), caption);
}

DialogTextField _captionField(WidgetTester tester) =>
    tester.widget<DialogTextField>(find.byType(DialogTextField));

Future<void> Function() _sendCallback(WidgetTester tester) {
  final action = tester.widget<AdaptiveDialogAction>(
    find.widgetWithText(AdaptiveDialogAction, 'Send'),
  );
  return action.onPressed! as Future<void> Function();
}

Future<void> _send(WidgetTester tester) async {
  // Keep SnackBar animation callbacks in the widget test's async zone.
  final sending = _sendCallback(tester)();
  await tester.pumpAndSettle();
  await sending;
}

class _CaptionApiClient extends TranslationApiClient {
  final requests = <List<TranslationRequestMessage>>[];
  String translation = 'Translated caption';
  Object? failure;
  Completer<String>? reply;
  Completer<void> started = Completer<void>();

  void reset() {
    requests.clear();
    translation = 'Translated caption';
    failure = null;
    reply = null;
    started = Completer<void>();
  }

  @override
  Future<Map<String, String>> translate({
    required TranslationProviderConfig provider,
    required String apiKey,
    required Map<String, TranslationRequestMessage> messages,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    requests.add(messages.values.toList());
    if (!started.isCompleted) started.complete();
    final error = failure;
    if (error != null) throw error;
    final text = reply == null ? translation : await reply!.future;
    return {for (final id in messages.keys) id: text};
  }
}

class _CaptionSecrets implements TranslationSecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _CaptionSendingRoom implements Room {
  final bool retryFirstSend;
  final calls = <Invocation>[];
  final _client = _CaptionSendingClient();

  _CaptionSendingRoom({this.retryFirstSend = false});

  @override
  Object? noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #id:
        return '!caption:test';
      case #encrypted:
        return false;
      case #client:
        return _client;
      case #sendFileEvent:
        calls.add(invocation);
        if (retryFirstSend && calls.length == 1) {
          return Future<String?>.error(
            MatrixException.fromJson({
              'errcode': 'M_LIMIT_EXCEEDED',
              'retry_after_ms': -1000,
            }),
          );
        }
        return Future<String?>.value('sent-event');
      default:
        throw StateError('Unexpected room call: ${invocation.memberName}');
    }
  }
}

class _CaptionSendingClient implements Client {
  @override
  Object? noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #userID:
        return '@caption:test';
      case #getConfig:
        return Future.value(MediaConfig());
      default:
        throw StateError('Unexpected client call: ${invocation.memberName}');
    }
  }
}
