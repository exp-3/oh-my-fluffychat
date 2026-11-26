// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

class SettingsCheckboxListTile extends StatelessWidget {
  final Widget title;
  final bool value;
  final ValueChanged<bool?>? onChanged;

  const SettingsCheckboxListTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => ListTileTheme.merge(
    horizontalTitleGap: 0,
    child: CheckboxListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      controlAffinity: ListTileControlAffinity.leading,
      title: DefaultTextStyle.merge(
        style: TextStyle(
          fontSize: Theme.of(context).textTheme.bodyLarge?.fontSize,
        ),
        child: title,
      ),
      value: value,
      onChanged: onChanged,
    ),
  );
}
