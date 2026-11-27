// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('batch settings boundaries are valid', () {
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
    expect(decoded.reasoningEffort, TranslationReasoningEffort.unspecified);
    expect(decoded.toJson().containsKey('apiKey'), isFalse);
  });

  test('reasoning metadata round trips for every protocol', () {
    for (final protocol in TranslationProtocol.values) {
      for (final effort in TranslationReasoningEffort.values) {
        final provider = TranslationProviderConfig(
          id: 'provider-id',
          name: 'Example',
          endpoint: Uri.parse('https://example.test/v1'),
          useFullEndpoint: false,
          protocol: protocol,
          model: 'example-model',
          reasoningEffort: effort,
        );
        final decoded = TranslationProviderConfig.decodeList(
          TranslationProviderConfig.encodeList([provider]),
        ).single;

        expect(decoded.toJson(), provider.toJson());
        expect(decoded.reasoningEffort, effort);
      }
    }
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
    expect(
      provider(TranslationProtocol.anthropicMessages).requestEndpoint,
      Uri.parse('https://example.test/v1/messages'),
    );
  });

  test('Anthropic preserves complete endpoints and base URL prefixes', () {
    for (final endpoint in [
      'https://example.test/proxy/v1',
      'https://example.test/proxy/v1/',
    ]) {
      final provider = TranslationProviderConfig(
        id: 'provider-id',
        name: 'Example',
        endpoint: Uri.parse(endpoint),
        useFullEndpoint: false,
        protocol: TranslationProtocol.anthropicMessages,
        model: 'example-model',
      );
      expect(
        provider.requestEndpoint,
        Uri.parse('https://example.test/proxy/v1/messages'),
      );
    }
    final provider = TranslationProviderConfig(
      id: 'provider-id',
      name: 'Example',
      endpoint: Uri.parse('https://example.test/custom/messages'),
      protocol: TranslationProtocol.anthropicMessages,
      model: 'example-model',
    );
    expect(provider.requestEndpoint, provider.endpoint);
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
    expect(decoded.reasoningEffort, TranslationReasoningEffort.unspecified);
  });

  test('legacy authentication metadata and unknown reasoning are accepted', () {
    final provider = TranslationProviderConfig.fromJson({
      'id': 'provider-id',
      'name': 'Example',
      'endpoint': 'https://example.test/v1/responses',
      'protocol': TranslationProtocol.responses.name,
      'model': 'example-model',
      'auth_method': 'apiKey',
      'reasoning_effort': 'future-effort',
    });

    expect(provider.toJson().containsKey('auth_method'), isFalse);
    expect(provider.reasoningEffort, TranslationReasoningEffort.unspecified);
  });

  test('provider endpoints require a valid HTTP or HTTPS host', () {
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
    for (final endpoint in [
      'http://example.test/v1/responses',
      'http://192.168.1.10:8080/v1/responses',
      'http://[fd00::1]:8080/v1/responses',
      'http://localhost/v1/responses',
      'http://127.0.0.1/v1/responses',
      'http://[::1]/v1/responses',
    ]) {
      final value = provider(Uri.parse(endpoint));
      expect(value.isValid, isTrue, reason: endpoint);
      final decoded = TranslationProviderConfig.decodeList(
        TranslationProviderConfig.encodeList([value]),
      ).single;
      expect(decoded.toJson(), value.toJson());
    }
    for (final endpoint in [
      'http:/v1/responses',
      'ftp://example.test/v1/responses',
      'http://example.test/v1/responses?api_key=secret',
      'http://user:secret@example.test/v1/responses',
      'http://example.test/v1/responses#fragment',
    ]) {
      expect(provider(Uri.parse(endpoint)).isValid, isFalse, reason: endpoint);
    }
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
