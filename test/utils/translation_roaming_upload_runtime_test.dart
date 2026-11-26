// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'translation_test_backend.dart';

const _userId = '@reader:test';
const _roomId = '!translations:test';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a recent edit cannot make an expired original eligible for upload',
    () async {
      final fixture = await _RuntimeHarness.create();
      addTearDown(fixture.runtime.dispose);
      final now = DateTime.now().toUtc();
      final original = _message(
        fixture.clients.single.rooms.single,
        r'$original',
        now.subtract(const Duration(days: 45)),
      );
      final edit = _edit(original, now.subtract(const Duration(days: 1)));
      fixture.clients.single.localDatabase.events.addAll([original, edit]);
      await fixture.seed(
        edit,
        source: 'updated source',
        rootId: original.eventId,
      );

      final session = await fixture.runtime.createRoamingUploadSession();
      addTearDown(session.dispose);
      await session.scan();

      expect(session.phase, TranslationRoamingUploadPhase.ready);
      expect(session.rooms, isEmpty);
      expect(fixture.services.single.calls, isEmpty);
    },
  );

  test(
    'edited messages use the original send time for the initial TTL',
    () async {
      final fixture = await _RuntimeHarness.create();
      addTearDown(fixture.runtime.dispose);
      final now = DateTime.now().toUtc();
      final original = _message(
        fixture.clients.single.rooms.single,
        r'$original',
        now.subtract(const Duration(days: 20)),
      );
      final edit = _edit(original, now.subtract(const Duration(days: 2)));
      fixture.clients.single.localDatabase.events.addAll([original, edit]);
      await fixture.seed(
        edit,
        source: 'updated source',
        rootId: original.eventId,
      );

      final session = await fixture.runtime.createRoamingUploadSession();
      addTearDown(session.dispose);
      await session.scan();
      expect(session.rooms.single.count, 1);
      await session.upload({_roomId});

      expect(session.phase, TranslationRoamingUploadPhase.complete);
      final call = fixture.services.single.calls.single;
      expect(call.source, 'updated source');
      // Thirty idle days plus seven days, minus the original's twenty-day age.
      // Allow scheduling time without accepting the edit's much longer lifetime.
      expect(call.ttlSeconds, inInclusiveRange(16 * 86400, 17 * 86400));
    },
  );

  test(
    'a missing event in the first client falls back to another local copy',
    () async {
      final fixture = await _RuntimeHarness.create(clientCount: 2);
      addTearDown(fixture.runtime.dispose);
      final second = fixture.clients.last;
      final original = _message(
        second.rooms.single,
        r'$available-in-second-client',
        DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );
      second.localDatabase.events.add(original);
      await fixture.seed(original);

      final session = await fixture.runtime.createRoamingUploadSession();
      addTearDown(session.dispose);
      await session.scan();

      expect(session.phase, TranslationRoamingUploadPhase.ready);
      expect(session.rooms.single.roomId, _roomId);
      expect(session.rooms.single.count, 1);
      expect(
        fixture.clients.first.localDatabase.singleReads,
        contains(original.eventId),
      );
      expect(second.localDatabase.singleReads, contains(original.eventId));
      await session.upload({_roomId});
      expect(fixture.services.single.calls.single.source, 'original source');
    },
  );
}

Event _message(Room room, String id, DateTime sentAt) => Event(
  room: room,
  eventId: id,
  senderId: '@sender:test',
  type: EventTypes.Message,
  originServerTs: sentAt,
  content: {'msgtype': MessageTypes.Text, 'body': 'original source'},
);

Event _edit(Event original, DateTime sentAt) => Event(
  room: original.room,
  eventId: r'$edit',
  senderId: original.senderId,
  type: EventTypes.Message,
  originServerTs: sentAt,
  content: {
    'msgtype': MessageTypes.Text,
    'body': '* updated source',
    'm.relates_to': {
      'rel_type': RelationshipTypes.edit,
      'event_id': original.eventId,
    },
    'm.new_content': {'msgtype': MessageTypes.Text, 'body': 'updated source'},
  },
);

class _RuntimeHarness {
  final TranslationRuntime runtime;
  final TranslationCache cache;
  final List<_LocalClient> clients;
  final List<_RecordingRoaming> services;

  const _RuntimeHarness(this.runtime, this.cache, this.clients, this.services);

  static Future<_RuntimeHarness> create({int clientCount = 1}) async {
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.translation.enabled': true,
      'chat.fluffy.translation.privacy_accepted': true,
    });
    final store = await SharedPreferences.getInstance();
    final secrets = _MemorySecrets();
    final cache = TranslationCache(secrets, MemoryTranslationBackend());
    final runtime = TranslationRuntime.forTesting();
    final services = <_RecordingRoaming>[];
    await runtime.initialize(
      store,
      secrets: secrets,
      cache: cache,
      roamingFactory: (config, credentials) {
        final service = _RecordingRoaming(config, credentials);
        services.add(service);
        return service;
      },
    );
    await runtime.saveRoaming(
      const TranslationRoamingConfig(
        enabled: true,
        host: 'redis.example.invalid',
        retentionDays: 30,
      ),
      const TranslationRoamingSecrets(
        preSharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ),
    );
    final clients = [
      for (var i = 0; i < clientCount; i++) _LocalClient(_LocalDatabase()),
    ];
    for (final client in clients) {
      client.rooms = [Room(id: _roomId, client: client)];
    }
    runtime.attachClients(clients);
    return _RuntimeHarness(runtime, cache, clients, services);
  }

  Future<void> seed(Event event, {String? source, String? rootId}) =>
      cache.write(
        TranslationCacheKey(
          userId: _userId,
          roomId: event.room.id,
          eventId: event.eventId,
          originalEventId: rootId,
          source: source ?? event.body,
          sourceLanguage: 'auto',
          targetLanguage: 'en',
          messageType: MessageTypes.Text,
        ),
        'local translation',
      );
}

class _LocalClient extends Client {
  final _LocalDatabase localDatabase;

  _LocalClient(this.localDatabase)
    : super('roaming upload resolver tests', database: localDatabase);

  @override
  String get userID => _userId;

  @override
  bool isLogged() => true;
}

class _LocalDatabase implements DatabaseApi {
  final events = <Event>[];
  final singleReads = <String>[];

  @override
  Future<Event?> getEventById(String eventId, Room room) async {
    singleReads.add(eventId);
    for (final event in events) {
      if (event.eventId == eventId && event.room.id == room.id) return event;
    }
    return null;
  }

  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => events
      .where((event) => event.room.id == room.id)
      .skip(start)
      .take(limit ?? events.length)
      .toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingRoaming extends TranslationRoamingService {
  final calls = <({String source, int ttlSeconds})>[];

  _RecordingRoaming(
    TranslationRoamingConfig config,
    TranslationRoamingSecrets secrets,
  ) : super(config: config, secrets: secrets);

  @override
  Future<TranslationRoamingUploadResult> uploadIfAbsent({
    required String source,
    required String targetLanguage,
    required String translation,
    required int Function() ttlSeconds,
    required bool Function() isValid,
  }) async {
    if (!isValid()) {
      return const TranslationRoamingUploadResult(
        TranslationRoamingUploadStatus.skipped,
      );
    }
    calls.add((source: source, ttlSeconds: ttlSeconds()));
    return const TranslationRoamingUploadResult(
      TranslationRoamingUploadStatus.uploaded,
    );
  }
}

class _MemorySecrets implements TranslationSecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
