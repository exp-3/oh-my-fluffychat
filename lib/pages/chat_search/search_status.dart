// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:material_ui/material_ui.dart';

/// Kept above the tabs so the message scan can also be stopped from the gallery.
class ChatSearchStatus extends StatelessWidget {
  final String query;
  final ChatSearchRunState runState;
  final DateTime? searchedUntil;
  final int undecryptableCount;
  final VoidCallback onPause;
  final VoidCallback onResume;

  const ChatSearchStatus({
    required this.query,
    required this.runState,
    required this.searchedUntil,
    required this.undecryptableCount,
    required this.onPause,
    required this.onResume,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) return const SizedBox.shrink();
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
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
    final searchedUntil = this.searchedUntil;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          if (isRunning) ...[
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(liveRegion: true, child: Text(label)),
                if (searchedUntil != null)
                  Text(
                    l10n.chatSearchedUntil(
                      searchedUntil.localizedTime(context),
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                if (undecryptableCount > 0)
                  Text(
                    l10n.chatSearchUndecryptableCount(undecryptableCount),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (isRunning || canResume)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: isRunning
                    ? TextButton.icon(
                        onPressed: onPause,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(l10n.chatSearchStop),
                      )
                    : TextButton.icon(
                        onPressed: onResume,
                        icon: Icon(
                          runState == ChatSearchRunState.failed
                              ? Icons.refresh_outlined
                              : Icons.play_arrow_outlined,
                        ),
                        label: Text(
                          runState == ChatSearchRunState.failed
                              ? l10n.tryAgain
                              : l10n.continueText,
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
