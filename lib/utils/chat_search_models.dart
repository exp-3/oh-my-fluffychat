// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

enum ChatSearchRunState { idle, running, paused, exhausted, failed }

/// An edit changes the displayed content, never the result's identity or date.
class ChatSearchResult {
  final Event originalEvent;
  final Event displayEvent;

  const ChatSearchResult({
    required this.originalEvent,
    required this.displayEvent,
  });

  String get originalEventId => originalEvent.eventId;
  DateTime get originalTimestamp => originalEvent.originServerTs;
}
