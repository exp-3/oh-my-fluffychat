// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/translation/translation_cache_backend_interface.dart';

class MemoryTranslationBackend implements TranslationCacheBackend {
  Map<CacheStore, Map<String, CacheRow>> rows = {
    for (final store in CacheStore.values) store: {},
  };
  bool present = false, unavailable = false;
  int createCalls = 0, openExistingCalls = 0, deleteCalls = 0, queries = 0;
  bool failOpenAfterCreate = false;
  void Function()? afterOpenOrCreate;
  Future<void> Function()? beforePutAll;
  void Function()? afterPutAll;
  final deletedRoomIds = <String>[];
  final changes = StreamController<void>.broadcast();
  List<CacheRow> get records => rows[CacheStore.contents]!.values.toList();
  @override
  Stream<void> get externalChanges => changes.stream;
  @override
  void signalInvalidation() {}
  @override
  Future<bool> exists() async {
    if (unavailable) throw StateError('locked');
    return present;
  }

  @override
  Future<T> coordinated<T>(Future<T> Function() action) => action();

  @override
  Future<bool> openExisting(String databaseKey, {bool migrate = false}) async {
    openExistingCalls++;
    if (unavailable) throw StateError('locked');
    return present;
  }

  @override
  Future<void> openOrCreate(String databaseKey) async {
    present = true;
    createCalls++;
    afterOpenOrCreate?.call();
    if (failOpenAfterCreate) throw StateError('creation failed');
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(TranslationCacheTransaction tx) action, {
    bool write = false,
    bool notify = false,
  }) async {
    if (unavailable) throw StateError('locked');
    final copy = {
      for (final store in rows.entries)
        store.key: {
          for (final row in store.value.entries)
            row.key: Map<String, Object?>.of(row.value),
        },
    };
    final result = await action(_MemoryTransaction(this, copy));
    if (write) rows = copy;
    return result;
  }

  @override
  Future<void> deleteIfExists() async {
    deleteCalls++;
    present = false;
    for (final store in rows.values) {
      store.clear();
    }
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() => changes.close();
}

class _MemoryTransaction implements TranslationCacheTransaction {
  final MemoryTranslationBackend backend;
  final Map<CacheStore, Map<String, CacheRow>> rows;
  _MemoryTransaction(this.backend, this.rows);
  @override
  bool hasStore(CacheStore store) => true;
  @override
  Future<CacheRow?> get(CacheStore store, String key) async =>
      rows[store]![key];
  @override
  Future<void> put(CacheStore store, CacheRow row) async {
    if (store == CacheStore.contents) await backend.beforePutAll?.call();
    rows[store]![cacheString(row, 'cache_key')] = Map.of(row)
      ..remove('_cursor');
    if (store == CacheStore.contents) backend.afterPutAll?.call();
  }

  @override
  Future<void> delete(CacheStore store, String key) async {
    rows[store]!.remove(key);
  }

  @override
  Future<int> count(CacheStore store) async => rows[store]!.length;
  @override
  Future<List<CacheRow>> query(
    CacheStore store, {
    String? index,
    List<String>? equals,
    Object? after,
    int limit = 200,
  }) async {
    backend.queries++;
    if (index == 'room' && store == CacheStore.refs && after == null) {
      backend.deletedRoomIds.add(equals!.single);
    }
    final result =
        rows[store]!.values
            .where((row) {
              if (after != null &&
                  cacheString(row, 'cache_key').compareTo(after as String) <=
                      0) {
                return false;
              }
              if (index == null) return true;
              final fields = cacheIndexes[store]![index]!;
              return [
                    for (var i = 0; i < fields.length; i++) row[fields[i]],
                  ].join('\u0000') ==
                  equals!.join('\u0000');
            })
            .map((row) => {...row, '_cursor': row['cache_key']})
            .toList()
          ..sort(
            (a, b) => cacheString(
              a,
              'cache_key',
            ).compareTo(cacheString(b, 'cache_key')),
          );
    return result.take(limit).toList();
  }
}
