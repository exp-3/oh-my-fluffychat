// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'chat_search_event_store.dart';
import 'chat_search_models.dart';

/// A page-scoped search. Downloaded history stays in memory, outside the SDK's
/// default timeline, so a search cannot change normal timeline pagination.
class ChatSearchSession extends ChangeNotifier {
  static const _pageSize = 200;
  static const _publishInterval = 50;
  static const _maximumPageReferences = 25;

  final Room room;
  late final ChatSearchEventStore _store;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _pages = <String, _PageReference>{};
  final _liveEvents = <String, Event>{};
  final _pendingSessionKeys = <String>{};
  final _encryptedSessions = <String, String>{};
  final _queryWaiters = <int, Completer<void>>{};
  int _nextWaiter = 0;

  String _query = '';
  int _queryRevision = 0;
  bool _disposed = false;
  bool _invalidated = false;
  bool _foreground = true;
  bool _requestedRunning = false;
  bool _workerRunning = false;
  bool _liveWorkerRunning = false;
  bool _exhausted = false;
  bool _publishing = false;
  Object? _error;
  DateTime? _searchedUntil;
  List<String>? _localIds;
  int _localOffset = 0;
  String? _remoteCursor;
  final _visitedRemoteCursors = <String>{};
  _SearchBatch? _batch;
  Future<_RemotePage>? _historyFlight;

  ChatSearchSession(this.room) {
    _store = ChatSearchEventStore(
      room,
      onChanged: () {
        if (!_publishing) _notify();
      },
      loadMissingEvent: _loadMissingEvent,
    );
    _subscriptions.add(
      room.client.onTimelineEvent.stream.listen(_queueLiveEvent),
    );
    _subscriptions.add(
      room.client.onHistoryEvent.stream.listen(_queueLiveEvent),
    );
    _subscriptions.add(
      // Delayed decryption has no replacement stream in SDK 14.1.0 yet.
      // ignore: deprecated_member_use
      room.client.onEvent.stream.listen((update) {
        if (update.roomID != room.id ||
            update.type != EventUpdateType.decryptedTimelineQueue) {
          return;
        }
        _queueLiveEvent(Event.fromJson(update.content, room));
      }),
    );
    _subscriptions.add(
      room.onSessionKeyReceived.stream.listen((sessionId) {
        if (_disposed || _invalidated) return;
        _pendingSessionKeys.add(sessionId);
        _ensureWorker();
      }),
    );
    _subscriptions.add(
      room.client.onLoginStateChanged.stream.listen((state) {
        if (state == LoginState.loggedOut) {
          _invalidate(StateError('The account has logged out.'));
        }
      }),
    );
    _subscriptions.add(
      room.client.onSync.stream.listen((update) {
        if (update.rooms?.leave?.containsKey(room.id) == true) {
          _invalidate(StateError('The account has left this room.'));
        }
      }),
    );
  }

  String get query => _query;
  int get queryRevision => _queryRevision;
  List<ChatSearchResult> get results =>
      _invalidated ? const [] : _store.results;
  DateTime? get searchedUntil => _searchedUntil;
  int get undecryptableCount => _invalidated ? 0 : _store.undecryptableCount;
  Object? get error => _error;

  ChatSearchRunState get runState {
    if (_invalidated || _error != null) return ChatSearchRunState.failed;
    if (_query.isEmpty) return ChatSearchRunState.idle;
    if (_exhausted) return ChatSearchRunState.exhausted;
    if (!_requestedRunning || !_foreground) return ChatSearchRunState.paused;
    return ChatSearchRunState.running;
  }

  void submitQuery(String value) {
    if (_disposed || _invalidated) return;
    _supersede();
    _query = value.trim();
    _localIds = null;
    _localOffset = 0;
    _remoteCursor = null;
    _visitedRemoteCursors.clear();
    _batch = null;
    _searchedUntil = null;
    _error = null;
    _exhausted = false;
    _requestedRunning = _query.isNotEmpty;
    _store.setQuery(_query);
    _publish();
    _ensureWorker();
  }

  void pause() {
    if (_disposed || _invalidated || !_requestedRunning) return;
    _requestedRunning = false;
    // Commit only work already ingested before stopping. A later live update
    // must not be the first notification for a hidden partial scan batch.
    _publish();
  }

  void resume() {
    if (_disposed || _invalidated || _query.isEmpty || _exhausted) return;
    _error = null;
    _requestedRunning = true;
    _notify();
    _ensureWorker();
  }

  void setForeground(bool value) {
    if (_disposed || _invalidated || _foreground == value) return;
    _foreground = value;
    _publish();
    if (value) _ensureWorker();
  }

  bool get _canScan =>
      !_disposed &&
      !_invalidated &&
      _foreground &&
      _requestedRunning &&
      !_exhausted &&
      _error == null &&
      _query.isNotEmpty;

  bool get _hasWork =>
      !_disposed &&
      !_invalidated &&
      ((_foreground && _pendingSessionKeys.isNotEmpty) || _canScan);

  void _ensureWorker() {
    if (_workerRunning || !_hasWork) return;
    _workerRunning = true;
    unawaited(_drive());
  }

  Future<void> _drive() async {
    try {
      while (_hasWork) {
        final revision = _queryRevision;
        try {
          if (_foreground && _pendingSessionKeys.isNotEmpty) {
            final sessionId = _pendingSessionKeys.first;
            _pendingSessionKeys.remove(sessionId);
            await _retrySession(sessionId, revision);
            continue;
          }
          await _advance(revision);
        } on _SearchSuperseded {
          // The old SDK operation may still finish; it has no right to publish
          // into the new query. The same worker starts its local scan now.
        } on _SearchSuspended {
          // Waiting for the previous query's request finished while paused.
        } catch (error, stackTrace) {
          if (_disposed || _invalidated) return;
          if (revision != _queryRevision) continue;
          _error = error;
          _requestedRunning = false;
          Logs().w('Searching room history failed', error, stackTrace);
          _publish();
        }
      }
    } finally {
      _workerRunning = false;
      if (_hasWork) _ensureWorker();
    }
  }

  Future<void> _advance(int revision) async {
    if (_localIds == null) {
      // getEventIdList's start argument is ignored by SDK 14.1.0. Copy once,
      // then slice here so /sync insertions cannot move the scan's offsets.
      final ids = await _forQuery(
        room.client.database.getEventIdList(room, includeSending: true),
        revision,
      );
      _localIds = ids.toSet().toList(growable: false);
      if (!_canScan) return;
    }

    if (_batch == null) {
      final ids = _localIds!;
      if (_localOffset >= ids.length) {
        final from = _remoteCursor;
        final page = await _loadRemotePage(from, revision);
        _checkRevision(revision);
        final next = page.nextBatch;
        if (next != null &&
            (next == from || _visitedRemoteCursors.contains(next))) {
          throw StateError('The history server repeated a pagination cursor.');
        }
        _batch = _SearchBatch.remote(page, from);
      }
      if (_batch == null) {
        final requestedEnd = _localOffset + _pageSize;
        final end = requestedEnd < ids.length ? requestedEnd : ids.length;
        _batch = _SearchBatch.local(ids.sublist(_localOffset, end));
      }
    }
    if (!_canScan) return;

    final batch = _batch!;
    if (batch.isLocal && !batch.bulkLoaded) {
      if (batch.ids.any((id) => !_store.containsRaw(id))) {
        final events = await _forQuery(
          room.client.database.getEventList(
            room,
            start: _localOffset,
            limit: _pageSize,
          ),
          revision,
        );
        final wanted = batch.ids.toSet();
        for (final event in events) {
          if (wanted.contains(event.eventId)) {
            batch.events[event.eventId] = event;
          }
        }
      }
      batch.bulkLoaded = true;
      if (!_canScan) return;
    }

    while (batch.index < batch.ids.length && _canScan) {
      final id = batch.ids[batch.index];
      if (!batch.eventLoaded) {
        // Always merge a freshly downloaded event first: its unsigned data
        // may contain a redaction missing from an older plaintext cache.
        batch.currentEvent = batch.isLocal
            ? _store.cachedEvent(id) ?? batch.events[id]
            : batch.events[id] ?? _store.cachedEvent(id);
        if (batch.currentEvent == null && batch.isLocal) {
          // getEventList prepends SENDING only at offset zero, and sync may
          // have shifted its IDs. Only missing snapshot IDs need single reads.
          batch.currentEvent = await _forQuery(
            room.client.database.getEventById(id, room),
            revision,
          );
        }
        batch.eventLoaded = true;
        if (!_canScan) return;
      }
      final event = batch.currentEvent;
      if (event != null) {
        if (!batch.rawIngested) {
          await _forQuery(
            _store.ingest(event, expectedRevision: _store.queryRevision),
            revision,
          );
          batch.rawIngested = true;
          if (!_canScan) return;
        }
        if (batch.resolvedEvent == null) {
          final retained = _store.cachedEvent(id) ?? event;
          final resolved = await _forQuery(_decrypt(retained), revision);
          batch.resolvedEvent = resolved;
          batch.resolvedNeedsIngest =
              retained.type == EventTypes.Encrypted &&
              resolved.type != EventTypes.Encrypted;
          if (!_canScan) return;
        }
        final resolved = batch.resolvedEvent!;
        if (batch.resolvedNeedsIngest) {
          await _forQuery(
            _store.ingest(resolved, expectedRevision: _store.queryRevision),
            revision,
          );
          batch.resolvedNeedsIngest = false;
          if (!_canScan) return;
        }
        _trackEncryptedEvent(resolved);
        final timestamp = event.originServerTs;
        if (_searchedUntil == null || timestamp.isBefore(_searchedUntil!)) {
          _searchedUntil = timestamp;
        }
      }
      batch.finishEvent();
      if (batch.index % _publishInterval == 0) {
        _publish();
        // Let input, painting and lifecycle notifications run between chunks,
        // including when the SDK served every read from its memory cache.
        await _forQuery(Future<void>.delayed(Duration.zero), revision);
      }
    }
    if (!_canScan || batch.index != batch.ids.length) return;

    if (batch.isLocal) {
      _localOffset += batch.ids.length;
    }
    if (!batch.isLocal) {
      final next = batch.nextBatch;
      if (batch.from != null) _rememberPage(batch);
      _remoteCursor = next;
      if (next == null) {
        _exhausted = true;
        _requestedRunning = false;
      }
      if (next != null) _visitedRemoteCursors.add(next);
    }
    _batch = null;
    _publish();
  }

  Future<_RemotePage> _loadRemotePage(String? from, int revision) async {
    if (from != null) {
      final cached = _pages.remove(from);
      if (cached != null && cached.ids.every(_store.containsRaw)) {
        _pages[from] = cached;
        return _RemotePage(
          cached.ids.map((id) => _store.cachedEvent(id)!).toList(),
          cached.nextBatch,
        );
      }
    }

    // A superseded HTTP request cannot be physically cancelled through the
    // SDK. New local work proceeds, but a second history request must wait.
    final previous = _historyFlight;
    if (previous != null) {
      try {
        await _forQuery(previous, revision);
      } on _SearchSuperseded {
        rethrow;
      } catch (_) {
        // Failure belonged to the previous query, which is already obsolete.
      }
    }
    _checkRevision(revision);
    if (!_canScan) throw const _SearchSuspended();

    final request = _requestPage(from);
    _historyFlight = request;
    unawaited(
      request.then<void>(
        (_) {
          if (identical(_historyFlight, request)) _historyFlight = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_historyFlight, request)) _historyFlight = null;
        },
      ),
    );
    return _forQuery(request, revision);
  }

  Future<_RemotePage> _requestPage(String? from) async {
    final response = await room.client.getRoomEvents(
      room.id,
      Direction.b,
      from: from,
      limit: _pageSize,
      filter: jsonEncode(
        StateFilter(
          types: const [
            EventTypes.Message,
            EventTypes.Encrypted,
            EventTypes.Redaction,
          ],
        ).toJson(),
      ),
    );
    return _RemotePage(
      response.chunk
          .map((event) => Event.fromMatrixEvent(event, room))
          .toList(growable: false),
      response.end,
    );
  }

  void _rememberPage(_SearchBatch batch) {
    final from = batch.from!;
    _pages.remove(from);
    if (!batch.ids.every(_store.containsRaw)) return;
    _pages[from] = _PageReference(List.of(batch.ids), batch.nextBatch);
    while (_pages.length > _maximumPageReferences) {
      _pages.remove(_pages.keys.first);
    }
  }

  Future<Event> _decrypt(Event event) async {
    final encryption = room.client.encryption;
    if (event.redacted ||
        event.type != EventTypes.Encrypted ||
        encryption == null) {
      return event;
    }
    final decrypted = await encryption.decryptRoomEvent(
      event,
      store: false,
      updateType: EventUpdateType.history,
    );
    if (decrypted.type != EventTypes.Encrypted) return decrypted;
    final content = event.parsedRoomEncryptedContent;
    if (content.sessionId != null) {
      await encryption.keyManager.maybeAutoRequest(
        room,
        content.sessionId!,
        content.senderKey,
        tryOnlineBackup: true,
        onlineKeyBackupOnly: true,
        awaitRequest: true,
      );
      final retried = await encryption.decryptRoomEvent(
        event,
        store: false,
        updateType: EventUpdateType.history,
      );
      if (retried.type != EventTypes.Encrypted) return retried;
    }
    // Keep the original ciphertext instead of the SDK's failure placeholder.
    return event;
  }

  Future<Event?> _loadMissingEvent(String id) async {
    if (_disposed || _invalidated) return null;
    final event = await room.getEventById(id);
    if (_disposed || _invalidated || event == null) return null;
    final resolved = await _decrypt(event);
    return _disposed || _invalidated ? null : resolved;
  }

  void _queueLiveEvent(Event event) {
    if (_disposed ||
        _invalidated ||
        event.room.id != room.id ||
        !identical(event.room.client, room.client) ||
        (_query.isEmpty && _store.retainedRawCount == 0)) {
      return;
    }
    final previous = _liveEvents[event.eventId];
    if (previous != null &&
        ((previous.redacted && !event.redacted) ||
            (previous.type != EventTypes.Encrypted &&
                event.type == EventTypes.Encrypted &&
                !event.redacted))) {
      return;
    }
    _liveEvents[event.eventId] = event;
    _ensureLiveWorker();
  }

  void _ensureLiveWorker() {
    if (_disposed ||
        _invalidated ||
        _liveWorkerRunning ||
        _liveEvents.isEmpty) {
      return;
    }
    _liveWorkerRunning = true;
    unawaited(_drainLiveEvents());
  }

  Future<void> _drainLiveEvents() async {
    try {
      while (!_disposed && !_invalidated && _liveEvents.isNotEmpty) {
        final event = _liveEvents.remove(_liveEvents.keys.first)!;
        try {
          // This drain never requests a history page. It remains responsive
          // while the scan is paused or waiting for HTTP / an online key.
          await _store.ingest(event, live: true);
          if (_disposed || _invalidated) return;
          _trackEncryptedEvent(event);
          _publish();
        } catch (error, stackTrace) {
          Logs().w('Updating a search result failed', error, stackTrace);
        }
      }
    } finally {
      _liveWorkerRunning = false;
      _ensureLiveWorker();
    }
  }

  void _trackEncryptedEvent(Event event) {
    if (event.redacted || event.type != EventTypes.Encrypted) {
      _encryptedSessions.remove(event.eventId);
      return;
    }
    final sessionId = event.parsedRoomEncryptedContent.sessionId;
    if (sessionId != null) _encryptedSessions[event.eventId] = sessionId;
  }

  Future<void> _retrySession(String sessionId, int revision) async {
    final ids = _encryptedSessions.entries
        .where((entry) => entry.value == sessionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    var count = 0;
    for (final id in ids) {
      if (_disposed || _invalidated) return;
      if (!_foreground) {
        _pendingSessionKeys.add(sessionId);
        return;
      }
      _checkRevision(revision);
      // Eviction must not imply successful decryption. The store retains its
      // per-query failure metadata; retry again if a later scan reloads it.
      final event = _store.cachedEvent(id);
      if (event == null || event.type != EventTypes.Encrypted) continue;
      final resolved = await _forQuery(_decrypt(event), revision);
      if (_disposed || _invalidated) return;
      if (!_foreground) {
        _pendingSessionKeys.add(sessionId);
        return;
      }
      if (resolved.type != EventTypes.Encrypted) {
        await _forQuery(_store.ingest(resolved, live: true), revision);
        _trackEncryptedEvent(resolved);
      }
      if (++count % _publishInterval == 0) {
        _publish();
        await _forQuery(Future<void>.delayed(Duration.zero), revision);
      }
    }
    _publish();
  }

  Future<T> _forQuery<T>(Future<T> operation, int revision) async {
    _checkRevision(revision);
    final token = _nextWaiter++;
    final cancelled = Completer<void>();
    final completion = Completer<T>();
    _queryWaiters[token] = cancelled;
    unawaited(
      cancelled.future.then<void>((_) {
        if (!completion.isCompleted) {
          completion.completeError(const _SearchSuperseded());
        }
      }),
    );
    unawaited(
      operation.then<void>(
        (value) {
          _queryWaiters.remove(token);
          if (!completion.isCompleted) completion.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          _queryWaiters.remove(token);
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
        },
      ),
    );
    final value = await completion.future;
    _checkRevision(revision);
    return value;
  }

  void _checkRevision(int revision) {
    if (_disposed || _invalidated || revision != _queryRevision) {
      throw const _SearchSuperseded();
    }
  }

  void _supersede() {
    _queryRevision++;
    for (final waiter in _queryWaiters.values) {
      waiter.complete();
    }
    _queryWaiters.clear();
  }

  void _publish() {
    if (_disposed || _invalidated) return;
    _publishing = true;
    try {
      _store.flush();
    } finally {
      _publishing = false;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _invalidate(Object reason) {
    if (_disposed || _invalidated) return;
    _invalidated = true;
    _error = reason;
    _requestedRunning = false;
    _supersede();
    _clearMemory();
    _cancelSubscriptions();
    _store.dispose();
    _notify();
  }

  void _clearMemory() {
    _pages.clear();
    _liveEvents.clear();
    _encryptedSessions.clear();
    _pendingSessionKeys.clear();
    _localIds = null;
    _batch = null;
    _visitedRemoteCursors.clear();
    _searchedUntil = null;
  }

  void _cancelSubscriptions() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _supersede();
    _clearMemory();
    _cancelSubscriptions();
    if (!_invalidated) _store.dispose();
    super.dispose();
  }
}

class _RemotePage {
  final List<Event> events;
  final String? nextBatch;

  const _RemotePage(this.events, this.nextBatch);
}

class _PageReference {
  final List<String> ids;
  final String? nextBatch;

  const _PageReference(this.ids, this.nextBatch);
}

class _SearchBatch {
  final List<String> ids;
  final Map<String, Event> events;
  final bool isLocal;
  final String? from;
  final String? nextBatch;
  bool bulkLoaded = false;
  int index = 0;
  bool eventLoaded = false;
  bool rawIngested = false;
  bool resolvedNeedsIngest = false;
  Event? currentEvent;
  Event? resolvedEvent;

  _SearchBatch.local(this.ids)
    : events = {},
      isLocal = true,
      from = null,
      nextBatch = null;

  _SearchBatch.remote(_RemotePage page, this.from)
    : ids = page.events.map((event) => event.eventId).toList(growable: false),
      events = {for (final event in page.events) event.eventId: event},
      isLocal = false,
      nextBatch = page.nextBatch;

  void finishEvent() {
    index++;
    eventLoaded = false;
    rawIngested = false;
    resolvedNeedsIngest = false;
    currentEvent = null;
    resolvedEvent = null;
  }
}

class _SearchSuperseded implements Exception {
  const _SearchSuperseded();
}

class _SearchSuspended implements Exception {
  const _SearchSuspended();
}
