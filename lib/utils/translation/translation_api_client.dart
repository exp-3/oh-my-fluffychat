// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_models.dart';

class TranslationProtocolException implements Exception {
  final String message;
  const TranslationProtocolException(this.message);

  @override
  String toString() => 'TranslationProtocolException: $message';
}

class TranslationApiClient {
  final http.Client client;

  TranslationApiClient([http.Client? client])
    : client = client ?? http.Client();

  Future<Map<String, String>> translate({
    required TranslationProviderConfig provider,
    required String apiKey,
    required Map<String, TranslationRequestMessage> messages,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (!provider.isValid) {
      throw ArgumentError.value(provider, 'provider');
    }
    final normalizedApiKey = apiKey.trim();
    if (normalizedApiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey');
    }
    final prompt = _userPrompt(messages, sourceLanguage, targetLanguage);
    final body = switch (provider.protocol) {
      TranslationProtocol.chatCompletions => {
        'model': provider.model,
        'temperature': 0,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': prompt},
        ],
      },
      TranslationProtocol.responses => {
        'model': provider.model,
        'temperature': 0,
        'instructions': _systemPrompt,
        'input': prompt,
        'text': {
          'format': {
            'type': 'json_schema',
            'name': 'translations',
            'strict': true,
            'schema': _responseSchema,
          },
        },
      },
    };
    final requestEndpoint = provider.requestEndpoint;
    final response = await client.post(
      requestEndpoint,
      headers: {
        'authorization': 'Bearer $normalizedApiKey',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Translation provider returned HTTP ${response.statusCode}',
        requestEndpoint,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<Object?, Object?>) {
      throw const TranslationProtocolException('Response is not an object');
    }
    final responseText = switch (provider.protocol) {
      TranslationProtocol.chatCompletions => _chatCompletionText(decoded),
      TranslationProtocol.responses => _responsesText(decoded),
    };
    return parseTranslations(responseText, messages.keys.toSet());
  }

  static Map<String, String> parseTranslations(
    String responseText,
    Set<String> expectedIds,
  ) {
    final decoded = jsonDecode(responseText);
    if (decoded is! Map<Object?, Object?> ||
        decoded.length != 1 ||
        decoded['translations'] is! List<Object?>) {
      throw const TranslationProtocolException('Missing translations array');
    }
    final result = <String, String>{};
    for (final item in decoded['translations']! as List<Object?>) {
      if (item is! Map<Object?, Object?> ||
          item.length != 2 ||
          item['id'] is! String ||
          item['text'] is! String) {
        throw const TranslationProtocolException('Invalid translation item');
      }
      final id = item['id']! as String;
      if (!expectedIds.contains(id) || result.containsKey(id)) {
        throw const TranslationProtocolException(
          'Duplicate or unexpected translation ID',
        );
      }
      result[id] = item['text']! as String;
    }
    if (result.length != expectedIds.length ||
        !result.keys.toSet().containsAll(expectedIds)) {
      throw const TranslationProtocolException(
        'Translation IDs are incomplete',
      );
    }
    return result;
  }

  static String _chatCompletionText(Map<Object?, Object?> response) {
    final choices = response['choices'];
    if (choices is! List<Object?> || choices.isEmpty) {
      throw const TranslationProtocolException('Missing choices');
    }
    final choice = choices.first;
    if (choice is! Map<Object?, Object?>) {
      throw const TranslationProtocolException('Invalid choice');
    }
    final message = choice['message'];
    if (message is! Map<Object?, Object?> || message['content'] is! String) {
      throw const TranslationProtocolException('Missing message content');
    }
    return message['content']! as String;
  }

  static String _responsesText(Map<Object?, Object?> response) {
    if (response['output_text'] is String) {
      return response['output_text']! as String;
    }
    final output = response['output'];
    if (output is List<Object?>) {
      for (final item in output) {
        if (item is! Map<Object?, Object?>) continue;
        final content = item['content'];
        if (content is! List<Object?>) continue;
        for (final part in content) {
          if (part is Map<Object?, Object?> && part['text'] is String) {
            return part['text']! as String;
          }
        }
      }
    }
    throw const TranslationProtocolException('Missing response output text');
  }

  static String _userPrompt(
    Map<String, TranslationRequestMessage> messages,
    String sourceLanguage,
    String targetLanguage,
  ) => jsonEncode({
    'source_language': sourceLanguage,
    'target_language': targetLanguage,
    'messages': messages.entries
        .map(
          (entry) => {
            'id': entry.key,
            'text': entry.value.text,
            'message_type': entry.value.messageType,
          },
        )
        .toList(),
  });

  static const _systemPrompt = '''You are a precise message translator.
Return only a JSON object in exactly this form: {"translations":[{"id":"<input id>","text":"<translation>"}]}. Return every input ID exactly once and unchanged, with no extra fields or items. Translate every message independently; never use another message to infer or complete its meaning. Automatically detect the source language when source_language is "auto". Preserve Markdown, HTML, code, URLs, Matrix IDs, placeholders, paragraphs, line breaks, tone, and punctuation. When message_type is "m.emote", preserve its action semantics. Do not add explanations, labels, or commentary.''';

  static const Map<String, Object?> _responseSchema = {
    'type': 'object',
    'additionalProperties': false,
    'required': ['translations'],
    'properties': {
      'translations': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['id', 'text'],
          'properties': {
            'id': {'type': 'string'},
            'text': {'type': 'string'},
          },
        },
      },
    },
  };
}
