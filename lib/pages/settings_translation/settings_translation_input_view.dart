// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/widgets/layouts/settings_spacing.dart';
import 'package:fluffychat/widgets/settings_checkbox_list_tile.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_translation_details.dart';
import 'translation_settings_layout.dart';

class SettingsTranslationInputView extends StatelessWidget {
  final SettingsTranslationInputController controller;

  const SettingsTranslationInputView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final runtime = controller.runtime;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => TranslationSettingsScaffold(
        title: l10n.inputTranslation,
        onBack: controller.back,
        children: switch ((runtime.enabled, controller.loading)) {
          (false, _) => [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.translationDisabledGlobally),
            ),
          ],
          (true, true) => [
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: SettingsSpacing.inset,
              ),
              child: LinearProgressIndicator(),
            ),
          ],
          (true, false) => [
            SwitchListTile.adaptive(
              title: Text(l10n.inputTranslationModeManual),
              value: runtime.manualInputTranslationEnabled,
              onChanged: controller.changeManualEnabled,
            ),
            if (runtime.manualInputTranslationEnabled)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: SettingsSpacing.inset * 2,
                  top: SettingsSpacing.related,
                  end: SettingsSpacing.inset,
                ),
                child: DropdownButtonFormField<InputTranslationTrigger>(
                  key: ValueKey(runtime.inputTrigger),
                  initialValue: runtime.inputTrigger,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.inputTranslationTrigger,
                    prefixIcon: const Icon(Icons.touch_app_outlined),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: InputTranslationTrigger.button,
                      child: Text(l10n.inputTranslationTriggerButton),
                    ),
                    DropdownMenuItem(
                      value: InputTranslationTrigger.longPress,
                      child: Text(l10n.inputTranslationTriggerLongPress),
                    ),
                    DropdownMenuItem(
                      value: InputTranslationTrigger.doubleTap,
                      child: Text(l10n.inputTranslationTriggerDoubleTap),
                    ),
                  ],
                  onChanged: controller.changeTrigger,
                ),
              ),
            Divider(
              height: SettingsSpacing.section,
              color: theme.dividerColor,
            ),
            SwitchListTile.adaptive(
              title: Text(l10n.inputTranslationModeAutomatic),
              value: runtime.automaticInputTranslationEnabled,
              onChanged: controller.changeAutomaticEnabled,
            ),
            if (runtime.automaticInputTranslationEnabled)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: SettingsSpacing.inset * 2,
                  top: SettingsSpacing.related,
                  end: SettingsSpacing.inset,
                ),
                child: DropdownButtonFormField<InputTranslationSendMode>(
                  key: ValueKey(runtime.inputSendMode),
                  initialValue: runtime.inputSendMode,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.inputTranslationSendModeTitle,
                    prefixIcon: const Icon(Icons.touch_app_outlined),
                  ),
                  items: [
                    DropdownMenuItem(
                      value:
                          InputTranslationSendMode.shortOriginalLongTranslated,
                      child: Text(
                        l10n.inputTranslationSendModeLongTrans,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value:
                          InputTranslationSendMode.shortTranslatedLongOriginal,
                      child: Text(
                        l10n.inputTranslationSendModeShortTrans,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: controller.changeSendMode,
                ),
              ),
            if (runtime.inputMode != InputTranslationMode.disabled) ...[
              Divider(
                height: SettingsSpacing.section,
                color: theme.dividerColor,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SettingsSpacing.inset,
                ),
                child: DropdownButtonFormField<InputTranslationScope>(
                  key: ValueKey(runtime.inputScope),
                  initialValue: runtime.inputScope,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.inputTranslationScope,
                    prefixIcon: const Icon(Icons.meeting_room_outlined),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: InputTranslationScope.automaticRooms,
                      child: Text(l10n.inputTranslationScopeAutomaticRooms),
                    ),
                    DropdownMenuItem(
                      value: InputTranslationScope.allRooms,
                      child: Text(l10n.inputTranslationScopeAllRooms),
                    ),
                  ],
                  onChanged: controller.changeScope,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SettingsSpacing.inset,
                  SettingsSpacing.field,
                  SettingsSpacing.inset,
                  SettingsSpacing.related,
                ),
                child: TranslationSettingsLayout(
                  padding: EdgeInsets.zero,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: controller.sourceLanguage,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.inputSourceLanguage,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'auto',
                          child: Text(l10n.translationAutoDetect),
                        ),
                        for (final language in translationLanguages)
                          DropdownMenuItem(
                            value: language.code,
                            child: Text(
                              language.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: controller.changeSourceLanguage,
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: controller.targetLanguage,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.inputTargetLanguage,
                      ),
                      items: [
                        for (final language in translationLanguages)
                          DropdownMenuItem(
                            value: language.code,
                            child: Text(
                              language.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: controller.changeTargetLanguage,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SettingsSpacing.inset,
                ),
                child: SettingsCheckboxListTile(
                  title: Text(l10n.preferRoomLanguageForInputTarget),
                  value: runtime.preferRoomLanguageForInputTarget,
                  onChanged: controller.changePreferRoomLanguage,
                ),
              ),
            ],
          ],
        },
      ),
    );
  }
}
