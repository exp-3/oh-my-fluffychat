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
          padding: const EdgeInsets.all(16.0),
          child: Text(L10n.of(context).noMoreResultsFound),
        ),
      );
    }
    final theme = Theme.of(context);
    final searchedUntil = this.searchedUntil;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: .min,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(L10n.of(context).oopsSomethingWentWrong),
              ),
            if (searchedUntil != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  L10n.of(
                    context,
                  ).chatSearchedUntil(searchedUntil.localizedTime(context)),
                  style: TextStyle(fontSize: 10.5),
                ),
              ),
            TextButton.icon(
              style: TextButton.styleFrom(
                backgroundColor: theme.colorScheme.secondaryContainer,
                foregroundColor: theme.colorScheme.onSecondaryContainer,
              ),
              onPressed: isLoading ? null : onStartSearch,
              icon: isLoading
                  ? SizedBox.square(
                      dimension: 18,
                      child: const CircularProgressIndicator.adaptive(
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
          ],
        ),
      ),
    );
  }
}
