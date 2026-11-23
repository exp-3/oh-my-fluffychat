// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Diagnostic text is separate from the safe default exception description.
abstract interface class TranslationDiagnosticException implements Exception {
  String? get diagnosticDetails;
}

/// Removes credentials before bounding text so a cut cannot expose a secret.
String sanitizeTranslationDiagnostic(
  String text, {
  Iterable<String> secrets = const [],
}) {
  final sensitive = <String>{};
  for (final value in secrets) {
    if (value.isEmpty) continue;
    for (final secret in {value, value.trim()}) {
      if (secret.isEmpty) continue;
      final json = jsonEncode(secret);
      sensitive.addAll([
        secret,
        Uri.encodeComponent(secret),
        json.substring(1, json.length - 1),
      ]);
    }
  }
  final ordered = sensitive.toList()
    ..sort((first, second) => second.length.compareTo(first.length));
  var result = text;
  for (final secret in ordered) {
    result = result.replaceAll(secret, '[redacted]');
  }
  result = result.replaceAllMapped(
    RegExp(r'''[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"')]+'''),
    (match) {
      final uri = Uri.tryParse(match[0]!);
      if (uri == null || !uri.hasAuthority) return '[redacted URL]';
      return uri.replace(userInfo: '', query: '', fragment: '').toString();
    },
  );
  result = result.replaceAll(
    RegExp(r'\bBearer\s+[^\s,"\x27;]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  result = result.replaceAll(
    RegExp(
      r'''\b(?:authorization|proxy-authorization)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\r\n,;]+)''',
      caseSensitive: false,
    ),
    'Authorization: [redacted]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'''\b(authorization|proxy-authorization|x-api-key|api[_ -]?key|password|passwd|token|secret|pre[_ -]?shared[_ -]?key)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}: [redacted]',
  );
  result = result.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
  const maximumLength = 4096;
  return result.length > maximumLength
      ? '${result.substring(0, maximumLength - 1)}…'
      : result;
}

/// Never falls back to arbitrary exception strings, which may contain a body.
String translationErrorDetails(
  Object error, {
  Iterable<String> secrets = const [],
}) {
  final description = switch (error) {
    TranslationDiagnosticException() =>
      error.diagnosticDetails ?? error.toString(),
    http.ClientException() => '${error.runtimeType}: ${error.message}',
    SocketException() =>
      'SocketException: ${error.message}'
          '${error.osError == null ? '' : '\n${error.osError}'}',
    TlsException() =>
      '${error.runtimeType}: ${error.message}'
          '${error.osError == null ? '' : '\n${error.osError}'}',
    HttpException() => 'HttpException: ${error.message}',
    TimeoutException() => 'TimeoutException: Operation timed out',
    FormatException() => 'FormatException: Invalid response format',
    _ => error.runtimeType.toString(),
  };
  return sanitizeTranslationDiagnostic(description, secrets: secrets);
}

/// Extracts only named error fields; HTML and other response bodies stay private.
String translationHttpResponseDetails(
  http.Response response, {
  Iterable<String> secrets = const [],
}) {
  final lines = ['HTTP ${response.statusCode}'];
  // Large proxy pages are not useful diagnostic objects and need not be parsed.
  if (response.bodyBytes.length <= 65536) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) {
        final error = decoded['error'];
        if (error is String) {
          lines.add(error);
        } else if (error is Map<String, Object?>) {
          for (final field in ['message', 'code', 'type']) {
            final value = error[field];
            if (value is String || value is num) lines.add('$field: $value');
          }
        }
        for (final field in ['message', 'code', 'type']) {
          final value = decoded[field];
          if (value is String || value is num) lines.add('$field: $value');
        }
      }
    } on FormatException {
      // Do not include the decoder exception, which can echo the response body.
    }
  }
  return sanitizeTranslationDiagnostic(lines.join('\n'), secrets: secrets);
}
