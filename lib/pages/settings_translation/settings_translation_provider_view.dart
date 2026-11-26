// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_translation.dart';

class SettingsTranslationProviderView extends StatelessWidget {
  final SettingsTranslationProviderController controller;

  const SettingsTranslationProviderView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final previewEndpoint = controller.previewEndpoint;
    final busy = controller.busy;
    if (controller.providerMissing) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.editTranslationProvider)),
        body: Center(child: Text(l10n.oopsSomethingWentWrong)),
      );
    }
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: controller.onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: controller.requestExit),
          title: Text(
            controller.existing == null
                ? l10n.addTranslationProvider
                : l10n.editTranslationProvider,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton(
                onPressed: controller.canSave ? controller.save : null,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  spacing: 12,
                  children: [
                    TextField(
                      controller: controller.name,
                      enabled: !busy,
                      decoration: InputDecoration(labelText: l10n.providerName),
                      onChanged: (_) => controller.formChanged(),
                    ),
                    TextField(
                      controller: controller.endpoint,
                      enabled: !busy,
                      decoration: InputDecoration(
                        labelText: 'URL',
                        hintText: controller.useFullEndpoint
                            ? switch (controller.protocol) {
                                TranslationProtocol.chatCompletions =>
                                  'https://api.example/v1/chat/completions',
                                TranslationProtocol.responses =>
                                  'https://api.example/v1/responses',
                                TranslationProtocol.anthropicMessages =>
                                  'https://api.anthropic.com/v1/messages',
                              }
                            : 'https://api.example/v1',
                        helperText: previewEndpoint == null
                            ? null
                            : '${l10n.translationEndpoint}: $previewEndpoint',
                        helperMaxLines: 3,
                      ),
                      keyboardType: TextInputType.url,
                      onChanged: (_) => controller.formChanged(),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: ListTileTheme.merge(
                        horizontalTitleGap: 0,
                        child: CheckboxListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          visualDensity: const VisualDensity(vertical: -2),
                          controlAffinity: ListTileControlAffinity.leading,
                          value: controller.useFullEndpoint,
                          title: Text(l10n.translationEndpointIsComplete),
                          onChanged: busy
                              ? null
                              : controller.changeUseFullEndpoint,
                        ),
                      ),
                    ),
                    DropdownButtonFormField<TranslationProtocol>(
                      initialValue: controller.protocol,
                      decoration: InputDecoration(
                        labelText: l10n.translationProtocol,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: TranslationProtocol.chatCompletions,
                          child: Text('Chat Completions'),
                        ),
                        DropdownMenuItem(
                          value: TranslationProtocol.responses,
                          child: Text('Responses'),
                        ),
                        DropdownMenuItem(
                          value: TranslationProtocol.anthropicMessages,
                          child: Text('Anthropic Messages'),
                        ),
                      ],
                      onChanged: busy ? null : controller.changeProtocol,
                    ),
                    TextField(
                      controller: controller.model,
                      enabled: !busy,
                      decoration: InputDecoration(labelText: l10n.model),
                      onChanged: (_) => controller.formChanged(),
                    ),
                    DropdownButtonFormField<TranslationReasoningEffort>(
                      initialValue: controller.reasoningEffort,
                      decoration: InputDecoration(
                        labelText: l10n.translationReasoningEffort,
                      ),
                      items: TranslationReasoningEffort.values
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                value == TranslationReasoningEffort.unspecified
                                    ? l10n.translationReasoningUnspecified
                                    : value.name,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: busy ? null : controller.changeReasoningEffort,
                    ),
                    TextField(
                      controller: controller.apiKey,
                      enabled: !busy && !controller.loadingApiKey,
                      obscureText: !controller.apiKeyVisible,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(
                        labelText: l10n.apiKey,
                        helperText: controller.existing == null
                            ? null
                            : l10n.leaveEmptyToKeepCurrent,
                        suffixIcon: IconButton(
                          tooltip: controller.apiKeyVisible
                              ? l10n.showLess
                              : l10n.showMore,
                          onPressed: busy || controller.loadingApiKey
                              ? null
                              : controller.toggleApiKeyVisibility,
                          icon: Icon(
                            controller.apiKeyVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      onChanged: (_) => controller.formChanged(),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: busy || controller.loadingApiKey
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
                    ),
                  ],
                ),
              ),
              if (controller.existing != null) ...[
                Divider(color: theme.dividerColor),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : controller.delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      side: BorderSide(color: theme.colorScheme.error),
                    ),
                    icon: controller.deleting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline),
                    label: Text(l10n.deleteTranslationProvider),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
