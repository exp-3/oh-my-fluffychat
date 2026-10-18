// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
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
  final String userId,
      roomId,
      eventId,
      source,
      sourceLanguage,
      targetLanguage,
      messageType;

  /// Encrypted provenance only. Never contributes to identity or AAD.
  final String? model;
  final String? originalEventId;
  const TranslationCacheKey({
    required this.userId,
    required this.roomId,
    required this.eventId,
    required this.source,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.messageType,
    this.model,
    this.originalEventId,
  });
  List<String> identity(String binding) => [
    userId,
    binding,
    sourceLanguage,
    targetLanguage,
    messageType,
  ];
  String aad(String binding) => jsonEncode([2, ...identity(binding)]);
}

enum TranslationCacheLookupStatus { hit, miss, unavailable }

class TranslationCacheTicket {
  final String sourceDigest;
  final int epoch;
  final String generation;
  final String storeId;
  const TranslationCacheTicket(
    this.sourceDigest,
    this.epoch,
    this.generation, [
    this.storeId = '',
  ]);
}

class TranslationCacheLookup {
  final TranslationCacheLookupStatus status;
  final String? translation;
  final TranslationCacheTicket? ticket;
  const TranslationCacheLookup(this.status, {this.translation, this.ticket});
  static const unavailable = TranslationCacheLookup(
    TranslationCacheLookupStatus.unavailable,
  );
}

enum TranslationLocalSourceStatus { valid, obsolete, unavailable }

class TranslationLocalSource {
  final TranslationLocalSourceStatus status;
  final String? source;
  final String? originalEventId;
  const TranslationLocalSource.valid(String value, {this.originalEventId})
    : status = TranslationLocalSourceStatus.valid,
      source = value;
  static const obsolete = TranslationLocalSource._(
    TranslationLocalSourceStatus.obsolete,
  );
  static const unavailable = TranslationLocalSource._(
    TranslationLocalSourceStatus.unavailable,
  );
  const TranslationLocalSource._(this.status)
    : source = null,
      originalEventId = null;
}

typedef TranslationSourceResolver =
    Future<TranslationLocalSource> Function(
      String userId,
      String roomId,
      String eventId,
    );

class TranslationCacheCleanupResult {
  final int checked, retained, deleted;
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

/// Content is addressed independently of its envelope format and provenance.
/// All mutations, reference changes and tombstones use backend transactions.
class TranslationCache {
  static const _masterKeyName = 'chat.fluffy.translation.cache_master_key';
  final TranslationSecretStore secrets;
  final TranslationCacheBackend backend;
  TranslationPreferences? safetyPreferences;
  TranslationSourceResolver? localSourceResolver;
  Uint8List? _masterKey;
  Future<void> _operationTail = Future.value();
  final _epochs = <String, int>{};
  List<CacheRow> _pending = [];
  bool _pendingLoaded = false;
  int _safetyEpoch = 0;
  TranslationCache(this.secrets, [TranslationCacheBackend? backend])
    : backend = backend ?? createTranslationCacheBackend();

  Stream<void> get externalChanges => backend.externalChanges;
  Future<void> refreshSafetyState() => _serialized(() async {
    // Another context may have cleared the cache and created a new master.
    _masterKey = null;
    await backend.close();
    await _loadPending(refresh: true);
  });
  String _digest(String source) =>
      sha256.convert(utf8.encode(source)).toString();
  String? bindingIfLoaded(String source) =>
      _masterKey == null ? null : _sourceBinding(_masterKey!, source);
  Future<bool> exists() async {
    try {
      return await backend.exists();
    } catch (_) {
      return false;
    }
  }

  Future<String?> read(TranslationCacheKey key) async =>
      (await lookup(key)).translation;
  Future<TranslationCacheLookup> lookup(TranslationCacheKey key) => _serialized(
    () async {
      final digest = _digest(key.source);
      final epoch = _epochs[digest] ?? 0;
      final safetyEpoch = _safetyEpoch;
      try {
        if (!await _openExisting(migrate: true)) {
          return TranslationCacheLookup(
            TranslationCacheLookupStatus.miss,
            ticket: TranslationCacheTicket(digest, epoch, ''),
          );
        }
        if (!await _replayPending()) return TranslationCacheLookup.unavailable;
        final master = _masterKey!;
        final binding = _sourceBinding(master, key.source);
        final storageKey = _storageKey(master, key.identity(binding));
        final candidate = await backend.transaction(
          (tx) => tx.get(CacheStore.contents, storageKey),
        );
        TranslationCacheKey? validatedOrigin;
        if (candidate?['legacy'] == 1 && localSourceResolver != null) {
          final source = await localSourceResolver!(
            key.userId,
            cacheString(candidate!, 'room_id'),
            cacheString(candidate, 'event_id'),
          );
          if (source.status == TranslationLocalSourceStatus.unavailable) {
            return TranslationCacheLookup.unavailable;
          }
          if (source.status == TranslationLocalSourceStatus.obsolete ||
              source.source != key.source) {
            await backend.transaction(
              (tx) => _deleteBindings(tx, {binding}),
              write: true,
              notify: true,
            );
            return TranslationCacheLookup.unavailable;
          }
          validatedOrigin = TranslationCacheKey(
            userId: key.userId,
            roomId: cacheString(candidate, 'room_id'),
            eventId: cacheString(candidate, 'event_id'),
            originalEventId: source.originalEventId,
            source: key.source,
            sourceLanguage: key.sourceLanguage,
            targetLanguage: key.targetLanguage,
            messageType: key.messageType,
          );
        }
        return await backend.transaction((tx) async {
          final generation = await _generation(tx, binding);
          final ticket = TranslationCacheTicket(
            digest,
            epoch,
            generation,
            await _storeId(tx),
          );
          final row = await tx.get(CacheStore.contents, storageKey);
          // References also cover corrupt/missing content and requests that
          // join an existing translation operation.
          await _attachReferences(tx, master, key, binding, storageKey);
          if (row == null) {
            // Persist a reference for an in-flight miss too, so another tab can
            // invalidate the source before a late network result is committed.
            return TranslationCacheLookup(
              TranslationCacheLookupStatus.miss,
              ticket: ticket,
            );
          }
          if (cacheString(row, 'generation') != generation) {
            await tx.delete(CacheStore.contents, storageKey);
            return TranslationCacheLookup(
              TranslationCacheLookupStatus.miss,
              ticket: ticket,
            );
          }
          String text;
          try {
            if (cacheString(row, 'user_id') != key.userId ||
                cacheString(row, 'source_binding') != binding) {
              throw const FormatException();
            }
            if (row['legacy'] == 1) {
              if (!_legacyMatches(master, key.source, row) ||
                  !_legacyLanguagesMatch(key, row)) {
                throw const FormatException();
              }
              text = _decrypt(master, key.source, row);
              final converted = _encrypt(
                master,
                key,
                text,
                generation,
                legacyModel: _legacyModel(row),
              )..['rank'] = cacheString(row, 'rank');
              // Converted backfills remain lower priority than actual writes.
              converted['legacy'] = 2;
              await tx.put(CacheStore.contents, converted);
            } else {
              if (cacheString(row, 'aad') != key.aad(binding)) {
                throw const FormatException();
              }
              final payload =
                  jsonDecode(_decrypt(master, key.source, row))
                      as Map<String, Object?>;
              if (payload['v'] != 2 || payload['text'] is! String) {
                throw const FormatException();
              }
              text = payload['text']! as String;
            }
          } catch (_) {
            await tx.delete(CacheStore.contents, storageKey);
            return TranslationCacheLookup(
              TranslationCacheLookupStatus.miss,
              ticket: ticket,
            );
          }
          if ((_epochs[digest] ?? 0) != epoch || safetyEpoch != _safetyEpoch) {
            return TranslationCacheLookup.unavailable;
          }
          if (validatedOrigin != null) {
            await _attachReferences(
              tx,
              master,
              validatedOrigin,
              binding,
              storageKey,
            );
          }
          return TranslationCacheLookup(
            TranslationCacheLookupStatus.hit,
            translation: text,
            ticket: ticket,
          );
        }, write: true);
      } catch (_) {
        return TranslationCacheLookup.unavailable;
      }
    },
  );

  Future<void> write(
    TranslationCacheKey key,
    String translation, {
    bool Function()? isValid,
    TranslationCacheTicket? ticket,
  }) => writeAll(
    {key: translation},
    isValid: isValid,
    tickets: ticket == null ? null : {key: ticket},
  );

  Future<void> writeAll(
    Map<TranslationCacheKey, String> translations, {
    bool Function()? isValid,
    Map<TranslationCacheKey, TranslationCacheTicket>? tickets,
  }) {
    if (translations.isEmpty) return Future.value();
    // Capture the local generation before waiting for the serialization queue.
    final captured = {
      for (final key in translations.keys)
        key:
            tickets?[key] ??
            TranslationCacheTicket(
              _digest(key.source),
              _epochs[_digest(key.source)] ?? 0,
              '',
            ),
    };
    final safetyEpoch = _safetyEpoch;
    return _serialized(() async {
      var createdKey = false;
      var createdDatabase = false;
      void ensureValid() {
        if (isValid?.call() == false ||
            safetyEpoch != _safetyEpoch ||
            captured.values.any(
              (ticket) => (_epochs[ticket.sourceDigest] ?? 0) != ticket.epoch,
            )) {
          throw StateError('Translation cache write expired');
        }
      }

      try {
        ensureValid();
        final existed = await backend.exists();
        if (!existed) _masterKey = null;
        final existingMaster = await _loadExistingMasterKey();
        if (existed && existingMaster == null) {
          throw StateError('Translation cache key unavailable');
        }
        ensureValid();
        final master =
            existingMaster ??
            await (() {
              createdKey = true;
              return _createMasterKey();
            })();
        ensureValid();
        if (existed) {
          if (!await backend.openExisting(
            _databaseKey(master),
            migrate: true,
          )) {
            throw StateError('Translation cache disappeared');
          }
        } else {
          createdDatabase = true;
          await backend.openOrCreate(_databaseKey(master));
        }
        ensureValid();
        if (!await _replayPending()) {
          throw StateError('Translation cache cleanup pending');
        }
        await backend.transaction(
          (tx) async {
            final storeId = await _storeId(tx);
            for (final entry in translations.entries) {
              final key = entry.key;
              if (key.userId.isEmpty) {
                throw StateError('Translation cache owner missing');
              }
              final binding = _sourceBinding(master, key.source);
              final generation = await _generation(tx, binding);
              // Explicit tickets always guard disk generations. Direct writes
              // (maintenance/tests) start a new request at the current generation.
              if (tickets?[key] != null &&
                  (captured[key]!.generation != generation ||
                      (captured[key]!.storeId.isNotEmpty &&
                          captured[key]!.storeId != storeId))) {
                throw StateError('Translation source invalidated');
              }
              ensureValid();
              final row = _encrypt(master, key, entry.value, generation);
              await tx.put(CacheStore.contents, row);
              await _attachReferences(
                tx,
                master,
                key,
                binding,
                cacheString(row, 'cache_key'),
              );
            }
            // Throwing here aborts the entire transaction. Never restore a prior
            // snapshot after commit: that could resurrect content from another tab.
            ensureValid();
          },
          write: true,
          notify: true,
        );
      } catch (_) {
        // Only remove a newly created, empty store. A concurrent valid write
        // must survive cancellation or secure-storage failures.
        if (createdDatabase) {
          try {
            final empty = await backend.transaction(
              (tx) async =>
                  await tx.count(CacheStore.contents) == 0 &&
                  await tx.count(CacheStore.translations) == 0 &&
                  await tx.count(CacheStore.refs) == 0 &&
                  await tx.count(CacheStore.generations) == 0,
            );
            if (empty) await backend.deleteIfExists();
          } catch (_) {}
        }
        if (createdKey && !await backend.exists()) {
          await secrets.delete(_masterKeyName);
          _masterKey = null;
        }
        rethrow;
      }
    });
  }

  /// Destructive by source, including every user/language/type variant and
  /// all shared references. No reference-count retention on edits/deletions.
  Future<void> invalidateEventIfExists(
    String roomId,
    String eventId, {
    Iterable<String> sources = const [],
  }) {
    _safetyEpoch++;
    backend.signalInvalidation();
    final sourceList = sources.toSet();
    for (final source in sourceList) {
      final digest = _digest(source);
      _epochs[digest] = (_epochs[digest] ?? 0) + 1;
    }
    return _serialized(
      () => _safeCleanup({
        'room_id': roomId,
        'event_id': eventId,
        'bindings': sourceList
            .map(bindingIfLoaded)
            .whereType<String>()
            .toList(),
      }, sources: sourceList),
    );
  }

  Future<void> invalidateRoomIfExists(String roomId, {String? userId}) {
    _safetyEpoch++;
    backend.signalInvalidation();
    return _serialized(
      () => _safeCleanup({'room_id': roomId, 'user_id': ?userId}),
    );
  }

  Future<void> invalidateUserIfExists(String userId) {
    _safetyEpoch++;
    backend.signalInvalidation();
    return _serialized(() => _safeCleanup({'user_id': userId}));
  }

  Future<void> _loadPending({bool refresh = false}) async {
    if (_pendingLoaded && !refresh) return;
    if (refresh) await safetyPreferences?.store.reload();
    // Preserve in-memory identifiers even when a previous settings write
    // failed, and merge queue entries created by another context.
    final merged = {
      for (final row in [
        ..._pending,
        ...?safetyPreferences?.pendingCacheCleanup,
      ])
        jsonEncode(row): row,
    };
    _pending = merged.values.toList();
    _pendingLoaded = true;
  }

  Future<void> _savePending() =>
      safetyPreferences?.setPendingCacheCleanup(_pending) ??
      Future<void>.value();
  Future<void> _safeCleanup(
    CacheRow identifier, {
    Set<String> sources = const {},
  }) async {
    identifier = {
      ...identifier,
      // Distinct occurrences must not be removed by a tab acknowledging an
      // earlier cleanup of the same event.
      'id': base64UrlEncode(_randomBytes(12)),
    };
    try {
      if (!await backend.exists()) {
        return; // No key, tables, settings or migration.
      }
    } catch (_) {
      _pending.add(identifier);
      try {
        await _loadPending(refresh: true);
        await _savePending();
        backend.signalInvalidation();
      } catch (_) {}
      return;
    }
    // Derive bindings only after confirming the store exists. Source snapshots
    // stay in memory; only keyed digests enter the retry queue.
    try {
      final master = await _loadExistingMasterKey();
      if (master != null && sources.isNotEmpty) {
        identifier = {
          ...identifier,
          'bindings': {
            ...(identifier['bindings'] as List<Object?>? ?? [])
                .whereType<String>(),
            ...sources.map((source) => _sourceBinding(master, source)),
          }.toList(),
        };
      }
    } catch (_) {}
    _pending.add(identifier);
    try {
      await _loadPending(refresh: true);
      await _savePending();
      backend.signalInvalidation();
      if (!await _openExisting()) {
        _pending.removeWhere(
          (row) => jsonEncode(row) == jsonEncode(identifier),
        );
        await _savePending();
        return;
      }
      await _replayPending();
    } catch (_) {
      /* Retry before serving another cache hit. Normal chat proceeds. */
    }
  }

  Future<bool> _replayPending() async {
    try {
      await _loadPending(refresh: true);
      if (_pending.isEmpty) return true;
      for (final item in List<CacheRow>.of(_pending)) {
        if (item['suspended'] == true) return false;
        if (cacheString(item, 'room_id').isEmpty &&
            cacheString(item, 'user_id').isEmpty &&
            (item['bindings'] is! List ||
                (item['bindings']! as List).isEmpty)) {
          return false;
        }
        await backend.transaction(
          (tx) => _cleanup(tx, item),
          write: true,
          notify: true,
        );
        _pending.remove(item);
        await _savePending();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _cleanup(
    TranslationCacheTransaction tx,
    CacheRow item, {
    Set<String>? visited,
  }) async {
    final room = cacheString(item, 'room_id');
    final event = cacheString(item, 'event_id');
    final user = cacheString(item, 'user_id');
    visited ??= {};
    if (event.isNotEmpty && !visited.add(jsonEncode([room, event]))) return;
    final bindings = (item['bindings'] as List<Object?>? ?? [])
        .whereType<String>()
        .toSet();
    final index = event.isNotEmpty
        ? 'event'
        : room.isNotEmpty
        ? 'room'
        : 'user';
    final equals = event.isNotEmpty
        ? [room, event]
        : room.isNotEmpty
        ? [room]
        : [user];
    if (event.isNotEmpty) {
      // An edit reference records its original event, including after the SDK
      // has redacted away the edit relationship itself.
      final roots = <String>{};
      Object? cursor;
      while (true) {
        final refs = await tx.query(
          CacheStore.refs,
          index: 'event',
          equals: equals,
          after: cursor,
        );
        if (refs.isEmpty) break;
        for (final ref in refs) {
          final root = cacheString(ref, 'original_event_id');
          if (root.isNotEmpty && root != event) roots.add(root);
        }
        cursor = refs.last['_cursor'];
      }
      for (final root in roots) {
        await _cleanup(tx, {
          'room_id': room,
          'event_id': root,
        }, visited: visited);
      }
    }
    for (final store in [CacheStore.refs, CacheStore.translations]) {
      if (store == CacheStore.translations && index == 'user') continue;
      Object? cursor;
      while (true) {
        final rows = await tx.query(
          store,
          index: index,
          equals: equals,
          after: cursor,
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          if (user.isNotEmpty &&
              store == CacheStore.refs &&
              row['user_id'] != user) {
            continue;
          }
          final binding = cacheString(row, 'source_binding');
          if (event.isNotEmpty) {
            if (binding.isNotEmpty) bindings.add(binding);
          } else if (store == CacheStore.refs) {
            final contentKey = cacheString(row, 'content_key');
            await tx.delete(store, cacheString(row, 'cache_key'));
            if ((await tx.query(
              CacheStore.refs,
              index: 'content',
              equals: [contentKey],
              limit: 1,
            )).isEmpty) {
              await tx.delete(CacheStore.contents, contentKey);
            }
          }
          await tx.delete(store, cacheString(row, 'cache_key'));
        }
        cursor = rows.last['_cursor'];
      }
    }
    await _deleteBindings(tx, bindings);
    if (index == 'user') {
      await _deleteMatching(tx, CacheStore.contents, 'user', [user]);
    }
  }

  Future<void> _deleteBindings(
    TranslationCacheTransaction tx,
    Set<String> bindings,
  ) async {
    for (final binding in bindings) {
      if (tx.hasStore(CacheStore.generations)) {
        await tx.put(CacheStore.generations, {
          'cache_key': binding,
          'value': base64UrlEncode(_randomBytes(18)),
        });
      }
      for (final store in [
        CacheStore.contents,
        CacheStore.refs,
        CacheStore.translations,
      ]) {
        await _deleteMatching(tx, store, 'binding', [binding]);
      }
    }
  }

  Future<void> _deleteMatching(
    TranslationCacheTransaction tx,
    CacheStore store,
    String index,
    List<String> equals,
  ) async {
    Object? cursor;
    while (true) {
      final rows = await tx.query(
        store,
        index: index,
        equals: equals,
        after: cursor,
      );
      if (rows.isEmpty) return;
      for (final row in rows) {
        await tx.delete(store, cacheString(row, 'cache_key'));
      }
      cursor = rows.last['_cursor'];
    }
  }

  /// Reindexes sealed envelopes in batches without requiring plaintext. The
  /// actual AES-GCM conversion happens only with an available matching source.
  Future<bool> migrateLegacy({
    required List<String> Function(String roomId) owners,
    required TranslationSourceResolver localSource,
    required bool Function() isEnabled,
    int pageSize = 200,
  }) => _serialized(() async {
    var changed = false;
    if (!isEnabled()) return changed;
    final startEpoch = _safetyEpoch;
    try {
      if (!await _openExisting(migrate: true) || !await _replayPending()) {
        return changed;
      }
      Object? cursor;
      final checkpoint = await backend.transaction(
        (tx) => tx.get(CacheStore.metadata, 'legacy_cursor'),
      );
      if (checkpoint != null) {
        cursor = jsonDecode(cacheString(checkpoint, 'value'));
      }
      while (isEnabled() && startEpoch == _safetyEpoch) {
        final rows = await backend.transaction(
          (tx) => tx.query(
            CacheStore.translations,
            after: cursor,
            limit: pageSize.clamp(1, 200),
          ),
        );
        if (rows.isEmpty) {
          await backend.transaction(
            (tx) => tx.delete(CacheStore.metadata, 'legacy_cursor'),
            write: true,
          );
          return changed;
        }
        final resolved =
            <({CacheRow row, String user, TranslationLocalSource source})>[];
        for (final row in rows) {
          final room = cacheString(row, 'room_id');
          final event = cacheString(row, 'event_id');
          for (final owner in owners(room).toSet()) {
            TranslationLocalSource source;
            try {
              source = await localSource(owner, room, event);
            } catch (_) {
              source = TranslationLocalSource.unavailable;
            }
            resolved.add((row: row, user: owner, source: source));
          }
        }
        if (!isEnabled() || startEpoch != _safetyEpoch) return changed;
        final batchChanged = await backend.transaction(
          (tx) async {
            final processed = <String>{};
            var updated = false;
            for (final entry in resolved) {
              final row = entry.row;
              final oldKey = cacheString(row, 'cache_key');
              if (await tx.get(CacheStore.translations, oldKey) == null) {
                continue;
              }
              updated = true;
              final binding = cacheString(row, 'source_binding');
              List<Object?> aad;
              try {
                aad = (jsonDecode(cacheString(row, 'aad')) as List)
                    .cast<Object?>();
                if (aad.length != 7 ||
                    aad.first != 1 ||
                    aad[1] != row['room_id'] ||
                    aad[2] != row['event_id'] ||
                    binding.isEmpty ||
                    !aad.skip(1).every((value) => value is String)) {
                  throw const FormatException();
                }
              } catch (_) {
                await tx.delete(CacheStore.translations, oldKey);
                continue;
              }
              if (entry.source.status ==
                      TranslationLocalSourceStatus.obsolete ||
                  (entry.source.source != null &&
                      _sourceBinding(_masterKey!, entry.source.source!) !=
                          binding)) {
                await _deleteBindings(tx, {binding});
                continue;
              }
              // A pre-existing tombstone always wins over an old envelope.
              final generation = await _generation(tx, binding);
              if (generation.isNotEmpty) {
                await tx.delete(CacheStore.translations, oldKey);
                continue;
              }
              final identity = [
                entry.user,
                binding,
                aad[3]! as String,
                aad[4]! as String,
                aad[6]! as String,
              ];
              final key = _storageKey(_masterKey!, identity);
              final current = await tx.get(CacheStore.contents, key);
              final order = row['_cursor'];
              final rank = order is int
                  ? order.toString().padLeft(20, '0')
                  : order! as String;
              if (current == null ||
                  (current['legacy'] != 0 &&
                      cacheString(current, 'rank').compareTo(rank) < 0)) {
                var content = <String, Object?>{
                  ...row,
                  'cache_key': key,
                  'user_id': entry.user,
                  'legacy': 1,
                  'rank': rank,
                  'generation': generation,
                }..remove('_cursor');
                if (entry.source.status == TranslationLocalSourceStatus.valid) {
                  try {
                    final source = entry.source.source!;
                    final translation = _decrypt(_masterKey!, source, row);
                    content = _encrypt(
                      _masterKey!,
                      TranslationCacheKey(
                        userId: entry.user,
                        roomId: cacheString(row, 'room_id'),
                        eventId: cacheString(row, 'event_id'),
                        source: source,
                        sourceLanguage: aad[3]! as String,
                        targetLanguage: aad[4]! as String,
                        messageType: aad[6]! as String,
                      ),
                      translation,
                      generation,
                      legacyModel: _legacyModel(row),
                    )..addAll({'legacy': 2, 'rank': rank});
                  } catch (_) {
                    // Isolate a malformed envelope instead of aborting the
                    // batch; lookup/maintenance can discard this one record.
                  }
                }
                await tx.put(CacheStore.contents, content);
              }
              // Loser records still contribute references for destructive cleanup.
              final refIdentity = [
                entry.user,
                row['room_id'],
                row['event_id'],
                key,
              ];
              await tx.put(CacheStore.refs, {
                'cache_key': _storageKey(_masterKey!, refIdentity),
                'user_id': entry.user,
                'room_id': row['room_id'],
                'event_id': row['event_id'],
                'source_binding': binding,
                'content_key': key,
                'original_event_id':
                    entry.source.originalEventId ?? row['event_id'],
              });
              final root = entry.source.originalEventId;
              if (root != null && root != row['event_id']) {
                await tx.put(CacheStore.refs, {
                  'cache_key': _storageKey(_masterKey!, [
                    entry.user,
                    row['room_id'],
                    root,
                    key,
                  ]),
                  'user_id': entry.user,
                  'room_id': row['room_id'],
                  'event_id': root,
                  'source_binding': binding,
                  'content_key': key,
                  'original_event_id': root,
                });
              }
              processed.add(oldKey);
            }
            for (final key in processed) {
              await tx.delete(CacheStore.translations, key);
            }
            await tx.put(CacheStore.metadata, {
              'cache_key': 'legacy_cursor',
              'value': jsonEncode(rows.last['_cursor']),
            });
            if (!isEnabled() || startEpoch != _safetyEpoch) {
              throw StateError('Migration expired');
            }
            return updated;
          },
          write: true,
          notify: resolved.isNotEmpty,
        );
        changed = changed || batchChanged;
        cursor = rows.last['_cursor'];
      }
    } catch (_) {
      /* Sealed rows/checkpoint survive for the next attempt. */
    }
    return changed;
  });

  Future<TranslationCacheCleanupResult> cleanInvalid(
    TranslationSourceResolver localSource, {
    int pageSize = 200,
  }) => _serialized(() async {
    try {
      if (!await _openExisting() || !await _replayPending()) {
        return TranslationCacheCleanupResult.notFound;
      }
      var checked = 0, retained = 0, deleted = 0;
      for (final store in [CacheStore.refs, CacheStore.translations]) {
        Object? cursor;
        while (true) {
          final rows = await backend.transaction(
            (tx) =>
                tx.query(store, after: cursor, limit: pageSize.clamp(1, 200)),
          );
          if (rows.isEmpty) break;
          for (final row in rows) {
            checked++;
            TranslationLocalSource source;
            try {
              source = await localSource(
                cacheString(row, 'user_id'),
                cacheString(row, 'room_id'),
                cacheString(row, 'event_id'),
              );
            } catch (_) {
              source = TranslationLocalSource.unavailable;
            }
            if (source.status == TranslationLocalSourceStatus.unavailable) {
              retained++;
              continue;
            }
            var valid =
                source.status == TranslationLocalSourceStatus.valid &&
                cacheString(row, 'source_binding') ==
                    _sourceBinding(_masterKey!, source.source!);
            if (valid) {
              final content = store == CacheStore.translations
                  ? row
                  : await backend.transaction(
                      (tx) => tx.get(
                        CacheStore.contents,
                        cacheString(row, 'content_key'),
                      ),
                    );
              try {
                if (content == null) throw const FormatException();
                _decrypt(_masterKey!, source.source!, content);
              } catch (_) {
                valid = false;
              }
            }
            if (valid) {
              retained++;
            } else {
              try {
                await backend.transaction(
                  (tx) async {
                    final binding = cacheString(row, 'source_binding');
                    if (binding.isNotEmpty) {
                      await _deleteBindings(tx, {binding});
                    }
                    await tx.delete(store, cacheString(row, 'cache_key'));
                  },
                  write: true,
                  notify: true,
                );
              } catch (_) {
                await _safeCleanup({
                  'room_id': row['room_id'],
                  'event_id': row['event_id'],
                  'bindings': [
                    if (cacheString(row, 'source_binding').isNotEmpty)
                      row['source_binding'],
                  ],
                });
                return TranslationCacheCleanupResult(
                  checked: checked,
                  retained: retained,
                  deleted: deleted,
                  cacheExisted: true,
                );
              }
              deleted++;
            }
          }
          cursor = rows.last['_cursor'];
        }
      }
      return TranslationCacheCleanupResult(
        checked: checked,
        retained: retained,
        deleted: deleted,
        cacheExisted: true,
      );
    } catch (_) {
      return TranslationCacheCleanupResult.notFound;
    }
  });

  Future<void> deleteIfExists() => _serialized(() async {
    _safetyEpoch++;
    await _loadPending(refresh: true);
    await backend.deleteIfExists();
    _masterKey = null;
    await secrets.delete(_masterKeyName);
    _pending.clear();
    await _savePending();
  });

  Future<void> dispose() => _serialized(backend.dispose);

  Future<bool> _openExisting({bool migrate = false}) async {
    if (!await backend.exists()) return false;
    final master = await _loadExistingMasterKey();
    if (master == null) throw StateError('Translation cache key unavailable');
    return backend.openExisting(_databaseKey(master), migrate: migrate);
  }

  Future<Uint8List?> _loadExistingMasterKey() async {
    if (_masterKey != null) return _masterKey;
    final encoded = await secrets.read(_masterKeyName);
    if (encoded == null) return null;
    try {
      final decoded = base64Url.decode(encoded);
      if (decoded.length == 32) return _masterKey = Uint8List.fromList(decoded);
    } catch (_) {}
    return null;
  }

  Future<Uint8List> _createMasterKey() async {
    final generated = _randomBytes(32);
    await secrets.write(_masterKeyName, base64UrlEncode(generated));
    return _masterKey = generated;
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _operationTail;
    final release = Completer<void>();
    _operationTail = release.future;
    return (() async {
      await previous;
      try {
        return await backend.coordinated(operation);
      } finally {
        release.complete();
      }
    })();
  }

  static Future<String> _generation(
    TranslationCacheTransaction tx,
    String binding,
  ) async =>
      cacheString(await tx.get(CacheStore.generations, binding) ?? {}, 'value');
  static Future<String> _storeId(TranslationCacheTransaction tx) async {
    var id = cacheString(
      await tx.get(CacheStore.metadata, 'store_id') ?? {},
      'value',
    );
    if (id.isEmpty) {
      id = base64UrlEncode(_randomBytes(18));
      await tx.put(CacheStore.metadata, {'cache_key': 'store_id', 'value': id});
    }
    return id;
  }

  static CacheRow _reference(
    Uint8List master,
    TranslationCacheKey key,
    String binding,
    String storageKey,
  ) => {
    'cache_key': _storageKey(master, [
      key.userId,
      key.roomId,
      key.eventId,
      storageKey,
    ]),
    'user_id': key.userId,
    'room_id': key.roomId,
    'event_id': key.eventId,
    'source_binding': binding,
    'content_key': storageKey,
    'original_event_id': key.originalEventId ?? key.eventId,
  };
  static Future<void> _attachReferences(
    TranslationCacheTransaction tx,
    Uint8List master,
    TranslationCacheKey key,
    String binding,
    String storageKey,
  ) async {
    final reference = _reference(master, key, binding, storageKey);
    // A display event may no longer carry its edit relationship. Do not erase
    // a previously established original-event reference in that case.
    final existing = await tx.get(
      CacheStore.refs,
      cacheString(reference, 'cache_key'),
    );
    final original = cacheString(existing ?? {}, 'original_event_id');
    final root =
        key.originalEventId ?? (original.isEmpty ? key.eventId : original);
    reference['original_event_id'] = root;
    await tx.put(CacheStore.refs, reference);
    if (root != key.eventId) {
      await tx.put(CacheStore.refs, {
        ...reference,
        'event_id': root,
        'cache_key': _storageKey(master, [
          key.userId,
          key.roomId,
          root,
          storageKey,
        ]),
      });
    }
  }

  static CacheRow _encrypt(
    Uint8List master,
    TranslationCacheKey key,
    String text,
    String generation, {
    String? legacyModel,
  }) {
    final binding = _sourceBinding(master, key.source);
    final aad = key.aad(binding);
    final nonce = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_derivedKeyForSource(master, key.source)),
          128,
          nonce,
          Uint8List.fromList(utf8.encode(aad)),
        ),
      );
    final payload = jsonEncode({
      'v': 2,
      'text': text,
      'model': ?key.model ?? legacyModel,
      'written_at': DateTime.now().toUtc().toIso8601String(),
    });
    return {
      'cache_key': _storageKey(master, key.identity(binding)),
      'user_id': key.userId,
      'source_binding': binding,
      'nonce': base64UrlEncode(nonce),
      'ciphertext': base64UrlEncode(
        cipher.process(Uint8List.fromList(utf8.encode(payload))),
      ),
      'aad': aad,
      'generation': generation,
      'legacy': 0,
      'rank': '',
      'room_id': '',
      'event_id': '',
    };
  }

  static String _decrypt(Uint8List master, String source, CacheRow row) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_derivedKeyForSource(master, source)),
          128,
          Uint8List.fromList(base64Url.decode(cacheString(row, 'nonce'))),
          Uint8List.fromList(utf8.encode(cacheString(row, 'aad'))),
        ),
      );
    return utf8.decode(
      cipher.process(
        Uint8List.fromList(base64Url.decode(cacheString(row, 'ciphertext'))),
      ),
    );
  }

  static bool _legacyMatches(Uint8List master, String source, CacheRow row) {
    try {
      final aad = jsonDecode(cacheString(row, 'aad')) as List;
      // The old cache key is no longer the content key; authenticate its AAD
      // and source binding instead. No legacy envelope is served directly.
      return aad.length == 7 &&
          aad.first == 1 &&
          aad[1] == row['room_id'] &&
          aad[2] == row['event_id'] &&
          row['source_binding'] == _sourceBinding(master, source);
    } catch (_) {
      return false;
    }
  }

  static bool _legacyLanguagesMatch(TranslationCacheKey key, CacheRow row) {
    final aad = jsonDecode(cacheString(row, 'aad')) as List;
    return aad[3] == key.sourceLanguage &&
        aad[4] == key.targetLanguage &&
        aad[6] == key.messageType;
  }

  static String? _legacyModel(CacheRow row) {
    try {
      final aad = jsonDecode(cacheString(row, 'aad')) as List;
      final revision = jsonDecode(aad[5]! as String) as List;
      return revision.length > 2 && revision[2] is String
          ? revision[2]! as String
          : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _derivedKeyForSource(Uint8List master, String source) {
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(
        HkdfParameters(
          master,
          32,
          Uint8List.fromList(sha256.convert(utf8.encode(source)).bytes),
          Uint8List.fromList(utf8.encode('fluffychat-translation-v1')),
        ),
      );
    final output = Uint8List(32);
    derivator.deriveKey(null, 0, output, 0);
    return output;
  }

  static String _sourceBinding(Uint8List master, String source) =>
      base64UrlEncode(
        Hmac(
          sha256,
          master,
        ).convert(utf8.encode('source-binding:$source')).bytes,
      );
  static String _storageKey(Uint8List master, List<Object?> identity) =>
      base64UrlEncode(
        Hmac(sha256, master).convert(utf8.encode(jsonEncode(identity))).bytes,
      );
  static String _databaseKey(Uint8List master) =>
      sha256.convert(master + utf8.encode('database')).toString();
  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }
}
