// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_translation_batch_view.dart';
import 'settings_translation_input_view.dart';
import 'translation_roaming_settings.dart';

class SettingsTranslationInput extends StatefulWidget {
  const SettingsTranslationInput({super.key});

  @override
  State<SettingsTranslationInput> createState() =>
      SettingsTranslationInputController();
}

class SettingsTranslationInputController
    extends State<SettingsTranslationInput> {
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

  bool get loading => _loading;

  void changeManualEnabled(bool value) =>
      _save(runtime.setManualInputTranslationEnabled(value));

  void changeAutomaticEnabled(bool value) =>
      _save(runtime.setAutomaticInputTranslationEnabled(value));

  void changeTrigger(InputTranslationTrigger? value) {
    if (value == null) return;
    _save(runtime.setInputTrigger(value));
  }

  void changeSendMode(InputTranslationSendMode? value) {
    if (value == null) return;
    _save(runtime.setInputSendMode(value));
  }

  void changeScope(InputTranslationScope? value) {
    if (value == null) return;
    _save(runtime.setInputScope(value));
  }

  void changeSourceLanguage(String? value) {
    if (value == null) return;
    setState(() => sourceLanguage = value);
    _saveLanguages();
  }

  void changeTargetLanguage(String? value) {
    if (value == null) return;
    setState(() => targetLanguage = value);
    _saveLanguages();
  }

  void changePreferRoomLanguage(bool? value) {
    if (value == null) return;
    _save(runtime.setPreferRoomLanguageForInputTarget(value));
  }

  void back() => context.go('/rooms/settings/translation');

  @override
  Widget build(BuildContext context) => SettingsTranslationInputView(this);
}

class SettingsTranslationBatch extends StatefulWidget {
  const SettingsTranslationBatch({super.key});

  @override
  State<SettingsTranslationBatch> createState() =>
      SettingsTranslationBatchController();
}

class SettingsTranslationBatchController
    extends State<SettingsTranslationBatch> {
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

  void settingsChanged() {
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

  bool numberValid(TextEditingController field, int min, int max) {
    final value = int.tryParse(field.text);
    return value != null && value >= min && value <= max;
  }

  bool get loading => _loading;

  void changeNumber(
    TextEditingController field,
    int delta, {
    required int min,
    required int max,
  }) {
    final current = int.tryParse(field.text) ?? min;
    field.text = (current + delta).clamp(min, max).toString();
    settingsChanged();
  }

  void back() => context.go('/rooms/settings/translation');

  @override
  Widget build(BuildContext context) => SettingsTranslationBatchView(this);
}

class SettingsTranslationRoaming extends StatelessWidget {
  const SettingsTranslationRoaming({super.key});

  @override
  Widget build(BuildContext context) {
    final runtime = TranslationRuntime.instance;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => TranslationRoamingSettings(runtime: runtime),
    );
  }
}
