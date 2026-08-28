// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

class SettingsTranslation extends StatefulWidget {
  const SettingsTranslation({super.key});

  @override
  State<SettingsTranslation> createState() => _SettingsTranslationState();
}

class _SettingsTranslationState extends State<SettingsTranslation> {
  final runtime = TranslationRuntime.instance;
  late String sourceLanguage;
  late String targetLanguage;
  late String inputSourceLanguage;
  late String inputTargetLanguage;
  late final TextEditingController mergeWindow;
  late final TextEditingController maxMessages;
  late final TextEditingController maxCharacters;
  late final TextEditingController retries;
  Future<void> _languageSave = Future.value();
  Future<void> _inputLanguageSave = Future.value();
  Future<void> _batchSave = Future.value();
  int _batchSaveToken = 0;

  @override
  void initState() {
    super.initState();
    sourceLanguage = runtime.sourceLanguage;
    targetLanguage = runtime.targetLanguage;
    inputSourceLanguage = runtime.inputSourceLanguage;
    inputTargetLanguage = runtime.inputTargetLanguage;
    mergeWindow = TextEditingController(
      text: runtime.batchSettings.mergeWindowMs.toString(),
    );
    maxMessages = TextEditingController(
      text: runtime.batchSettings.maxMessages.toString(),
    );
    maxCharacters = TextEditingController(
      text: runtime.batchSettings.maxCharacters.toString(),
    );
    retries = TextEditingController(
      text: runtime.batchSettings.malformedResponseRetries.toString(),
    );
  }

  @override
  void dispose() {
    mergeWindow.dispose();
    maxMessages.dispose();
    maxCharacters.dispose();
    retries.dispose();
    super.dispose();
  }

  TranslationBatchSettings? get _parsedBatchSettings {
    final value = TranslationBatchSettings(
      mergeWindowMs: int.tryParse(mergeWindow.text) ?? -1,
      maxMessages: int.tryParse(maxMessages.text) ?? -1,
      maxCharacters: int.tryParse(maxCharacters.text) ?? -1,
      malformedResponseRetries: int.tryParse(retries.text) ?? -1,
    );
    return value.isValid ? value : null;
  }

  void _batchSettingsChanged() {
    setState(() {});
    final token = ++_batchSaveToken;
    final batch = _parsedBatchSettings;
    if (batch == null) return;
    _batchSave = _batchSave.then((_) async {
      if (token != _batchSaveToken) return;
      await _languageSave;
      await _inputLanguageSave;
      if (token != _batchSaveToken) return;
      try {
        await runtime.saveBatchSettings(batch);
      } catch (error, stackTrace) {
        await _handleLanguageSaveError(error, stackTrace);
      }
    });
  }

  void _saveLanguages() {
    final source = sourceLanguage;
    final target = targetLanguage;
    _languageSave = _languageSave
        .then((_) => runtime.setLanguages(source: source, target: target))
        .onError(_handleLanguageSaveError);
  }

  void _saveInputLanguages() {
    final source = inputSourceLanguage;
    final target = inputTargetLanguage;
    _inputLanguageSave = _inputLanguageSave
        .then((_) => runtime.setInputLanguages(source: source, target: target))
        .onError(_handleLanguageSaveError);
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
    if (value && !runtime.privacyAccepted) {
      final result = await showOkCancelAlertDialog(
        context: context,
        title: L10n.of(context).translation,
        message: L10n.of(context).translationPrivacyNotice,
        okLabel: L10n.of(context).ok,
        cancelLabel: L10n.of(context).cancel,
      );
      if (result != OkCancelResult.ok) return;
      await runtime.acceptPrivacyNotice();
    }
    final changed = await runtime.setEnabled(value);
    if (changed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).translationProviderRequired)),
    );
  }

  Future<void> _cleanCache() async {
    final result = await runtime.cleanInvalidCache();
    if (!mounted) return;
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
  }

  Future<void> _clearCache() async {
    await runtime.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).translationCacheCleared)),
    );
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
            withScrolling: false,
            child: ListView(
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
                    subtitle: Text(
                      '${provider.model} - ${provider.protocol.name}',
                    ),
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
                Divider(color: theme.dividerColor),
                IgnorePointer(
                  ignoring: !enabled,
                  child: Opacity(
                    opacity: enabled ? 1 : 0.5,
                    child: Column(
                      children: [
                        _SectionTitle(l10n.automaticTranslation),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: DropdownButtonFormField<TranslationScope>(
                            initialValue: runtime.scope,
                            decoration: InputDecoration(
                              labelText: l10n.automaticTranslationScope,
                              prefixIcon: const Icon(
                                Icons.auto_awesome_outlined,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                            items: [
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
                              DropdownMenuItem(
                                value: TranslationScope.selectedRooms,
                                child: Text(l10n.translationScopeSelectedRooms),
                              ),
                              DropdownMenuItem(
                                value: TranslationScope.manualOnly,
                                child: Text(l10n.translationScopeManualOnly),
                              ),
                            ],
                            onChanged: (scope) =>
                                scope == null ? null : runtime.setScope(scope),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: sourceLanguage,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: l10n.sourceLanguage,
                                    prefixIcon: const Icon(
                                      Icons.language_outlined,
                                    ),
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
                                          '${language.name} '
                                          '(${language.code})',
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
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: targetLanguage,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: l10n.targetLanguage,
                                    prefixIcon: const Icon(Icons.flag_outlined),
                                  ),
                                  items: [
                                    for (final language in translationLanguages)
                                      DropdownMenuItem(
                                        value: language.code,
                                        child: Text(
                                          '${language.name} '
                                          '(${language.code})',
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
                              ),
                            ],
                          ),
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
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          child: Column(
                            children: [
                              DropdownButtonFormField<
                                TranslationBilingualColor
                              >(
                                initialValue: runtime.bilingualColor,
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
                                onChanged:
                                    runtime.displayMode ==
                                        TranslationDisplayMode.bilingual
                                    ? (color) => color == null
                                          ? null
                                          : runtime.setBilingualColor(color)
                                    : null,
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<
                                TranslationBilingualStyle
                              >(
                                initialValue: runtime.bilingualStyle,
                                decoration: InputDecoration(
                                  labelText: l10n.translationBilingualStyle,
                                  prefixIcon: const Icon(
                                    Icons.view_stream_outlined,
                                  ),
                                ),
                                items: [
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.divider,
                                    child: Text(l10n.translationStyleDivider),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslationBilingualStyle.background,
                                    child: Text(
                                      l10n.translationStyleBackground,
                                    ),
                                  ),
                                ],
                                onChanged:
                                    runtime.displayMode ==
                                        TranslationDisplayMode.bilingual
                                    ? (style) => style == null
                                          ? null
                                          : runtime.setBilingualStyle(style)
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        Divider(color: theme.dividerColor),
                        _SectionTitle(l10n.inputTranslation),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: DropdownButtonFormField<InputTranslationMode>(
                            key: ValueKey(runtime.inputMode),
                            initialValue: runtime.inputMode,
                            decoration: InputDecoration(
                              labelText: l10n.inputTranslationMode,
                              prefixIcon: const Icon(Icons.translate_outlined),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: InputTranslationMode.disabled,
                                child: Text(l10n.inputTranslationModeDisabled),
                              ),
                              DropdownMenuItem(
                                value: InputTranslationMode.manual,
                                child: Text(l10n.inputTranslationModeManual),
                              ),
                              DropdownMenuItem(
                                value: InputTranslationMode.automatic,
                                child: Text(l10n.inputTranslationModeAutomatic),
                              ),
                            ],
                            onChanged: (mode) => mode == null
                                ? null
                                : runtime.setInputMode(mode),
                          ),
                        ),
                        IgnorePointer(
                          ignoring:
                              runtime.inputMode ==
                              InputTranslationMode.disabled,
                          child: Opacity(
                            opacity:
                                runtime.inputMode ==
                                    InputTranslationMode.disabled
                                ? 0.5
                                : 1,
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    0,
                                  ),
                                  child:
                                      DropdownButtonFormField<
                                        InputTranslationScope
                                      >(
                                        key: ValueKey(runtime.inputScope),
                                        initialValue: runtime.inputScope,
                                        decoration: InputDecoration(
                                          labelText: l10n.inputTranslationScope,
                                          prefixIcon: const Icon(
                                            Icons.meeting_room_outlined,
                                          ),
                                        ),
                                        items: [
                                          DropdownMenuItem(
                                            value: InputTranslationScope
                                                .automaticRooms,
                                            child: Text(
                                              l10n.inputTranslationScopeAutomaticRooms,
                                            ),
                                          ),
                                          DropdownMenuItem(
                                            value:
                                                InputTranslationScope.allRooms,
                                            child: Text(
                                              l10n.inputTranslationScopeAllRooms,
                                            ),
                                          ),
                                        ],
                                        onChanged: (scope) => scope == null
                                            ? null
                                            : runtime.setInputScope(scope),
                                      ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    0,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue: inputSourceLanguage,
                                          isExpanded: true,
                                          decoration: InputDecoration(
                                            labelText: l10n.inputSourceLanguage,
                                            prefixIcon: const Icon(
                                              Icons.language_outlined,
                                            ),
                                          ),
                                          items: [
                                            DropdownMenuItem(
                                              value: 'auto',
                                              child: Text(
                                                l10n.translationAutoDetect,
                                              ),
                                            ),
                                            for (final language
                                                in translationLanguages)
                                              DropdownMenuItem(
                                                value: language.code,
                                                child: Text(
                                                  '${language.name} '
                                                  '(${language.code})',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                          onChanged: (value) {
                                            if (value == null) return;
                                            setState(
                                              () => inputSourceLanguage = value,
                                            );
                                            _saveInputLanguages();
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue: inputTargetLanguage,
                                          isExpanded: true,
                                          decoration: InputDecoration(
                                            labelText: l10n.inputTargetLanguage,
                                            prefixIcon: const Icon(
                                              Icons.flag_outlined,
                                            ),
                                          ),
                                          items: [
                                            for (final language
                                                in translationLanguages)
                                              DropdownMenuItem(
                                                value: language.code,
                                                child: Text(
                                                  '${language.name} '
                                                  '(${language.code})',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                          onChanged: (value) {
                                            if (value == null) return;
                                            setState(
                                              () => inputTargetLanguage = value,
                                            );
                                            _saveInputLanguages();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    0,
                                  ),
                                  child:
                                      runtime.inputMode ==
                                          InputTranslationMode.automatic
                                      ? DropdownButtonFormField<
                                          InputTranslationSendMode
                                        >(
                                          key: ValueKey(runtime.inputSendMode),
                                          initialValue: runtime.inputSendMode,
                                          decoration: InputDecoration(
                                            labelText:
                                                l10n.inputTranslationTrigger,
                                            prefixIcon: const Icon(
                                              Icons.touch_app_outlined,
                                            ),
                                          ),
                                          items: [
                                            DropdownMenuItem(
                                              value: InputTranslationSendMode
                                                  .shortOriginalLongTranslated,
                                              child: Text(
                                                l10n.inputTranslationSendModeShortOriginalLongTranslated,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            DropdownMenuItem(
                                              value: InputTranslationSendMode
                                                  .shortTranslatedLongOriginal,
                                              child: Text(
                                                l10n.inputTranslationSendModeShortTranslatedLongOriginal,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                          onChanged: (mode) => mode == null
                                              ? null
                                              : runtime.setInputSendMode(mode),
                                        )
                                      : DropdownButtonFormField<
                                          InputTranslationTrigger
                                        >(
                                          key: ValueKey(runtime.inputTrigger),
                                          initialValue: runtime.inputTrigger,
                                          decoration: InputDecoration(
                                            labelText:
                                                l10n.inputTranslationTrigger,
                                            prefixIcon: const Icon(
                                              Icons.touch_app_outlined,
                                            ),
                                          ),
                                          items: [
                                            DropdownMenuItem(
                                              value: InputTranslationTrigger
                                                  .button,
                                              child: Text(
                                                l10n.inputTranslationTriggerButton,
                                              ),
                                            ),
                                            DropdownMenuItem(
                                              value: InputTranslationTrigger
                                                  .longPress,
                                              child: Text(
                                                l10n.inputTranslationTriggerLongPress,
                                              ),
                                            ),
                                            DropdownMenuItem(
                                              value: InputTranslationTrigger
                                                  .doubleTap,
                                              child: Text(
                                                l10n.inputTranslationTriggerDoubleTap,
                                              ),
                                            ),
                                          ],
                                          onChanged:
                                              runtime.inputMode ==
                                                  InputTranslationMode.manual
                                              ? (trigger) => trigger == null
                                                    ? null
                                                    : runtime.setInputTrigger(
                                                        trigger,
                                                      )
                                              : null,
                                        ),
                                ),
                                ListTile(
                                  leading: const Icon(Icons.info_outline),
                                  title: Text(
                                    l10n.inputTranslationPrivacyNotice,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        _SectionTitle(l10n.batchTranslation),
                        _NumberSetting(
                          controller: mergeWindow,
                          label: l10n.translationMergeWait,
                          min: 0,
                          max: 2000,
                          suffix: 'ms',
                          onChanged: _batchSettingsChanged,
                        ),
                        _NumberSetting(
                          controller: maxMessages,
                          label: l10n.translationMaxMessages,
                          min: 1,
                          max: 50,
                          onChanged: _batchSettingsChanged,
                        ),
                        _NumberSetting(
                          controller: maxCharacters,
                          label: l10n.translationMaxCharacters,
                          min: 100,
                          max: 20000,
                          step: 100,
                          onChanged: _batchSettingsChanged,
                        ),
                        _NumberSetting(
                          controller: retries,
                          label: l10n.translationStructureRetries,
                          min: 0,
                          max: 3,
                          onChanged: _batchSettingsChanged,
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(color: theme.dividerColor),
                _SectionTitle(l10n.translationCache),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: Text(l10n.cleanInvalidTranslationCache),
                  onTap: _cleanCache,
                ),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(l10n.clearTranslationCache),
                  onTap: _clearCache,
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

class _NumberSetting extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int min;
  final int max;
  final int step;
  final String? suffix;
  final VoidCallback onChanged;

  const _NumberSetting({
    required this.controller,
    required this.label,
    required this.min,
    required this.max,
    this.step = 1,
    this.suffix,
    required this.onChanged,
  });

  bool get valid {
    final value = int.tryParse(controller.text);
    return value != null && value >= min && value <= max;
  }

  void change(int delta) {
    final current = int.tryParse(controller.text) ?? min;
    controller.text = (current + delta).clamp(min, max).toString();
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        helperText: '$min-$max',
        suffixText: suffix,
        errorText: valid ? null : L10n.of(context).invalidInput,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 96,
          minHeight: 48,
        ),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.remove),
              tooltip: L10n.of(context).decrease,
              onPressed: () => change(-step),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: L10n.of(context).increase,
              onPressed: () => change(step),
            ),
          ],
        ),
      ),
      onChanged: (_) => onChanged(),
    ),
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
  late bool useFullEndpoint;
  bool testing = false;
  bool saving = false;
  bool deleting = false;
  bool? testPassed;
  String? testMessage;

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
    useFullEndpoint = existing?.useFullEndpoint ?? false;
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

  TranslationProviderConfig? get config {
    final uri = Uri.tryParse(endpoint.text.trim());
    if (uri == null) return null;
    final value = TranslationProviderConfig(
      id: providerId,
      name: name.text.trim(),
      endpoint: uri,
      useFullEndpoint: useFullEndpoint,
      protocol: protocol,
      model: model.text.trim(),
    );
    return value.isValid ? value : null;
  }

  void formChanged() {
    setState(() {
      testPassed = null;
      testMessage = null;
    });
  }

  Future<void> test() async {
    final value = config;
    if (value == null || (existing == null && apiKey.text.trim().isEmpty)) {
      setState(() {
        testPassed = false;
        testMessage = L10n.of(context).translationProviderRequired;
      });
      return;
    }
    setState(() {
      testing = true;
      testPassed = null;
      testMessage = null;
    });
    try {
      await runtime.testProvider(value, apiKey.text);
      if (!mounted) return;
      setState(() {
        testPassed = true;
        testMessage = L10n.of(context).translationProviderTestPassed;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        testPassed = false;
        testMessage = '${L10n.of(context).translationFailed}: $error';
      });
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> save() async {
    final value = config;
    if (value == null ||
        (existing == null && apiKey.text.trim().isEmpty) ||
        saving) {
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
    final testMessage = this.testMessage;
    final busy = testing || saving || deleting;
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
                          ? 'https://api.example/v1/chat/completions'
                          : 'https://api.example/v1',
                    ),
                    keyboardType: TextInputType.url,
                    onChanged: (_) => formChanged(),
                  ),
                  CheckboxListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: useFullEndpoint,
                    title: Text(l10n.translationEndpointIsComplete),
                    subtitle: value == null || useFullEndpoint
                        ? null
                        : Text(
                            '${l10n.translationEndpoint}: '
                            '${value.requestEndpoint}',
                          ),
                    onChanged: busy
                        ? null
                        : (checked) {
                            if (checked == null) return;
                            useFullEndpoint = checked;
                            formChanged();
                          },
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
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value == null) return;
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
                  TextField(
                    controller: apiKey,
                    enabled: !busy,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.apiKey,
                      helperText: existing == null
                          ? null
                          : l10n.leaveEmptyToKeepCurrent,
                    ),
                    onChanged: (_) => formChanged(),
                  ),
                  if (testMessage != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: testPassed == true
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 8,
                        children: [
                          Icon(
                            testPassed == true
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            color: testPassed == true
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onErrorContainer,
                          ),
                          Expanded(
                            child: Text(
                              testMessage,
                              style: TextStyle(
                                color: testPassed == true
                                    ? theme.colorScheme.onPrimaryContainer
                                    : theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : test,
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
