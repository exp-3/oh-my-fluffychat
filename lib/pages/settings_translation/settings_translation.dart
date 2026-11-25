// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_roaming_models.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import 'translation_settings_layout.dart';
import 'translation_test_feedback.dart';

class SettingsTranslation extends StatefulWidget {
  const SettingsTranslation({super.key});

  @override
  State<SettingsTranslation> createState() => _SettingsTranslationState();
}

class _SettingsTranslationState extends State<SettingsTranslation> {
  final runtime = TranslationRuntime.instance;
  late String sourceLanguage;
  late String targetLanguage;
  Future<void> _languageSave = Future.value();
  bool _cacheBusy = false;

  @override
  void initState() {
    super.initState();
    sourceLanguage = runtime.sourceLanguage;
    targetLanguage = runtime.targetLanguage;
  }

  void _saveLanguages() {
    final source = sourceLanguage;
    final target = targetLanguage;
    _languageSave = _languageSave
        .then((_) => runtime.setLanguages(source: source, target: target))
        .onError(_handleLanguageSaveError);
  }

  String _languageLabel(String code, L10n l10n) {
    if (code == 'auto') return l10n.translationAutoDetect;
    for (final language in translationLanguages) {
      if (language.code == code) return language.name;
    }
    return code;
  }

  Future<void> _handleLanguageSaveError(
    Object error,
    StackTrace stackTrace,
  ) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
    );
  }

  Future<void> _toggleEnabled(bool value) async {
    if (value) {
      final result = await showOkCancelAlertDialog(
        context: context,
        title: L10n.of(context).translation,
        message: L10n.of(context).translationPrivacyDetails,
        okLabel: L10n.of(context).ok,
        cancelLabel: L10n.of(context).cancel,
      );
      if (result != OkCancelResult.ok || !mounted) return;
      await runtime.acceptPrivacyNotice();
    }
    if (!mounted) return;
    final changed = await runtime.setEnabled(value);
    if (changed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).translationProviderRequired)),
    );
  }

  Future<void> _cleanCache() async {
    if (_cacheBusy) return;
    setState(() => _cacheBusy = true);
    try {
      final operation = await showFutureLoadingDialog(
        context: context,
        future: runtime.cleanInvalidCache,
        delay: false,
      );
      if (!mounted) return;
      final result = operation.asValue?.value;
      if (result == null) return;
      final message = result.cacheExisted
          ? L10n.of(context).translationCacheCleanupResult(
              result.checked,
              result.retained,
              result.deleted,
            )
          : L10n.of(context).noTranslationCache;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

  Future<void> _clearCache() async {
    if (_cacheBusy) return;
    setState(() => _cacheBusy = true);
    try {
      final l10n = L10n.of(context);
      final result = await showOkCancelAlertDialog(
        context: context,
        title: l10n.clearTranslationCache,
        message: l10n.clearTranslationCacheWarning,
        okLabel: l10n.clearTranslationCache,
        cancelLabel: l10n.cancel,
        isDestructive: true,
      );
      if (result != OkCancelResult.ok || !mounted) return;
      final operation = await showFutureLoadingDialog(
        context: context,
        future: runtime.clearCache,
        delay: false,
      );
      if (!mounted || operation.isError) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).translationCacheCleared)),
      );
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        final enabled = runtime.enabled;
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
                  onChanged: _toggleEnabled,
                ),
                _SectionTitle(l10n.translationProviders),
                for (final provider in runtime.providers)
                  ListTile(
                    onTap: () => runtime.selectProvider(provider.id),
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
                      onPressed: () {
                        final location = Uri(
                          path: '/rooms/settings/translation/provider',
                          queryParameters: {'id': provider.id},
                        );
                        context.go(location.toString());
                      },
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
                  onTap: () =>
                      context.go('/rooms/settings/translation/provider'),
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
                              child: Text(l10n.translationScopeNone),
                            ),
                            DropdownMenuItem(
                              value: TranslationScope.allRooms,
                              child: Text(l10n.translationScopeAllRooms),
                            ),
                            DropdownMenuItem(
                              value: TranslationScope.unencryptedRooms,
                              child: Text(
                                l10n.translationScopeUnencryptedRooms,
                              ),
                            ),
                          ],
                          onChanged: (scope) =>
                              scope == null ? null : runtime.setScope(scope),
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
                              initialValue: sourceLanguage,
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
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => sourceLanguage = value);
                                _saveLanguages();
                              },
                            ),
                            DropdownButtonFormField<String>(
                              initialValue: targetLanguage,
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
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => targetLanguage = value);
                                _saveLanguages();
                              },
                            ),
                          ],
                        ),
                      ),
                      CheckboxListTile.adaptive(
                        title: Text(l10n.preferRoomLanguageForSource),
                        value: runtime.preferRoomLanguageForSource,
                        onChanged: (value) => value == null
                            ? null
                            : runtime.setPreferRoomLanguageForSource(value),
                      ),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.view_agenda_outlined),
                        title: Text(l10n.bilingual),
                        value:
                            runtime.displayMode ==
                            TranslationDisplayMode.bilingual,
                        onChanged: (bilingual) => runtime.setDisplayMode(
                          bilingual
                              ? TranslationDisplayMode.bilingual
                              : TranslationDisplayMode.translatedOnly,
                        ),
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
                                onChanged: (color) => color == null
                                    ? null
                                    : runtime.setBilingualColor(color),
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
                                onChanged: (style) => style == null
                                    ? null
                                    : runtime.setBilingualStyle(style),
                              ),
                            ],
                          ),
                        ),
                      Divider(color: theme.dividerColor),
                      ListTile(
                        leading: const Icon(Icons.edit_note_outlined),
                        title: Text(l10n.inputTranslation),
                        subtitle: Text(
                          '${_languageLabel(runtime.inputSourceLanguage, l10n)}'
                          ' → ${_languageLabel(runtime.inputTargetLanguage, l10n)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_outlined),
                        onTap: () =>
                            context.go('/rooms/settings/translation/input'),
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
                        onTap: () =>
                            context.go('/rooms/settings/translation/batch'),
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
                  subtitle: Text(switch (runtime.roamingConfig.type) {
                    TranslationRoamingType.redis =>
                      l10n.translationRoamingNative,
                    TranslationRoamingType.upstash =>
                      l10n.translationRoamingUpstash,
                  }),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: () =>
                      context.go('/rooms/settings/translation/roaming'),
                ),
                Divider(color: theme.dividerColor),
                _SectionTitle(l10n.translationCache),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: Text(l10n.cleanInvalidTranslationCache),
                  onTap: _cacheBusy ? null : _cleanCache,
                  enabled: !_cacheBusy,
                ),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(l10n.clearTranslationCache),
                  onTap: _cacheBusy ? null : _clearCache,
                  enabled: !_cacheBusy,
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

class SettingsTranslationProvider extends StatefulWidget {
  final String? providerId;

  const SettingsTranslationProvider({this.providerId, super.key});

  @override
  State<SettingsTranslationProvider> createState() =>
      _SettingsTranslationProviderState();
}

class _SettingsTranslationProviderState
    extends State<SettingsTranslationProvider> {
  final runtime = TranslationRuntime.instance;
  late final TranslationProviderConfig? existing;
  late final String providerId;
  late final TextEditingController name;
  late final TextEditingController endpoint;
  late final TextEditingController model;
  late final TextEditingController apiKey;
  late TranslationProtocol protocol;
  late TranslationReasoningEffort reasoningEffort;
  late bool useFullEndpoint;
  bool testing = false;
  bool saving = false;
  bool deleting = false;
  bool _loadingApiKey = false;
  bool _apiKeyVisible = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _testFeedback;

  bool get _busy => testing || saving || deleting;

  @override
  void initState() {
    super.initState();
    existing = _findProvider(widget.providerId);
    providerId = existing?.id ?? const Uuid().v4();
    name = TextEditingController(text: existing?.name ?? '');
    endpoint = TextEditingController(text: existing?.endpoint.toString() ?? '');
    model = TextEditingController(text: existing?.model ?? '');
    apiKey = TextEditingController();
    protocol = existing?.protocol ?? TranslationProtocol.chatCompletions;
    reasoningEffort =
        existing?.reasoningEffort ?? TranslationReasoningEffort.unspecified;
    useFullEndpoint = existing?.useFullEndpoint ?? false;
    if (existing != null) {
      _loadingApiKey = true;
      unawaited(_loadApiKey());
    }
  }

  Future<void> _loadApiKey() async {
    try {
      final value = await runtime.preferences.readApiKey(providerId);
      if (!mounted) return;
      apiKey.text = value ?? '';
    } catch (_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
        );
      });
    } finally {
      if (mounted) setState(() => _loadingApiKey = false);
    }
  }

  TranslationProviderConfig? _findProvider(String? id) {
    if (id == null) return null;
    for (final provider in runtime.providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  @override
  void dispose() {
    name.dispose();
    endpoint.dispose();
    model.dispose();
    apiKey.dispose();
    super.dispose();
  }

  TranslationProviderConfig? get _draftConfig {
    final uri = Uri.tryParse(endpoint.text.trim());
    if (uri == null) return null;
    return TranslationProviderConfig(
      id: providerId,
      name: name.text.trim(),
      endpoint: uri,
      useFullEndpoint: useFullEndpoint,
      protocol: protocol,
      reasoningEffort: reasoningEffort,
      model: model.text.trim(),
    );
  }

  TranslationProviderConfig? get config {
    final value = _draftConfig;
    return value?.isValid == true ? value : null;
  }

  void formChanged() {
    _clearTestFeedback();
    setState(() {});
  }

  void _clearTestFeedback() {
    _testFeedback?.close();
    _testFeedback = null;
  }

  void _showTestFeedback({required String message, Object? error}) {
    final feedback = showTranslationTestFeedback(
      context,
      message: message,
      error: error,
      secrets: [apiKey.text],
    );
    _testFeedback = feedback;
    unawaited(
      feedback.closed.then((_) {
        if (identical(_testFeedback, feedback)) _testFeedback = null;
      }),
    );
  }

  Future<void> test() async {
    if (_busy || _loadingApiKey) return;
    _clearTestFeedback();
    final value = config;
    if (value == null || (existing == null && apiKey.text.trim().isEmpty)) {
      _showTestFeedback(message: L10n.of(context).translationProviderRequired);
      return;
    }
    setState(() => testing = true);
    try {
      await runtime.testProvider(value, apiKey.text);
      if (!mounted) return;
      _showTestFeedback(
        message: L10n.of(context).translationProviderTestPassed,
      );
    } catch (error) {
      if (!mounted) return;
      _showTestFeedback(
        message: L10n.of(context).oopsSomethingWentWrong,
        error: error,
      );
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> save() async {
    final value = config;
    if (value == null ||
        (existing == null && apiKey.text.trim().isEmpty) ||
        _busy ||
        _loadingApiKey) {
      return;
    }
    setState(() => saving = true);
    try {
      await runtime.saveProvider(
        value,
        apiKey: apiKey.text.trim().isEmpty ? null : apiKey.text,
      );
      if (!mounted) return;
      context.go('/rooms/settings/translation');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${L10n.of(context).oopsSomethingWentWrong}: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> delete() async {
    final provider = existing;
    if (provider == null || deleting) return;
    final l10n = L10n.of(context);
    final result = await showOkCancelAlertDialog(
      context: context,
      title: l10n.deleteTranslationProvider,
      message: l10n.areYouSure,
      okLabel: l10n.delete,
      cancelLabel: l10n.cancel,
      isDestructive: true,
    );
    if (result != OkCancelResult.ok || !mounted) return;
    setState(() => deleting = true);
    try {
      await runtime.deleteProvider(provider.id);
      if (!mounted) return;
      context.go('/rooms/settings/translation');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.oopsSomethingWentWrong}: $error')),
      );
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final value = config;
    final draft = _draftConfig;
    final previewEndpoint =
        draft != null &&
            draft.endpoint.hasScheme &&
            draft.endpoint.host.isNotEmpty
        ? draft.requestEndpoint
        : null;
    final busy = _busy;
    if (widget.providerId != null && existing == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.editTranslationProvider)),
        body: Center(child: Text(l10n.oopsSomethingWentWrong)),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: busy
              ? null
              : () => context.go('/rooms/settings/translation'),
        ),
        title: Text(
          existing == null
              ? l10n.addTranslationProvider
              : l10n.editTranslationProvider,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton(
              onPressed:
                  busy ||
                      _loadingApiKey ||
                      value == null ||
                      (existing == null && apiKey.text.trim().isEmpty)
                  ? null
                  : save,
              child: saving
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
                    controller: name,
                    enabled: !busy,
                    decoration: InputDecoration(labelText: l10n.providerName),
                    onChanged: (_) => formChanged(),
                  ),
                  TextField(
                    controller: endpoint,
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: 'URL',
                      hintText: useFullEndpoint
                          ? switch (protocol) {
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
                    onChanged: (_) => formChanged(),
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
                        value: useFullEndpoint,
                        title: Text(l10n.translationEndpointIsComplete),
                        onChanged: busy
                            ? null
                            : (checked) {
                                if (checked == null) return;
                                useFullEndpoint = checked;
                                formChanged();
                              },
                      ),
                    ),
                  ),
                  DropdownButtonFormField<TranslationProtocol>(
                    initialValue: protocol,
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
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value == null || value == protocol) return;
                            protocol = value;
                            formChanged();
                          },
                  ),
                  TextField(
                    controller: model,
                    enabled: !busy,
                    decoration: InputDecoration(labelText: l10n.model),
                    onChanged: (_) => formChanged(),
                  ),
                  DropdownButtonFormField<TranslationReasoningEffort>(
                    initialValue: reasoningEffort,
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
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            reasoningEffort = value;
                            formChanged();
                          },
                  ),
                  TextField(
                    controller: apiKey,
                    enabled: !busy && !_loadingApiKey,
                    obscureText: !_apiKeyVisible,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: InputDecoration(
                      labelText: l10n.apiKey,
                      helperText: existing == null
                          ? null
                          : l10n.leaveEmptyToKeepCurrent,
                      suffixIcon: IconButton(
                        tooltip: _apiKeyVisible ? l10n.showLess : l10n.showMore,
                        onPressed: busy || _loadingApiKey
                            ? null
                            : () => setState(
                                () => _apiKeyVisible = !_apiKeyVisible,
                              ),
                        icon: Icon(
                          _apiKeyVisible
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                    onChanged: (_) => formChanged(),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: busy || _loadingApiKey ? null : test,
                      icon: testing
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.science_outlined),
                      label: Text(l10n.test),
                    ),
                  ),
                ],
              ),
            ),
            if (existing != null) ...[
              Divider(color: theme.dividerColor),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: busy ? null : delete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                  icon: deleting
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
    );
  }
}
