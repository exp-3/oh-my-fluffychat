// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:fluffychat/utils/chat_search_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  late _SearchDatabase database;
  late _SearchClient client;
  late Room room;
  late ChatSearchSession session;

  Event message(String id, String body, {int time = 0}) => Event(
    room: room,
    eventId: id,
    senderId: '@sender:test',
    type: EventTypes.Message,
    originServerTs: DateTime.utc(2026).add(Duration(milliseconds: time)),
    content: {'msgtype': MessageTypes.Text, 'body': body},
  );

  GetRoomEventsResponse page(List<Event> events, {String? next}) =>
      GetRoomEventsResponse.fromJson({
        'start': 'page-start',
        'end': ?next,
        'chunk': events.map((event) => event.toJson()).toList(),
      });

  setUp(() {
    database = _SearchDatabase();
    client = _SearchClient(database);
    room = Room(id: '!search:test', client: client);
    session = ChatSearchSession(room);
  });

  tearDown(() => session.dispose());

  test(
    'local matches publish before history and pause resumes the same batch',
    () async {
      database.events.addAll([
        for (var i = 0; i < 250; i++) message('local-$i', 'needle $i'),
      ]);
      final history = Completer<GetRoomEventsResponse>();
      client.onRequest = (_) => history.future;

      session.submitQuery('needle');
      await _until(session, () => session.results.isNotEmpty);
      session.pause();
      expect(session.runState, ChatSearchRunState.paused);
      expect(client.requests, isEmpty);
      expect(session.results.length, lessThan(250));

      session.resume();
      await client.requestStarted.future;
      expect(session.results.length, 250);
      history.complete(page([]));
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(
        session.results.map((result) => result.originalEventId).toSet().length,
        250,
      );
      expect(client.requests, [null]);
      expect(client.maximumConcurrentRequests, 1);
    },
  );

  test(
    'a new query scans locally while the obsolete HTTP request finishes',
    () async {
      database.events.addAll([
        message('old-local', 'old'),
        message('new-local', 'new'),
      ]);
      final obsolete = Completer<GetRoomEventsResponse>();
      final current = Completer<GetRoomEventsResponse>();
      client.onRequest = (_) =>
          client.requests.length == 1 ? obsolete.future : current.future;

      session.submitQuery('old');
      await client.requestStarted.future;
      session.submitQuery('new');
      await _until(
        session,
        () => session.results.any(
          (result) => result.originalEventId == 'new-local',
        ),
      );
      expect(client.requests, [null]);

      obsolete.complete(page([message('old-remote', 'old')], next: 'obsolete'));
      await _untilRequestCount(client, 2);
      current.complete(page([message('new-remote', 'new')]));
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(session.results.map((result) => result.originalEventId).toSet(), {
        'new-local',
        'new-remote',
      });
      expect(client.requests, [null, null]);
      expect(client.maximumConcurrentRequests, 1);
    },
  );

  test(
    'empty pages with advancing cursors continue to the actual end',
    () async {
      client.onRequest = (from) async => switch (from) {
        null => page([], next: 'a'),
        'a' => page([message('hit', 'needle')], next: 'b'),
        _ => page([]),
      };
      session.submitQuery('needle');
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(client.requests, [null, 'a', 'b']);
      expect(session.results.single.originalEventId, 'hit');
    },
  );

  test(
    'a repeated cursor fails without falsely completing or skipping on retry',
    () async {
      var retry = false;
      client.onRequest = (from) async {
        if (from == null) return page([message('first', 'needle')], next: 'a');
        return retry
            ? page([message('second', 'needle')])
            : page([], next: 'a');
      };
      session.submitQuery('needle');
      await _until(
        session,
        () => session.runState == ChatSearchRunState.failed,
      );
      expect(session.error, isA<StateError>());
      expect(session.results.single.originalEventId, 'first');
      retry = true;
      session.resume();
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(client.requests, [null, 'a', 'a']);
      expect(session.results.length, 2);
    },
  );

  test(
    'a shifted local bulk read fills missing snapshot IDs without scanning new IDs',
    () async {
      database.events.addAll([
        for (var i = 0; i < 201; i++) message('snapshot-$i', 'needle'),
      ]);
      database.onFirstBulkRead = () {
        database.events.insert(0, message('arrived-after-snapshot', 'needle'));
      };
      client.onRequest = (_) async => page([]);
      session.submitQuery('needle');
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(session.results.length, 201);
      expect(
        session.results.any(
          (result) => result.originalEventId == 'arrived-after-snapshot',
        ),
        isFalse,
      );
      expect(database.singleReads, ['snapshot-199']);
      expect(database.bulkReads, 2);
    },
  );

  test(
    'pause during a remote batch keeps the remaining events and cursor',
    () async {
      client.onRequest = (_) async =>
          page([for (var i = 0; i < 200; i++) message('remote-$i', 'needle')]);
      var stopped = false;
      session.addListener(() {
        if (!stopped && session.results.length == 50) {
          stopped = true;
          session.pause();
        }
      });
      session.submitQuery('needle');
      await _until(
        session,
        () => session.runState == ChatSearchRunState.paused,
      );
      expect(session.results.length, 50);
      session.resume();
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(session.results.length, 200);
      expect(client.requests, [null]);
    },
  );

  test('only exact non-null cursor pages are reused across keywords', () async {
    client.onRequest = (from) async => from == null
        ? page([message('alpha', 'alpha')], next: 'a')
        : page([message('beta', 'beta')]);
    session.submitQuery('alpha');
    await _until(
      session,
      () => session.runState == ChatSearchRunState.exhausted,
    );
    session.submitQuery('beta');
    await _until(
      session,
      () => session.runState == ChatSearchRunState.exhausted,
    );
    expect(client.requests, [null, 'a', null]);
    expect(session.results.single.originalEventId, 'beta');
  });

  test(
    'live redactions publish while paused with history pending',
    () async {
      database.events.add(message('root', 'needle'));
      final history = Completer<GetRoomEventsResponse>();
      client.onRequest = (_) => history.future;
      session.submitQuery('needle');
      await client.requestStarted.future;
      expect(session.results.single.originalEventId, 'root');
      session.pause();

      client.onTimelineEvent.add(
        Event(
          room: room,
          eventId: 'live-redaction',
          senderId: '@sender:test',
          type: EventTypes.Redaction,
          originServerTs: DateTime.utc(2026, 2),
          redacts: 'root',
          content: {},
        ),
      );
      await _until(session, () => session.results.isEmpty);
      expect(history.isCompleted, isFalse);
      expect(client.requests, [null]);
      expect(session.runState, ChatSearchRunState.paused);
      history.complete(page([]));
    },
  );

  test(
    'backgrounding preserves an in-flight page until foreground resumes',
    () async {
      final history = Completer<GetRoomEventsResponse>();
      client.onRequest = (_) => history.future;
      session.submitQuery('needle');
      await client.requestStarted.future;
      session.setForeground(false);
      history.complete(page([message('remote', 'needle')]));
      await Future<void>.delayed(Duration.zero);
      expect(session.runState, ChatSearchRunState.paused);
      expect(session.results, isEmpty);
      session.setForeground(true);
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(session.results.single.originalEventId, 'remote');
      expect(client.requests, [null]);
    },
  );

  test(
    'logout clears results and ignores the pending history response',
    () async {
      database.events.add(message('local', 'needle'));
      final history = Completer<GetRoomEventsResponse>();
      client.onRequest = (_) => history.future;
      session.submitQuery('needle');
      await client.requestStarted.future;
      expect(session.results.length, 1);
      client.onLoginStateChanged.add(LoginState.loggedOut);
      await _until(
        session,
        () => session.runState == ChatSearchRunState.failed,
      );
      expect(session.results, isEmpty);
      history.complete(page([message('late', 'needle')]));
      await Future<void>.delayed(Duration.zero);
      expect(session.results, isEmpty);
      expect(client.requests, [null]);
    },
  );

  test(
    'fresh server redactions override cached plaintext from an earlier query',
    () async {
      final original = message('root', 'needle');
      final redaction = Event(
        room: room,
        eventId: 'redaction',
        senderId: '@sender:test',
        type: EventTypes.Redaction,
        originServerTs: DateTime.utc(2026, 2),
        redacts: 'root',
        content: {},
      );
      final redacted = Event.fromJson({
        ...original.toJson(),
        'content': <String, dynamic>{},
        'unsigned': {'redacted_because': redaction.toJson()},
      }, room);
      client.onRequest = (_) async =>
          page([client.requests.length == 1 ? original : redacted]);
      session.submitQuery('needle');
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(session.results.length, 1);
      session.submitQuery('needle');
      await _until(
        session,
        () => session.runState == ChatSearchRunState.exhausted,
      );
      expect(session.results, isEmpty);
      expect(client.requests, [null, null]);
    },
  );
}

Future<void> _until(
  ChatSearchSession session,
  bool Function() condition,
) async {
  if (condition()) return;
  final completion = Completer<void>();
  void check() {
    if (condition() && !completion.isCompleted) completion.complete();
  }

  session.addListener(check);
  try {
    await completion.future.timeout(const Duration(seconds: 3));
  } finally {
    session.removeListener(check);
  }
}

Future<void> _untilRequestCount(_SearchClient client, int count) async {
  await (() async {
    while (client.requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  })().timeout(const Duration(seconds: 3));
}

class _SearchDatabase implements DatabaseApi {
  final events = <Event>[];
  final singleReads = <String>[];
  int bulkReads = 0;
  void Function()? onFirstBulkRead;

  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  }) async => events.map((event) => event.eventId).toList();

  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async {
    if (bulkReads++ == 0) onFirstBulkRead?.call();
    return events.skip(start).take(limit ?? events.length).toList();
  }

  @override
  Future<Event?> getEventById(String eventId, Room room) async {
    singleReads.add(eventId);
    for (final event in events) {
      if (event.eventId == eventId) return event;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchClient extends Client {
  final requests = <String?>[];
  final requestStarted = Completer<void>();
  late Future<GetRoomEventsResponse> Function(String?) onRequest;
  int _activeRequests = 0;
  int maximumConcurrentRequests = 0;

  _SearchClient(DatabaseApi database)
    : super('chat search session tests', database: database);

  @override
  String get userID => '@sender:test';

  @override
  Future<GetRoomEventsResponse> getRoomEvents(
    String roomId,
    Direction dir, {
    String? from,
    String? to,
    int? limit,
    String? filter,
  }) async {
    requests.add(from);
    _activeRequests++;
    if (_activeRequests > maximumConcurrentRequests) {
      maximumConcurrentRequests = _activeRequests;
    }
    if (!requestStarted.isCompleted) requestStarted.complete();
    try {
      return await onRequest(from);
    } finally {
      _activeRequests--;
    }
  }
}
