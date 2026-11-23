// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:material_ui/material_ui.dart';

class ChatSearchStatus extends StatefulWidget {
  final String query;
  final ChatSearchRunState runState;
  final DateTime? searchedUntil;
  final int undecryptableCount;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final bool collapsed;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
  final ValueChanged<double>? onHeightChanged;

  const ChatSearchStatus({
    required this.query,
    required this.runState,
    required this.searchedUntil,
    required this.undecryptableCount,
    required this.onPause,
    required this.onResume,
    this.collapsed = false,
    this.onExpand,
    this.onCollapse,
    this.onHeightChanged,
    super.key,
  });

  @override
  State<ChatSearchStatus> createState() => _ChatSearchStatusState();
}

class _ChatSearchStatusState extends State<ChatSearchStatus> {
  final GlobalKey _expandedKey = GlobalKey();
  bool _measurementPending = false;
  double _dragDistance = 0;

  void _scheduleMeasurement() {
    if (_measurementPending || widget.onHeightChanged == null) return;
    _measurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementPending = false;
      if (!mounted) return;
      final box = _expandedKey.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        widget.onHeightChanged?.call(box.size.height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.isEmpty) return const SizedBox.shrink();
    _scheduleMeasurement();
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final runState = widget.runState;
    final isRunning = runState == ChatSearchRunState.running;
    final canResume = const {
      ChatSearchRunState.paused,
      ChatSearchRunState.failed,
    }.contains(runState);
    final label = switch (runState) {
      ChatSearchRunState.idle => l10n.messages,
      ChatSearchRunState.running => l10n.chatSearchSearching,
      ChatSearchRunState.paused => l10n.chatSearchPaused,
      ChatSearchRunState.exhausted => l10n.chatSearchComplete,
      ChatSearchRunState.failed => l10n.chatSearchFailed,
    };
    final actionIcon = isRunning
        ? Icons.stop_circle_outlined
        : runState == ChatSearchRunState.failed
        ? Icons.refresh_outlined
        : Icons.play_arrow_outlined;
    final actionLabel = isRunning
        ? l10n.chatSearchStop
        : runState == ChatSearchRunState.failed
        ? l10n.tryAgain
        : l10n.continueText;
    final searchedUntil = widget.searchedUntil;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    const shape = BorderRadius.vertical(top: Radius.circular(12));

    final summary = Row(
      textDirection: TextDirection.ltr,
      children: [
        if (isRunning) ...[
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: DefaultTextStyle.merge(
            style: theme.textTheme.bodySmall,
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(liveRegion: true, child: Text(label)),
                if (searchedUntil != null)
                  Text(
                    l10n.chatSearchedUntil(
                      searchedUntil.localizedTime(context),
                    ),
                  ),
                if (widget.undecryptableCount > 0)
                  Text(
                    l10n.chatSearchUndecryptableCount(
                      widget.undecryptableCount,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    final details = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!isRunning && !canResume) return summary;
          final action = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                iconSize: 18,
              ),
              onPressed: isRunning ? widget.onPause : widget.onResume,
              icon: Icon(actionIcon),
              label: Text(actionLabel),
            ),
          );
          final fontSize = theme.textTheme.bodySmall?.fontSize ?? 12;
          final textScale =
              MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
          // Give scaled details the full width before they become a tall,
          // narrow column beside the action.
          if (constraints.maxWidth < 280 * textScale) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                summary,
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            );
          }
          return Row(
            textDirection: TextDirection.ltr,
            children: [
              Expanded(child: summary),
              const SizedBox(width: 8),
              action,
            ],
          );
        },
      ),
    );
    final expanded = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        elevation: 4,
        borderRadius: shape,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: details,
        ),
      ),
    );
    final handle = Tooltip(
      message: l10n.showMore,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: l10n.showMore,
        value: label,
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 4,
          borderRadius: shape,
          child: InkWell(
            onTap: widget.onExpand,
            borderRadius: shape,
            child: SizedBox(
              width: 64,
              height: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    switch (runState) {
                      ChatSearchRunState.paused => Icons.pause_outlined,
                      ChatSearchRunState.failed => Icons.error_outline,
                      ChatSearchRunState.exhausted => Icons.check_outlined,
                      _ => Icons.search_outlined,
                    },
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const Icon(Icons.expand_less_outlined, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return GestureDetector(
      excludeFromSemantics: true,
      onVerticalDragStart: (_) => _dragDistance = 0,
      onVerticalDragUpdate: (details) {
        _dragDistance += details.primaryDelta ?? 0;
      },
      onVerticalDragEnd: (_) {
        if (widget.collapsed && _dragDistance <= -24) widget.onExpand?.call();
        if (!widget.collapsed && _dragDistance >= 24) widget.onCollapse?.call();
      },
      child: ClipRect(
        child: Stack(
          children: [
            // The hidden bar keeps its measured size, but only the handle
            // receives input; the rest of this area belongs to the list.
            IgnorePointer(
              ignoring: widget.collapsed,
              child: ExcludeFocus(
                excluding: widget.collapsed,
                child: ExcludeSemantics(
                  excluding: widget.collapsed,
                  child: AnimatedSlide(
                    offset: widget.collapsed ? const Offset(0, 1) : Offset.zero,
                    duration: reducedMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: TickerMode(
                      enabled: !widget.collapsed && !reducedMotion,
                      child:
                          NotificationListener<SizeChangedLayoutNotification>(
                            onNotification: (_) {
                              _scheduleMeasurement();
                              return true;
                            },
                            child: SizeChangedLayoutNotifier(
                              key: _expandedKey,
                              child: expanded,
                            ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.collapsed)
              Positioned(right: 0, bottom: 0, child: handle),
          ],
        ),
      ),
    );
  }
}
