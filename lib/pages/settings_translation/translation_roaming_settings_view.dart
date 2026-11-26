// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_roaming_models.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/layouts/settings_spacing.dart';
import 'package:fluffychat/widgets/settings_checkbox_list_tile.dart';
import 'package:material_ui/material_ui.dart';

import 'translation_roaming_settings.dart';
import 'translation_settings_layout.dart';

class TranslationRoamingSettingsView extends StatelessWidget {
  final TranslationRoamingSettingsController controller;

  const TranslationRoamingSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final uploadHint = switch ((
      controller.fieldsDisabled,
      controller.readOnly,
      controller.uploadNeedsSave,
    )) {
      (true, _, _) => '',
      (_, true, _) => l10n.translationRoamingReadOnlyUploadUnavailable,
      (_, _, true) => l10n.translationSaveBeforeUse,
      _ => '',
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(controller.requestBack());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: controller.requestBack),
          title: Text(l10n.translationRoaming),
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(
                end: SettingsSpacing.inset,
              ),
              child: FilledButton(
                onPressed: controller.busy || controller.loadFailed
                    ? null
                    : controller.save,
                child: controller.saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.save),
              ),
            ),
          ],
        ),
        body: MaxWidthBody(
          contentPadding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: SettingsSpacing.inset),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.cloud_sync_outlined),
                title: Text(
                  l10n.translationRoaming,
                  style: TextStyle(
                    color: theme.colorScheme.secondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(l10n.translationRoamingDescription),
                value: controller.enabled,
                onChanged: controller.busy || controller.loadFailed
                    ? null
                    : controller.setEnabled,
              ),
              if (controller.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: SettingsSpacing.inset,
                    vertical: SettingsSpacing.actions,
                  ),
                  child: LinearProgressIndicator(),
                ),
              if (controller.loadFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SettingsSpacing.inset,
                  ),
                  child: TextButton.icon(
                    onPressed: controller.loading
                        ? null
                        : controller.loadSecrets,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.tryAgain),
                  ),
                ),
              if (controller.saveFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SettingsSpacing.inset,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.oopsSomethingWentWrong,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: controller.busy || controller.loadFailed
                            ? null
                            : controller.save,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.tryAgain),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(
                  left: SettingsSpacing.inset,
                  top: SettingsSpacing.section,
                  right: SettingsSpacing.inset,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: SettingsSpacing.field,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: SettingsSpacing.related,
                          children: [
                            DropdownButtonFormField<TranslationRoamingType>(
                              initialValue: controller.type,
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText:
                                    l10n.translationRoamingConnectionType,
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: TranslationRoamingType.redis,
                                  child: Text(l10n.translationRoamingNative),
                                ),
                                DropdownMenuItem(
                                  value: TranslationRoamingType.upstash,
                                  child: Text(l10n.translationRoamingUpstash),
                                ),
                              ],
                              onChanged: controller.fieldsDisabled
                                  ? null
                                  : controller.changeType,
                            ),
                            if (controller.enabled && controller.unsupported)
                              Text(
                                l10n.translationRoamingWebUnsupported,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                        ...switch (controller.type) {
                          TranslationRoamingType.redis => [
                            TranslationSettingsLayout(
                              padding: EdgeInsets.zero,
                              runSpacing: SettingsSpacing.field,
                              children: [
                                TextField(
                                  controller: controller.host,
                                  enabled: !controller.fieldsDisabled,
                                  autocorrect: false,
                                  keyboardType: TextInputType.url,
                                  decoration: InputDecoration(
                                    labelText: l10n.translationRoamingHost,
                                  ),
                                  onChanged: (_) =>
                                      controller.settingsChanged(),
                                ),
                                TextField(
                                  controller: controller.port,
                                  enabled: !controller.fieldsDisabled,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: l10n.translationRoamingPort,
                                  ),
                                  onChanged: (_) =>
                                      controller.settingsChanged(),
                                ),
                                TextField(
                                  controller: controller.username,
                                  enabled: !controller.fieldsDisabled,
                                  autocorrect: false,
                                  decoration: InputDecoration(
                                    labelText: l10n.translationRoamingUsername,
                                  ),
                                  onChanged: (_) =>
                                      controller.settingsChanged(),
                                ),
                                TextField(
                                  controller: controller.password,
                                  enabled: !controller.fieldsDisabled,
                                  obscureText: !controller.passwordVisible,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  enableIMEPersonalizedLearning: false,
                                  decoration: InputDecoration(
                                    labelText: l10n.password,
                                    suffixIcon: IconButton(
                                      tooltip: controller.passwordVisible
                                          ? l10n.showLess
                                          : l10n.showMore,
                                      onPressed: controller.fieldsDisabled
                                          ? null
                                          : controller.togglePasswordVisibility,
                                      icon: Icon(
                                        controller.passwordVisible
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ),
                                  onChanged: (_) =>
                                      controller.settingsChanged(),
                                ),
                                TextField(
                                  controller: controller.database,
                                  enabled: !controller.fieldsDisabled,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: l10n.translationRoamingDatabase,
                                  ),
                                  onChanged: (_) =>
                                      controller.settingsChanged(),
                                ),
                                DropdownButtonFormField<bool>(
                                  initialValue: controller.tls,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'TLS',
                                  ),
                                  items: [
                                    DropdownMenuItem(
                                      value: true,
                                      child: Text(
                                        l10n.open,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: false,
                                      child: Text(
                                        l10n.close,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                  onChanged: controller.fieldsDisabled
                                      ? null
                                      : controller.changeTls,
                                ),
                              ],
                            ),
                          ],
                          TranslationRoamingType.upstash => [
                            TextField(
                              controller: controller.endpoint,
                              enabled: !controller.fieldsDisabled,
                              autocorrect: false,
                              keyboardType: TextInputType.url,
                              decoration: InputDecoration(
                                labelText: l10n.translationEndpoint,
                                hintText: 'https://example.upstash.io',
                              ),
                              onChanged: (_) => controller.settingsChanged(),
                            ),
                            TextField(
                              controller: controller.token,
                              enabled: !controller.fieldsDisabled,
                              obscureText: !controller.tokenVisible,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              decoration: InputDecoration(
                                labelText: l10n.translationRoamingToken,
                                suffixIcon: IconButton(
                                  tooltip: controller.tokenVisible
                                      ? l10n.showLess
                                      : l10n.showMore,
                                  onPressed: controller.fieldsDisabled
                                      ? null
                                      : controller.toggleTokenVisibility,
                                  icon: Icon(
                                    controller.tokenVisible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              onChanged: (_) => controller.settingsChanged(),
                            ),
                          ],
                        },
                      ],
                    ),
                    const SizedBox(height: SettingsSpacing.section),
                    TranslationSettingsLayout(
                      padding: EdgeInsets.zero,
                      runSpacing: SettingsSpacing.field,
                      children: [
                        TextField(
                          controller: controller.prefix,
                          enabled: !controller.fieldsDisabled,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: l10n.translationRoamingKeyPrefix,
                          ),
                          onChanged: (_) => controller.settingsChanged(),
                        ),
                        TextField(
                          controller: controller.days,
                          enabled: !controller.fieldsDisabled,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.translationRoamingRetentionDays,
                          ),
                          onChanged: (_) => controller.settingsChanged(),
                        ),
                      ],
                    ),
                    const SizedBox(height: SettingsSpacing.section),
                    TextField(
                      controller: controller.psk,
                      enabled: !controller.fieldsDisabled,
                      obscureText: !controller.pskVisible,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingPreSharedKey,
                        suffixIcon: IconButton(
                          tooltip: controller.pskVisible
                              ? l10n.showLess
                              : l10n.showMore,
                          onPressed: controller.fieldsDisabled
                              ? null
                              : controller.togglePskVisibility,
                          icon: Icon(
                            controller.pskVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      onChanged: (_) => controller.settingsChanged(),
                    ),
                    if (controller.invalidInput) ...[
                      const SizedBox(height: SettingsSpacing.related),
                      Text(
                        l10n.invalidInput,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: SettingsSpacing.actions),
                    Wrap(
                      spacing: SettingsSpacing.actions,
                      runSpacing: SettingsSpacing.actions,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: controller.fieldsDisabled
                              ? null
                              : controller.generateKey,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: SettingsSpacing.field,
                              vertical: SettingsSpacing.actions,
                            ),
                          ),
                          icon: const Icon(Icons.key_outlined, size: 18),
                          label: Text(l10n.translationRoamingGenerateKey),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: controller.fieldsDisabled
                              ? null
                              : controller.copyKey,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: SettingsSpacing.field,
                              vertical: SettingsSpacing.actions,
                            ),
                          ),
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          label: Text(l10n.copyToClipboard),
                        ),
                      ],
                    ),
                    const SizedBox(height: SettingsSpacing.section),
                    SettingsCheckboxListTile(
                      title: Text(l10n.translationRoamingReadOnly),
                      value: controller.readOnly,
                      onChanged: controller.fieldsDisabled
                          ? null
                          : controller.changeReadOnly,
                    ),
                    Divider(
                      height: SettingsSpacing.section,
                      color: theme.dividerColor,
                    ),
                    TranslationSettingsLayout(
                      padding: EdgeInsets.zero,
                      spacing: SettingsSpacing.actions,
                      runSpacing: SettingsSpacing.actions,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              controller.fieldsDisabled ||
                                  controller.unsupported
                              ? null
                              : controller.test,
                          icon: controller.testing
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.science_outlined),
                          label: Text(l10n.test),
                        ),
                        Tooltip(
                          key: controller.uploadTooltip,
                          message: uploadHint,
                          triggerMode: TooltipTriggerMode.manual,
                          excludeFromSemantics: uploadHint.isEmpty,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: uploadHint.isNotEmpty
                                ? controller.showUploadHint
                                : null,
                            child: OutlinedButton.icon(
                              onPressed: controller.canUpload
                                  ? controller.openUpload
                                  : null,
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text(l10n.translationRoamingUploadLocal),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: SettingsSpacing.inset),
            ],
          ),
        ),
      ),
    );
  }
}
