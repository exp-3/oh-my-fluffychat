// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:material_ui/material_ui.dart';

enum TranslationUnsavedChangesAction { save, discard }

/// A dismissed dialog leaves the settings page and its draft untouched.
Future<TranslationUnsavedChangesAction?> showTranslationUnsavedChangesDialog(
  BuildContext context,
) => showDialog<TranslationUnsavedChangesAction>(
  context: context,
  barrierDismissible: true,
  builder: (context) {
    final l10n = L10n.of(context);
    return AlertDialog.adaptive(
      title: Text(l10n.saveChanges),
      content: Text(l10n.translationUnsavedChanges),
      actions: [
        AdaptiveDialogAction(
          key: const Key('translation_unsaved_discard'),
          onPressed: () => Navigator.of(
            context,
          ).pop(TranslationUnsavedChangesAction.discard),
          child: Text(l10n.translationDiscardChanges),
        ),
        AdaptiveDialogAction(
          key: const Key('translation_unsaved_save'),
          autofocus: true,
          onPressed: () =>
              Navigator.of(context).pop(TranslationUnsavedChangesAction.save),
          child: Text(l10n.save),
        ),
      ],
    );
  },
);
