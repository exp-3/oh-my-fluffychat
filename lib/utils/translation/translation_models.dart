// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

enum TranslationProtocol { chatCompletions, responses, anthropicMessages }

enum TranslationReasoningEffort { unspecified, max, xhigh, high, medium, low }

enum TranslationScope { none, allRooms, unencryptedRooms }

enum InputTranslationMode { disabled, manual, automatic, manualAndAutomatic }

enum InputTranslationScope { automaticRooms, allRooms }

enum InputTranslationTrigger { button, longPress, doubleTap }

enum InputTranslationSendMode {
  shortOriginalLongTranslated,
  shortTranslatedLongOriginal,
}

enum TranslationDisplayMode { translatedOnly, bilingual }

enum TranslationBilingualColor { body, accent, secondary, tertiary, muted }

enum TranslationBilingualStyle {
  divider,
  background,
  glow,
  plain,
  duotone,
  outsideBubble,
}

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
  final TranslationReasoningEffort reasoningEffort;

  const TranslationProviderConfig({
    required this.id,
    required this.name,
    required this.endpoint,
    this.useFullEndpoint = true,
    required this.protocol,
    required this.model,
    this.reasoningEffort = TranslationReasoningEffort.unspecified,
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
      TranslationProtocol.anthropicMessages => const ['messages'],
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
    'reasoning_effort': reasoningEffort.name,
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
      reasoningEffort:
          TranslationReasoningEffort.values
              .where((value) => value.name == json['reasoning_effort'])
              .firstOrNull ??
          TranslationReasoningEffort.unspecified,
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
  const TranslationResultState.refreshing(String previous)
    : this._(TranslationStatus.loading, previous, null);
  const TranslationResultState.translated(String value)
    : this._(TranslationStatus.translated, value, null);
  const TranslationResultState.failed(Object error, {String? previous})
    : this._(TranslationStatus.failed, previous, error);
}

int unicodeCodePointLength(String value) => value.runes.length;
