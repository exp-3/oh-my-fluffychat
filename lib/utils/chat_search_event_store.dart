// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:matrix/matrix.dart';

/// The 5000 event limit applies to rereadable scan data. Result content, small
/// root headers, edit candidates and redaction tombstones live for the session:
/// evicting them would allow an older page to resurrect obsolete messages.
class ChatSearchEventStore {
  static const _rawLimit = 5000;

  final Room room;
  final void Function() _onChanged;
  final Future<Event?> Function(String) _loadMissingEvent;
  final _raw = <String, _CachedEvent>{};
  final Map<String, _RootHeader> _headers = {};
  final Map<String, Event> _editBases = {};
  final Map<String, Map<String, _EditCandidate>> _edits = {};
  final Map<String, String> _editRoots = {};
  final Map<String, _TransactionIdentity> _transactions = {};
  final Map<String, String> _aliases = {};
  final Map<String, Future<Event?>> _loads = {};
  final Set<String> _redacted = {};
  final Set<String> _activeRoots = {};
  final Set<String> _dirtyRoots = {};
  final Set<String> _undecryptable = {};
  final Map<String, ChatSearchResult> _matches = {};
  List<ChatSearchResult> _results = const [];
  Future<void> _ingestQueue = Future<void>.value();
  String _query = '';
  int _revision = 0;
  bool _changed = false;
  bool _disposed = false;

  ChatSearchEventStore(
    this.room, {
    required void Function() onChanged,
    required Future<Event?> Function(String) loadMissingEvent,
  }) : _onChanged = onChanged,
       _loadMissingEvent = loadMissingEvent;

  List<ChatSearchResult> get results => _results;
  int get undecryptableCount => _undecryptable.length;
  int get retainedRawCount => _raw.length;
  int get queryRevision => _revision;

  bool containsRaw(String id) => _raw.containsKey(_resolve(id));

  Event? cachedEvent(String id) {
    final key = _resolve(id);
    final cached = _raw.remove(key);
    if (cached == null) return null;
    _raw[key] = cached;
    return cached.event;
  }

  void setQuery(String query) {
    if (_disposed) return;
    _revision++;
    _query = query.trim().toLowerCase();
    _activeRoots.clear();
    _dirtyRoots.clear();
    _undecryptable.clear();
    _matches.clear();
    _results = const [];
    _changed = true;
  }

  Future<void> ingest(Event event, {bool live = false, int? expectedRevision}) {
    final capturedRevision = expectedRevision ?? (live ? null : _revision);
    final previous = _ingestQueue;
    final current = previous.then(
      (_) => _ingestImpl(event, live: live, expectedRevision: capturedRevision),
    );
    // A failed event must not permanently block later live/history events.
    _ingestQueue = current.catchError((_) {});
    return current;
  }

  Future<void> _ingestImpl(
    Event event, {
    required bool live,
    int? expectedRevision,
  }) async {
    if (_disposed ||
        (expectedRevision != null && expectedRevision != _revision) ||
        event.room.id != room.id ||
        !identical(event.room.client, room.client) ||
        event.eventId.isEmpty) {
      return;
    }
    // SDK timelines may mutate Event instances in place on redaction or send
    // confirmation. Own the JSON maps so previous result snapshots stay stable.
    event = _snapshot(event);
    final revision = _revision;
    if (!_acceptTransaction(event)) return;
    final id = _resolve(event.eventId);

    if (event.type == EventTypes.Redaction) {
      _cache(id, event, live: live);
      final target = event.redacts ?? event.content.tryGet<String>('redacts');
      if (target == null || target.isEmpty) return;
      _markRedacted(_resolve(target));
      if (live &&
          !_editRoots.containsKey(_resolve(target)) &&
          !_headers.containsKey(_resolve(target))) {
        await _loadTarget(target, revision: revision, live: true);
      }
      return;
    }

    if (event.redacted) _markRedacted(id);

    final retained = _retainedEvent(id);
    // Decryption is an enrichment of the same immutable Matrix event. A late
    // encrypted representation must not erase an already known plaintext.
    final enriched =
        event.type == EventTypes.Encrypted &&
            retained != null &&
            retained.type != EventTypes.Encrypted
        ? retained
        : event;
    final selected = _cache(id, enriched, live: live);

    if (selected.type == EventTypes.Encrypted) {
      if (!_redacted.contains(id) && _undecryptable.add(id)) _changed = true;
      return;
    }
    if (_undecryptable.remove(id)) _changed = true;

    final rootId = selected.relationshipType == RelationshipTypes.edit
        ? selected.relationshipEventId
        : null;
    if (rootId != null && rootId.isNotEmpty) {
      final root = _resolve(rootId);
      _editRoots[id] = root;
      final replacement = selected.content.tryGetMap<String, Object?>(
        'm.new_content',
      );
      if (selected.type == EventTypes.Message &&
          replacement != null &&
          replacement.tryGet<String>('body') != null &&
          replacement.tryGet<String>('msgtype') != null &&
          !_redacted.contains(id)) {
        final candidates = _edits.putIfAbsent(root, () => {});
        final old = candidates[id];
        if (old == null || live || !old.live) {
          candidates[id] = _EditCandidate(selected, replacement, live: live);
        }
      }
      final original = _original(root);
      if (original != null && original.content.isNotEmpty) {
        _editBases.putIfAbsent(root, () => _snapshot(original));
      }
      if (live || _headers.containsKey(root)) {
        _activeRoots.add(root);
        _dirtyRoots.add(root);
        if (_editBases[root] == null) {
          await _loadTarget(root, revision: revision, live: live);
        }
      }
      return;
    }

    if (selected.type != EventTypes.Message &&
        selected.type != EventTypes.Sticker) {
      return;
    }
    // A redacted edit may have lost m.relates_to. Keep its known binding instead
    // of accidentally presenting it as an ordinary original message.
    final knownEditRoot = _editRoots[id];
    if (knownEditRoot != null) {
      _dirtyRoots.add(knownEditRoot);
      return;
    }
    final previousHeader = _headers[id];
    if (previousHeader == null ||
        selected.status.intValue >= previousHeader.status.intValue) {
      _headers[id] = _RootHeader(selected);
    }
    if (_edits.containsKey(id) && !_redacted.contains(id)) {
      _editBases.putIfAbsent(id, () => _snapshot(selected));
    }
    _activeRoots.add(id);
    _dirtyRoots.add(id);
  }

  void flush() {
    if (_disposed) return;
    var resultChanged = false;
    for (final root in _dirtyRoots) {
      final previous = _matches[root];
      final next = _materialize(root);
      if (next == null) {
        if (_matches.remove(root) != null) resultChanged = true;
        continue;
      }
      if (previous == null || !_sameResult(previous, next)) {
        _matches[root] = next;
        resultChanged = true;
      }
    }
    _dirtyRoots.clear();
    if (resultChanged || _changed) {
      final sorted = _matches.values.toList()
        ..sort((a, b) {
          final time = b.originalTimestamp.compareTo(a.originalTimestamp);
          return time != 0
              ? time
              : a.originalEventId.compareTo(b.originalEventId);
        });
      _results = List.unmodifiable(sorted);
    }
    if (_changed || resultChanged) {
      _changed = false;
      _onChanged();
    }
  }

  ChatSearchResult? _materialize(String root) {
    if (_query.isEmpty ||
        !_activeRoots.contains(root) ||
        !_headers.containsKey(root) ||
        _redacted.contains(root)) {
      return null;
    }
    final original = _original(root);
    if (original == null || original.redacted) return null;
    var display = original;
    _EditCandidate? latest;
    if (original.type == EventTypes.Message) {
      for (final edit in _edits[root]?.values ?? <_EditCandidate>[]) {
        if (_redacted.contains(_resolve(edit.event.eventId)) ||
            edit.event.senderId != original.senderId) {
          continue;
        }
        if (latest == null || edit.compareTo(latest) > 0) latest = edit;
      }
    }
    final lowerBody = latest?.lowerBody ?? _lowerBody(original);
    if (!lowerBody.contains(_query)) return null;
    if (latest != null) display = latest.event;
    return ChatSearchResult(originalEvent: original, displayEvent: display);
  }

  String _lowerBody(Event event) {
    final cached = _raw[_resolve(event.eventId)];
    if (cached != null && identical(cached.event, event)) {
      return cached.lowerBody ??= _body(event).toLowerCase();
    }
    return _body(event).toLowerCase();
  }

  static String _body(Event event) =>
      event.content.tryGet<String>('body') ?? '';

  static bool _sameResult(ChatSearchResult a, ChatSearchResult b) =>
      a.originalEventId == b.originalEventId &&
      a.originalTimestamp == b.originalTimestamp &&
      a.originalEvent.status == b.originalEvent.status &&
      a.displayEvent.eventId == b.displayEvent.eventId &&
      a.displayEvent.text == b.displayEvent.text &&
      a.displayEvent.formattedText == b.displayEvent.formattedText &&
      a.displayEvent.messageType == b.displayEvent.messageType;

  Event? _original(String id) =>
      _editBases[id] ??
      _raw[id]?.event ??
      _matches[id]?.originalEvent ??
      _headers[id]?.event(room);

  Event? _retainedEvent(String id) {
    final direct = _raw[id]?.event ?? _editBases[id];
    if (direct != null && direct.type != EventTypes.Encrypted) return direct;
    final match = _matches[id];
    if (match != null && match.originalEvent.content.isNotEmpty) {
      return match.originalEvent;
    }
    final root = _editRoots[id];
    return _edits[root]?[id]?.event ?? direct;
  }

  Event _cache(String id, Event event, {required bool live}) {
    final previous = _raw.remove(id);
    final keepPrevious =
        previous != null &&
        ((previous.live &&
                !live &&
                !event.redacted &&
                previous.event.type != EventTypes.Encrypted &&
                previous.event.status.intValue >= event.status.intValue) ||
            (previous.event.type != EventTypes.Encrypted &&
                event.type == EventTypes.Encrypted));
    _raw[id] = previous != null && keepPrevious
        ? previous
        : _CachedEvent(event, live: live);
    while (_raw.length > _rawLimit) {
      _raw.remove(_raw.keys.first);
    }
    return _raw[id]!.event;
  }

  void _markRedacted(String id) {
    if (_redacted.add(id)) _changed = true;
    if (_undecryptable.remove(id)) _changed = true;
    final root = _editRoots[id] ?? id;
    _dirtyRoots.add(root);
  }

  Future<void> _loadTarget(
    String id, {
    required int revision,
    required bool live,
  }) async {
    final target = _resolve(id);
    final future = _loads.putIfAbsent(target, () => _loadMissingEvent(target));
    try {
      final loaded = await future;
      if (_disposed ||
          (!live && revision != _revision) ||
          loaded == null ||
          _resolve(loaded.eventId) != target) {
        return;
      }
      // Avoid recursively resolving malformed edits that target other edits.
      await _ingestImpl(
        loaded,
        live: false,
        expectedRevision: live ? null : revision,
      );
      if (_disposed || (!live && revision != _revision)) return;
      final original = _original(target);
      if (original != null && original.content.isNotEmpty) {
        _editBases.putIfAbsent(target, () => _snapshot(original));
      }
      if (_headers.containsKey(target)) {
        _activeRoots.add(target);
        _dirtyRoots.add(target);
      }
    } catch (error, stack) {
      // Missing originals must not break scanning the remaining room history.
      Logs().w('Unable to resolve a search message update', error, stack);
    } finally {
      if (identical(_loads[target], future)) {
        _loads.remove(target);
      }
    }
  }

  bool _acceptTransaction(Event event) {
    if (_aliases.containsKey(event.eventId)) return false;
    final transaction = event.transactionId;
    if (transaction == null || event.senderId != room.client.userID) {
      return true;
    }
    final old = _transactions[transaction];
    if (old != null &&
        old.id == event.eventId &&
        event.status.intValue < old.status.intValue) {
      return false;
    }
    if (old != null && old.id != event.eventId) {
      if (old.status.isSynced || event.status.intValue < old.status.intValue) {
        return false;
      }
      _moveIdentity(old.id, event.eventId);
    }
    _transactions[transaction] = _TransactionIdentity(event);
    return true;
  }

  void _moveIdentity(String oldId, String newId) {
    oldId = _resolve(oldId);
    newId = _resolve(newId);
    if (oldId == newId) return;
    _aliases[oldId] = newId;
    _raw.remove(oldId);
    _headers.remove(oldId);
    _editBases.remove(oldId);
    if (_matches.remove(oldId) != null) _changed = true;
    if (_activeRoots.remove(oldId)) _activeRoots.add(newId);
    if (_redacted.remove(oldId)) _redacted.add(newId);
    if (_undecryptable.remove(oldId)) _undecryptable.add(newId);
    final edits = _edits.remove(oldId);
    if (edits != null) {
      _edits.putIfAbsent(newId, () => {}).addAll(edits);
      for (final id in edits.keys) {
        _editRoots[id] = newId;
      }
    }
    final editRoot = _editRoots.remove(oldId);
    if (editRoot != null) {
      _editRoots[newId] = editRoot;
      _edits[editRoot]?.remove(oldId);
      _dirtyRoots.add(editRoot);
    }
    _dirtyRoots.add(newId);
  }

  String _resolve(String id) {
    while (_aliases.containsKey(id)) {
      id = _aliases[id]!;
    }
    return id;
  }

  static Event _snapshot(Event event) {
    // Construct as synced to avoid the SDK constructor's sending timeout side
    // effects, then retain the actual presentation status of the original.
    return Event(
      content: _copyMap(event.content),
      type: event.type,
      eventId: event.eventId,
      senderId: event.senderId,
      originServerTs: event.originServerTs,
      stateKey: event.stateKey,
      unsigned: event.unsigned == null ? null : _copyMap(event.unsigned!),
      redacts: event.redacts,
      room: event.room,
    )..status = event.status;
  }

  static Map<String, dynamic> _copyMap(Map<String, dynamic> source) => {
    for (final entry in source.entries) entry.key: _copyValue(entry.value),
  };

  static Object? _copyValue(Object? value) {
    if (value is Map<String, dynamic>) return _copyMap(value);
    if (value is List<Object?>) return value.map(_copyValue).toList();
    return value;
  }

  void dispose() {
    _disposed = true;
    _revision++;
    _raw.clear();
    _headers.clear();
    _editBases.clear();
    _edits.clear();
    _editRoots.clear();
    _transactions.clear();
    _aliases.clear();
    _loads.clear();
    _redacted.clear();
    _activeRoots.clear();
    _dirtyRoots.clear();
    _undecryptable.clear();
    _matches.clear();
    _results = const [];
  }
}

class _CachedEvent {
  final Event event;
  final bool live;
  String? lowerBody;

  _CachedEvent(this.event, {required this.live});
}

class _RootHeader {
  final String id;
  final String sender;
  final String type;
  final DateTime timestamp;
  final EventStatus status;
  final String? transaction;

  _RootHeader(Event event)
    : id = event.eventId,
      sender = event.senderId,
      type = event.type,
      timestamp = event.originServerTs,
      status = event.status,
      transaction = event.transactionId;

  Event event(Room room) => Event(
    content: {},
    type: type,
    eventId: id,
    senderId: sender,
    originServerTs: timestamp,
    unsigned: transaction == null ? null : {'transaction_id': transaction},
    room: room,
  )..status = status;
}

class _EditCandidate {
  final Event event;
  final String lowerBody;
  final bool live;

  _EditCandidate(
    Event edit,
    Map<String, Object?> replacement, {
    required this.live,
  }) : event = Event(
         content: Map<String, dynamic>.from(replacement),
         type: edit.type,
         eventId: edit.eventId,
         senderId: edit.senderId,
         originServerTs: edit.originServerTs,
         room: edit.room,
       ),
       lowerBody = (replacement.tryGet<String>('body') ?? '').toLowerCase();

  int compareTo(_EditCandidate other) {
    final time = event.originServerTs.compareTo(other.event.originServerTs);
    return time != 0 ? time : event.eventId.compareTo(other.event.eventId);
  }
}

class _TransactionIdentity {
  final String id;
  final EventStatus status;

  _TransactionIdentity(Event event) : id = event.eventId, status = event.status;
}
