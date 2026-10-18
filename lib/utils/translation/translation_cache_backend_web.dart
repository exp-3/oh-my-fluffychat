// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'translation_cache_backend_interface.dart';

@JS('window.indexedDB')
external web.IDBFactory? get _indexedDb;

@JS('navigator.locks')
external web.LockManager? get _locks;

// ignore: unused-code
TranslationCacheBackend createTranslationCacheBackend() =>
    WebTranslationCacheBackend();

class WebTranslationCacheBackend implements TranslationCacheBackend {
  static const _name = 'fluffychat_translation_cache';
  static const _marker = 'chat.fluffy.translation.cache_exists';
  web.IDBDatabase? _database;
  final _changes = StreamController<void>.broadcast();
  web.BroadcastChannel? _channel;
  JSFunction? _reactivation;

  WebTranslationCacheBackend() {
    try {
      _channel = web.BroadcastChannel('fluffychat.translation.cache');
      _channel!.onmessage = ((web.MessageEvent _) {
        _changes.add(null);
      }).toJS;
    } catch (_) {
      // Focus/resume still rechecks persisted generations when broadcasting
      // is unavailable in this browser.
    }
    _reactivation = ((web.Event _) {
      _changes.add(null);
    }).toJS;
    web.window.addEventListener('focus', _reactivation);
    web.document.addEventListener('visibilitychange', _reactivation);
  }
  @override
  Stream<void> get externalChanges => _changes.stream;
  @override
  void signalInvalidation() => _channel?.postMessage('invalidated'.toJS);

  @override
  Future<T> coordinated<T>(Future<T> Function() action) async {
    final locks = _locks;
    if (locks == null) return action();
    late T result;
    Future<JSAny?> run() async {
      result = await action();
      return null;
    }

    await locks
        .request(
          'fluffychat.translation.cache',
          ((web.Lock _) => run().toJS).toJS,
        )
        .toDart;
    return result;
  }

  Future<web.IDBDatabase?> _open({bool create = false, bool migrate = false}) {
    final factory = _indexedDb;
    if (factory == null) throw StateError('IndexedDB is unavailable');
    final completer = Completer<web.IDBDatabase?>();
    var absent = false;
    // No version on safety probes: even an upgrade would create tables.
    final request = migrate ? factory.open(_name, 3) : factory.open(_name);
    request.onupgradeneeded = ((web.IDBVersionChangeEvent event) {
      try {
        if (completer.isCompleted) {
          request.transaction?.abort();
          return;
        }
        if (!create && event.oldVersion == 0) {
          absent = true;
          request.transaction!.abort();
          return;
        }
        final db = request.result as web.IDBDatabase;
        for (final store in CacheStore.values) {
          final objectStore = db.objectStoreNames.contains(store.name)
              ? request.transaction!.objectStore(store.name)
              : db.createObjectStore(
                  store.name,
                  web.IDBObjectStoreParameters(keyPath: 'cache_key'.toJS),
                );
          for (final index
              in (cacheIndexes[store] ?? const <String, List<String>>{})
                  .entries) {
            if (objectStore.indexNames.contains(index.key)) continue;
            objectStore.createIndex(
              index.key,
              index.value.length == 1
                  ? index.value.single.toJS
                  : index.value.map((field) => field.toJS).toList().toJS,
            );
          }
        }
      } catch (error, stack) {
        request.transaction?.abort();
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (completer.isCompleted) return;
      if (absent) {
        completer.complete(null);
        return;
      }
      completer.completeError(
        StateError('Unable to open translation IndexedDB'),
      );
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Translation IndexedDB is blocked'));
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      db.onversionchange = ((web.IDBVersionChangeEvent _) {
        db.close();
        if (identical(_database, db)) _database = null;
        _changes.add(null);
      }).toJS;
      if (completer.isCompleted) {
        db.close();
      } else {
        completer.complete(db);
      }
    }).toJS;
    return completer.future;
  }

  @override
  Future<bool> exists() async {
    if (_locks == null) throw StateError('Translation cache lock unavailable');
    if (_database != null) return true;
    final db = await _open();
    db?.close();
    return db != null;
  }

  @override
  Future<bool> openExisting(String databaseKey, {bool migrate = false}) async {
    if (_database != null) {
      if (!migrate || _database!.version >= 3) return true;
      await close();
    }
    _database = await _open(migrate: migrate);
    return _database != null;
  }

  @override
  Future<void> openOrCreate(String databaseKey) async {
    if (_database != null && _database!.version >= 3) return;
    await close();
    _database = await _open(create: true, migrate: true);
    web.window.localStorage.setItem(_marker, 'true');
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(TranslationCacheTransaction tx) action, {
    bool write = false,
    bool notify = false,
  }) async {
    final db = _database!;
    final names = CacheStore.values
        .where((store) => db.objectStoreNames.contains(store.name))
        .map((store) => store.name.toJS)
        .toList();
    final transaction = db.transaction(
      names.toJS,
      write ? 'readwrite' : 'readonly',
    );
    final completion = _completed(transaction);
    // Observe aborts immediately, even while an individual request is pending.
    unawaited(completion.catchError((Object _) {}));
    try {
      final result = await action(_WebTransaction(transaction, db));
      await completion;
      if (write && notify) _channel?.postMessage('changed'.toJS);
      return result;
    } catch (_) {
      try {
        transaction.abort();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> deleteIfExists() async {
    await close();
    final factory = _indexedDb;
    if (factory == null) throw StateError('IndexedDB is unavailable');
    final request = factory.deleteDatabase(_name);
    final completed = _request(request);
    request.onblocked = ((web.Event _) {
      // Other tabs close their connection in onversionchange. Keep waiting
      // for the actual deletion before the service removes its master key.
      signalInvalidation();
    }).toJS;
    await completed.timeout(const Duration(seconds: 10));
    web.window.localStorage.removeItem(_marker);
    _channel?.postMessage('changed'.toJS);
  }

  @override
  Future<void> close() {
    _database?.close();
    _database = null;
    return Future<void>.value();
  }

  @override
  Future<void> dispose() async {
    await close();
    web.window.removeEventListener('focus', _reactivation);
    web.document.removeEventListener('visibilitychange', _reactivation);
    _channel?.close();
    _channel = null;
    await _changes.close();
  }
}

class _WebTransaction implements TranslationCacheTransaction {
  final web.IDBTransaction tx;
  final web.IDBDatabase db;
  _WebTransaction(this.tx, this.db);
  @override
  bool hasStore(CacheStore store) => db.objectStoreNames.contains(store.name);
  @override
  Future<CacheRow?> get(CacheStore store, String key) async {
    if (!hasStore(store)) return null;
    final value = (await _request(
      tx.objectStore(store.name).get(key.toJS),
    ))?.dartify();
    return value is Map ? value.cast<String, Object?>() : null;
  }

  @override
  Future<void> put(CacheStore store, CacheRow row) async {
    await _request(
      tx.objectStore(store.name).put((Map.of(row)..remove('_cursor')).jsify()),
    );
  }

  @override
  Future<void> delete(CacheStore store, String key) async {
    if (hasStore(store)) {
      await _request(tx.objectStore(store.name).delete(key.toJS));
    }
  }

  @override
  Future<List<CacheRow>> query(
    CacheStore store, {
    String? index,
    List<String>? equals,
    Object? after,
    int limit = 200,
  }) async {
    if (!hasStore(store)) return [];
    final objectStore = tx.objectStore(store.name);
    web.IDBRequest request;
    List<String>? fallbackFields;
    JSAny? indexKey;
    if (index != null) {
      // Existing v2 indexes had different names. Use them without upgrading.
      final oldName = index == 'event'
          ? 'event_id'
          : index == 'room'
          ? 'room_id'
          : index;
      final name = objectStore.indexNames.contains(index) ? index : oldName;
      if (!objectStore.indexNames.contains(name)) {
        // Pre-v3 safety cleanup may lack a source-binding index. Leave the
        // schema untouched and filter its cursor; v3 always uses an index.
        fallbackFields = cacheIndexes[store]![index]!;
        request = objectStore.openCursor(
          after == null
              ? null
              : web.IDBKeyRange.lowerBound((after as String).toJS, true),
        );
      } else {
        final key = equals!.length == 1
            ? equals.single.toJS
            : equals.map((item) => item.toJS).toList().toJS;
        indexKey = key;
        request = objectStore.index(name).openCursor(web.IDBKeyRange.only(key));
      }
    } else {
      request = objectStore.openCursor(
        after == null
            ? null
            : web.IDBKeyRange.lowerBound((after as String).toJS, true),
      );
    }
    final completer = Completer<List<CacheRow>>();
    final rows = <CacheRow>[];
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Translation cache cursor failed'));
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      try {
        final result = request.result;
        if (result == null || result.isUndefinedOrNull) {
          completer.complete(rows);
          return;
        }
        final cursor = result as web.IDBCursorWithValue;
        final key = cursor.primaryKey.dartify();
        if (indexKey != null &&
            after != null &&
            (key as String).compareTo(after as String) < 0) {
          // Jump directly within duplicate index keys instead of scanning all
          // previous pages again for a widely shared source.
          cursor.continuePrimaryKey(indexKey, after.toJS);
          return;
        }
        final value = cursor.value.dartify();
        final fields = fallbackFields;
        final matches =
            fields == null ||
            (value is Map &&
                List.generate(
                  fields.length,
                  (i) => value[fields[i]] == equals![i],
                ).every((match) => match));
        if (matches &&
            (after == null || (key as String).compareTo(after as String) > 0) &&
            value is Map) {
          rows.add({...value.cast<String, Object?>(), '_cursor': key});
        }
        if (rows.length >= limit) {
          completer.complete(rows);
        } else {
          cursor.continue_();
        }
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    }).toJS;
    return completer.future;
  }

  @override
  Future<int> count(CacheStore store) async => !hasStore(store)
      ? 0
      : ((await _request(tx.objectStore(store.name).count()))!.dartify()!
                as num)
            .toInt();
}

Future<JSAny?> _request(web.IDBRequest request) {
  final completer = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) {
    completer.complete(request.result);
  }).toJS;
  request.onerror = ((web.Event _) {
    completer.completeError(StateError('Translation cache request failed'));
  }).toJS;
  return completer.future;
}

Future<void> _completed(web.IDBTransaction transaction) {
  final completer = Completer<void>();
  transaction.oncomplete = ((web.Event _) {
    if (!completer.isCompleted) completer.complete();
  }).toJS;
  final failed = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('Translation cache transaction failed'),
      );
    }
  }).toJS;
  transaction.onerror = failed;
  transaction.onabort = failed;
  return completer.future;
}
