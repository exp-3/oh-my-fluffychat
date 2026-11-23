// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'translation_roaming_models.dart';

/// PSK and source-dependent key derivation stay entirely on the client.
class TranslationRoamingCrypto {
  final Uint8List _preSharedKey;

  TranslationRoamingCrypto(String preSharedKey)
    : _preSharedKey =
          TranslationRoamingSecrets(
            preSharedKey: preSharedKey,
          ).decodedPreSharedKey ??
          (throw const TranslationRoamingException(
            TranslationRoamingError.configuration,
          ));

  static String generatePreSharedKey() => _encode(_randomBytes(32));

  String storageKey({
    required String source,
    required String targetLanguage,
    required String keyPrefix,
  }) {
    final digest = Hmac(sha256, _preSharedKey).convert(utf8.encode(source));
    return '$keyPrefix:v1:$targetLanguage:${_encode(digest.bytes)}';
  }

  String encrypt({
    required String source,
    required String targetLanguage,
    required String key,
    required String translation,
  }) {
    final nonce = _randomBytes(12);
    final derived = _derive(source, targetLanguage);
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(derived),
            128,
            nonce,
            Uint8List.fromList(utf8.encode(key)),
          ),
        );
      return jsonEncode({
        'v': 1,
        'nonce': _encode(nonce),
        'ciphertext': _encode(
          cipher.process(Uint8List.fromList(utf8.encode(translation))),
        ),
      });
    } finally {
      derived.fillRange(0, derived.length, 0);
    }
  }

  String decrypt({
    required String source,
    required String targetLanguage,
    required String key,
    required String envelope,
  }) {
    try {
      final json = (jsonDecode(envelope) as Map).cast<String, Object?>();
      if (json['v'] != 1 ||
          json['nonce'] is! String ||
          json['ciphertext'] is! String) {
        throw const TranslationRoamingException(
          TranslationRoamingError.protocol,
        );
      }
      final nonce = _decode(json['nonce']! as String);
      final encrypted = _decode(json['ciphertext']! as String);
      if (nonce.length != 12 || encrypted.length < 16) {
        throw const TranslationRoamingException(
          TranslationRoamingError.protocol,
        );
      }
      final derived = _derive(source, targetLanguage);
      try {
        final cipher = GCMBlockCipher(AESEngine())
          ..init(
            false,
            AEADParameters(
              KeyParameter(derived),
              128,
              nonce,
              Uint8List.fromList(utf8.encode(key)),
            ),
          );
        final translation = utf8.decode(cipher.process(encrypted));
        if (translation.trim().isEmpty) {
          throw const TranslationRoamingException(
            TranslationRoamingError.protocol,
          );
        }
        return translation;
      } finally {
        derived.fillRange(0, derived.length, 0);
      }
    } catch (_) {
      throw const TranslationRoamingException(TranslationRoamingError.protocol);
    }
  }

  Uint8List _derive(String source, String targetLanguage) {
    final salt = Uint8List.fromList(sha512.convert(utf8.encode(source)).bytes);
    try {
      final derivator = HKDFKeyDerivator(SHA256Digest())
        ..init(
          HkdfParameters(
            _preSharedKey,
            32,
            salt,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode([
                  'fluffychat.translation.roaming',
                  1,
                  targetLanguage,
                ]),
              ),
            ),
          ),
        );
      final derived = Uint8List(32);
      derivator.deriveKey(null, 0, derived, 0);
      return derived;
    } finally {
      salt.fillRange(0, salt.length, 0);
    }
  }

  void dispose() => _preSharedKey.fillRange(0, _preSharedKey.length, 0);

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _encode(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static Uint8List _decode(String encoded) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      throw const TranslationRoamingException(TranslationRoamingError.protocol);
    }
    return base64Url.decode(base64Url.normalize(encoded));
  }
}
