// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_search/chat_search_message_tab.dart';
import 'package:fluffychat/pages/chat_search/search_status.dart';
import 'package:fluffychat/utils/chat_search_event_store.dart';
import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

void main() {
  late Room room;

  setUp(() {
    room =
        Room(
          id: '!search:test',
          client: Client('search widget tests', database: _UnusedDatabase()),
        )..setState(
          StrippedStateEvent(
            type: EventTypes.RoomMember,
            stateKey: '@sender:test',
            senderId: '@sender:test',
            content: {'membership': 'join', 'displayname': 'Sender'},
          ),
        );
  });

  Future<void> showMessages(
    WidgetTester tester, {
    required List<ChatSearchResult> results,
    String query = 'needle',
    int revision = 1,
    ChatSearchRunState runState = ChatSearchRunState.paused,
    VoidCallback? onResume,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: ChatSearchMessageTab(
            room: room,
            searchQuery: query,
            queryRevision: revision,
            results: results,
            runState: runState,
            onResume: onResume ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('edited results display current text and jump to the original', (
    tester,
  ) async {
    final original = _message(
      room,
      r'$original',
      'obsolete text',
      DateTime.utc(2020, 1, 2),
    );
    final displayed = _message(
      room,
      r'$edit',
      'current needle',
      DateTime.utc(2025, 8, 9),
    );
    final result = ChatSearchResult(
      originalEvent: original,
      displayEvent: displayed,
    );
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/search',
          builder: (context, state) => Scaffold(
            body: ChatSearchMessageTab(
              room: room,
              searchQuery: 'needle',
              queryRevision: 1,
              results: [result],
              runState: ChatSearchRunState.paused,
              onResume: () {},
            ),
          ),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (context, state) => Scaffold(
            body: Text('jumped:${state.uri.queryParameters['event']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey(r'$original')), findsOneWidget);
    expect(find.byKey(const ValueKey(r'$edit')), findsNothing);
    expect(tester.widget<Linkify>(find.byType(Linkify)).text, 'current needle');
    final context = tester.element(find.byType(ListTile));
    expect(
      find.text(' | ${original.originServerTs.localizedTimeShort(context)}'),
      findsOneWidget,
    );
    expect(find.textContaining('obsolete text'), findsNothing);

    await tester.tap(find.byIcon(Icons.chevron_right_outlined));
    await tester.pumpAndSettle();
    expect(find.text(r'jumped:$original'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing away a matched word removes its rendered result', (
    tester,
  ) async {
    final original = _message(
      room,
      r'$original',
      'old needle',
      DateTime.utc(2026, 1, 1),
    );
    final edit = Event(
      room: room,
      eventId: r'$edit',
      senderId: original.senderId,
      originServerTs: DateTime.utc(2026, 1, 2),
      type: EventTypes.Message,
      content: {
        'msgtype': MessageTypes.Text,
        'body': '* replacement text',
        'm.new_content': {
          'msgtype': MessageTypes.Text,
          'body': 'replacement text',
        },
        'm.relates_to': {
          'rel_type': RelationshipTypes.edit,
          'event_id': original.eventId,
        },
      },
    );
    final store = ChatSearchEventStore(
      room,
      onChanged: () {},
      loadMissingEvent: (_) async => original,
    );
    addTearDown(store.dispose);
    store.setQuery('needle');
    await store.ingest(original);
    store.flush();
    await showMessages(tester, results: store.results);
    expect(tester.widget<Linkify>(find.byType(Linkify)).text, 'old needle');

    await store.ingest(edit, live: true);
    store.flush();
    await showMessages(tester, results: store.results);
    expect(find.byType(Linkify), findsNothing);
    expect(find.byKey(const ValueKey(r'$original')), findsNothing);

    store.setQuery('replacement');
    await store.ingest(original);
    await store.ingest(edit);
    store.flush();
    await showMessages(
      tester,
      results: store.results,
      query: 'replacement',
      revision: 2,
    );
    expect(find.byKey(const ValueKey(r'$original')), findsOneWidget);
    expect(
      tester.widget<Linkify>(find.byType(Linkify)).text,
      'replacement text',
    );
    expect(find.textContaining('* replacement'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('batch insertions anchor a root and a new query returns to top', (
    tester,
  ) async {
    final results = [
      for (var i = 0; i < 60; i++) _result(room, 'root-$i', time: 100 - i),
    ];
    await showMessages(tester, results: results);
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byType(ListView));
    final visible =
        tester.widgetList<AutoScrollTag>(find.byType(AutoScrollTag)).where((
          tag,
        ) {
          final rect = tester.getRect(find.byKey(tag.key!));
          return rect.bottom > viewport.top && rect.top < viewport.bottom;
        }).toList()..sort(
          (a, b) => tester
              .getTopLeft(find.byKey(a.key!))
              .dy
              .compareTo(tester.getTopLeft(find.byKey(b.key!)).dy),
        );
    expect(visible, isNotEmpty);
    final anchorKey = visible.first.key!;
    final anchorOffset = tester.getTopLeft(find.byKey(anchorKey)).dy;

    final expanded = [
      _result(room, 'new-0', time: 103),
      _result(room, 'new-1', time: 102),
      _result(room, 'new-2', time: 101),
      ...results,
      _result(room, 'older', time: 0),
    ];
    await showMessages(tester, results: expanded);
    await tester.pumpAndSettle();
    expect(find.byKey(anchorKey), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(anchorKey)).dy,
      closeTo(anchorOffset, 0.5),
    );

    await showMessages(tester, results: expanded, revision: 2);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller!.offset, 0);
    expect(find.byKey(const ValueKey('new-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pulling an empty list resumes without waiting for history', (
    tester,
  ) async {
    var resumes = 0;
    await showMessages(tester, results: const [], onResume: () => resumes++);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(resumes, 1);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.text('Message search paused'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed search status exposes stop, continue and failure retry', (
    tester,
  ) async {
    var pauses = 0;
    var resumes = 0;
    Future<void> showStatus(ChatSearchRunState runState) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: TickerMode(
              // Wait for localization without the running spinner ticking.
              enabled: false,
              child: ChatSearchStatus(
                query: 'needle',
                runState: runState,
                searchedUntil: DateTime.utc(2026, 1, 1),
                undecryptableCount: 3,
                onPause: () => pauses++,
                onResume: () => resumes++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await showStatus(ChatSearchRunState.running);
    expect(find.text('Searching messages…'), findsOneWidget);
    expect(find.text('3 messages could not be decrypted'), findsOneWidget);
    expect(find.textContaining('Chat searched until'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    expect(pauses, 1);

    await showStatus(ChatSearchRunState.paused);
    expect(find.text('Message search paused'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    expect(resumes, 1);

    await showStatus(ChatSearchRunState.failed);
    expect(find.text('Message search failed'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(resumes, 2);
    expect(tester.takeException(), isNull);
  });
}

Event _message(Room room, String id, String body, DateTime timestamp) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@sender:test',
  originServerTs: timestamp,
  content: {'msgtype': MessageTypes.Text, 'body': body},
);

ChatSearchResult _result(Room room, String id, {required int time}) {
  final event = _message(
    room,
    id,
    'needle $id',
    DateTime.utc(2026).add(Duration(minutes: time)),
  );
  return ChatSearchResult(originalEvent: event, displayEvent: event);
}

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Search widget tests must not access the SDK database');
}
