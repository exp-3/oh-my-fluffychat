// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
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

  for (final protocol in TranslationProtocol.values) {
    for (final effort in TranslationReasoningEffort.values) {
      test('${protocol.name} request with ${effort.name} effort', () async {
        late http.Request request;
        final apiClient = TranslationApiClient(
          MockClient((value) async {
            request = value;
            return _successResponse(protocol);
          }),
        );

        expect(
          await _translate(apiClient, protocol: protocol, effort: effort),
          {'opaque-id': 'waves'},
        );
        expect(request.method, 'POST');
        expect(request.url.path, switch (protocol) {
          TranslationProtocol.chatCompletions => '/v1/chat/completions',
          TranslationProtocol.responses => '/v1/responses',
          TranslationProtocol.anthropicMessages => '/v1/messages',
        });
        expect(request.headers['content-type'], 'application/json');
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['model'], 'example-model');
        final hasEffort = effort != TranslationReasoningEffort.unspecified;
        if (protocol == TranslationProtocol.anthropicMessages || hasEffort) {
          expect(body, isNot(contains('temperature')));
        } else {
          expect(body['temperature'], 0);
        }

        late String prompt;
        switch (protocol) {
          case TranslationProtocol.chatCompletions:
            {
              if (hasEffort) {
                expect(body['reasoning_effort'], effort.name);
              } else {
                expect(body, isNot(contains('reasoning_effort')));
              }
              expect(body, isNot(contains('reasoning')));
              expect(body, isNot(contains('output_config')));
              expect(body['response_format'], {'type': 'json_object'});
              final messages = body['messages']! as List<Object?>;
              expect(messages, hasLength(2));
              expect(messages.first, containsPair('role', 'system'));
              prompt =
                  (messages.last! as Map<String, Object?>)['content']!
                      as String;
            }
          case TranslationProtocol.responses:
            {
              if (hasEffort) {
                expect(body['reasoning'], {'effort': effort.name});
              } else {
                expect(body, isNot(contains('reasoning')));
              }
              expect(body, isNot(contains('reasoning_effort')));
              expect(
                body['instructions'],
                contains('precise message translator'),
              );
              final format =
                  (body['text']! as Map<String, Object?>)['format']!
                      as Map<String, Object?>;
              expect(format['type'], 'json_schema');
              expect(format['name'], 'translations');
              expect(format['strict'], isTrue);
              _expectTranslationSchema(format['schema']);
              prompt = body['input']! as String;
            }
          case TranslationProtocol.anthropicMessages:
            {
              expect(body['max_tokens'], 4096);
              expect(body['system'], contains('precise message translator'));
              final output = body['output_config']! as Map<String, Object?>;
              if (hasEffort) {
                expect(output['effort'], effort.name);
              } else {
                expect(output, isNot(contains('effort')));
              }
              expect(body, isNot(contains('reasoning')));
              expect(body, isNot(contains('reasoning_effort')));
              expect(body, isNot(contains('response_format')));
              final format = output['format']! as Map<String, Object?>;
              expect(format['type'], 'json_schema');
              _expectTranslationSchema(format['schema']);
              final messages = body['messages']! as List<Object?>;
              expect(messages, hasLength(1));
              expect(messages.single, containsPair('role', 'user'));
              prompt =
                  (messages.single! as Map<String, Object?>)['content']!
                      as String;
            }
        }
        expect(jsonDecode(prompt), {
          'source_language': 'auto',
          'target_language': 'en',
          'messages': [
            {'id': 'opaque-id', 'text': 'waves', 'message_type': 'm.emote'},
          ],
        });
      });
    }

    test('${protocol.name} sends both authentication headers', () async {
      late Map<String, String> headers;
      final apiClient = TranslationApiClient(
        MockClient((request) async {
          headers = request.headers;
          return _successResponse(protocol);
        }),
      );

      await _translate(apiClient, protocol: protocol);

      expect(headers['authorization'], 'Bearer test-key');
      expect(headers['x-api-key'], 'test-key');
      if (protocol == TranslationProtocol.anthropicMessages) {
        expect(headers['anthropic-version'], '2026-10-21');
      } else {
        expect(headers, isNot(contains('anthropic-version')));
      }
      if (protocol == TranslationProtocol.anthropicMessages &&
          const bool.fromEnvironment('dart.library.js_interop')) {
        expect(headers['anthropic-dangerous-direct-browser-access'], 'true');
      } else {
        expect(
          headers,
          isNot(contains('anthropic-dangerous-direct-browser-access')),
        );
      }
    });
  }

  test(
    'Anthropic concatenates text blocks and ignores thinking blocks',
    () async {
      final text = jsonEncode(_translations);
      final splitAt = text.length ~/ 2;
      final apiClient = TranslationApiClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'thinking', 'thinking': 'Not translation JSON'},
                {'type': 'text', 'text': text.substring(0, splitAt)},
                {'type': 'redacted_thinking', 'data': 'opaque'},
                {'type': 'text', 'text': text.substring(splitAt)},
              ],
            }),
            200,
          ),
        ),
      );

      expect(
        await _translate(
          apiClient,
          protocol: TranslationProtocol.anthropicMessages,
        ),
        {'opaque-id': 'waves'},
      );
    },
  );

  final invalidAnthropicResponses = <String, Map<String, Object?>>{
    'missing content': {},
    'invalid content': {'content': 'text'},
    'empty content': {'content': []},
    'thinking only': {
      'content': [
        {'type': 'thinking', 'thinking': jsonEncode(_translations)},
      ],
    },
    'invalid text block': {
      'content': [
        {'type': 'text', 'text': 42},
      ],
    },
    'truncated output': {
      'stop_reason': 'max_tokens',
      'content': [
        {'type': 'text', 'text': jsonEncode(_translations)},
      ],
    },
    'refusal': {
      'stop_reason': 'refusal',
      'content': [
        {'type': 'text', 'text': jsonEncode(_translations)},
      ],
    },
    'context limit': {
      'stop_reason': 'model_context_window_exceeded',
      'content': [
        {'type': 'text', 'text': jsonEncode(_translations)},
      ],
    },
    'unexpected translation ID': {
      'content': [
        {
          'type': 'text',
          'text': '{"translations":[{"id":"other","text":"X"}]}',
        },
      ],
    },
  };
  for (final entry in invalidAnthropicResponses.entries) {
    test('Anthropic rejects ${entry.key}', () async {
      final apiClient = TranslationApiClient(
        MockClient((_) async => http.Response(jsonEncode(entry.value), 200)),
      );

      await expectLater(
        _translate(apiClient, protocol: TranslationProtocol.anthropicMessages),
        throwsA(isA<TranslationProtocolException>()),
      );
    });
  }

  test(
    'Anthropic HTTP errors do not expose response bodies or credentials',
    () async {
      final apiClient = TranslationApiClient(
        MockClient((_) async => http.Response('sensitive provider error', 400)),
      );

      await expectLater(
        _translate(apiClient, protocol: TranslationProtocol.anthropicMessages),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            'Translation provider returned HTTP 400',
          ),
        ),
      );
    },
  );
}

const _translations = {
  'translations': [
    {'id': 'opaque-id', 'text': 'waves'},
  ],
};

http.Response _successResponse(TranslationProtocol protocol) {
  final text = jsonEncode(_translations);
  return http.Response(
    jsonEncode(switch (protocol) {
      TranslationProtocol.chatCompletions => {
        'choices': [
          {
            'message': {'content': text},
          },
        ],
      },
      TranslationProtocol.responses => {
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          },
        ],
      },
      TranslationProtocol.anthropicMessages => {
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    }),
    200,
  );
}

Future<Map<String, String>> _translate(
  TranslationApiClient apiClient, {
  required TranslationProtocol protocol,
  TranslationReasoningEffort effort = TranslationReasoningEffort.unspecified,
}) => apiClient.translate(
  provider: TranslationProviderConfig(
    id: 'provider-id',
    name: 'Example',
    endpoint: Uri.parse('https://example.test/v1'),
    useFullEndpoint: false,
    protocol: protocol,
    model: 'example-model',
    reasoningEffort: effort,
  ),
  apiKey: ' test-key ',
  messages: const {
    'opaque-id': TranslationRequestMessage(
      text: 'waves',
      messageType: 'm.emote',
    ),
  },
  sourceLanguage: 'auto',
  targetLanguage: 'en',
);

void _expectTranslationSchema(Object? value) {
  expect(value, isA<Map<String, Object?>>());
  final schema = value! as Map<String, Object?>;
  expect(schema['type'], 'object');
  expect(schema['additionalProperties'], isFalse);
  expect(schema['required'], ['translations']);
  final translations =
      (schema['properties']! as Map<String, Object?>)['translations']!
          as Map<String, Object?>;
  expect(translations['type'], 'array');
  final item = translations['items']! as Map<String, Object?>;
  expect(item['additionalProperties'], isFalse);
  expect(item['required'], ['id', 'text']);
}
