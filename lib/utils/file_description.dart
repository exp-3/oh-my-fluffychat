// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

extension FileDescriptionExtension on Event {
  String? get fileDescription {
    var captionEvent = this;
    final newContent = relationshipType == RelationshipTypes.edit
        ? content.tryGetMap<String, Object?>('m.new_content')
        : null;
    if (newContent != null) {
      captionEvent = Event(
        content: newContent,
        type: type,
        eventId: eventId,
        senderId: senderId,
        originServerTs: originServerTs,
        room: room,
      );
    }
    if (captionEvent.type != EventTypes.Sticker &&
        !const {
          MessageTypes.File,
          MessageTypes.Image,
          MessageTypes.Sticker,
          MessageTypes.Video,
          MessageTypes.Audio,
        }.contains(captionEvent.messageType)) {
      return null;
    }
    final filename = captionEvent.content.tryGet<String>('filename');
    // Captions use literal text; plaintextBody converts HTML to Markdown.
    final body = captionEvent.calcUnlocalizedBody(hideReply: true);

    if (filename != body &&
        filename != null &&
        captionEvent.content.tryGet<String>('body')?.isNotEmpty == true) {
      return body;
    }
    return null;
  }
}
