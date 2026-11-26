// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/chat_search_event_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  late Room room;
  late ChatSearchEventStore store;
  late Map<String, Event> missingEvents;
  late List<String> requestedIds;
  late int notifications;

  Event message(
    String id,
    String body, {
    int time = 0,
    String sender = '@sender:test',
    String? transaction,
    EventStatus status = EventStatus.synced,
  }) => Event(
    room: room,
    eventId: id,
    senderId: sender,
    type: EventTypes.Message,
    originServerTs: DateTime.utc(2026).add(Duration(milliseconds: time)),
    status: status,
    unsigned: transaction == null ? null : {'transaction_id': transaction},
    content: {'msgtype': MessageTypes.Text, 'body': body},
  );

  Event edit(
    String id,
    String originalId,
    String body, {
    int time = 1,
    String sender = '@sender:test',
  }) => Event(
    room: room,
    eventId: id,
    senderId: sender,
    type: EventTypes.Message,
    originServerTs: DateTime.utc(2026).add(Duration(milliseconds: time)),
    content: {
      'msgtype': MessageTypes.Text,
      'body': '* $body',
      'm.new_content': {'msgtype': MessageTypes.Text, 'body': body},
      'm.relates_to': {
        'rel_type': RelationshipTypes.edit,
        'event_id': originalId,
      },
    },
  );

  Event redaction(String id, String target) => Event(
    room: room,
    eventId: id,
    senderId: '@sender:test',
    type: EventTypes.Redaction,
    originServerTs: DateTime.utc(2026, 2),
    redacts: target,
    content: {},
  );

  Event encrypted(String id) => Event(
    room: room,
    eventId: id,
    senderId: '@sender:test',
    type: EventTypes.Encrypted,
    originServerTs: DateTime.utc(2026),
    content: {
      'algorithm': 'm.megolm.v1.aes-sha2',
      'ciphertext': 'unavailable',
      'session_id': 'session',
      'sender_key': 'sender-key',
    },
  );

  Future<void> evictScanCache() async {
    for (var i = 0; i < 5001; i++) {
      await store.ingest(message('filler-$i', 'unrelated', time: i + 100));
    }
    store.flush();
  }

  setUp(() {
    room = Room(id: '!search:test', client: _SearchClient());
    missingEvents = {};
    requestedIds = [];
    notifications = 0;
    store = ChatSearchEventStore(
      room,
      onChanged: () => notifications++,
      loadMissingEvent: (id) async {
        requestedIds.add(id);
        return missingEvents[id];
      },
    );
  });

  tearDown(() => store.dispose());

  test('matches substrings and case without per-event notifications', () async {
    store.setQuery('世界');
    await store.ingest(message('root', '你好世界！'));
    await store.ingest(message('other', 'hello'));
    expect(notifications, 0);
    store.flush();
    expect(store.results.single.originalEventId, 'root');
    expect(notifications, 1);

    store.setQuery('HELLO');
    await store.ingest(message('other', 'Hello World'));
    store.flush();
    expect(store.results.single.originalEventId, 'other');
  });

  test(
    'edits change hits while retaining original identity and date',
    () async {
      final root = message('root', 'old body');
      store.setQuery('needle');
      await store.ingest(root);
      store.flush();
      expect(store.results, isEmpty);

      await store.ingest(edit('edit-1', 'root', 'a needle', time: 10));
      store.flush();
      expect(store.results.single.originalEventId, 'root');
      expect(store.results.single.originalTimestamp, root.originServerTs);
      expect(store.results.single.displayEvent.text, 'a needle');

      await store.ingest(edit('edit-2', 'root', 'no match', time: 20));
      store.flush();
      expect(store.results, isEmpty);
    },
  );

  test(
    'a redacted newest edit falls back through edits to the original',
    () async {
      store.setQuery('needle');
      await store.ingest(message('root', 'original needle'));
      await store.ingest(edit('edit-1', 'root', 'earlier needle', time: 10));
      await store.ingest(edit('edit-2', 'root', 'newest needle', time: 20));
      store.flush();
      expect(store.results.single.displayEvent.text, 'newest needle');

      await store.ingest(redaction('redact-2', 'edit-2'));
      store.flush();
      expect(store.results.single.displayEvent.text, 'earlier needle');
      await store.ingest(redaction('redact-1', 'edit-1'));
      store.flush();
      expect(store.results.single.displayEvent.text, 'original needle');

      await store.ingest(edit('edit-2', 'root', 'newest needle', time: 20));
      store.flush();
      expect(store.results.single.displayEvent.text, 'original needle');
    },
  );

  test(
    'a root redaction survives late pages and another keyword query',
    () async {
      final root = message('root', 'needle');
      store.setQuery('needle');
      await store.ingest(root);
      store.flush();
      await store.ingest(redaction('redact-root', 'root'), live: true);
      await store.ingest(root);
      await store.ingest(edit('late-edit', 'root', 'needle', time: 100));
      store.flush();
      expect(store.results, isEmpty);

      store.setQuery('need');
      await store.ingest(root);
      store.flush();
      expect(store.results, isEmpty);
    },
  );

  test(
    'an edit before its root waits without requesting every old original',
    () async {
      store.setQuery('needle');
      await store.ingest(edit('edit', 'root', 'needle'));
      store.flush();
      expect(store.results, isEmpty);
      expect(requestedIds, isEmpty);

      await store.ingest(message('root', 'original'));
      store.flush();
      expect(store.results.single.originalEventId, 'root');
      expect(store.results.single.displayEvent.text, 'needle');
    },
  );

  test('only edits by the original author affect matching', () async {
    store.setQuery('needle');
    await store.ingest(message('root', 'ordinary'));
    await store.ingest(edit('forged', 'root', 'needle', sender: '@other:test'));
    store.flush();
    expect(store.results, isEmpty);
  });

  test(
    'SDK mutations cannot silently change a published result snapshot',
    () async {
      final root = message('root', 'needle');
      store.setQuery('needle');
      await store.ingest(root);
      store.flush();
      root.content['body'] = 'changed';
      expect(store.results.single.displayEvent.text, 'needle');
      await store.ingest(root, live: true);
      store.flush();
      expect(store.results, isEmpty);
    },
  );

  test(
    'late ciphertext cannot replace a decrypted result or grow its count',
    () async {
      store.setQuery('needle');
      await store.ingest(encrypted('root'), live: true);
      store.flush();
      expect(store.undecryptableCount, 1);
      expect(store.results, isEmpty);

      await store.ingest(message('root', 'needle'));
      store.flush();
      expect(store.undecryptableCount, 0);
      expect(store.results.single.displayEvent.text, 'needle');
      expect(store.cachedEvent('root')!.type, EventTypes.Message);

      await store.ingest(encrypted('root'));
      store.flush();
      expect(store.undecryptableCount, 0);
      expect(store.results.single.displayEvent.text, 'needle');
    },
  );

  test(
    'result order follows original timestamps with an ID tie break',
    () async {
      store.setQuery('needle');
      await store.ingest(message('older', 'needle', time: 1));
      await store.ingest(message('b', 'needle', time: 2));
      await store.ingest(message('a', 'needle', time: 2));
      await store.ingest(
        edit('new-edit', 'older', 'needle edited', time: 1000),
      );
      store.flush();
      expect(store.results.map((result) => result.originalEventId), [
        'a',
        'b',
        'older',
      ]);
    },
  );

  test(
    'LRU eviction preserves matches and required edit rollback content',
    () async {
      store.setQuery('needle');
      final root = message('root', 'original needle');
      await store.ingest(root);
      await store.ingest(edit('edit', 'root', 'edited needle'));
      store.flush();
      await evictScanCache();
      expect(store.retainedRawCount, 5000);
      expect(store.containsRaw('root'), isFalse);
      expect(store.results.single.displayEvent.text, 'edited needle');

      await store.ingest(redaction('redact-edit', 'edit'), live: true);
      store.flush();
      expect(store.results.single.displayEvent.text, 'original needle');
    },
  );

  test(
    'live edit resolves an evicted nonmatching root and can roll back',
    () async {
      final root = message('root', 'original needle');
      missingEvents['root'] = root;
      store.setQuery('fresh');
      await store.ingest(root);
      await evictScanCache();
      expect(store.containsRaw('root'), isFalse);

      await store.ingest(edit('edit', 'root', 'fresh needle'), live: true);
      store.flush();
      expect(requestedIds, ['root']);
      expect(store.results.single.displayEvent.text, 'fresh needle');

      await store.ingest(redaction('redact-edit', 'edit'), live: true);
      store.flush();
      expect(store.results, isEmpty);
      store.setQuery('needle');
      await store.ingest(root);
      store.flush();
      expect(store.results.single.displayEvent.text, 'original needle');
    },
  );

  test(
    'send confirmation migrates identity and rejects late local echoes',
    () async {
      final pending = message(
        'local',
        'needle',
        transaction: 'transaction',
        status: EventStatus.sent,
      );
      store.setQuery('needle');
      await store.ingest(pending, live: true);
      store.flush();
      await store.ingest(
        message('server', 'needle', transaction: 'transaction'),
      );
      store.flush();
      expect(store.results.single.originalEventId, 'server');
      await store.ingest(
        message(
          'server',
          'needle',
          transaction: 'transaction',
          status: EventStatus.sent,
        ),
      );
      await store.ingest(pending);
      store.flush();
      expect(store.results.single.originalEventId, 'server');

      store.setQuery('needle');
      await store.ingest(
        message(
          'local-2',
          'needle',
          transaction: 'transaction-2',
          status: EventStatus.sent,
        ),
      );
      store.flush();
      await store.ingest(
        message('server-2', 'different', transaction: 'transaction-2'),
      );
      store.flush();
      expect(store.results, isEmpty);
    },
  );
}

class _SearchClient extends Client {
  _SearchClient() : super('search store tests', database: _SearchDatabase());

  @override
  String get userID => '@sender:test';
}

class _SearchDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The event store must not access the SDK database');
}
