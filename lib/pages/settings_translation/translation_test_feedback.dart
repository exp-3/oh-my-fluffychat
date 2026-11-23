// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_diagnostics.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
showTranslationTestFeedback(
  BuildContext context, {
  required String message,
  Object? error,
  Iterable<String> secrets = const [],
}) {
  final l10n = L10n.of(context);
  final details = error == null
      ? null
      : translationErrorDetails(error, secrets: secrets);
  final messenger = ScaffoldMessenger.of(context);
  // Discard old notices so this controller always belongs to the current bar.
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: details == null
          ? null
          : SnackBarAction(
              label: l10n.more,
              onPressed: () {
                if (!context.mounted) return;
                unawaited(_showTestErrorDetails(context, message, details));
              },
            ),
    ),
  );
}

Future<void> _showTestErrorDetails(
  BuildContext context,
  String message,
  String details,
) {
  final l10n = L10n.of(context);
  String? copyMessage;
  return showAdaptiveDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog.adaptive(
        scrollable: true,
        title: Text(message),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(details),
              if (copyMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(copyMessage!),
                ),
            ],
          ),
        ),
        actions: [
          AdaptiveDialogAction(
            onPressed: () async {
              String result;
              try {
                await Clipboard.setData(ClipboardData(text: details));
                result = l10n.copiedToClipboard;
              } catch (_) {
                result = l10n.oopsSomethingWentWrong;
              }
              if (!context.mounted) return;
              setState(() => copyMessage = result);
            },
            child: Text(l10n.copy),
          ),
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.close),
          ),
        ],
      ),
    ),
  );
}
