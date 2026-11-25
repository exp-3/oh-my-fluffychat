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
    binding,
    sourceLanguage,
    targetLanguage,
    messageType,
  ];
  String aad(String binding) => jsonEncode([3, ...identity(binding)]);
  String get referenceKey => jsonEncode([
    userId,
    roomId,
    eventId,
    sourceLanguage,
    targetLanguage,
    messageType,
  ]);
}

enum TranslationCacheLookupStatus { hit, miss, unavailable }

class TranslationCacheWriteInvalidated extends StateError {
  TranslationCacheWriteInvalidated()
    : super('Translation cache write invalidated');
}

class TranslationCacheTicket {
  final String referenceKey;
  final int epoch;
  final String generation;
  final String storeId;
  const TranslationCacheTicket(
    this.referenceKey,
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

class TranslationCache {
  static const _masterKeyName = 'chat.fluffy.translation.cache_master_key';
  final TranslationSecretStore secrets;
  final TranslationCacheBackend backend;
  TranslationPreferences? safetyPreferences;
  Uint8List? _masterKey;
  Future<void> _operationTail = Future.value();
  final _epochs = <String, int>{};
  List<CacheRow> _pending = [];
  bool _pendingLoaded = false;
  bool _formatChecked = false;
  int _safetyEpoch = 0;
  TranslationCache(this.secrets, [TranslationCacheBackend? backend])
    : backend = backend ?? createTranslationCacheBackend();

  Stream<void> get externalChanges => backend.externalChanges;

  Future<void> refreshSafetyState() => _serialized(() async {
    _masterKey = null;
    _formatChecked = false;
    await backend.close();
    await _loadPending(refresh: true);
  });

  Future<bool> needsUpgrade() => _serialized(() async {
    if (!backend.supported) return false;
    if (!await _openExisting(checkFormat: false)) return false;
    final needed = await backend.needsUpgrade();
    _formatChecked = !needed;
    return needed;
  });

  Future<String?> read(TranslationCacheKey key) async =>
      (await lookup(key)).translation;

  Future<TranslationCacheLookup> lookup(
    TranslationCacheKey key,
  ) => _serialized(() async {
    final epoch = _epoch(key);
    final safetyEpoch = _safetyEpoch;
    try {
      if (!await _openExisting()) {
        return TranslationCacheLookup(
          TranslationCacheLookupStatus.miss,
          ticket: TranslationCacheTicket(key.referenceKey, epoch, ''),
        );
      }
      await _replayPending();
      final master = _masterKey!;
      return await backend.transaction((tx) async {
        final ticket = TranslationCacheTicket(
          key.referenceKey,
          epoch,
          await _generation(tx, key),
          await _storeId(tx),
        );
        final reference = await tx.get(
          CacheStore.messageRefs,
          key.referenceKey,
        );
        if (reference != null) {
          final content = await tx.get(
            CacheStore.sharedContents,
            cacheString(reference, 'content_key'),
          );
          if (content != null) {
            String? text;
            try {
              text = _readContent(master, key, content);
            } catch (_) {
              // Detach only this message after an edit or failed authentication.
            }
            if (text != null) {
              if (_epoch(key) != epoch || safetyEpoch != _safetyEpoch) {
                return TranslationCacheLookup.unavailable;
              }
              if (key.originalEventId != null &&
                  reference['original_event_id'] != key.originalEventId) {
                await _attachReference(
                  tx,
                  key,
                  cacheString(reference, 'content_key'),
                );
              }
              return TranslationCacheLookup(
                TranslationCacheLookupStatus.hit,
                translation: text,
                ticket: ticket,
              );
            }
          }
          await _detachReference(tx, reference);
        }
        final binding = _sourceBinding(master, key.source);
        final storageKey = _storageKey(master, key.identity(binding));
        final content = await tx.get(CacheStore.sharedContents, storageKey);
        String? text;
        if (content != null) {
          try {
            text = _readContent(master, key, content);
          } catch (_) {
            // Other messages retain their references until checked.
          }
        }
        await _attachReference(tx, key, storageKey);
        if (_epoch(key) != epoch || safetyEpoch != _safetyEpoch) {
          return TranslationCacheLookup.unavailable;
        }
        return TranslationCacheLookup(
          text == null
              ? TranslationCacheLookupStatus.miss
              : TranslationCacheLookupStatus.hit,
          translation: text,
          ticket: ticket,
        );
      }, write: true);
    } catch (_) {
      return TranslationCacheLookup.unavailable;
    }
  });

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
    final epochs = {for (final key in translations.keys) key: _epoch(key)};
    final safetyEpoch = _safetyEpoch;
    return _serialized(() async {
      var createdKey = false;
      var createdDatabase = false;
      void ensureValid() {
        if (isValid?.call() == false ||
            safetyEpoch != _safetyEpoch ||
            translations.keys.any((key) {
              final ticket = tickets?[key];
              return _epoch(key) != epochs[key] ||
                  (ticket != null &&
                      (ticket.referenceKey != key.referenceKey ||
                          ticket.epoch != _epoch(key)));
            })) {
          throw TranslationCacheWriteInvalidated();
        }
      }

      try {
        ensureValid();
        final existed = await backend.exists();
        if (!existed) {
          _masterKey = null;
          _formatChecked = false;
        }
        final existingMaster = await _loadExistingMasterKey();
        if (existed && existingMaster == null) {
          throw StateError('Translation cache key unavailable');
        }
        final master =
            existingMaster ??
            await (() {
              createdKey = true;
              return _createMasterKey();
            })();
        ensureValid();
        if (existed) {
          if (!await _openExisting()) {
            throw StateError('Translation cache disappeared');
          }
        } else {
          createdDatabase = true;
          await backend.openOrCreate(_databaseKey(master));
          _formatChecked = true;
        }
        ensureValid();
        await _replayPending();
        await backend.transaction(
          (tx) async {
            final storeId = await _storeId(tx);
            for (final entry in translations.entries) {
              final key = entry.key;
              if (key.userId.isEmpty) {
                throw StateError('Translation cache reference owner missing');
              }
              final ticket = tickets?[key];
              if (ticket != null &&
                  (ticket.generation != await _generation(tx, key) ||
                      (ticket.storeId.isNotEmpty &&
                          ticket.storeId != storeId))) {
                throw TranslationCacheWriteInvalidated();
              }
              ensureValid();
              final binding = _sourceBinding(master, key.source);
              final row = _encrypt(master, key, entry.value, binding);
              await tx.put(CacheStore.sharedContents, row);
              await _attachReference(tx, key, cacheString(row, 'cache_key'));
            }
            ensureValid();
          },
          write: true,
          notify: true,
        );
      } catch (_) {
        if (createdDatabase) {
          try {
            final empty = await backend.transaction(
              (tx) async =>
                  await tx.count(CacheStore.sharedContents) == 0 &&
                  await tx.count(CacheStore.messageRefs) == 0 &&
                  await tx.count(CacheStore.revisions) == 0,
            );
            if (empty) {
              await backend.deleteIfExists();
              _formatChecked = false;
            }
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

  Future<void> invalidateEventIfExists(String roomId, String eventId) {
    _bumpEpoch(_scope('event', [roomId, eventId]));
    return _serialized(
      () => _safeCleanup({'room_id': roomId, 'event_id': eventId}),
    );
  }

  Future<void> invalidateRoomIfExists(String roomId, {String? userId}) {
    _bumpEpoch(
      userId == null
          ? _scope('room', [roomId])
          : _scope('user_room', [userId, roomId]),
    );
    return _serialized(
      () => _safeCleanup({'room_id': roomId, 'user_id': ?userId}),
    );
  }

  Future<void> invalidateUserIfExists(String userId) {
    _bumpEpoch(_scope('user', [userId]));
    return _serialized(() => _safeCleanup({'user_id': userId}));
  }

  Future<void> _loadPending({bool refresh = false}) async {
    if (_pendingLoaded && !refresh) return;
    if (refresh) await safetyPreferences?.store.reload();
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

  Future<void> _safeCleanup(CacheRow identifier) async {
    identifier = {...identifier, 'id': base64UrlEncode(_randomBytes(12))};
    try {
      if (!await backend.exists()) return;
    } catch (_) {
      _pending.add(identifier);
      try {
        await _loadPending(refresh: true);
        await _savePending();
        backend.signalInvalidation();
      } catch (_) {}
      return;
    }
    _pending.add(identifier);
    try {
      await _loadPending(refresh: true);
      await _savePending();
      backend.signalInvalidation();
      if (!await _openExisting()) return;
      await _replayPending();
    } catch (_) {
      // Retry persistent cleanup before serving another cache hit.
    }
  }

  Future<void> _replayPending() async {
    await _loadPending(refresh: true);
    for (final item in List<CacheRow>.of(_pending)) {
      await backend.transaction(
        (tx) => _cleanup(tx, item),
        write: true,
        notify: true,
      );
      _pending.remove(item);
      await _savePending();
    }
  }

  Future<void> _cleanup(TranslationCacheTransaction tx, CacheRow item) async {
    final room = cacheString(item, 'room_id');
    final event = cacheString(item, 'event_id');
    final user = cacheString(item, 'user_id');
    if (item['suspended'] == true ||
        (room.isEmpty && user.isEmpty && event.isEmpty)) {
      throw StateError('Translation cleanup identifiers unavailable');
    }
    if (event.isNotEmpty) {
      final roots = <String>{event};
      Object? cursor;
      while (true) {
        final direct = await tx.query(
          CacheStore.messageRefs,
          index: 'event',
          equals: [room, event],
          after: cursor,
        );
        if (direct.isEmpty) break;
        for (final reference in direct) {
          final root = cacheString(reference, 'original_event_id');
          if (root.isNotEmpty) roots.add(root);
        }
        cursor = direct.last['_cursor'];
      }
      for (final root in roots) {
        await _revise(tx, _scope('event', [room, root]));
        await _detachMatching(tx, 'event', [room, root], reviseEvents: true);
        await _detachMatching(tx, 'root', [room, root], reviseEvents: true);
      }
      return;
    }
    if (room.isNotEmpty) {
      if (user.isEmpty) {
        await _revise(tx, _scope('room', [room]));
        await _detachMatching(tx, 'room', [room]);
      } else {
        await _revise(tx, _scope('user_room', [user, room]));
        await _detachMatching(tx, 'user_room', [user, room]);
      }
      return;
    }
    await _revise(tx, _scope('user', [user]));
    await _detachMatching(tx, 'user', [user]);
  }

  static Future<void> _revise(TranslationCacheTransaction tx, String scope) =>
      tx.put(CacheStore.revisions, {
        'cache_key': scope,
        'value': base64UrlEncode(_randomBytes(18)),
      });

  static Future<void> _detachMatching(
    TranslationCacheTransaction tx,
    String index,
    List<String> equals, {
    bool reviseEvents = false,
  }) async {
    Object? cursor;
    while (true) {
      final rows = await tx.query(
        CacheStore.messageRefs,
        index: index,
        equals: equals,
        after: cursor,
      );
      if (rows.isEmpty) return;
      for (final row in rows) {
        if (reviseEvents) {
          await _revise(
            tx,
            _scope('event', [
              cacheString(row, 'room_id'),
              cacheString(row, 'event_id'),
            ]),
          );
        }
        await _detachReference(tx, row);
      }
      cursor = rows.last['_cursor'];
    }
  }

  static Future<void> _detachReference(
    TranslationCacheTransaction tx,
    CacheRow reference,
  ) async {
    await tx.delete(
      CacheStore.messageRefs,
      cacheString(reference, 'cache_key'),
    );
    final contentKey = cacheString(reference, 'content_key');
    if ((await tx.query(
      CacheStore.messageRefs,
      index: 'content',
      equals: [contentKey],
      limit: 1,
    )).isEmpty) {
      await tx.delete(CacheStore.sharedContents, contentKey);
    }
  }

  static Future<void> _attachReference(
    TranslationCacheTransaction tx,
    TranslationCacheKey key,
    String contentKey,
  ) async {
    final existing = await tx.get(CacheStore.messageRefs, key.referenceKey);
    if (existing != null && existing['content_key'] != contentKey) {
      await _detachReference(tx, existing);
    }
    final original = cacheString(existing ?? {}, 'original_event_id');
    await tx.put(CacheStore.messageRefs, {
      'cache_key': key.referenceKey,
      'user_id': key.userId,
      'room_id': key.roomId,
      'event_id': key.eventId,
      'source_language': key.sourceLanguage,
      'target_language': key.targetLanguage,
      'message_type': key.messageType,
      'content_key': contentKey,
      'original_event_id':
          key.originalEventId ?? (original.isEmpty ? key.eventId : original),
    });
  }

  Future<TranslationCacheCleanupResult> cleanInvalid(
    TranslationSourceResolver localSource, {
    int pageSize = 200,
  }) => _serialized(() async {
    if (!await _openExisting()) return TranslationCacheCleanupResult.notFound;
    await _replayPending();
    var checked = 0, retained = 0, deleted = 0;
    Object? cursor;
    while (true) {
      final rows = await backend.transaction(
        (tx) => tx.query(
          CacheStore.messageRefs,
          after: cursor,
          limit: pageSize.clamp(1, 200),
        ),
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
        var valid = source.status == TranslationLocalSourceStatus.valid;
        if (valid) {
          final content = await backend.transaction(
            (tx) => tx.get(
              CacheStore.sharedContents,
              cacheString(row, 'content_key'),
            ),
          );
          try {
            if (content == null) throw const FormatException();
            _readContent(_masterKey!, _keyFromReference(row, source), content);
          } catch (_) {
            valid = false;
          }
        }
        if (valid) {
          retained++;
        } else {
          await backend.transaction(
            (tx) async {
              await _revise(
                tx,
                _scope('event', [
                  cacheString(row, 'room_id'),
                  cacheString(row, 'event_id'),
                ]),
              );
              await _detachReference(tx, row);
            },
            write: true,
            notify: true,
          );
          deleted++;
        }
      }
      cursor = rows.last['_cursor'];
    }
    return TranslationCacheCleanupResult(
      checked: checked,
      retained: retained,
      deleted: deleted,
      cacheExisted: true,
    );
  });

  Future<void> upgrade(
    TranslationSourceResolver localSource, {
    Iterable<String> userIds = const [],
    int pageSize = 200,
  }) => _serialized(() async {
    if (!await _openExisting(checkFormat: false)) return;
    if (!await backend.needsUpgrade()) {
      _formatChecked = true;
      return;
    }
    _safetyEpoch++;
    _formatChecked = false;
    if (!await backend.openExisting(_databaseKey(_masterKey!), migrate: true)) {
      throw StateError('Translation cache disappeared during upgrade');
    }
    await _loadPending(refresh: true);
    if (_pending.any((row) => row['suspended'] == true)) {
      throw StateError('Translation cleanup must be recovered before upgrade');
    }
    for (final store in [
      CacheStore.sharedContents,
      CacheStore.messageRefs,
      CacheStore.revisions,
    ]) {
      await _clearStore(store);
    }
    await _clearUpgradeRanks();
    final master = _masterKey!;
    for (final store in [CacheStore.refs, CacheStore.translations]) {
      Object? cursor;
      while (true) {
        final rows = await backend.transaction(
          (tx) => tx.query(store, after: cursor, limit: pageSize.clamp(1, 200)),
        );
        if (rows.isEmpty) break;
        for (final reference in rows) {
          final owners = store == CacheStore.refs
              ? [cacheString(reference, 'user_id')]
              : userIds.toSet();
          for (final owner in owners) {
            if (owner.isEmpty) continue;
            final source = await localSource(
              owner,
              cacheString(reference, 'room_id'),
              cacheString(reference, 'event_id'),
            );
            if (source.status != TranslationLocalSourceStatus.valid ||
                source.source == null) {
              continue;
            }
            final old = store == CacheStore.translations
                ? reference
                : await backend.transaction(
                    (tx) => tx.get(
                      CacheStore.contents,
                      cacheString(reference, 'content_key'),
                    ),
                  );
            if (old == null) continue;
            final converted = _decodeOld(master, owner, reference, source, old);
            if (converted == null) continue;
            final key = converted.key;
            final binding = _sourceBinding(master, key.source);
            final storageKey = _storageKey(master, key.identity(binding));
            await backend.transaction((tx) async {
              if (store == CacheStore.refs) {
                final generation = cacheString(
                  await tx.get(CacheStore.generations, binding) ?? {},
                  'value',
                );
                if (cacheString(old, 'generation') != generation) return;
              }
              final rankKey = jsonEncode(['upgrade_rank', storageKey]);
              final previous = cacheString(
                await tx.get(CacheStore.metadata, rankKey) ?? {},
                'value',
              );
              if (previous.isEmpty || converted.rank.compareTo(previous) > 0) {
                await tx.put(
                  CacheStore.sharedContents,
                  _encrypt(
                    master,
                    key,
                    converted.text,
                    binding,
                    writtenAt: converted.writtenAt,
                  ),
                );
                await tx.put(CacheStore.metadata, {
                  'cache_key': rankKey,
                  'value': converted.rank,
                });
              }
              await _attachReference(tx, key, storageKey);
            }, write: true);
          }
        }
        cursor = rows.last['_cursor'];
        await Future<void>.delayed(Duration.zero);
      }
    }
    await _loadPending(refresh: true);
    for (final item in _pending) {
      await backend.transaction((tx) => _cleanup(tx, item), write: true);
    }
    await _clearUpgradeRanks();
    await backend.transaction(
      (tx) => tx.put(CacheStore.metadata, {
        'cache_key': 'store_id',
        'value': base64UrlEncode(_randomBytes(18)),
      }),
      write: true,
    );
    await backend.finishUpgrade();
    _formatChecked = true;
    _pending.clear();
    await _savePending();
  });

  static _ConvertedTranslation? _decodeOld(
    Uint8List master,
    String owner,
    CacheRow reference,
    TranslationLocalSource source,
    CacheRow row,
  ) {
    try {
      final binding = _sourceBinding(master, source.source!);
      final aad = jsonDecode(cacheString(row, 'aad')) as List<Object?>;
      final String sourceLanguage, targetLanguage, messageType;
      Map<String, Object?> payload;
      var priority = 0;
      if (aad.first == 2 && aad.length == 6) {
        if (aad[1] != owner ||
            row['user_id'] != owner ||
            row['source_binding'] != binding ||
            aad[2] != binding ||
            row['cache_key'] != _storageKey(master, aad.sublist(1))) {
          return null;
        }
        sourceLanguage = aad[3]! as String;
        targetLanguage = aad[4]! as String;
        messageType = aad[5]! as String;
        payload =
            jsonDecode(_decrypt(master, source.source!, row))
                as Map<String, Object?>;
        if (payload['v'] != 2 || payload['text'] is! String) return null;
        priority = row['legacy'] == 2 ? 0 : 1;
      } else if (aad.first == 1 && aad.length == 7) {
        if ((cacheString(row, 'source_binding').isNotEmpty &&
                row['source_binding'] != binding) ||
            aad[1] != reference['room_id'] ||
            aad[2] != reference['event_id']) {
          return null;
        }
        sourceLanguage = aad[3]! as String;
        targetLanguage = aad[4]! as String;
        messageType = aad[6]! as String;
        payload = {'text': _decrypt(master, source.source!, row)};
      } else {
        return null;
      }
      final writtenAt = payload['written_at'] is String
          ? DateTime.tryParse(payload['written_at']! as String)?.toUtc()
          : null;
      final timestamp = (writtenAt?.microsecondsSinceEpoch ?? 0)
          .toString()
          .padLeft(20, '0');
      return _ConvertedTranslation(
        key: TranslationCacheKey(
          userId: owner,
          roomId: cacheString(reference, 'room_id'),
          eventId: cacheString(reference, 'event_id'),
          originalEventId:
              source.originalEventId ??
              (cacheString(reference, 'original_event_id').isEmpty
                  ? null
                  : cacheString(reference, 'original_event_id')),
          source: source.source!,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          messageType: messageType,
          model: payload['model'] is String
              ? payload['model']! as String
              : null,
        ),
        text: payload['text']! as String,
        writtenAt: writtenAt?.toIso8601String(),
        rank: '$priority:$timestamp:${cacheString(row, 'cache_key')}',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearStore(CacheStore store) async {
    while (true) {
      final removed = await backend.transaction((tx) async {
        final rows = await tx.query(store);
        for (final row in rows) {
          await tx.delete(store, cacheString(row, 'cache_key'));
        }
        return rows.length;
      }, write: true);
      if (removed == 0) return;
    }
  }

  Future<void> _clearUpgradeRanks() async {
    Object? cursor;
    while (true) {
      final rows = await backend.transaction((tx) async {
        final rows = await tx.query(CacheStore.metadata, after: cursor);
        for (final row in rows) {
          if (cacheString(row, 'cache_key').startsWith('["upgrade_rank",')) {
            await tx.delete(CacheStore.metadata, cacheString(row, 'cache_key'));
          }
        }
        return rows;
      }, write: true);
      if (rows.isEmpty) return;
      cursor = rows.last['_cursor'];
    }
  }

  Future<void> deleteIfExists() => _serialized(() async {
    _safetyEpoch++;
    await _loadPending(refresh: true);
    await backend.deleteIfExists();
    _formatChecked = false;
    _masterKey = null;
    await secrets.delete(_masterKeyName);
    _pending.clear();
    await _savePending();
  });

  Future<void> dispose() => _serialized(backend.dispose);

  Future<bool> _openExisting({bool checkFormat = true}) async {
    if (!await backend.exists()) return false;
    final master = await _loadExistingMasterKey();
    if (master == null) throw StateError('Translation cache key unavailable');
    if (!await backend.openExisting(_databaseKey(master))) return false;
    if (checkFormat && !_formatChecked) {
      if (await backend.needsUpgrade()) {
        throw StateError('Translation cache archive upgrade required');
      }
      _formatChecked = true;
    }
    return true;
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

  static String _scope(String kind, List<String> values) =>
      jsonEncode([kind, ...values]);

  static List<String> _scopes(TranslationCacheKey key) => [
    _scope('user', [key.userId]),
    _scope('room', [key.roomId]),
    _scope('user_room', [key.userId, key.roomId]),
    _scope('event', [key.roomId, key.eventId]),
    if (key.originalEventId != null && key.originalEventId != key.eventId)
      _scope('event', [key.roomId, key.originalEventId!]),
  ];

  int _epoch(TranslationCacheKey key) =>
      _scopes(key).fold(0, (value, scope) => value + (_epochs[scope] ?? 0));

  void _bumpEpoch(String scope) {
    _epochs[scope] = (_epochs[scope] ?? 0) + 1;
    backend.signalInvalidation();
  }

  static Future<String> _generation(
    TranslationCacheTransaction tx,
    TranslationCacheKey key,
  ) async {
    final revisions = <String>[];
    for (final scope in _scopes(key)) {
      revisions.add(
        cacheString(await tx.get(CacheStore.revisions, scope) ?? {}, 'value'),
      );
    }
    return revisions.every((value) => value.isEmpty)
        ? ''
        : jsonEncode(revisions);
  }

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

  static TranslationCacheKey _keyFromReference(
    CacheRow reference,
    TranslationLocalSource source,
  ) => TranslationCacheKey(
    userId: cacheString(reference, 'user_id'),
    roomId: cacheString(reference, 'room_id'),
    eventId: cacheString(reference, 'event_id'),
    originalEventId: source.originalEventId,
    source: source.source!,
    sourceLanguage: cacheString(reference, 'source_language'),
    targetLanguage: cacheString(reference, 'target_language'),
    messageType: cacheString(reference, 'message_type'),
  );

  static String _readContent(
    Uint8List master,
    TranslationCacheKey key,
    CacheRow row,
  ) {
    if (row['source_language'] != key.sourceLanguage ||
        row['target_language'] != key.targetLanguage ||
        row['message_type'] != key.messageType ||
        row['aad'] != key.aad(cacheString(row, 'source_binding'))) {
      throw const FormatException('Translation identity mismatch');
    }
    final payload =
        jsonDecode(_decrypt(master, key.source, row)) as Map<String, Object?>;
    if (payload['v'] != 3 || payload['text'] is! String) {
      throw const FormatException('Translation envelope is invalid');
    }
    return payload['text']! as String;
  }

  static CacheRow _encrypt(
    Uint8List master,
    TranslationCacheKey key,
    String text,
    String binding, {
    String? writtenAt,
  }) {
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
      'v': 3,
      'text': text,
      'model': ?key.model,
      'written_at': writtenAt ?? DateTime.now().toUtc().toIso8601String(),
    });
    return {
      'cache_key': _storageKey(master, key.identity(binding)),
      'source_binding': binding,
      'source_language': key.sourceLanguage,
      'target_language': key.targetLanguage,
      'message_type': key.messageType,
      'nonce': base64UrlEncode(nonce),
      'ciphertext': base64UrlEncode(
        cipher.process(Uint8List.fromList(utf8.encode(payload))),
      ),
      'aad': aad,
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

class _ConvertedTranslation {
  final TranslationCacheKey key;
  final String text;
  final String? writtenAt;
  final String rank;
  const _ConvertedTranslation({
    required this.key,
    required this.text,
    required this.writtenAt,
    required this.rank,
  });
}
