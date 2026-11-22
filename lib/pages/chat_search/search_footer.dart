// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:material_ui/material_ui.dart';

class SearchFooter extends StatelessWidget {
  final DateTime? searchedUntil;
  final bool endReached, isLoading;
  final void Function() onStartSearch;
  final Object? error;

  const SearchFooter({
    super.key,
    required this.searchedUntil,
    required this.endReached,
    required this.isLoading,
    required this.onStartSearch,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    if (endReached && error == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(L10n.of(context).noMoreResultsFound),
        ),
      );
    }
    final theme = Theme.of(context);
    final searchedUntil = this.searchedUntil;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          textDirection: TextDirection.ltr,
          children: [
            Expanded(
              child: Wrap(
                spacing: 12,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (error != null)
                    Text(
                      L10n.of(context).oopsSomethingWentWrong,
                      style: theme.textTheme.bodySmall,
                    ),
                  if (searchedUntil != null)
                    Text(
                      L10n.of(
                        context,
                      ).chatSearchedUntil(searchedUntil.localizedTime(context)),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  iconSize: 18,
                ),
                onPressed: isLoading ? null : onStartSearch,
                icon: isLoading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(
                        error == null
                            ? Icons.arrow_downward_outlined
                            : Icons.refresh_outlined,
                      ),
                label: Text(
                  error == null
                      ? L10n.of(context).searchMore
                      : L10n.of(context).tryAgain,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
