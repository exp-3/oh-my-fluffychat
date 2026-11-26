// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:redis/redis.dart' as redis;

import 'translation_diagnostics.dart';
import 'translation_roaming_models.dart';
import 'translation_roaming_store.dart';

class NativeTranslationRoamingStore implements TranslationRoamingStore {
  final TranslationRoamingConfig config;
  final String password;
  Socket? _socket;
  redis.Command? _command;
  Future<redis.Command>? _connecting;
  int _generation = 0;
  bool _disposed = false;

  NativeTranslationRoamingStore(this.config, this.password);

  Future<redis.Command> _getCommand() {
    if (_disposed) {
      return Future.error(
        const TranslationRoamingException(TranslationRoamingError.disposed),
      );
    }
    final command = _command;
    if (command != null) return Future.value(command);
    final connecting = _connecting;
    if (connecting != null) return connecting;
    final operation = _connect(_generation);
    _connecting = operation;
    return operation.whenComplete(() {
      if (identical(_connecting, operation)) _connecting = null;
    });
  }

  Future<redis.Command> _connect(int generation) async {
    Socket? socket;
    try {
      socket = config.tls
          ? await SecureSocket.connect(
              config.host.trim(),
              config.port,
              timeout: const Duration(seconds: 3),
            )
          : await Socket.connect(
              config.host.trim(),
              config.port,
              timeout: const Duration(seconds: 3),
            );
      if (_disposed || generation != _generation) {
        socket.destroy();
        throw const TranslationRoamingException(
          TranslationRoamingError.disposed,
        );
      }
      _socket = socket;
      final connected = socket;
      unawaited(
        connected.done.then<void>(
          (_) {
            if (identical(_socket, connected)) reset();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (identical(_socket, connected)) reset();
          },
        ),
      );
      final command = await redis.RedisConnection().connectWithSocket(socket);
      if (password.isNotEmpty || config.username.trim().isNotEmpty) {
        final result = await _send(command, [
          'AUTH',
          if (config.username.trim().isNotEmpty) config.username.trim(),
          password,
        ]);
        if (result != 'OK') {
          throw const TranslationRoamingException(
            TranslationRoamingError.authentication,
          );
        }
      }
      if (config.database != 0) {
        final result = await _send(command, [
          'SELECT',
          config.database.toString(),
        ]);
        if (result != 'OK') {
          throw const TranslationRoamingException(
            TranslationRoamingError.protocol,
          );
        }
      }
      if (_disposed || generation != _generation) {
        socket.destroy();
        throw const TranslationRoamingException(
          TranslationRoamingError.disposed,
        );
      }
      _command = command;
      return command;
    } catch (error) {
      socket?.destroy();
      if (generation == _generation) reset();
      if (error is TranslationRoamingException) rethrow;
      throw _failure(error);
    }
  }

  Future<Object?> _execute(List<String> parts) async {
    final generation = _generation;
    try {
      final command = await _getCommand();
      if (_disposed || generation != _generation) {
        throw const TranslationRoamingException(
          TranslationRoamingError.disposed,
        );
      }
      final response = await _send(command, parts);
      if (_disposed || generation != _generation) {
        throw const TranslationRoamingException(
          TranslationRoamingError.disposed,
        );
      }
      return response;
    } catch (error) {
      if (generation == _generation) reset();
      if (error is TranslationRoamingException) rethrow;
      throw _failure(error);
    }
  }

  // The package exposes a non-generic Future. Keep its dynamic boundary here.
  Future<Object?> _send(redis.Command command, List<String> parts) async {
    try {
      return await command.send_object(parts);
    } catch (error) {
      if (error is TranslationRoamingException) rethrow;
      throw _failure(error, command: parts);
    }
  }

  TranslationRoamingException _failure(
    Object error, {
    List<String> command = const [],
  }) {
    // Redis server errors may echo command arguments; sanitize at this boundary.
    final description = switch (error) {
      SocketException() =>
        'SocketException: ${error.message}'
            '${error.osError == null ? '' : '\n${error.osError}'}',
      TlsException() =>
        '${error.runtimeType}: ${error.message}'
            '${error.osError == null ? '' : '\n${error.osError}'}',
      TimeoutException() => 'TimeoutException: Redis operation timed out',
      FormatException() => 'FormatException: Invalid Redis response',
      _ => error.toString(),
    };
    final authentication =
        command.firstOrNull == 'AUTH' ||
        RegExp(r'\b(NOAUTH|WRONGPASS)\b').hasMatch(description);
    final category = error is TimeoutException
        ? TranslationRoamingError.timeout
        : error is SocketException || error is TlsException
        ? TranslationRoamingError.connection
        : authentication
        ? TranslationRoamingError.authentication
        : command.isNotEmpty || error is FormatException
        ? TranslationRoamingError.protocol
        : TranslationRoamingError.connection;
    return TranslationRoamingException(
      category,
      diagnosticDetails: sanitizeTranslationDiagnostic(
        '${command.isEmpty ? '' : '${command.first}: '}$description',
        secrets: [
          password,
          config.username.trim(),
          if (command.length > 1) command[1],
          if (command.firstOrNull == 'SET' && command.length > 2) command[2],
        ],
      ),
    );
  }

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
    _socket?.destroy();
    _socket = null;
    _command = null;
    _connecting = null;
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
  }
}
