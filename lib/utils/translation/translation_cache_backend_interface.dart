// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

typedef CacheRow = Map<String, Object?>;
String cacheString(Map<Object?, Object?> row, String field) =>
    row[field] is String ? row[field]! as String : '';

enum CacheStore {
  translations,
  contents,
  refs,
  generations,
  metadata,
  sharedContents,
  messageRefs,
  revisions;

  String get tableName => switch (this) {
    CacheStore.sharedContents => 'shared_contents',
    CacheStore.messageRefs => 'message_refs',
    _ => name,
  };
}

const cacheFormatVersion = 4;
const activeCacheStores = {
  CacheStore.sharedContents,
  CacheStore.messageRefs,
  CacheStore.revisions,
  CacheStore.metadata,
};
const legacyCacheStores = {
  CacheStore.translations,
  CacheStore.contents,
  CacheStore.refs,
  CacheStore.generations,
};

const cacheColumns = <CacheStore, List<String>>{
  CacheStore.sharedContents: [
    'cache_key',
    'source_binding',
    'source_language',
    'target_language',
    'message_type',
    'nonce',
    'ciphertext',
    'aad',
  ],
  CacheStore.messageRefs: [
    'cache_key',
    'user_id',
    'room_id',
    'event_id',
    'source_language',
    'target_language',
    'message_type',
    'content_key',
    'original_event_id',
  ],
  CacheStore.revisions: ['cache_key', 'value'],
  CacheStore.metadata: ['cache_key', 'value'],
};

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
  CacheStore.sharedContents: {
    'binding': ['source_binding'],
  },
  CacheStore.messageRefs: {
    'event': ['room_id', 'event_id'],
    'root': ['room_id', 'original_event_id'],
    'room': ['room_id'],
    'user': ['user_id'],
    'user_room': ['user_id', 'room_id'],
    'content': ['content_key'],
  },
};

abstract interface class TranslationCacheTransaction {
  bool hasStore(CacheStore store);
  Future<CacheRow?> get(CacheStore store, String key);
  Future<void> put(CacheStore store, CacheRow row);
  Future<void> delete(CacheStore store, String key);

  /// Bounded keyset pagination. Older native rows use rowid; Web rows use
  /// cache_key. `_cursor` identifies the last row for the next page.
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
  bool get supported;
  Future<bool> exists();

  /// Coordinates key creation and multi-step cleanup with other Web contexts.
  Future<T> coordinated<T>(Future<T> Function() action);

  /// A safety open must not create or upgrade a schema. Missing stores in an
  /// older schema read as empty and are never implicitly created.
  Future<bool> openExisting(String databaseKey, {bool migrate = false});
  Future<void> openOrCreate(String databaseKey);
  Future<bool> needsUpgrade();
  Future<void> finishUpgrade();
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
