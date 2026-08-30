// SPDX-FileCopyrightText: 2026 OMF Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

enum TranslationProtocol { chatCompletions, responses }

enum TranslationScope { none, allRooms, unencryptedRooms }

enum InputTranslationMode { disabled, manual, automatic }

enum InputTranslationScope { automaticRooms, allRooms }

enum InputTranslationTrigger { button, longPress, doubleTap }

enum InputTranslationSendMode {
  shortOriginalLongTranslated,
  shortTranslatedLongOriginal,
}

// Keep the longer names available to callers while the concise names are used
// throughout the chat UI.
typedef TranslationInputMode = InputTranslationMode;
typedef TranslationInputScope = InputTranslationScope;
typedef TranslationInputTrigger = InputTranslationTrigger;
typedef TranslationInputSendMode = InputTranslationSendMode;
typedef InputTranslationAutoSendMode = InputTranslationSendMode;
typedef TranslationInputAutoSendMode = InputTranslationSendMode;

enum TranslationDisplayMode { translatedOnly, bilingual }

enum TranslationBilingualColor { body, accent, secondary, tertiary, muted }

enum TranslationBilingualStyle { divider, background }

class TranslationRequestMessage {
  final String text;
  final String messageType;

  const TranslationRequestMessage({
    required this.text,
    required this.messageType,
  });
}

class TranslationProviderConfig {
  final String id;
  final String name;
  final Uri endpoint;
  final bool useFullEndpoint;
  final TranslationProtocol protocol;
  final String model;

  const TranslationProviderConfig({
    required this.id,
    required this.name,
    required this.endpoint,
    this.useFullEndpoint = true,
    required this.protocol,
    required this.model,
  });

  Uri get requestEndpoint {
    if (useFullEndpoint) return endpoint;
    final pathSegments = endpoint.pathSegments.toList();
    while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
      pathSegments.removeLast();
    }
    pathSegments.addAll(switch (protocol) {
      TranslationProtocol.chatCompletions => const ['chat', 'completions'],
      TranslationProtocol.responses => const ['responses'],
    });
    return endpoint.replace(pathSegments: pathSegments);
  }

  bool get isValid =>
      id.trim().isNotEmpty &&
      name.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      endpoint.host.isNotEmpty &&
      !endpoint.hasQuery &&
      endpoint.userInfo.isEmpty &&
      !endpoint.hasFragment &&
      (endpoint.scheme == 'https' ||
          (endpoint.scheme == 'http' &&
              (endpoint.host == 'localhost' ||
                  endpoint.host == '127.0.0.1' ||
                  endpoint.host == '::1')));

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'endpoint': endpoint.toString(),
    'use_full_endpoint': useFullEndpoint,
    'protocol': protocol.name,
    'model': model,
  };

  factory TranslationProviderConfig.fromJson(Map<String, Object?> json) {
    return TranslationProviderConfig(
      id: json['id']! as String,
      name: json['name']! as String,
      endpoint: Uri.parse(json['endpoint']! as String),
      // Configurations saved before base URL support always contained a full
      // request endpoint, so preserve that behavior during migration.
      useFullEndpoint: json['use_full_endpoint'] as bool? ?? true,
      protocol: TranslationProtocol.values.byName(json['protocol']! as String),
      model: json['model']! as String,
    );
  }

  static List<TranslationProviderConfig> decodeList(String? value) {
    if (value == null || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value) as List<Object?>;
      return decoded
          .map(
            (item) => TranslationProviderConfig.fromJson(
              (item! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .where((provider) => provider.isValid)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(Iterable<TranslationProviderConfig> providers) =>
      jsonEncode(providers.map((provider) => provider.toJson()).toList());
}

class TranslationBatchSettings {
  static const defaults = TranslationBatchSettings();

  final int mergeWindowMs;
  final int maxMessages;
  final int maxCharacters;
  final int malformedResponseRetries;

  const TranslationBatchSettings({
    this.mergeWindowMs = 1000,
    this.maxMessages = 5,
    this.maxCharacters = 3000,
    this.malformedResponseRetries = 2,
  });

  bool get isValid =>
      mergeWindowMs >= 0 &&
      mergeWindowMs <= 2000 &&
      maxMessages >= 1 &&
      maxMessages <= 50 &&
      maxCharacters >= 100 &&
      maxCharacters <= 20000 &&
      malformedResponseRetries >= 0 &&
      malformedResponseRetries <= 3;

  TranslationBatchSettings copyWith({
    int? mergeWindowMs,
    int? maxMessages,
    int? maxCharacters,
    int? malformedResponseRetries,
  }) => TranslationBatchSettings(
    mergeWindowMs: mergeWindowMs ?? this.mergeWindowMs,
    maxMessages: maxMessages ?? this.maxMessages,
    maxCharacters: maxCharacters ?? this.maxCharacters,
    malformedResponseRetries:
        malformedResponseRetries ?? this.malformedResponseRetries,
  );
}

enum TranslationStatus { idle, loading, translated, failed }

class TranslationResultState {
  final TranslationStatus status;
  final String? translation;
  final Object? error;

  const TranslationResultState._(this.status, this.translation, this.error);

  static const idle = TranslationResultState._(
    TranslationStatus.idle,
    null,
    null,
  );
  static const loading = TranslationResultState._(
    TranslationStatus.loading,
    null,
    null,
  );
  const TranslationResultState.translated(String value)
    : this._(TranslationStatus.translated, value, null);
  const TranslationResultState.failed(Object error)
    : this._(TranslationStatus.failed, null, error);
}

int unicodeCodePointLength(String value) => value.runes.length;
