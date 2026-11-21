// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

class ChatSearchMessageTab extends StatefulWidget {
  final String searchQuery;
  final Room room;
  final List<ChatSearchResult> results;
  final VoidCallback onResume;
  final ChatSearchRunState runState;
  final int queryRevision;

  const ChatSearchMessageTab({
    required this.searchQuery,
    required this.room,
    required this.onResume,
    required this.results,
    required this.runState,
    required this.queryRevision,
    super.key,
  });

  @override
  State<ChatSearchMessageTab> createState() => _ChatSearchMessageTabState();
}

class _ChatSearchMessageTabState extends State<ChatSearchMessageTab>
    with AutomaticKeepAliveClientMixin<ChatSearchMessageTab> {
  final AutoScrollController _scrollController = AutoScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  _SearchScrollAnchor? _pendingAnchor;
  int _anchorRevision = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant ChatSearchMessageTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queryRevision != widget.queryRevision) {
      _pendingAnchor = null;
      final revision = ++_anchorRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _anchorRevision) return;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
      });
      return;
    }

    if (identical(oldWidget.results, widget.results)) return;
    final remaining = {
      for (final result in widget.results) result.originalEventId,
    };
    final pending = _pendingAnchor;
    final anchor = pending != null && remaining.contains(pending.eventId)
        ? pending
        : _captureAnchor(oldWidget.results, remaining);
    _pendingAnchor = anchor;
    final revision = ++_anchorRevision;
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreAnchor(anchor, revision));
    });
  }

  _SearchScrollAnchor? _captureAnchor(
    List<ChatSearchResult> previous,
    Set<String> remaining,
  ) {
    if (!_scrollController.hasClients) return null;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final candidates = <_SearchScrollAnchor>[];
    for (final entry in _scrollController.tagMap.entries) {
      if (entry.key >= previous.length || !entry.value.mounted) continue;
      final eventId = previous[entry.key].originalEventId;
      if (!remaining.contains(eventId)) continue;
      final box = entry.value.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final offset = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      candidates.add(
        _SearchScrollAnchor(
          eventId: eventId,
          offset: offset,
          isVisible:
              offset < viewport.size.height && offset + box.size.height > 0,
        ),
      );
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      if (a.isVisible != b.isVisible) return a.isVisible ? -1 : 1;
      return a.isVisible
          ? a.offset.compareTo(b.offset)
          : a.offset.abs().compareTo(b.offset.abs());
    });
    return candidates.first;
  }

  Future<void> _restoreAnchor(_SearchScrollAnchor anchor, int revision) async {
    if (!mounted || revision != _anchorRevision) return;
    if (!_scrollController.hasClients) return;
    final index = widget.results.indexWhere(
      (result) => result.originalEventId == anchor.eventId,
    );
    if (index < 0) return;

    // A large insertion can move the root outside the lazily built viewport.
    // Materialize it by its new index before restoring its exact pixel offset.
    if (_scrollController.tagMap[index] == null) {
      try {
        await _scrollController.scrollToIndex(
          index,
          duration: const Duration(milliseconds: 1),
          preferPosition: AutoScrollPosition.begin,
        );
      } catch (_) {
        // Navigation or a newer snapshot can detach a scroll during restoration.
        return;
      }
      if (!mounted || revision != _anchorRevision) return;
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || revision != _anchorRevision) return;
    if (!_scrollController.hasClients) return;
    final tag = _scrollController.tagMap[index];
    if (tag == null || !tag.mounted) return;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final box = tag.context.findRenderObject();
    if (viewport is! RenderBox || box is! RenderBox) return;
    if (!viewport.hasSize || !box.attached || !box.hasSize) return;
    final offset = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final position = _scrollController.position;
    final target = (position.pixels + offset - anchor.offset).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _pendingAnchor = null;
    if ((target - position.pixels).abs() > 0.5) {
      _scrollController.jumpTo(target);
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      // A user's new gesture takes priority over a queued pixel correction.
      _anchorRevision++;
      _pendingAnchor = null;
    }
    return false;
  }

  @override
  void dispose() {
    _anchorRevision++;
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final indices = <String, int>{
      for (var i = 0; i < widget.results.length; i++)
        widget.results[i].originalEventId: i,
    };

    return SizedBox.expand(
      key: _viewportKey,
      child: LayoutBuilder(
        builder: (context, constraints) => RefreshIndicator(
          // Resuming starts a continuous scan; the gesture must not wait for
          // the complete room history before its own animation can finish.
          onRefresh: () {
            widget.onResume();
            return Future<void>.value();
          },
          child: SelectionArea(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: ListView.custom(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                childrenDelegate: SliverChildBuilderDelegate(
                  (context, i) {
                    if (i == widget.results.length) {
                      if (widget.searchQuery.isEmpty) {
                        return SizedBox(
                          height: constraints.maxHeight,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.search_outlined, size: 64),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 32,
                                ),
                                child: Text(
                                  L10n.of(context).searchIn(
                                    widget.room.getLocalizedDisplayname(
                                      MatrixLocals(L10n.of(context)),
                                    ),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return _SearchProgressFooter(runState: widget.runState);
                    }
                    final result = widget.results[i];
                    return AutoScrollTag(
                      key: ValueKey(result.originalEventId),
                      controller: _scrollController,
                      index: i,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MessageSearchResultListTile(
                            result: result,
                            room: widget.room,
                          ),
                          Divider(color: theme.dividerColor, height: 1),
                        ],
                      ),
                    );
                  },
                  childCount: widget.results.length + 1,
                  findChildIndexCallback: (key) =>
                      key is ValueKey<String> ? indices[key.value] : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchScrollAnchor {
  final String eventId;
  final double offset;
  final bool isVisible;

  const _SearchScrollAnchor({
    required this.eventId,
    required this.offset,
    required this.isVisible,
  });
}

class _SearchProgressFooter extends StatelessWidget {
  final ChatSearchRunState runState;

  const _SearchProgressFooter({required this.runState});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: runState == ChatSearchRunState.running
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              )
            : Text(switch (runState) {
                ChatSearchRunState.exhausted => l10n.noMoreResultsFound,
                ChatSearchRunState.failed => l10n.chatSearchFailed,
                ChatSearchRunState.paused => l10n.chatSearchPaused,
                _ => '',
              }),
      ),
    );
  }
}

class _MessageSearchResultListTile extends StatelessWidget {
  const _MessageSearchResultListTile({
    required this.result,
    required this.room,
  });

  final ChatSearchResult result;
  final Room room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sender = result.originalEvent.senderFromMemoryOrFallback;
    final displayname = sender.calcDisplayname(
      i18n: MatrixLocals(L10n.of(context)),
    );

    return ListTile(
      title: Row(
        children: [
          Avatar(
            client: room.client,
            mxContent: sender.avatarUrl,
            name: displayname,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(displayname),
          Expanded(
            child: Text(
              ' | ${result.originalTimestamp.localizedTimeShort(context)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      subtitle: Linkify(
        textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
        options: const LinkifyOptions(humanize: false),
        style: TextStyle(color: theme.colorScheme.onSurface),
        linkStyle: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        ),
        onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
        text: result.displayEvent
            .calcLocalizedBody(
              plaintextBody: true,
              removeMarkdown: true,
              MatrixLocals(L10n.of(context)),
            )
            .trim(),
        maxLines: 7,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.chevron_right_outlined),
        onPressed: () => context.go(
          '/${Uri(pathSegments: ['rooms', room.id], queryParameters: {'event': result.originalEventId})}',
        ),
      ),
    );
  }
}
