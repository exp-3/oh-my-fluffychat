// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_roaming_models.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_translation.dart';
import 'translation_settings_layout.dart';

class SettingsTranslationView extends StatelessWidget {
  final SettingsTranslationController controller;

  const SettingsTranslationView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final runtime = controller.runtime;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        final enabled = runtime.enabled;
        final inputSource = controller.languageLabel(
          runtime.inputSourceLanguage,
          l10n,
        );
        final inputTarget = controller.languageLabel(
          runtime.inputTargetLanguage,
          l10n,
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.translation),
            automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
            centerTitle: FluffyThemes.isColumnMode(context),
          ),
          body: MaxWidthBody(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.translate_outlined),
                  title: Text(l10n.enableTranslation),
                  subtitle: Text(l10n.translationPrivacyNotice),
                  value: enabled,
                  onChanged: controller.toggleEnabled,
                ),
                _SectionTitle(l10n.translationProviders),
                for (final provider in runtime.providers)
                  ListTile(
                    onTap: () => controller.selectProvider(provider.id),
                    leading: Icon(
                      runtime.activeProvider?.id == provider.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(provider.name),
                    subtitle: Text(provider.model),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l10n.edit,
                      onPressed: () => controller.openProvider(provider.id),
                    ),
                  ),
                if (runtime.providers.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.noTranslationProviders),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(l10n.addTranslationProvider),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: controller.openProvider,
                ),
                if (enabled) ...[
                  Divider(color: theme.dividerColor),
                  Column(
                    children: [
                      _SectionTitle(l10n.automaticTranslation),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: DropdownButtonFormField<TranslationScope>(
                          initialValue: runtime.scope,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.automaticTranslationScope,
                            prefixIcon: const Icon(Icons.auto_awesome_outlined),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: TranslationScope.none,
                              child: Text(
                                l10n.translationScopeNone,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            DropdownMenuItem(
                              value: TranslationScope.allRooms,
                              child: Text(
                                l10n.translationScopeAllRooms,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            DropdownMenuItem(
                              value: TranslationScope.unencryptedRooms,
                              child: Text(
                                l10n.translationScopeUnencryptedRooms,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          onChanged: controller.changeScope,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            l10n.translationScopeOverrideHint,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TranslationSettingsLayout(
                          padding: EdgeInsets.zero,
                          runSpacing: 12,
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: controller.sourceLanguage,
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: l10n.sourceLanguage,
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
                                labelText: l10n.targetLanguage,
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: systemTranslationLanguageCode,
                                  child: Text(l10n.systemTheme),
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
                              onChanged: controller.changeTargetLanguage,
                            ),
                          ],
                        ),
                      ),
                      CheckboxListTile.adaptive(
                        title: Text(l10n.preferRoomLanguageForSource),
                        value: runtime.preferRoomLanguageForSource,
                        onChanged: controller.changePreferRoomLanguage,
                      ),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.view_agenda_outlined),
                        title: Text(l10n.bilingual),
                        value:
                            runtime.displayMode ==
                            TranslationDisplayMode.bilingual,
                        onChanged: controller.changeBilingual,
                      ),
                      if (runtime.displayMode ==
                          TranslationDisplayMode.bilingual)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 32,
                            right: 16,
                            bottom: 12,
                          ),
                          child: TranslationSettingsLayout(
                            padding: EdgeInsets.zero,
                            runSpacing: 12,
                            minimumColumnWidth: 180,
                            children: [
                              DropdownButtonFormField<
                                TranslationBilingualColor
                              >(
                                initialValue: runtime.bilingualColor,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: l10n.translationBilingualColor,
                                  prefixIcon: const Icon(
                                    Icons.palette_outlined,
                                  ),
                                ),
                                items: [
                                  DropdownMenuItem(
                                    value: TranslationBilingualColor.body,
                                    child: _ColorOption(
                                      color: theme.colorScheme.onSurface,
                                      label: l10n.translationStyleBody,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualColor.accent,
                                    child: _ColorOption(
                                      color: theme.colorScheme.primary,
                                      label: l10n.translationStyleAccent,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualColor.secondary,
                                    child: _ColorOption(
                                      color: theme.colorScheme.secondary,
                                      label: l10n.translationStyleSecondary,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualColor.tertiary,
                                    child: _ColorOption(
                                      color: theme.colorScheme.tertiary,
                                      label: l10n.translationStyleTertiary,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualColor.muted,
                                    child: _ColorOption(
                                      color: theme.colorScheme.onSurface
                                          .withAlpha(170),
                                      label: l10n.translationStyleMuted,
                                    ),
                                  ),
                                ],
                                onChanged: controller.changeBilingualColor,
                              ),
                              DropdownButtonFormField<
                                TranslationBilingualStyle
                              >(
                                initialValue: runtime.bilingualStyle,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: l10n.translationBilingualStyle,
                                  prefixIcon: const Icon(
                                    Icons.view_stream_outlined,
                                  ),
                                ),
                                items: [
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.plain,
                                    child: Text(l10n.translationStylePlain),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.divider,
                                    child: Text(l10n.translationStyleDivider),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.glow,
                                    child: Text(l10n.translationStyleGlow),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.background,
                                    child: Text(
                                      l10n.translationStyleBackground,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.duotone,
                                    child: Text(l10n.translationStyleDuotone),
                                  ),
                                  DropdownMenuItem(
                                    value:
                                        TranslationBilingualStyle.outsideBubble,
                                    child: Text(
                                      l10n.translationStyleOutsideBubble,
                                    ),
                                  ),
                                ],
                                onChanged: controller.changeBilingualStyle,
                              ),
                            ],
                          ),
                        ),
                      Divider(color: theme.dividerColor),
                      ListTile(
                        leading: const Icon(Icons.edit_note_outlined),
                        title: Text(l10n.inputTranslation),
                        subtitle: Text(
                          !runtime.manualInputTranslationEnabled &&
                                  !runtime.automaticInputTranslationEnabled
                              ? l10n.roomTranslationAlwaysOff
                              : '$inputSource → $inputTarget',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_outlined),
                        onTap: controller.openInput,
                      ),
                      ListTile(
                        leading: const Icon(Icons.layers_outlined),
                        title: Text(l10n.batchTranslation),
                        subtitle: Text(
                          '${l10n.translationMaxMessages}: '
                          '${runtime.batchSettings.maxMessages}\n'
                          '${l10n.translationMaxCharacters}: '
                          '${runtime.batchSettings.maxCharacters}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_outlined),
                        onTap: controller.openBatch,
                      ),
                    ],
                  ),
                ],
                Divider(color: theme.dividerColor),
                ListTile(
                  leading: Icon(
                    runtime.roamingConfig.enabled
                        ? Icons.cloud_sync_outlined
                        : Icons.cloud_off_outlined,
                  ),
                  title: Text(l10n.translationRoaming),
                  subtitle: Text(
                    !runtime.roamingConfig.enabled
                        ? l10n.roomTranslationAlwaysOff
                        : switch (runtime.roamingConfig.type) {
                            TranslationRoamingType.redis =>
                              l10n.translationRoamingNative,
                            TranslationRoamingType.upstash =>
                              l10n.translationRoamingUpstash,
                          },
                  ),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: controller.openRoaming,
                ),
                Divider(color: theme.dividerColor),
                _SectionTitle(l10n.translationCache),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: Text(l10n.cleanInvalidTranslationCache),
                  onTap: controller.cacheBusy ? null : controller.cleanCache,
                  enabled: !controller.cacheBusy,
                ),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(l10n.clearTranslationCache),
                  onTap: controller.cacheBusy ? null : controller.clearCache,
                  enabled: !controller.cacheBusy,
                ),
                Divider(color: theme.dividerColor),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(l10n.translationPrivacyDetails),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.secondary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

class _ColorOption extends StatelessWidget {
  final Color color;
  final String label;

  const _ColorOption({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(Icons.circle, size: 16, color: color),
      const SizedBox(width: 8),
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
    ],
  );
}
