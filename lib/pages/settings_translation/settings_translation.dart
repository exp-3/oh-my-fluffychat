// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_languages.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import 'settings_translation_provider_view.dart';
import 'settings_translation_view.dart';
import 'translation_test_feedback.dart';
import 'translation_unsaved_changes_dialog.dart';

class SettingsTranslation extends StatefulWidget {
  const SettingsTranslation({super.key});

  @override
  State<SettingsTranslation> createState() => SettingsTranslationController();
}

class SettingsTranslationController extends State<SettingsTranslation> {
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

  String languageLabel(String code, L10n l10n) {
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

  Future<void> toggleEnabled(bool value) async {
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

  Future<void> cleanCache() async {
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

  Future<void> clearCache() async {
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

  bool get cacheBusy => _cacheBusy;

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

  void openProvider([String? id]) {
    final location = Uri(
      path: '/rooms/settings/translation/provider',
      queryParameters: id == null ? null : {'id': id},
    );
    context.go(location.toString());
  }

  void openInput() => context.go('/rooms/settings/translation/input');

  void openBatch() => context.go('/rooms/settings/translation/batch');

  void openRoaming() => context.go('/rooms/settings/translation/roaming');

  Future<bool> selectProvider(String id) => runtime.selectProvider(id);

  void changeScope(TranslationScope? value) {
    if (value == null) return;
    unawaited(runtime.setScope(value));
  }

  void changePreferRoomLanguage(bool? value) {
    if (value == null) return;
    unawaited(runtime.setPreferRoomLanguageForSource(value));
  }

  void changeBilingual(bool value) => unawaited(
    runtime.setDisplayMode(
      value
          ? TranslationDisplayMode.bilingual
          : TranslationDisplayMode.translatedOnly,
    ),
  );

  void changeBilingualColor(TranslationBilingualColor? value) {
    if (value == null) return;
    unawaited(runtime.setBilingualColor(value));
  }

  void changeBilingualStyle(TranslationBilingualStyle? value) {
    if (value == null) return;
    unawaited(runtime.setBilingualStyle(value));
  }

  @override
  Widget build(BuildContext context) => SettingsTranslationView(this);
}

typedef _ProviderDraftSnapshot = ({
  String name,
  String endpoint,
  String model,
  TranslationProtocol protocol,
  TranslationReasoningEffort reasoningEffort,
  bool useFullEndpoint,
});

class SettingsTranslationProvider extends StatefulWidget {
  final String? providerId;

  const SettingsTranslationProvider({this.providerId, super.key});

  @override
  State<SettingsTranslationProvider> createState() =>
      SettingsTranslationProviderController();
}

class SettingsTranslationProviderController
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
  bool _dialogOpen = false;
  bool _leaving = false;
  late final _ProviderDraftSnapshot _initialValues;
  String _initialApiKey = '';
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _testFeedback;

  bool get _busy => testing || saving || deleting;

  _ProviderDraftSnapshot get _formValues => (
    name: name.text,
    endpoint: endpoint.text,
    model: model.text,
    protocol: protocol,
    reasoningEffort: reasoningEffort,
    useFullEndpoint: useFullEndpoint,
  );

  bool get _dirty =>
      _formValues != _initialValues || apiKey.text != _initialApiKey;

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
    _initialValues = _formValues;
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
      _initialApiKey = apiKey.text;
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

  void _returnToSettings() {
    if (!mounted || _leaving) return;
    _leaving = true;
    context.go('/rooms/settings/translation');
  }

  Future<void> requestExit() async {
    if (_busy || _dialogOpen || _leaving) return;
    if (!_dirty) {
      _returnToSettings();
      return;
    }
    _dialogOpen = true;
    final TranslationUnsavedChangesAction? action;
    try {
      action = await showTranslationUnsavedChangesDialog(context);
    } finally {
      _dialogOpen = false;
    }
    if (!mounted) return;
    switch (action) {
      case TranslationUnsavedChangesAction.save:
        await save();
      case TranslationUnsavedChangesAction.discard:
        _returnToSettings();
      case null:
        break;
    }
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
    if (_busy || _dialogOpen || _leaving) return;
    if (_loadingApiKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).loadingPleaseWait)),
      );
      return;
    }
    final value = config;
    if (value == null || (existing == null && apiKey.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).translationProviderRequired)),
      );
      return;
    }
    final enteredApiKey = apiKey.text;
    setState(() => saving = true);
    try {
      if (value.endpoint.scheme == 'http' &&
          value.requestEndpoint != existing?.requestEndpoint) {
        final l10n = L10n.of(context);
        _dialogOpen = true;
        final OkCancelResult? result;
        try {
          result = await showOkCancelAlertDialog(
            context: context,
            title: l10n.warning,
            message: l10n.translationProviderHttpWarning,
            okLabel: l10n.translationProviderHttpSaveAnyway,
            cancelLabel: l10n.cancel,
          );
        } finally {
          _dialogOpen = false;
        }
        if (result != OkCancelResult.ok || !mounted) return;
      }
      await runtime.saveProvider(
        value,
        apiKey: enteredApiKey.trim().isEmpty ? null : enteredApiKey,
      );
      if (!mounted) return;
      _returnToSettings();
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
    if (provider == null || _busy || _dialogOpen) return;
    final l10n = L10n.of(context);
    _dialogOpen = true;
    final OkCancelResult? result;
    try {
      result = await showOkCancelAlertDialog(
        context: context,
        title: l10n.deleteTranslationProvider,
        message: l10n.areYouSure,
        okLabel: l10n.delete,
        cancelLabel: l10n.cancel,
        isDestructive: true,
      );
    } finally {
      _dialogOpen = false;
    }
    if (result != OkCancelResult.ok || !mounted) return;
    setState(() => deleting = true);
    try {
      await runtime.deleteProvider(provider.id);
      if (!mounted) return;
      _returnToSettings();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.oopsSomethingWentWrong}: $error')),
      );
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  bool get canSave =>
      !_busy &&
      !_loadingApiKey &&
      config != null &&
      (existing != null || apiKey.text.trim().isNotEmpty);

  bool get busy => _busy;
  bool get loadingApiKey => _loadingApiKey;
  bool get apiKeyVisible => _apiKeyVisible;
  bool get providerMissing => widget.providerId != null && existing == null;

  Uri? get previewEndpoint {
    final draft = _draftConfig;
    if (draft == null ||
        !draft.endpoint.hasScheme ||
        draft.endpoint.host.isEmpty) {
      return null;
    }
    return draft.requestEndpoint;
  }

  void changeUseFullEndpoint(bool? value) {
    if (value == null) return;
    useFullEndpoint = value;
    formChanged();
  }

  void changeProtocol(TranslationProtocol? value) {
    if (value == null || value == protocol) return;
    protocol = value;
    formChanged();
  }

  void changeReasoningEffort(TranslationReasoningEffort? value) {
    if (value == null) return;
    reasoningEffort = value;
    formChanged();
  }

  void toggleApiKeyVisibility() =>
      setState(() => _apiKeyVisible = !_apiKeyVisible);

  void onPopInvoked(bool didPop, Object? result) {
    if (!didPop) unawaited(requestExit());
  }

  @override
  Widget build(BuildContext context) => SettingsTranslationProviderView(this);
}
