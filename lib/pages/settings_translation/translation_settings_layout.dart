// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/layouts/settings_spacing.dart';
import 'package:material_ui/material_ui.dart';

class TranslationSettingsLayout extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final double spacing;
  final double runSpacing;
  final double minimumColumnWidth;

  const TranslationSettingsLayout({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(
      horizontal: SettingsSpacing.inset,
    ),
    this.spacing = SettingsSpacing.field,
    this.runSpacing = SettingsSpacing.field,
    this.minimumColumnWidth = 188,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scaledColumnWidth = MediaQuery.textScalerOf(
          context,
        ).scale(minimumColumnWidth);
        final useTwoColumns =
            constraints.maxWidth >= scaledColumnWidth * 2 + spacing;
        final itemWidth = useTwoColumns
            ? (constraints.maxWidth - spacing) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    ),
  );
}

class TranslationSettingsScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final VoidCallback onBack;

  const TranslationSettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: BackButton(onPressed: onBack),
      title: Text(title),
    ),
    body: MaxWidthBody(
      contentPadding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SettingsSpacing.inset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}
