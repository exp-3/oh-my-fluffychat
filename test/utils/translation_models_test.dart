// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('batch settings defaults and boundaries are valid', () {
    expect(TranslationBatchSettings.defaults.mergeWindowMs, 100);
    expect(TranslationBatchSettings.defaults.maxMessages, 4);
    expect(TranslationBatchSettings.defaults.maxCharacters, 1000);
    expect(TranslationBatchSettings.defaults.malformedResponseRetries, 2);
    expect(
      const TranslationBatchSettings(
        mergeWindowMs: 0,
        maxMessages: 1,
        maxCharacters: 100,
        malformedResponseRetries: 0,
      ).isValid,
      isTrue,
    );
    expect(
      const TranslationBatchSettings(
        mergeWindowMs: 2000,
        maxMessages: 50,
        maxCharacters: 20000,
        malformedResponseRetries: 3,
      ).isValid,
      isTrue,
    );
    expect(const TranslationBatchSettings(maxCharacters: 99).isValid, isFalse);
  });

  test('character limits count Unicode code points', () {
    expect(unicodeCodePointLength('A😀B'), 3);
    expect(unicodeCodePointLength('👨‍👩‍👧'), 5);
  });

  test('provider metadata round trips without secrets', () {
    final provider = TranslationProviderConfig(
      id: 'provider-id',
      name: 'Example',
      endpoint: Uri.parse('https://example.test/v1/responses'),
      protocol: TranslationProtocol.responses,
      model: 'example-model',
    );
    final decoded = TranslationProviderConfig.decodeList(
      TranslationProviderConfig.encodeList([provider]),
    ).single;
    expect(decoded.id, provider.id);
    expect(decoded.protocol, TranslationProtocol.responses);
    expect(decoded.useFullEndpoint, isTrue);
    expect(decoded.toJson().containsKey('apiKey'), isFalse);
  });

  test('provider base URL resolves an endpoint for each API protocol', () {
    TranslationProviderConfig provider(TranslationProtocol protocol) =>
        TranslationProviderConfig(
          id: 'provider-id',
          name: 'Example',
          endpoint: Uri.parse('https://example.test/v1'),
          useFullEndpoint: false,
          protocol: protocol,
          model: 'example-model',
        );

    expect(
      provider(TranslationProtocol.chatCompletions).requestEndpoint,
      Uri.parse('https://example.test/v1/chat/completions'),
    );
    expect(
      provider(TranslationProtocol.responses).requestEndpoint,
      Uri.parse('https://example.test/v1/responses'),
    );
  });

  test('legacy provider metadata treats its address as a full endpoint', () {
    final decoded = TranslationProviderConfig.fromJson({
      'id': 'provider-id',
      'name': 'Example',
      'endpoint': 'https://example.test/custom/endpoint',
      'protocol': TranslationProtocol.responses.name,
      'model': 'example-model',
    });

    expect(decoded.useFullEndpoint, isTrue);
    expect(decoded.requestEndpoint, decoded.endpoint);
  });

  test('provider endpoints require a valid HTTPS host or local HTTP host', () {
    TranslationProviderConfig provider(Uri endpoint) =>
        TranslationProviderConfig(
          id: 'provider-id',
          name: 'Example',
          endpoint: endpoint,
          protocol: TranslationProtocol.responses,
          model: 'example-model',
        );

    expect(
      provider(Uri.parse('https://example.test/v1/responses')).isValid,
      isTrue,
    );
    expect(provider(Uri.parse('https:/v1/responses')).isValid, isFalse);
    expect(
      provider(Uri.parse('http://localhost/v1/responses')).isValid,
      isTrue,
    );
    expect(
      provider(Uri.parse('http://example.test/v1/responses')).isValid,
      isFalse,
    );
    expect(
      provider(
        Uri.parse('https://example.test/v1/responses?api_key=secret'),
      ).isValid,
      isFalse,
    );
    expect(
      provider(
        Uri.parse('https://user:secret@example.test/v1/responses'),
      ).isValid,
      isFalse,
    );
    expect(
      provider(Uri.parse('https://example.test/v1/responses#fragment')).isValid,
      isFalse,
    );
    expect(
      provider(Uri.parse('https://example.test/v1/responses?')).isValid,
      isFalse,
    );
    expect(
      provider(Uri.parse('https://example.test/v1/responses#')).isValid,
      isFalse,
    );
  });
}
