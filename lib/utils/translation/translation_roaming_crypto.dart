// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate, ZLibDecoder;
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'translation_roaming_models.dart';

class TranslationRoamingCrypto {
  static const maxTranslationBytes = 3 * 1024 * 1024;
  static const maxCompressedTranslationBytes = 600 * 1024;
  static const _compressionThreshold = 256;
  static const _nonceLength = 12;
  static const _tagLength = 16;

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
    var plaintext = Uint8List.fromList(utf8.encode(translation));
    if (plaintext.length > maxTranslationBytes) {
      throw const TranslationRoamingException(TranslationRoamingError.protocol);
    }
    var compressedLength = plaintext.length;
    var header = 'A';
    if (plaintext.length >= _compressionThreshold) {
      try {
        final compressed = Deflate(plaintext, level: 6).getBytes();
        compressedLength = compressed.length;
        // Fixed nonce/tag overhead and Base64 encoding preserve this saving.
        if (compressed.length < plaintext.length) {
          plaintext = compressed;
          header = 'B';
        }
      } catch (_) {
        // Compression is optional; the original bytes can still be encrypted.
      }
    }
    if (compressedLength >= maxCompressedTranslationBytes) {
      throw const TranslationRoamingException(TranslationRoamingError.protocol);
    }
    final nonce = _randomBytes(_nonceLength);
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
      final encrypted = cipher.process(plaintext);
      final payload = Uint8List(nonce.length + encrypted.length)
        ..setAll(0, nonce)
        ..setAll(nonce.length, encrypted);
      // One independent Base64URL character: 000 reserved | 000/001 codec.
      // The following encoded bytes are nonce | ciphertext | GCM tag.
      return '$header${_encode(payload)}';
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
      const maxPayloadBytes =
          maxCompressedTranslationBytes - 1 + _nonceLength + _tagLength;
      const maxEnvelopeLength = 1 + (maxPayloadBytes * 4 + 2) ~/ 3;
      if (envelope.isEmpty ||
          envelope.length > maxEnvelopeLength ||
          (envelope[0] != 'A' && envelope[0] != 'B')) {
        throw const TranslationRoamingException(
          TranslationRoamingError.protocol,
        );
      }
      final payload = _decode(envelope.substring(1));
      if (payload.length < _nonceLength + _tagLength ||
          payload.length - _nonceLength - _tagLength >=
              maxCompressedTranslationBytes) {
        throw const TranslationRoamingException(
          TranslationRoamingError.protocol,
        );
      }
      final nonce = Uint8List.sublistView(payload, 0, _nonceLength);
      final encrypted = Uint8List.sublistView(payload, _nonceLength);
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
        // Authenticate the complete payload before decoding or decompressing.
        var plaintext = cipher.process(encrypted);
        if (envelope[0] == 'B') {
          plaintext = const ZLibDecoder().decodeBytes(
            plaintext,
            raw: true,
            throwOnError: true,
            maxOutputSize: maxTranslationBytes,
          );
        }
        if (plaintext.length > maxTranslationBytes) {
          throw const TranslationRoamingException(
            TranslationRoamingError.protocol,
          );
        }
        final translation = utf8.decode(plaintext);
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
