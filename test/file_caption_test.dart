// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/chat/events/file_caption.dart';
import 'package:fluffychat/pages/chat/events/html_message.dart';
import 'package:fluffychat/pages/chat/events/translated_message.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as parser;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

void main() {
  const description = '**literal** <caption> https://example.com\nsecond line';

  Event captionEvent({
    String messageType = MessageTypes.File,
    String type = EventTypes.Message,
  }) => Event(
    type: type,
    eventId: r'$caption',
    senderId: '@sender:test',
    originServerTs: DateTime.utc(2026),
    content: {
      'msgtype': messageType,
      'filename': 'example.txt',
      'body': description,
    },
    room: Room(
      id: '!room:test',
      client: Client('caption test', database: _UnusedDatabase()),
    ),
  );

  Future<void> showCaption(WidgetTester tester, {Timeline? timeline}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileCaption(
            event: captionEvent(),
            description: description,
            textColor: Colors.black,
            linkColor: Colors.blue,
            fontSize: 18,
            timeline: timeline,
          ),
        ),
      ),
    );
  }

  for (final messageType in const [
    MessageTypes.File,
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Audio,
    MessageTypes.Sticker,
  ]) {
    test('$messageType translations preserve literal markup and entities', () {
      const translation = '<b>literal</b> &amp; & <caption>\nsecond line';
      final event = captionEvent(
        messageType: messageType,
        type: messageType == MessageTypes.Sticker
            ? EventTypes.Sticker
            : EventTypes.Message,
      );
      final rendered = parser.parse(
        translationHtmlForEvent(event, translation),
      );

      expect(rendered.body!.text, translation);
      expect(rendered.getElementsByTagName('b'), isEmpty);
    });
  }

  test('ordinary message HTML and emote presentation are preserved', () {
    const translation = '<b>translated</b>';
    final textEvent = captionEvent(messageType: MessageTypes.Text);
    final emoteEvent = captionEvent(messageType: MessageTypes.Emote);

    expect(translationHtmlForEvent(textEvent, translation), translation);
    expect(translationHtmlForEvent(emoteEvent, translation), '* $translation');
  });

  testWidgets('caption previews preserve literal text and link styling', (
    tester,
  ) async {
    await showCaption(tester);

    final caption = tester.widget<Linkify>(find.byType(Linkify));
    expect(caption.text, description);
    expect(caption.style?.fontSize, 18);
    expect(caption.linkStyle?.color, Colors.blue);
    expect(find.byType(TranslatedMessage), findsNothing);
    expect(find.byType(HtmlMessage), findsNothing);
  });

  testWidgets('disabled translation keeps captions as literal linked text', (
    tester,
  ) async {
    await showCaption(tester, timeline: _UnusedTimeline());

    expect(find.byType(TranslatedMessage), findsOneWidget);
    final caption = tester.widget<Linkify>(find.byType(Linkify));
    expect(caption.text, description);
    expect(caption.style?.fontSize, 18);
    expect(
      tester
          .widgetList<Padding>(
            find.ancestor(
              of: find.byType(Linkify),
              matching: find.byType(Padding),
            ),
          )
          .where(
            (widget) =>
                widget.padding ==
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
      hasLength(1),
    );
    expect(find.byType(HtmlMessage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

// Original captions must not need timeline access while translation is off.
class _UnusedTimeline implements Timeline {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Caption tests must not access the SDK database');
}
