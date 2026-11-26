// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/layouts/settings_spacing.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_translation_details.dart';
import 'translation_settings_layout.dart';

class SettingsTranslationBatchView extends StatelessWidget {
  final SettingsTranslationBatchController controller;

  const SettingsTranslationBatchView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return AnimatedBuilder(
      animation: controller.runtime,
      builder: (context, _) => TranslationSettingsScaffold(
        title: l10n.batchTranslation,
        onBack: controller.back,
        children: switch ((controller.runtime.enabled, controller.loading)) {
          (false, _) => [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.translationDisabledGlobally),
            ),
          ],
          (true, true) => [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: SettingsSpacing.inset),
              child: LinearProgressIndicator(),
            ),
          ],
          (true, false) => [
            TranslationSettingsLayout(
              children: [
                _NumberSetting(
                  controller: controller.mergeWindow,
                  valid: controller.numberValid(
                    controller.mergeWindow,
                    0,
                    2000,
                  ),
                  label: l10n.translationMergeWait,
                  min: 0,
                  max: 2000,
                  suffix: 'ms',
                  onChanged: controller.settingsChanged,
                  onStep: (delta) => controller.changeNumber(
                    controller.mergeWindow,
                    delta,
                    min: 0,
                    max: 2000,
                  ),
                ),
                _NumberSetting(
                  controller: controller.maxMessages,
                  valid: controller.numberValid(controller.maxMessages, 1, 50),
                  label: l10n.translationMaxMessages,
                  min: 1,
                  max: 50,
                  onChanged: controller.settingsChanged,
                  onStep: (delta) => controller.changeNumber(
                    controller.maxMessages,
                    delta,
                    min: 1,
                    max: 50,
                  ),
                ),
                _NumberSetting(
                  controller: controller.maxCharacters,
                  valid: controller.numberValid(
                    controller.maxCharacters,
                    100,
                    20000,
                  ),
                  label: l10n.translationMaxCharacters,
                  min: 100,
                  max: 20000,
                  step: 100,
                  onChanged: controller.settingsChanged,
                  onStep: (delta) => controller.changeNumber(
                    controller.maxCharacters,
                    delta,
                    min: 100,
                    max: 20000,
                  ),
                ),
                _NumberSetting(
                  controller: controller.retries,
                  valid: controller.numberValid(controller.retries, 0, 3),
                  label: l10n.translationStructureRetries,
                  min: 0,
                  max: 3,
                  onChanged: controller.settingsChanged,
                  onStep: (delta) => controller.changeNumber(
                    controller.retries,
                    delta,
                    min: 0,
                    max: 3,
                  ),
                ),
              ],
            ),
          ],
        },
      ),
    );
  }
}

class _NumberSetting extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int min;
  final bool valid;
  final int max;
  final int step;
  final String? suffix;
  final VoidCallback onChanged;
  final ValueChanged<int> onStep;

  const _NumberSetting({
    required this.controller,
    required this.label,
    required this.min,
    required this.valid,
    required this.max,
    this.step = 1,
    this.suffix,
    required this.onChanged,
    required this.onStep,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: label,
      helperText: '$min-$max',
      suffixText: suffix,
      errorText: valid ? null : L10n.of(context).invalidInput,
      suffixIconConstraints: const BoxConstraints(minWidth: 96, minHeight: 48),
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            tooltip: L10n.of(context).decrease,
            onPressed: () => onStep(-step),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: L10n.of(context).increase,
            onPressed: () => onStep(step),
          ),
        ],
      ),
    ),
    onChanged: (_) => onChanged(),
  );
}
