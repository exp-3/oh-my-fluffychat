// SPDX-License-Identifier: AGPL-3.0-or-later

class TranslationCacheRecord {
  final String cacheKey;
  final String roomId;
  final String eventId;
  final String nonce;
  final String ciphertext;
  final String sourceBinding;
  final String aad;

  const TranslationCacheRecord({
    required this.cacheKey,
    required this.roomId,
    required this.eventId,
    required this.nonce,
    required this.ciphertext,
    required this.sourceBinding,
    required this.aad,
  });

  Map<String, Object?> toMap() => {
    'cache_key': cacheKey,
    'room_id': roomId,
    'event_id': eventId,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'source_binding': sourceBinding,
    'aad': aad,
  };

  factory TranslationCacheRecord.fromMap(Map<Object?, Object?> map) =>
      TranslationCacheRecord(
        // Keep a valid cache key when possible so cleanup can delete a row
        // whose other fields were corrupted. Missing or non-string values are
        // represented as invalid empty fields and rejected by the cache
        // authentication checks instead of aborting a whole cleanup page.
        cacheKey: _stringValue(map['cache_key']),
        roomId: _stringValue(map['room_id']),
        eventId: _stringValue(map['event_id']),
        nonce: _stringValue(map['nonce']),
        ciphertext: _stringValue(map['ciphertext']),
        sourceBinding: _stringValue(map['source_binding']),
        aad: _stringValue(map['aad']),
      );

  static String _stringValue(Object? value) => value is String ? value : '';
}

abstract interface class TranslationCacheBackend {
  /// Checks the physical backing store without creating or opening a missing
  /// database. Implementations must not rely solely on an auxiliary marker.
  Future<bool> exists();

  /// Opens an existing database and returns false when it is absent. This must
  /// never create a database or schema when the physical store is missing.
  Future<bool> openExisting(String databaseKey);

  Future<void> openOrCreate(String databaseKey);
  Future<TranslationCacheRecord?> get(String cacheKey);

  /// Atomically commits every record or none of them.
  Future<void> putAll(List<TranslationCacheRecord> records);
  Future<int> deleteByEvent(String roomId, String eventId);
  Future<int> deleteByRoom(String roomId);
  Future<int> deleteKeys(List<String> cacheKeys);
  Future<List<TranslationCacheRecord>> page(int offset, int limit);
  Future<int> count();

  /// Deletes the physical database when present and otherwise succeeds. This
  /// must also remove databases whose auxiliary marker is missing.
  Future<void> deleteIfExists();
  Future<void> close();
}
