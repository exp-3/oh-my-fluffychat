// SPDX-FileCopyrightText: 2026 OMF Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'translation_cache_backend_interface.dart';

@JS('window.indexedDB')
external web.IDBFactory? get _indexedDb;

TranslationCacheBackend createTranslationCacheBackend() =>
    WebTranslationCacheBackend();

class WebTranslationCacheBackend implements TranslationCacheBackend {
  static const _name = 'fluffychat_translation_cache';
  static const _marker = 'chat.fluffy.translation.cache_exists';
  static const _storeName = 'translations';
  web.IDBDatabase? _database;

  @override
  Future<bool> exists() async {
    if (_database != null) return true;
    final database = await _openExistingDatabase();
    if (database == null) {
      web.window.localStorage.removeItem(_marker);
      return false;
    }
    database.close();
    web.window.localStorage.setItem(_marker, 'true');
    return true;
  }

  @override
  Future<bool> openExisting(String databaseKey) async {
    if (_database != null) return true;
    final database = await _openExistingDatabase();
    if (database == null) {
      web.window.localStorage.removeItem(_marker);
      return false;
    }
    _database = database;
    web.window.localStorage.setItem(_marker, 'true');
    return true;
  }

  @override
  Future<void> openOrCreate(String databaseKey) async {
    if (_database != null) return;
    _database = await _open(create: true);
    web.window.localStorage.setItem(_marker, 'true');
  }

  Future<web.IDBDatabase> _open({required bool create}) {
    final indexedDb = _indexedDb;
    if (indexedDb == null) throw StateError('IndexedDB is unavailable');
    final completer = Completer<web.IDBDatabase>();
    var absent = false;
    final request = indexedDb.open(_name, 2);

    request.onupgradeneeded = (web.IDBVersionChangeEvent event) {
      try {
        if (!create && event.oldVersion == 0) {
          final transaction = request.transaction;
          if (transaction == null) {
            throw StateError(
              'IndexedDB upgrade transaction is unavailable',
            );
          }
          absent = true;
          transaction.abort();
          return;
        }
        final database = request.result as web.IDBDatabase;
        if (event.oldVersion < 1) {
          final store = database.createObjectStore(
            _storeName,
            web.IDBObjectStoreParameters(keyPath: 'cache_key'.toJS),
          );
          store.createIndex('room_id', 'room_id'.toJS);
          store.createIndex(
            'event_id',
            ['room_id'.toJS, 'event_id'.toJS].toJS,
          );
        }
      } catch (error, stackTrace) {
        request.transaction?.abort();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    }.toJS;
    request.onerror = (web.Event event) {
      if (completer.isCompleted) return;
      if (absent) {
        // Aborting the initial version-change transaction prevents creation by
        // specification. Do not issue a follow-up delete here: another tab may
        // legitimately create the shared cache immediately after this probe.
        completer.completeError(const _TranslationCacheDatabaseAbsent());
        return;
      }
      completer.completeError(
        request.error ?? StateError('Unable to open IndexedDB'),
      );
    }.toJS;
    request.onblocked = (web.Event event) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('IndexedDB open request is blocked'));
      }
    }.toJS;
    request.onsuccess = (web.Event event) {
      final database = request.result as web.IDBDatabase;
      if (completer.isCompleted) {
        database.close();
      } else {
        completer.complete(database);
      }
    }.toJS;
    return completer.future;
  }

  Future<web.IDBDatabase?> _openExistingDatabase() async {
    if (_indexedDb == null) return null;
    try {
      return await _open(create: false);
    } on _TranslationCacheDatabaseAbsent {
      return null;
    }
  }

  web.IDBDatabase get _db =>
      _database ?? (throw StateError('Translation cache is not open'));

  @override
  Future<TranslationCacheRecord?> get(String cacheKey) async {
    final transaction = _db.transaction(_storeName.toJS, 'readonly');
    final completed = _waitForTransaction(transaction);
    final request = transaction.objectStore(_storeName).get(cacheKey.toJS);
    await completed;
    final value = request.result?.dartify();
    return value is Map<Object?, Object?>
        ? TranslationCacheRecord.fromMap(value)
        : null;
  }

  @override
  Future<void> putAll(List<TranslationCacheRecord> records) async {
    final transaction = _db.transaction(_storeName.toJS, 'readwrite');
    final completed = _waitForTransaction(transaction);
    final store = transaction.objectStore(_storeName);
    for (final record in records) {
      store.put(record.toMap().jsify());
    }
    await completed;
  }

  @override
  Future<int> deleteByEvent(String roomId, String eventId) => _deleteMatching(
    (record) => record.roomId == roomId && record.eventId == eventId,
  );

  @override
  Future<int> deleteByRoom(String roomId) =>
      _deleteMatching((record) => record.roomId == roomId);

  Future<int> _deleteMatching(
    bool Function(TranslationCacheRecord record) test,
  ) async {
    final records = await page(0, 0x7fffffff);
    return deleteKeys(
      records.where(test).map((record) => record.cacheKey).toList(),
    );
  }

  @override
  Future<int> deleteKeys(List<String> cacheKeys) async {
    if (cacheKeys.isEmpty) return 0;
    final transaction = _db.transaction(_storeName.toJS, 'readwrite');
    final completed = _waitForTransaction(transaction);
    final store = transaction.objectStore(_storeName);
    for (final key in cacheKeys) {
      store.delete(key.toJS);
    }
    await completed;
    return cacheKeys.length;
  }

  @override
  Future<List<TranslationCacheRecord>> page(int offset, int limit) async {
    final transaction = _db.transaction(_storeName.toJS, 'readonly');
    final completed = _waitForTransaction(transaction);
    final request = transaction.objectStore(_storeName).getAll();
    await completed;
    final values = request.result?.dartify();
    if (values is! List<Object?>) return const [];
    final records = values
        .whereType<Map<Object?, Object?>>()
        .map(TranslationCacheRecord.fromMap)
        .toList();
    final start = offset.clamp(0, records.length);
    final end = (start + limit).clamp(start, records.length);
    return records.sublist(start, end);
  }

  @override
  Future<int> count() async => (await page(0, 0x7fffffff)).length;

  @override
  Future<void> deleteIfExists() async {
    await close();
    // Deleting a missing IndexedDB database is a successful no-op, while
    // always issuing the delete also removes an orphan whose localStorage
    // marker was evicted independently.
    final indexedDb = _indexedDb;
    if (indexedDb != null) {
      await _waitForDatabaseRequest(indexedDb.deleteDatabase(_name));
    }
    web.window.localStorage.removeItem(_marker);
  }

  @override
  Future<void> close() {
    _database?.close();
    _database = null;
    return Future<void>.value();
  }
}

Future<void> _waitForTransaction(web.IDBTransaction transaction) {
  final completer = Completer<void>();
  transaction.oncomplete = (web.Event event) {
    if (!completer.isCompleted) completer.complete();
  }.toJS;
  transaction.onerror = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(
        transaction.error ?? StateError('IndexedDB transaction failed'),
      );
    }
  }.toJS;
  transaction.onabort = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(
        transaction.error ?? StateError('IndexedDB transaction was aborted'),
      );
    }
  }.toJS;
  return completer.future;
}

Future<void> _waitForDatabaseRequest(web.IDBOpenDBRequest request) {
  final completer = Completer<void>();
  request.onsuccess = (web.Event event) {
    if (!completer.isCompleted) completer.complete();
  }.toJS;
  request.onerror = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(
        request.error ?? StateError('IndexedDB request failed'),
      );
    }
  }.toJS;
  request.onblocked = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB request is blocked'));
    }
  }.toJS;
  return completer.future;
}

class _TranslationCacheDatabaseAbsent implements Exception {
  const _TranslationCacheDatabaseAbsent();
}
