// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/utils/translation/translation_api_client.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('strict response matching ignores array order', () {
    final result = TranslationApiClient.parseTranslations(
      '{"translations":[{"id":"b","text":"B"},{"id":"a","text":"A"}]}',
      {'a', 'b'},
    );
    expect(result, {'a': 'A', 'b': 'B'});
  });

  test(
    'strict response matching rejects missing, duplicate, and extra IDs',
    () {
      expect(
        () => TranslationApiClient.parseTranslations(
          '{"translations":[{"id":"a","text":"A"}]}',
          {'a', 'b'},
        ),
        throwsA(isA<TranslationProtocolException>()),
      );
      expect(
        () => TranslationApiClient.parseTranslations(
          '{"translations":[{"id":"a","text":"A"},{"id":"a","text":"B"}]}',
          {'a'},
        ),
        throwsA(isA<TranslationProtocolException>()),
      );
      expect(
        () => TranslationApiClient.parseTranslations(
          '{"translations":[{"id":"a","text":"A"},{"id":"x","text":"X"}]}',
          {'a'},
        ),
        throwsA(isA<TranslationProtocolException>()),
      );
    },
  );

  test('strict response matching rejects extra top-level fields', () {
    expect(
      () => TranslationApiClient.parseTranslations(
        '{"translations":[{"id":"a","text":"A"}],"note":"extra"}',
        {'a'},
      ),
      throwsA(isA<TranslationProtocolException>()),
    );
  });

  test('request prompt includes the Matrix message type for m.emote', () async {
    late Map<String, Object?> requestBody;
    late Uri requestUrl;
    final apiClient = TranslationApiClient(
      MockClient((request) async {
        requestUrl = request.url;
        requestBody = (jsonDecode(request.body) as Map<Object?, Object?>)
            .cast<String, Object?>();
        return http.Response(
          '{"choices":[{"message":{"content":"{\\"translations\\":[{\\"id\\":\\"opaque-id\\",\\"text\\":\\"waves\\"}]}"}}]}',
          200,
        );
      }),
    );

    await apiClient.translate(
      provider: TranslationProviderConfig(
        id: 'provider-id',
        name: 'Example',
        endpoint: Uri.parse('https://example.test/v1'),
        useFullEndpoint: false,
        protocol: TranslationProtocol.chatCompletions,
        model: 'example-model',
      ),
      apiKey: 'test-key',
      messages: const {
        'opaque-id': TranslationRequestMessage(
          text: 'waves',
          messageType: 'm.emote',
        ),
      },
      sourceLanguage: 'auto',
      targetLanguage: 'en',
    );

    expect(requestUrl, Uri.parse('https://example.test/v1/chat/completions'));

    final chatMessages = requestBody['messages']! as List<Object?>;
    final userMessage = (chatMessages.last! as Map<Object?, Object?>)
        .cast<String, Object?>();
    final prompt =
        (jsonDecode(userMessage['content']! as String) as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(prompt['messages'], [
      {'id': 'opaque-id', 'text': 'waves', 'message_type': 'm.emote'},
    ]);
  });
}
