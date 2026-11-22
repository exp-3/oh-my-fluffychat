// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:material_ui/material_ui.dart';

class MaxWidthBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final bool withScrolling;
  final EdgeInsets? innerPadding;
  final EdgeInsets contentPadding;

  const MaxWidthBody({
    required this.child,
    this.maxWidth = 600,
    this.withScrolling = true,
    this.innerPadding,
    this.contentPadding = const EdgeInsets.symmetric(vertical: 16),
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context);

          const desiredWidth = FluffyThemes.columnWidth * 1.5;
          final body = constraints.maxWidth <= desiredWidth
              ? child
              : Container(
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.all(32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: FluffyThemes.columnWidth * 1.5,
                    ),
                    child: Material(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius,
                        ),
                        side: BorderSide(color: theme.dividerColor),
                      ),
                      clipBehavior: Clip.hardEdge,
                      child: Padding(padding: contentPadding, child: child),
                    ),
                  ),
                );
          if (!withScrolling) return body;

          return SingleChildScrollView(
            padding: innerPadding,
            physics: const ScrollPhysics(),
            child: body,
          );
        },
      ),
    );
  }
}
