// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_diagnostics.dart';
import 'translation_roaming_models.dart';
import 'translation_roaming_store.dart';

class RestTranslationRoamingStore implements TranslationRoamingStore {
  final Uri endpoint;
  final String token;
  final http.Client Function() _clientFactory;
  http.Client? _client;
  int _generation = 0;
  bool _disposed = false;

  RestTranslationRoamingStore({
    required this.endpoint,
    required this.token,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  Future<Object?> _execute(List<String> parts) async {
    if (_disposed) {
      throw const TranslationRoamingException(TranslationRoamingError.disposed);
    }
    final generation = _generation;
    final client = _client ??= _clientFactory();
    final sensitive = [
      token,
      token.trim(),
      parts[1],
      if (parts.first == 'SET') parts[2],
    ];
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'authorization': 'Bearer ${token.trim()}',
          'content-type': 'application/json',
        })
        ..body = jsonEncode(parts);
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      if (_disposed || generation != _generation) {
        throw const TranslationRoamingException(
          TranslationRoamingError.disposed,
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw TranslationRoamingException(
          TranslationRoamingError.authentication,
          diagnosticDetails: translationHttpResponseDetails(
            response,
            secrets: sensitive,
          ),
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TranslationRoamingException(
          TranslationRoamingError.connection,
          diagnosticDetails: translationHttpResponseDetails(
            response,
            secrets: sensitive,
          ),
        );
      }
      final decoded = _decode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, Object?> ||
          decoded['error'] != null ||
          !decoded.containsKey('result')) {
        throw TranslationRoamingException(
          TranslationRoamingError.protocol,
          diagnosticDetails: translationHttpResponseDetails(
            response,
            secrets: sensitive,
          ),
        );
      }
      return decoded['result'];
    } catch (error) {
      if (error is TranslationRoamingException) rethrow;
      throw TranslationRoamingException(
        error is FormatException
            ? TranslationRoamingError.protocol
            : TranslationRoamingError.connection,
        diagnosticDetails: translationErrorDetails(error, secrets: sensitive),
      );
    }
  }

  static Object? _decode(String value) => jsonDecode(value);

  @override
  Future<String?> get(String key) async {
    final response = await _execute(['GET', key]);
    if (response == null || response is String) return response as String?;
    throw const TranslationRoamingException(TranslationRoamingError.protocol);
  }

  @override
  Future<String?> getEx(String key, int ttlSeconds) async {
    final response = await _execute([
      'GETEX',
      key,
      'EX',
      ttlSeconds.toString(),
    ]);
    if (response == null || response is String) return response as String?;
    throw const TranslationRoamingException(TranslationRoamingError.protocol);
  }

  @override
  Future<void> set(String key, String value, int ttlSeconds) async {
    final response = await _execute([
      'SET',
      key,
      value,
      'EX',
      ttlSeconds.toString(),
    ]);
    if (response != 'OK') {
      throw const TranslationRoamingException(TranslationRoamingError.protocol);
    }
  }

  @override
  Future<bool> setIfAbsent(String key, String value, int ttlSeconds) async {
    final response = await _execute([
      'SET',
      key,
      value,
      'EX',
      ttlSeconds.toString(),
      'NX',
    ]);
    if (response == 'OK') return true;
    if (response == null) return false;
    throw const TranslationRoamingException(TranslationRoamingError.protocol);
  }

  @override
  Future<void> delete(String key) async {
    final response = await _execute(['DEL', key]);
    if (response is! int) {
      throw const TranslationRoamingException(TranslationRoamingError.protocol);
    }
  }

  @override
  void reset() {
    _generation++;
    _client?.close();
    _client = null;
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
  }
}
