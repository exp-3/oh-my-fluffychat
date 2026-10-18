// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Sealed version 1/2 envelopes, also used by migration tests.
class TranslationCacheRecord {
  final String cacheKey, roomId, eventId, nonce, ciphertext, sourceBinding, aad;
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
  factory TranslationCacheRecord.fromMap(Map<Object?, Object?> row) =>
      TranslationCacheRecord(
        cacheKey: cacheString(row, 'cache_key'),
        roomId: cacheString(row, 'room_id'),
        eventId: cacheString(row, 'event_id'),
        nonce: cacheString(row, 'nonce'),
        ciphertext: cacheString(row, 'ciphertext'),
        sourceBinding: cacheString(row, 'source_binding'),
        aad: cacheString(row, 'aad'),
      );
}

typedef CacheRow = Map<String, Object?>;
String cacheString(Map<Object?, Object?> row, String field) =>
    row[field] is String ? row[field]! as String : '';

enum CacheStore { translations, contents, refs, generations, metadata }

const cacheIndexes = <CacheStore, Map<String, List<String>>>{
  CacheStore.translations: {
    'event': ['room_id', 'event_id'],
    'room': ['room_id'],
    'binding': ['source_binding'],
  },
  CacheStore.contents: {
    'binding': ['source_binding'],
    'user': ['user_id'],
  },
  CacheStore.refs: {
    'event': ['room_id', 'event_id'],
    'room': ['room_id'],
    'binding': ['source_binding'],
    'content': ['content_key'],
    'user': ['user_id'],
  },
};

abstract interface class TranslationCacheTransaction {
  bool hasStore(CacheStore store);
  Future<CacheRow?> get(CacheStore store, String key);
  Future<void> put(CacheStore store, CacheRow row);
  Future<void> delete(CacheStore store, String key);

  /// Bounded keyset pagination. Legacy native order is rowid; Web order is
  /// cache_key. `_cursor` is also the deterministic legacy migration rank.
  Future<List<CacheRow>> query(
    CacheStore store, {
    String? index,
    List<String>? equals,
    Object? after,
    int limit = 200,
  });
  Future<int> count(CacheStore store);
}

abstract interface class TranslationCacheBackend {
  Future<bool> exists();

  /// Coordinates key creation and multi-step cleanup with other Web contexts.
  Future<T> coordinated<T>(Future<T> Function() action);

  /// A safety open must not create or upgrade a schema. Missing stores in an
  /// older schema read as empty and are never implicitly created.
  Future<bool> openExisting(String databaseKey, {bool migrate = false});
  Future<void> openOrCreate(String databaseKey);
  Future<T> transaction<T>(
    Future<T> Function(TranslationCacheTransaction tx) action, {
    bool write = false,
    bool notify = false,
  });

  /// Other contexts and reactivation only, not this instance's own writes.
  Stream<void> get externalChanges;
  void signalInvalidation();
  Future<void> deleteIfExists();
  Future<void> close();
  Future<void> dispose();
}
