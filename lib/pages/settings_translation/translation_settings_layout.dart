// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:material_ui/material_ui.dart';

class TranslationSettingsLayout extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final double runSpacing;
  final double minimumColumnWidth;

  const TranslationSettingsLayout({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.runSpacing = 0,
    this.minimumColumnWidth = 188,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
