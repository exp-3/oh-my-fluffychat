// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/utils/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'translated_message.dart';

class FileCaption extends StatelessWidget {
  final Event event;
  final String description;
  final Color textColor;
  final Color? linkColor;
  final double fontSize;
  final Timeline? timeline;

  const FileCaption({
    super.key,
    required this.event,
    required this.description,
    required this.textColor,
    required this.linkColor,
    required this.fontSize,
    this.timeline,
  });

  @override
  Widget build(BuildContext context) {
    final original = Linkify(
      text: description,
      textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
      style: TextStyle(color: textColor, fontSize: fontSize),
      options: const LinkifyOptions(humanize: false),
      linkStyle: TextStyle(
        color: linkColor,
        fontSize: fontSize,
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      ),
      onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
    );
    final currentTimeline = timeline;
    if (currentTimeline == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: original,
      );
    }
    return TranslatedMessage(
      event: event,
      originalHtml: const HtmlEscape(
        HtmlEscapeMode.element,
      ).convert(description),
      originalChild: original,
      textColor: textColor,
      linkColor: linkColor ?? textColor,
      originalFontSize: fontSize,
      timeline: currentTimeline,
    );
  }
}
