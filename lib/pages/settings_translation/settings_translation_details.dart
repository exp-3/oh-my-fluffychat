// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'translation_roaming_settings.dart';
import 'translation_settings_layout.dart';

class SettingsTranslationInput extends StatefulWidget {
  const SettingsTranslationInput({super.key});

  @override
  State<SettingsTranslationInput> createState() =>
      _SettingsTranslationInputState();
}

class _SettingsTranslationInputState extends State<SettingsTranslationInput> {
  final runtime = TranslationRuntime.instance;
  late String sourceLanguage;
  late String targetLanguage;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLanguages());
  }

  Future<void> _loadLanguages() async {
    await runtime.waitForInputLanguageSaves();
    if (!mounted) return;
    setState(() {
      sourceLanguage = runtime.inputSourceLanguage;
      targetLanguage = runtime.inputTargetLanguage;
      _loading = false;
    });
  }

  void _save(Future<void> operation) {
    unawaited(
      operation.onError((Object error, StackTrace stackTrace) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
        );
      }),
    );
  }

  void _saveLanguages() {
    _save(
      runtime.setInputLanguages(source: sourceLanguage, target: targetLanguage),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => _TranslationSettingsScaffold(
        title: l10n.inputTranslation,
        children: [
          if (!runtime.enabled)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.translationDisabledGlobally),
            )
          else if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            )
          else ...[
            SwitchListTile.adaptive(
              title: Text(l10n.inputTranslationModeManual),
              value: runtime.manualInputTranslationEnabled,
              onChanged: (value) =>
                  _save(runtime.setManualInputTranslationEnabled(value)),
            ),
            if (runtime.manualInputTranslationEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 32, right: 16, bottom: 12),
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
                  onChanged: (trigger) {
                    if (trigger != null) {
                      _save(runtime.setInputTrigger(trigger));
                    }
                  },
                ),
              ),
            SwitchListTile.adaptive(
              title: Text(l10n.inputTranslationModeAutomatic),
              value: runtime.automaticInputTranslationEnabled,
              onChanged: (value) =>
                  _save(runtime.setAutomaticInputTranslationEnabled(value)),
            ),
            if (runtime.automaticInputTranslationEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 32, right: 16, bottom: 12),
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
                  onChanged: (mode) {
                    if (mode != null) {
                      _save(runtime.setInputSendMode(mode));
                    }
                  },
                ),
              ),
            if (runtime.inputMode != InputTranslationMode.disabled) ...[
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 12, right: 16),
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
                  onChanged: (scope) {
                    if (scope != null) {
                      _save(runtime.setInputScope(scope));
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 12, right: 16),
                child: TranslationSettingsLayout(
                  padding: EdgeInsets.zero,
                  runSpacing: 12,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: sourceLanguage,
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
                title: Text(l10n.preferRoomLanguageForInputTarget),
                value: runtime.preferRoomLanguageForInputTarget,
                onChanged: (value) {
                  if (value != null) {
                    _save(runtime.setPreferRoomLanguageForInputTarget(value));
                  }
                },
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class SettingsTranslationBatch extends StatefulWidget {
  const SettingsTranslationBatch({super.key});

  @override
  State<SettingsTranslationBatch> createState() =>
      _SettingsTranslationBatchState();
}

class _SettingsTranslationBatchState extends State<SettingsTranslationBatch> {
  final runtime = TranslationRuntime.instance;
  final mergeWindow = TextEditingController();
  final maxMessages = TextEditingController();
  final maxCharacters = TextEditingController();
  final retries = TextEditingController();
  bool _loading = true;
  int _batchSaveToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    await runtime.waitForBatchSettingsSaves();
    if (!mounted) return;
    final settings = runtime.batchSettings;
    setState(() {
      mergeWindow.text = settings.mergeWindowMs.toString();
      maxMessages.text = settings.maxMessages.toString();
      maxCharacters.text = settings.maxCharacters.toString();
      retries.text = settings.malformedResponseRetries.toString();
      _loading = false;
    });
  }

  @override
  void dispose() {
    mergeWindow.dispose();
    maxMessages.dispose();
    maxCharacters.dispose();
    retries.dispose();
    super.dispose();
  }

  TranslationBatchSettings? get _parsedSettings {
    final value = TranslationBatchSettings(
      mergeWindowMs: int.tryParse(mergeWindow.text) ?? -1,
      maxMessages: int.tryParse(maxMessages.text) ?? -1,
      maxCharacters: int.tryParse(maxCharacters.text) ?? -1,
      malformedResponseRetries: int.tryParse(retries.text) ?? -1,
    );
    return value.isValid ? value : null;
  }

  void _settingsChanged() {
    setState(() {});
    final token = ++_batchSaveToken;
    final settings = _parsedSettings;
    if (settings == null) return;
    unawaited(
      runtime
          .saveBatchSettings(
            settings,
            isCurrent: () => token == _batchSaveToken,
          )
          .onError((Object error, StackTrace stackTrace) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
            );
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => _TranslationSettingsScaffold(
        title: l10n.batchTranslation,
        children: [
          if (!runtime.enabled)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.translationDisabledGlobally),
            )
          else if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            )
          else
            TranslationSettingsLayout(
              children: [
                _NumberSetting(
                  controller: mergeWindow,
                  label: l10n.translationMergeWait,
                  min: 0,
                  max: 2000,
                  suffix: 'ms',
                  onChanged: _settingsChanged,
                ),
                _NumberSetting(
                  controller: maxMessages,
                  label: l10n.translationMaxMessages,
                  min: 1,
                  max: 50,
                  onChanged: _settingsChanged,
                ),
                _NumberSetting(
                  controller: maxCharacters,
                  label: l10n.translationMaxCharacters,
                  min: 100,
                  max: 20000,
                  step: 100,
                  onChanged: _settingsChanged,
                ),
                _NumberSetting(
                  controller: retries,
                  label: l10n.translationStructureRetries,
                  min: 0,
                  max: 3,
                  onChanged: _settingsChanged,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class SettingsTranslationRoaming extends StatelessWidget {
  const SettingsTranslationRoaming({super.key});

  @override
  Widget build(BuildContext context) {
    final runtime = TranslationRuntime.instance;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => _TranslationSettingsScaffold(
        title: L10n.of(context).translationRoaming,
        children: [TranslationRoamingSettings(runtime: runtime)],
      ),
    );
  }
}

class _TranslationSettingsScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _TranslationSettingsScaffold({
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: BackButton(
        onPressed: () => context.go('/rooms/settings/translation'),
      ),
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
    padding: const EdgeInsets.symmetric(vertical: 6),
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
