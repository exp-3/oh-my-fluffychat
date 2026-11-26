// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import 'translation_settings_layout.dart';

/// Separates connection actions from the pre-shared-key controls.
class RoamingActions extends StatelessWidget {
  final List<Widget> keyActions;
  final Widget testAction;
  final Widget uploadAction;

  const RoamingActions({
    super.key,
    required this.keyActions,
    required this.testAction,
    required this.uploadAction,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(spacing: 8, runSpacing: 8, children: keyActions),
      Divider(height: 16, color: Theme.of(context).dividerColor),
      TranslationSettingsLayout(
        padding: EdgeInsets.zero,
        runSpacing: 8,
        children: [testAction, uploadAction],
      ),
    ],
  );
}
