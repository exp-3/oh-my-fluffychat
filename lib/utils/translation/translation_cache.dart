// SPDX-FileCopyrightText: 2026 OMF Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'translation_cache_backend.dart';
import 'translation_cache_backend_interface.dart';
import 'translation_preferences.dart';

class TranslationCacheKey {
  static const formatVersion = 1;

  final String roomId;
  final String eventId;
  final String source;
  final String sourceLanguage;
  final String targetLanguage;
  final String semanticRevision;
  final String messageType;

  const TranslationCacheKey({
    required this.roomId,
    required this.eventId,
    required this.source,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.semanticRevision,
    required this.messageType,
  });

  String get aad => jsonEncode([
    formatVersion,
    roomId,
    eventId,
    sourceLanguage,
    targetLanguage,
    semanticRevision,
    messageType,
  ]);
}

class TranslationCacheCleanupResult {
  final int checked;
  final int retained;
  final int deleted;
  final bool cacheExisted;

  const TranslationCacheCleanupResult({
    required this.checked,
    required this.retained,
    required this.deleted,
    required this.cacheExisted,
  });

  static const notFound = TranslationCacheCleanupResult(
    checked: 0,
    retained: 0,
    deleted: 0,
    cacheExisted: false,
  );
}

class TranslationCache {
  static const _masterKeyName = 'chat.fluffy.translation.cache_master_key';

  final TranslationSecretStore secrets;
  final TranslationCacheBackend backend;
  Uint8List? _masterKey;
  Future<void> _operationTail = Future<void>.value();

  TranslationCache(this.secrets, [TranslationCacheBackend? backend])
    : backend = backend ?? createTranslationCacheBackend();

  Future<bool> exists() => _serialized(backend.exists);

  Future<String?> read(TranslationCacheKey key) =>
      _serialized(() => _read(key));

  Future<String?> _read(TranslationCacheKey key) async {
    if (!await _openExisting()) return null;
    final masterKey = _masterKey!;
    final storageKey = _storageKey(masterKey, key);
    TranslationCacheRecord? record;
    try {
      record = await backend.get(storageKey);
    } catch (_) {
      // A malformed row is unusable and must not poison future reads.
      await backend.deleteKeys([storageKey]);
      return null;
    }
    if (record == null) return null;
    try {
      if (record.cacheKey != storageKey ||
          record.roomId != key.roomId ||
          record.eventId != key.eventId ||
          record.aad != key.aad ||
          record.sourceBinding != _sourceBinding(masterKey, key.source)) {
        throw const FormatException('Translation cache metadata mismatch');
      }
      return _decrypt(masterKey, key, record);
    } catch (_) {
      await backend.deleteKeys([storageKey]);
      return null;
    }
  }

  Future<void> write(
    TranslationCacheKey key,
    String translation, {
    bool Function()? isValid,
  }) => writeAll({key: translation}, isValid: isValid);

  Future<void> writeAll(
    Map<TranslationCacheKey, String> translations, {
    bool Function()? isValid,
  }) {
    if (translations.isEmpty) return Future<void>.value();
    return _serialized(() => _writeAll(translations, isValid));
  }

  Future<void> _writeAll(
    Map<TranslationCacheKey, String> translations,
    bool Function()? isValid,
  ) async {
    var createdMasterKey = false;
    var createdDatabase = false;
    var writeAttempted = false;
    var writtenKeys = const <String>[];
    var previousRecords = const <TranslationCacheRecord>[];

    try {
      _ensureValid(isValid);
      var databaseExists = await backend.exists();

      _ensureValid(isValid); // Before loading or creating the master key.
      final existingMasterKey = await _loadExistingMasterKey();
      if (databaseExists && existingMasterKey == null) {
        // An encrypted database without its key is unusable. Remove it before
        // creating a replacement so a newly generated key is never applied to
        // an existing SQLCipher database.
        await backend.deleteIfExists();
        databaseExists = false;
      }
      final Uint8List masterKey;
      if (existingMasterKey == null) {
        _ensureValid(isValid); // Immediately before generating a master key.
        // Mark this before touching secure storage: a storage implementation
        // may persist successfully and then surface an error.
        createdMasterKey = true;
        masterKey = await _createMasterKey();
      } else {
        masterKey = existingMasterKey;
      }
      _ensureValid(isValid); // After loading or creating the master key.

      _ensureValid(isValid); // Before opening or creating the database.
      if (databaseExists) {
        databaseExists = await backend.openExisting(_databaseKey(masterKey));
      }
      if (!databaseExists) {
        createdDatabase = true;
        await backend.openOrCreate(_databaseKey(masterKey));
      }
      _ensureValid(isValid); // After opening or creating the database.

      _ensureValid(isValid); // Before encrypting records.
      final records = translations.entries
          .map((entry) => _encrypt(masterKey, entry.key, entry.value))
          .toList(growable: false);
      writtenKeys = records
          .map((record) => record.cacheKey)
          .toList(growable: false);
      if (!createdDatabase) {
        final existing = <TranslationCacheRecord>[];
        for (final storageKey in writtenKeys) {
          final record = await backend.get(storageKey);
          if (record != null) existing.add(record);
        }
        previousRecords = existing;
      }
      _ensureValid(isValid); // After encrypting records.

      _ensureValid(isValid); // Before the write transaction.
      writeAttempted = true;
      await backend.putAll(records);
      _ensureValid(isValid); // After the write transaction.
    } catch (error, stackTrace) {
      await _rollbackWrite(
        createdDatabase: createdDatabase,
        createdMasterKey: createdMasterKey,
        writeAttempted: writeAttempted,
        writtenKeys: writtenKeys,
        previousRecords: previousRecords,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> invalidateEventIfExists(String roomId, String eventId) =>
      _serialized(() => _invalidateEventIfExists(roomId, eventId));

  Future<void> _invalidateEventIfExists(String roomId, String eventId) async {
    if (!await _openExisting()) return;
    await backend.deleteByEvent(roomId, eventId);
  }

  Future<void> invalidateRoomIfExists(String roomId) =>
      _serialized(() => _invalidateRoomIfExists(roomId));

  Future<void> _invalidateRoomIfExists(String roomId) async {
    if (!await _openExisting()) return;
    await backend.deleteByRoom(roomId);
  }

  Future<void> deleteIfExists() => _serialized(_deleteIfExists);

  Future<void> _deleteIfExists() async {
    // Every backend guarantees that deletion of an absent database is a
    // non-creating no-op. Calling it unconditionally also removes an orphaned
    // Web database when its auxiliary marker has disappeared.
    await backend.deleteIfExists();
    _masterKey = null;
    await secrets.delete(_masterKeyName);
  }

  Future<TranslationCacheCleanupResult> cleanInvalid(
    Future<String?> Function(String roomId, String eventId) localSource, {
    int pageSize = 200,
  }) => _serialized(() => _cleanInvalid(localSource, pageSize: pageSize));

  Future<TranslationCacheCleanupResult> _cleanInvalid(
    Future<String?> Function(String roomId, String eventId) localSource, {
    required int pageSize,
  }) async {
    if (!await _openExisting()) return TranslationCacheCleanupResult.notFound;
    var checked = 0;
    var retained = 0;
    var deleted = 0;
    var offset = 0;
    final masterKey = _masterKey!;
    while (true) {
      final records = await backend.page(offset, pageSize);
      if (records.isEmpty) break;
      final invalid = <String>[];
      for (final record in records) {
        checked++;
        final source = await localSource(record.roomId, record.eventId);
        final valid =
            source != null &&
            _recordMetadataMatches(masterKey, source, record) &&
            record.sourceBinding == _sourceBinding(masterKey, source) &&
            _authenticates(masterKey, source, record);
        if (valid) {
          retained++;
        } else {
          invalid.add(record.cacheKey);
        }
      }
      deleted += await backend.deleteKeys(invalid);
      offset += records.length - invalid.length;
      if (records.length < pageSize) break;
    }
    return TranslationCacheCleanupResult(
      checked: checked,
      retained: retained,
      deleted: deleted,
      cacheExisted: true,
    );
  }

  Future<bool> _openExisting() async {
    if (!await backend.exists()) return false;
    final masterKey = await _loadExistingMasterKey();
    if (masterKey == null) {
      await backend.deleteIfExists();
      return false;
    }
    return backend.openExisting(_databaseKey(masterKey));
  }

  Future<Uint8List?> _loadExistingMasterKey() async {
    if (_masterKey != null) return _masterKey;
    final encoded = await secrets.read(_masterKeyName);
    if (encoded == null) return null;
    try {
      final decoded = base64Url.decode(encoded);
      if (decoded.length != 32) return null;
      return _masterKey = Uint8List.fromList(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _createMasterKey() async {
    final random = Random.secure();
    final generated = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await secrets.write(_masterKeyName, base64UrlEncode(generated));
    _masterKey = generated;
    return generated;
  }

  Future<void> _rollbackWrite({
    required bool createdDatabase,
    required bool createdMasterKey,
    required bool writeAttempted,
    required List<String> writtenKeys,
    required List<TranslationCacheRecord> previousRecords,
  }) async {
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    try {
      if (createdDatabase) {
        await backend.deleteIfExists();
      } else if (writeAttempted && writtenKeys.isNotEmpty) {
        // The transaction may have committed just before the runtime became
        // invalid. Restore any records replaced by the attempted transaction.
        await backend.deleteKeys(writtenKeys);
        if (previousRecords.isNotEmpty) {
          await backend.putAll(previousRecords);
        }
      }
    } catch (error, stackTrace) {
      cleanupError = error;
      cleanupStackTrace = stackTrace;
    }
    if (createdMasterKey) {
      try {
        await secrets.delete(_masterKeyName);
      } catch (error, stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
      } finally {
        _masterKey = null;
      }
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _operationTail;
    final release = Completer<void>();
    _operationTail = release.future;
    return (() async {
      await previous;
      try {
        return await operation();
      } finally {
        release.complete();
      }
    })();
  }

  static void _ensureValid(bool Function()? isValid) {
    if (isValid?.call() == false) {
      throw StateError('Translation cache write expired');
    }
  }

  static TranslationCacheRecord _encrypt(
    Uint8List masterKey,
    TranslationCacheKey key,
    String translation,
  ) {
    final nonce = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_derivedKey(masterKey, key)),
          128,
          nonce,
          Uint8List.fromList(utf8.encode(key.aad)),
        ),
      );
    final plaintext = Uint8List.fromList(utf8.encode(translation));
    final ciphertext = cipher.process(plaintext);
    return TranslationCacheRecord(
      cacheKey: _storageKey(masterKey, key),
      roomId: key.roomId,
      eventId: key.eventId,
      nonce: base64UrlEncode(nonce),
      ciphertext: base64UrlEncode(ciphertext),
      sourceBinding: _sourceBinding(masterKey, key.source),
      aad: key.aad,
    );
  }

  static String _decrypt(
    Uint8List masterKey,
    TranslationCacheKey key,
    TranslationCacheRecord record,
  ) {
    // The storage key selects a record, but the indexed metadata is still
    // mutable on disk. Check every value bound to the cache key before
    // attempting AEAD decryption so metadata tampering cannot turn into a
    // successful cache hit.
    if (record.roomId != key.roomId ||
        record.eventId != key.eventId ||
        record.aad != key.aad ||
        record.sourceBinding != _sourceBinding(masterKey, key.source)) {
      throw const FormatException('Translation cache metadata mismatch');
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_derivedKey(masterKey, key)),
          128,
          Uint8List.fromList(base64Url.decode(record.nonce)),
          Uint8List.fromList(utf8.encode(key.aad)),
        ),
      );
    return utf8.decode(
      cipher.process(Uint8List.fromList(base64Url.decode(record.ciphertext))),
    );
  }

  static bool _authenticates(
    Uint8List masterKey,
    String source,
    TranslationCacheRecord record,
  ) {
    if (record.aad.isEmpty || record.sourceBinding.isEmpty) return false;
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(_derivedKeyForSource(masterKey, source)),
            128,
            Uint8List.fromList(base64Url.decode(record.nonce)),
            Uint8List.fromList(utf8.encode(record.aad)),
          ),
        );
      cipher.process(Uint8List.fromList(base64Url.decode(record.ciphertext)));
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _recordMetadataMatches(
    Uint8List masterKey,
    String source,
    TranslationCacheRecord record,
  ) {
    try {
      final decoded = jsonDecode(record.aad);
      if (decoded is! List<Object?> ||
          decoded.length != 7 ||
          decoded.first != TranslationCacheKey.formatVersion ||
          decoded[1] != record.roomId ||
          decoded[2] != record.eventId) {
        return false;
      }
    } catch (_) {
      return false;
    }
    final sourceDigest = sha256.convert(utf8.encode(source)).bytes;
    final value = utf8.encode(record.aad) + sourceDigest;
    final expectedStorageKey = base64UrlEncode(
      Hmac(sha256, masterKey).convert(value).bytes,
    );
    return record.cacheKey == expectedStorageKey;
  }

  static Uint8List _derivedKey(Uint8List masterKey, TranslationCacheKey key) =>
      _derivedKeyForSource(masterKey, key.source);

  static Uint8List _derivedKeyForSource(Uint8List masterKey, String source) {
    final sourceDigest = Uint8List.fromList(
      sha256.convert(utf8.encode(source)).bytes,
    );
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(
        HkdfParameters(
          masterKey,
          32,
          sourceDigest,
          Uint8List.fromList(utf8.encode('fluffychat-translation-v1')),
        ),
      );
    final output = Uint8List(32);
    derivator.deriveKey(null, 0, output, 0);
    return output;
  }

  static String _sourceBinding(Uint8List masterKey, String source) =>
      base64UrlEncode(
        Hmac(
          sha256,
          masterKey,
        ).convert(utf8.encode('source-binding:$source')).bytes,
      );

  static String _storageKey(Uint8List masterKey, TranslationCacheKey key) {
    final sourceDigest = sha256.convert(utf8.encode(key.source)).bytes;
    final value = utf8.encode(key.aad) + sourceDigest;
    return base64UrlEncode(Hmac(sha256, masterKey).convert(value).bytes);
  }

  static String _databaseKey(Uint8List masterKey) =>
      sha256.convert(masterKey + utf8.encode('database')).toString();

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
