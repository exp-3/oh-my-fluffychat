// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/event_checkbox_extension.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'html_message.dart';

final _whitespacePattern = RegExp(r'\s+', unicode: true);

bool _sameTextIgnoringWhitespace(String first, String second) =>
    first.replaceAll(_whitespacePattern, '') ==
    second.replaceAll(_whitespacePattern, '');

class TranslatedMessage extends StatefulWidget {
  final Event event;
  final String originalHtml;
  final Color textColor;
  final Color linkColor;
  final double originalFontSize;
  final Timeline timeline;

  const TranslatedMessage({
    super.key,
    required this.event,
    required this.originalHtml,
    required this.textColor,
    required this.linkColor,
    required this.originalFontSize,
    required this.timeline,
  });

  @override
  State<TranslatedMessage> createState() => _TranslatedMessageState();
}

class _TranslatedMessageState extends State<TranslatedMessage> {
  final runtime = TranslationRuntime.instance;
  int? autoRequestedRevision;
  String? autoRequestedEventId;
  String? autoRequestedSource;
  String? autoRequestedMessageType;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _requestAutomaticTranslation();
  }

  @override
  void didUpdateWidget(covariant TranslatedMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentEventId = widget.event.eventId;
    final currentSource = runtime.sourceForEvent(widget.event);
    final currentMessageType = widget.event.messageType;
    // Matrix can mutate and reuse an Event instance. Reading
    // oldWidget.event here would then return the new content as well, so use
    // the event/source/type snapshot captured when the last request was
    // scheduled.
    if (oldWidget.event.eventId != currentEventId ||
        (autoRequestedEventId != null &&
            autoRequestedEventId != currentEventId) ||
        (autoRequestedSource != null && autoRequestedSource != currentSource) ||
        (autoRequestedMessageType != null &&
            autoRequestedMessageType != currentMessageType)) {
      autoRequestedRevision = null;
      autoRequestedEventId = null;
      autoRequestedSource = null;
      autoRequestedMessageType = null;
    }
    _requestAutomaticTranslation();
  }

  void _requestAutomaticTranslation() {
    final revision = runtime.revision;
    final eventId = widget.event.eventId;
    final source = runtime.sourceForEvent(widget.event);
    final messageType = widget.event.messageType;
    if ((autoRequestedRevision == revision &&
            autoRequestedEventId == eventId &&
            autoRequestedSource == source &&
            autoRequestedMessageType == messageType) ||
        !runtime.shouldAutoTranslate(widget.event)) {
      return;
    }
    final event = widget.event;
    autoRequestedRevision = revision;
    autoRequestedEventId = eventId;
    autoRequestedSource = source;
    autoRequestedMessageType = messageType;
    scheduleMicrotask(() async {
      if (!mounted ||
          runtime.revision != revision ||
          event.eventId != eventId ||
          widget.event.eventId != eventId ||
          runtime.sourceForEvent(widget.event) != source ||
          widget.event.messageType != messageType ||
          !runtime.shouldAutoTranslate(event)) {
        return;
      }
      try {
        await runtime.translateEvent(event, manual: false);
      } catch (_) {
        // The per-message state presents the failure and permits manual retry.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        if (!runtime.enabled || !runtime.canTranslateEvent(widget.event)) {
          return _OriginalTranslation(
            event: widget.event,
            originalHtml: widget.originalHtml,
            textColor: widget.textColor,
            linkColor: widget.linkColor,
            originalFontSize: widget.originalFontSize,
            timeline: widget.timeline,
          );
        }
        _requestAutomaticTranslation();
        return ValueListenableBuilder<TranslationResultState>(
          valueListenable: runtime.stateForEvent(widget.event),
          builder: (context, state, _) {
            if (state.status == TranslationStatus.translated &&
                _sameTextIgnoringWhitespace(
                  state.translation!,
                  runtime.sourceForEvent(widget.event),
                )) {
              return _OriginalTranslation(
                event: widget.event,
                originalHtml: widget.originalHtml,
                textColor: widget.textColor,
                linkColor: widget.linkColor,
                originalFontSize: widget.originalFontSize,
                timeline: widget.timeline,
              );
            }
            return switch (state.status) {
              TranslationStatus.translated => _TranslatedContent(
                event: widget.event,
                originalHtml: widget.originalHtml,
                textColor: widget.textColor,
                linkColor: widget.linkColor,
                originalFontSize: widget.originalFontSize,
                timeline: widget.timeline,
                translation: state.translation!,
                displayMode: runtime.displayMode,
                bilingualStyle: runtime.bilingualStyle,
              ),
              TranslationStatus.loading => Stack(
                children: [
                  _OriginalTranslation(
                    event: widget.event,
                    originalHtml: widget.originalHtml,
                    textColor: widget.textColor,
                    linkColor: widget.linkColor,
                    originalFontSize: widget.originalFontSize,
                    timeline: widget.timeline,
                  ),
                  const Positioned(
                    top: 4,
                    right: 4,
                    child: SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                ],
              ),
              TranslationStatus.failed => Stack(
                children: [
                  _OriginalTranslation(
                    event: widget.event,
                    originalHtml: widget.originalHtml,
                    textColor: widget.textColor,
                    linkColor: widget.linkColor,
                    originalFontSize: widget.originalFontSize,
                    timeline: widget.timeline,
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Tooltip(
                      message: L10n.of(context).translationFailed,
                      child: Icon(
                        Icons.translate_outlined,
                        size: 14,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
              TranslationStatus.idle => _OriginalTranslation(
                event: widget.event,
                originalHtml: widget.originalHtml,
                textColor: widget.textColor,
                linkColor: widget.linkColor,
                originalFontSize: widget.originalFontSize,
                timeline: widget.timeline,
              ),
            };
          },
        );
      },
    );
  }
}

class _TranslatedContent extends StatelessWidget {
  final Event event;
  final String originalHtml;
  final Color textColor;
  final Color linkColor;
  final double originalFontSize;
  final Timeline timeline;
  final String translation;
  final TranslationDisplayMode displayMode;
  final TranslationBilingualStyle bilingualStyle;

  const _TranslatedContent({
    required this.event,
    required this.originalHtml,
    required this.textColor,
    required this.linkColor,
    required this.originalFontSize,
    required this.timeline,
    required this.translation,
    required this.displayMode,
    required this.bilingualStyle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final translatedHtml = event.messageType == MessageTypes.Emote
        ? '* $translation'
        : translation;
    if (displayMode == TranslationDisplayMode.translatedOnly) {
      return _TranslationHtml(
        event: event,
        html: translatedHtml,
        textColor: textColor,
        linkColor: linkColor,
        fontSize: AppConfig.messageFontSize,
        timeline: timeline,
      );
    }
    final ownMessage = event.senderId == event.room.client.userID;
    final translationColor = switch (bilingualStyle) {
      TranslationBilingualStyle.body => textColor,
      TranslationBilingualStyle.accent =>
        ownMessage ? colorScheme.primaryFixed : colorScheme.primary,
      TranslationBilingualStyle.secondary =>
        ownMessage ? colorScheme.secondaryFixed : colorScheme.secondary,
      TranslationBilingualStyle.tertiary =>
        ownMessage ? colorScheme.tertiaryFixed : colorScheme.tertiary,
      TranslationBilingualStyle.muted => textColor.withAlpha(170),
      TranslationBilingualStyle.background => colorScheme.onTertiaryContainer,
    };
    final background = bilingualStyle == TranslationBilingualStyle.background;
    final translatedContent = _TranslationHtml(
      event: event,
      html: translatedHtml,
      textColor: translationColor,
      linkColor: background ? translationColor : linkColor,
      fontSize: AppConfig.messageFontSize,
      timeline: timeline,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _OriginalTranslation(
          event: event,
          originalHtml: originalHtml,
          textColor: textColor,
          linkColor: linkColor,
          originalFontSize: originalFontSize,
          timeline: timeline,
        ),
        Divider(height: 1, color: translationColor.withAlpha(64)),
        if (background)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: translatedContent,
            ),
          )
        else
          translatedContent,
      ],
    );
  }
}

class _OriginalTranslation extends StatelessWidget {
  final Event event;
  final String originalHtml;
  final Color textColor;
  final Color linkColor;
  final double originalFontSize;
  final Timeline timeline;

  const _OriginalTranslation({
    required this.event,
    required this.originalHtml,
    required this.textColor,
    required this.linkColor,
    required this.originalFontSize,
    required this.timeline,
  });

  @override
  Widget build(BuildContext context) => _TranslationHtml(
    event: event,
    html: originalHtml,
    textColor: textColor,
    linkColor: linkColor,
    fontSize: originalFontSize,
    timeline: timeline,
  );
}

class _TranslationHtml extends StatelessWidget {
  final Event event;
  final String html;
  final Color textColor;
  final Color linkColor;
  final double fontSize;
  final Timeline timeline;

  const _TranslationHtml({
    required this.event,
    required this.html,
    required this.textColor,
    required this.linkColor,
    required this.fontSize,
    required this.timeline,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: HtmlMessage(
      html: html,
      textColor: textColor,
      room: event.room,
      fontSize: fontSize,
      linkStyle: TextStyle(
        color: linkColor,
        fontSize: AppConfig.messageFontSize,
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      ),
      onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
      eventId: event.eventId,
      checkboxCheckedEvents: event.aggregatedEvents(
        timeline,
        EventCheckboxRoomExtension.relationshipType,
      ),
    ),
  );
}
