// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'translation_diagnostics.dart';
import 'translation_languages.dart';
import 'translation_roaming_crypto.dart';
import 'translation_roaming_models.dart';
import 'translation_roaming_store.dart';
import 'translation_roaming_store_factory.dart';

export 'translation_roaming_crypto.dart';
export 'translation_roaming_models.dart';
export 'translation_roaming_preferences.dart';
export 'translation_roaming_store.dart';

class TranslationRoamingService {
  static const readTimeout = Duration(seconds: 2);
  static const writeTimeout = Duration(seconds: 3);
  static const retryDelay = Duration(milliseconds: 500);

  final TranslationRoamingConfig config;
  final TranslationRoamingSecrets _secrets;
  final TranslationRoamingCrypto? _crypto;
  final Future<void> Function(Duration) _delay;
  final Map<String, Future<TranslationRoamingLookup>> _lookups = {};
  TranslationRoamingStore? _store;
  bool _disposed = false;

  TranslationRoamingService({
    required this.config,
    required TranslationRoamingSecrets secrets,
    TranslationRoamingStore? store,
    Future<void> Function(Duration)? delay,
  }) : _secrets = secrets,
       _crypto = secrets.decodedPreSharedKey == null
           ? null
           : TranslationRoamingCrypto(secrets.preSharedKey),
       _store = store,
       _delay = delay ?? Future<void>.delayed;

  bool get available =>
      !_disposed &&
      config.enabled &&
      config.isValid &&
      config.supportedOnPlatform &&
      _crypto != null &&
      _secrets.isValidFor(config);

  TranslationRoamingStore get _transport =>
      _store ??= createTranslationRoamingStore(
        config,
        redisPassword: _secrets.redisPassword,
        restToken: _secrets.restToken,
      );

  Future<TranslationRoamingLookup> lookup({
    required String source,
    required String targetLanguage,
  }) {
    if (!available ||
        source.isEmpty ||
        !isTranslationLanguage(targetLanguage)) {
      return Future.value(TranslationRoamingLookup.unavailable);
    }
    final key = _crypto!.storageKey(
      source: source,
      targetLanguage: targetLanguage,
      keyPrefix: config.keyPrefix,
    );
    final pending = _lookups[key];
    if (pending != null) return pending;
    final operation = _lookup(source, targetLanguage, key);
    _lookups[key] = operation;
    return operation.whenComplete(() {
      if (identical(_lookups[key], operation)) _lookups.remove(key);
    });
  }

  Future<TranslationRoamingLookup> _lookup(
    String source,
    String targetLanguage,
    String key,
  ) async {
    try {
      final envelope = await _timed(
        _transport.getEx(key, config.ttlSeconds),
        readTimeout,
      );
      if (_disposed) return TranslationRoamingLookup.unavailable;
      if (envelope == null) return TranslationRoamingLookup.miss;
      final translation = _crypto!.decrypt(
        source: source,
        targetLanguage: targetLanguage,
        key: key,
        envelope: envelope,
      );
      return TranslationRoamingLookup(
        TranslationRoamingLookupStatus.hit,
        translation: translation,
      );
    } catch (_) {
      return TranslationRoamingLookup.unavailable;
    }
  }

  Future<void> upload({
    required String source,
    required String targetLanguage,
    required String translation,
    required bool Function() isValid,
  }) async {
    final crypto = _crypto;
    if (!available ||
        crypto == null ||
        !isValid() ||
        source.isEmpty ||
        translation.trim().isEmpty ||
        !isTranslationLanguage(targetLanguage)) {
      return;
    }
    final key = crypto.storageKey(
      source: source,
      targetLanguage: targetLanguage,
      keyPrefix: config.keyPrefix,
    );
    final String envelope;
    try {
      envelope = crypto.encrypt(
        source: source,
        targetLanguage: targetLanguage,
        key: key,
        translation: translation,
      );
    } on TranslationRoamingException {
      // Translations outside the roaming size limits remain local.
      return;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!available || !isValid()) return;
      try {
        await _timed(
          _transport.set(key, envelope, config.ttlSeconds),
          writeTimeout,
        );
        return;
      } catch (_) {
        if (attempt == 1 || !available || !isValid()) return;
        await _delay(retryDelay);
      }
    }
  }

  /// The remaining lifetime is recalculated immediately before each attempt.
  Future<TranslationRoamingUploadResult> uploadIfAbsent({
    required String source,
    required String targetLanguage,
    required String translation,
    required int Function() ttlSeconds,
    required bool Function() isValid,
  }) async {
    const skipped = TranslationRoamingUploadResult(
      TranslationRoamingUploadStatus.skipped,
    );
    final crypto = _crypto;
    if (!available ||
        crypto == null ||
        !isValid() ||
        source.isEmpty ||
        translation.trim().isEmpty ||
        !isTranslationLanguage(targetLanguage)) {
      return skipped;
    }
    final key = crypto.storageKey(
      source: source,
      targetLanguage: targetLanguage,
      keyPrefix: config.keyPrefix,
    );
    final String envelope;
    try {
      envelope = crypto.encrypt(
        source: source,
        targetLanguage: targetLanguage,
        key: key,
        translation: translation,
      );
    } on TranslationRoamingException {
      return skipped;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!available || !isValid()) return skipped;
      final remaining = ttlSeconds();
      if (remaining <= 0) return skipped;
      // Redis command integers must also remain exact on Dart Web.
      if (remaining > 9007199254740991) {
        return const TranslationRoamingUploadResult(
          TranslationRoamingUploadStatus.failed,
          error: TranslationRoamingException(
            TranslationRoamingError.configuration,
          ),
        );
      }
      try {
        final uploaded = await _timed(
          _transport.setIfAbsent(key, envelope, remaining),
          writeTimeout,
        );
        return TranslationRoamingUploadResult(
          uploaded
              ? TranslationRoamingUploadStatus.uploaded
              : TranslationRoamingUploadStatus.existing,
        );
      } catch (error) {
        if (!available || !isValid()) return skipped;
        if (attempt == 1) {
          return TranslationRoamingUploadResult(
            TranslationRoamingUploadStatus.failed,
            error: TranslationRoamingException(
              error is TranslationRoamingException
                  ? error.error
                  : TranslationRoamingError.connection,
              diagnosticDetails: translationErrorDetails(
                error,
                secrets: [
                  _secrets.preSharedKey,
                  _secrets.redisPassword,
                  _secrets.restToken,
                  source,
                  translation,
                  key,
                  envelope,
                ],
              ),
            ),
          );
        }
        await _delay(retryDelay);
      }
    }
    return skipped;
  }

  Future<T> _timed<T>(Future<T> operation, Duration timeout) =>
      operation.timeout(
        timeout,
        onTimeout: () {
          _store?.reset();
          throw const TranslationRoamingException(
            TranslationRoamingError.timeout,
          );
        },
      );

  Future<void> testConnection() async {
    final crypto = _crypto;
    if (_disposed ||
        crypto == null ||
        !config.isValid ||
        !_secrets.isValidFor(config)) {
      throw const TranslationRoamingException(
        TranslationRoamingError.configuration,
      );
    }
    if (!config.supportedOnPlatform) {
      throw const TranslationRoamingException(
        TranslationRoamingError.unsupportedPlatform,
      );
    }
    final source = TranslationRoamingCrypto.generatePreSharedKey();
    final translation = TranslationRoamingCrypto.generatePreSharedKey();
    final key = crypto.storageKey(
      source: source,
      targetLanguage: 'en',
      keyPrefix: '${config.keyPrefix}:test',
    );
    final envelope = crypto.encrypt(
      source: source,
      targetLanguage: 'en',
      key: key,
      translation: translation,
    );
    try {
      await _timed(_transport.set(key, envelope, 60), writeTimeout);
      final restored = await _timed(_transport.getEx(key, 60), readTimeout);
      if (restored == null ||
          crypto.decrypt(
                source: source,
                targetLanguage: 'en',
                key: key,
                envelope: restored,
              ) !=
              translation) {
        throw const TranslationRoamingException(
          TranslationRoamingError.protocol,
        );
      }
    } finally {
      if (!_disposed) {
        try {
          await _timed(_transport.delete(key), writeTimeout);
        } catch (_) {
          // The test record also has a short TTL if cleanup cannot connect.
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _lookups.clear();
    _store?.dispose();
    _crypto?.dispose();
  }
}
