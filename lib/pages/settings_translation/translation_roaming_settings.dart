// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'roaming_actions.dart';
import 'translation_test_feedback.dart';
import 'translation_unsaved_changes_dialog.dart';

/// Keeps roaming settings local until the user explicitly saves them.
class TranslationRoamingSettings extends StatefulWidget {
  final TranslationRuntime runtime;

  const TranslationRoamingSettings({super.key, required this.runtime});

  @override
  State<TranslationRoamingSettings> createState() =>
      _TranslationRoamingSettingsState();
}

class _TranslationRoamingSettingsState
    extends State<TranslationRoamingSettings> {
  late TranslationRoamingConfig _saved;
  late TranslationRoamingType _type;
  late bool _enabled;
  late bool _tls;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _database;
  late final TextEditingController _endpoint;
  late final TextEditingController _token;
  late final TextEditingController _prefix;
  late final TextEditingController _psk;
  late final TextEditingController _days;
  bool _loading = true;
  bool _loadFailed = false;
  bool _testing = false;
  bool _saving = false;
  bool _saveFailed = false;
  bool _validationRequested = false;
  bool _confirmingExit = false;
  bool _hasSavedKey = false;
  bool _passwordVisible = false;
  bool _tokenVisible = false;
  bool _pskVisible = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _testFeedback;
  final _uploadTooltip = GlobalKey<TooltipState>();
  late List<Object> _baseline;

  bool get _busy => _loading || _testing || _saving;
  bool get _fieldsDisabled => _busy || _loadFailed || !_enabled;
  bool get _dirty => !listEquals(_baseline, _formValues);

  List<Object> get _formValues => [
    _enabled,
    _type,
    _tls,
    _host.text,
    _port.text,
    _username.text,
    _password.text,
    _database.text,
    _endpoint.text,
    _token.text,
    _prefix.text,
    _psk.text,
    _days.text,
  ];

  @override
  void initState() {
    super.initState();
    _saved = widget.runtime.roamingConfig;
    _type = _saved.type;
    _enabled = _saved.enabled;
    _tls = _saved.tls;
    _host = TextEditingController(text: _saved.host);
    _port = TextEditingController(text: _saved.port.toString());
    _username = TextEditingController(text: _saved.username);
    _password = TextEditingController();
    _database = TextEditingController(text: _saved.database.toString());
    _endpoint = TextEditingController(text: _saved.endpoint);
    _token = TextEditingController();
    _prefix = TextEditingController(text: _saved.keyPrefix);
    _psk = TextEditingController();
    _days = TextEditingController(text: _saved.retentionDays.toString());
    _baseline = _formValues;
    unawaited(_loadSecrets());
  }

  @override
  void dispose() {
    for (final controller in [
      _host,
      _port,
      _username,
      _password,
      _database,
      _endpoint,
      _token,
      _prefix,
      _psk,
      _days,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSecrets() async {
    if (!_loading) setState(() => _loading = true);
    try {
      final settings = await widget.runtime.readRoamingSettings();
      if (!mounted) return;
      final config = settings.config;
      final secrets = settings.secrets;
      _saved = config;
      _type = config.type;
      _tls = config.tls;
      _enabled = config.enabled;
      _host.text = config.host;
      _port.text = config.port.toString();
      _username.text = config.username;
      _database.text = config.database.toString();
      _endpoint.text = config.endpoint;
      _prefix.text = config.keyPrefix;
      _days.text = config.retentionDays.toString();
      _password.text = secrets.redisPassword;
      _token.text = secrets.restToken;
      _psk.text = secrets.preSharedKey.isEmpty
          ? TranslationRoamingCrypto.generatePreSharedKey()
          : secrets.preSharedKey;
      _hasSavedKey = secrets.preSharedKey.isNotEmpty;
      _baseline = _formValues;
      _loadFailed = false;
    } catch (_) {
      if (!mounted) return;
      _loadFailed = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  TranslationRoamingConfig? get _draft {
    int? number(String text, int min, int max, int fallback) {
      final value = int.tryParse(text);
      if (value != null && value >= min && value <= max) return value;
      return _enabled ? null : fallback;
    }

    final port = number(_port.text, 1, 65535, 6379);
    final database = number(_database.text, 0, 2147483647, 0);
    final days = number(_days.text, 1, 104249991374, 30);
    if (port == null || database == null || days == null) return null;
    return _saved.copyWith(
      enabled: _enabled,
      type: _type,
      host: _host.text.trim(),
      port: port,
      tls: _tls,
      username: _username.text.trim(),
      database: database,
      endpoint: _endpoint.text.trim(),
      keyPrefix: _prefix.text.trim(),
      retentionDays: days,
    );
  }

  TranslationRoamingSecrets get _secrets => TranslationRoamingSecrets(
    redisPassword: _password.text,
    restToken: _token.text.trim(),
    preSharedKey: _psk.text.trim(),
  );

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _clearTestFeedback() {
    final feedback = _testFeedback;
    _testFeedback = null;
    feedback?.close();
  }

  void _showTestFeedback(String message, {Object? error}) {
    if (!mounted) return;
    final feedback = showTranslationTestFeedback(
      context,
      message: message,
      error: error,
      secrets: [_password.text, _token.text, _psk.text],
    );
    _testFeedback = feedback;
    unawaited(
      feedback.closed.then((_) {
        if (identical(_testFeedback, feedback)) _testFeedback = null;
      }),
    );
  }

  void _settingsChanged() {
    _clearTestFeedback();
    setState(() => _saveFailed = false);
  }

  bool _canSave(TranslationRoamingConfig? config) =>
      config != null &&
      config.hasSafeEndpoint &&
      (!_enabled ||
          (config.isValid &&
              config.supportedOnPlatform &&
              _secrets.isValidFor(config)));

  Future<void> _save() async {
    if (_busy || _loadFailed) return;
    final config = _draft;
    final secrets = _secrets;
    if (!_canSave(config)) {
      setState(() => _validationRequested = true);
      _message(L10n.of(context).invalidInput);
      return;
    }
    _clearTestFeedback();
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await widget.runtime.saveRoaming(config!, secrets);
      if (!mounted) return;
      _baseline = _formValues;
      context.go('/rooms/settings/translation');
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveFailed = true);
      _message(L10n.of(context).oopsSomethingWentWrong);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestBack() async {
    if (_busy || _confirmingExit) return;
    if (!_dirty) {
      context.go('/rooms/settings/translation');
      return;
    }
    _confirmingExit = true;
    try {
      final result = await showTranslationUnsavedChangesDialog(context);
      if (!mounted) return;
      switch (result) {
        case TranslationUnsavedChangesAction.save:
          await _save();
          return;
        case TranslationUnsavedChangesAction.discard:
          context.go('/rooms/settings/translation');
          return;
        case null:
          return;
      }
    } finally {
      _confirmingExit = false;
    }
  }

  void _setEnabled(bool value) {
    if (_busy || _loadFailed) return;
    _clearTestFeedback();
    setState(() {
      _enabled = value;
      _saveFailed = false;
      if (!value) {
        _passwordVisible = false;
        _tokenVisible = false;
        _pskVisible = false;
      }
    });
  }

  Future<void> _test() async {
    if (_fieldsDisabled) return;
    _clearTestFeedback();
    final l10n = L10n.of(context);
    final config = _draft;
    final secrets = _secrets;
    if (config == null ||
        !config.isValid ||
        !config.supportedOnPlatform ||
        !secrets.isValidFor(config)) {
      _showTestFeedback(l10n.invalidInput);
      return;
    }
    setState(() => _testing = true);
    try {
      await widget.runtime.testRoaming(config, secrets);
      _showTestFeedback(l10n.translationRoamingTestPassed);
    } catch (error) {
      _showTestFeedback(l10n.oopsSomethingWentWrong, error: error);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _copyKey() async {
    try {
      await Clipboard.setData(ClipboardData(text: _psk.text.trim()));
      if (mounted) _message(L10n.of(context).copiedToClipboard);
    } catch (_) {
      if (mounted) _message(L10n.of(context).oopsSomethingWentWrong);
    }
  }

  void _showUploadSaveHint() {
    _uploadTooltip.currentState?.ensureTooltipVisible();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final unsupported = !_saved.copyWith(type: _type).supportedOnPlatform;
    final draft = _draft;
    final invalidInput =
        _validationRequested && !_loading && !_loadFailed && !_canSave(draft);
    final uploadNeedsSave = _dirty || !_hasSavedKey;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestBack());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _requestBack),
          title: Text(l10n.translationRoaming),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton(
                onPressed: _busy || _loadFailed ? null : _save,
                child: _saving
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                value: _enabled,
                onChanged: _busy || _loadFailed ? null : _setEnabled,
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: LinearProgressIndicator(),
                ),
              if (_loadFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton.icon(
                    onPressed: _loading ? null : _loadSecrets,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.tryAgain),
                  ),
                ),
              if (_saveFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.oopsSomethingWentWrong,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy || _loadFailed ? null : _save,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.tryAgain),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    DropdownButtonFormField<TranslationRoamingType>(
                      initialValue: _type,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingConnectionType,
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
                      onChanged: _fieldsDisabled
                          ? null
                          : (value) {
                              if (value == null || value == _type) return;
                              _type = value;
                              _settingsChanged();
                            },
                    ),
                    if (_enabled && unsupported)
                      Text(
                        l10n.translationRoamingWebUnsupported,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    if (_type == TranslationRoamingType.redis) ...[
                      _RoamingFields(
                        children: [
                          TextField(
                            controller: _host,
                            enabled: !_fieldsDisabled,
                            autocorrect: false,
                            keyboardType: TextInputType.url,
                            decoration: InputDecoration(
                              labelText: l10n.translationRoamingHost,
                            ),
                            onChanged: (_) => _settingsChanged(),
                          ),
                          TextField(
                            controller: _port,
                            enabled: !_fieldsDisabled,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.translationRoamingPort,
                            ),
                            onChanged: (_) => _settingsChanged(),
                          ),
                          TextField(
                            controller: _username,
                            enabled: !_fieldsDisabled,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: l10n.translationRoamingUsername,
                            ),
                            onChanged: (_) => _settingsChanged(),
                          ),
                          TextField(
                            controller: _password,
                            enabled: !_fieldsDisabled,
                            obscureText: !_passwordVisible,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            decoration: InputDecoration(
                              labelText: l10n.password,
                              suffixIcon: IconButton(
                                tooltip: _passwordVisible
                                    ? l10n.showLess
                                    : l10n.showMore,
                                onPressed: _fieldsDisabled
                                    ? null
                                    : () => setState(
                                        () => _passwordVisible =
                                            !_passwordVisible,
                                      ),
                                icon: Icon(
                                  _passwordVisible
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                            onChanged: (_) => _settingsChanged(),
                          ),
                          TextField(
                            controller: _database,
                            enabled: !_fieldsDisabled,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.translationRoamingDatabase,
                            ),
                            onChanged: (_) => _settingsChanged(),
                          ),
                          DropdownButtonFormField<bool>(
                            initialValue: _tls,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'TLS'),
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
                            onChanged: _fieldsDisabled
                                ? null
                                : (value) {
                                    if (value == null || value == _tls) return;
                                    _tls = value;
                                    _settingsChanged();
                                  },
                          ),
                        ],
                      ),
                    ] else ...[
                      TextField(
                        controller: _endpoint,
                        enabled: !_fieldsDisabled,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: l10n.translationEndpoint,
                          hintText: 'https://example.upstash.io',
                        ),
                        onChanged: (_) => _settingsChanged(),
                      ),
                      TextField(
                        controller: _token,
                        enabled: !_fieldsDisabled,
                        obscureText: !_tokenVisible,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: l10n.translationRoamingToken,
                          suffixIcon: IconButton(
                            tooltip: _tokenVisible
                                ? l10n.showLess
                                : l10n.showMore,
                            onPressed: _fieldsDisabled
                                ? null
                                : () => setState(
                                    () => _tokenVisible = !_tokenVisible,
                                  ),
                            icon: Icon(
                              _tokenVisible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                        onChanged: (_) => _settingsChanged(),
                      ),
                    ],
                    _RoamingFields(
                      children: [
                        TextField(
                          controller: _prefix,
                          enabled: !_fieldsDisabled,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: l10n.translationRoamingKeyPrefix,
                          ),
                          onChanged: (_) => _settingsChanged(),
                        ),
                        TextField(
                          controller: _days,
                          enabled: !_fieldsDisabled,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.translationRoamingRetentionDays,
                          ),
                          onChanged: (_) => _settingsChanged(),
                        ),
                      ],
                    ),
                    TextField(
                      controller: _psk,
                      enabled: !_fieldsDisabled,
                      obscureText: !_pskVisible,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingPreSharedKey,
                        suffixIcon: IconButton(
                          tooltip: _pskVisible ? l10n.showLess : l10n.showMore,
                          onPressed: _fieldsDisabled
                              ? null
                              : () =>
                                    setState(() => _pskVisible = !_pskVisible),
                          icon: Icon(
                            _pskVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      onChanged: (_) => _settingsChanged(),
                    ),
                    if (invalidInput)
                      Text(
                        l10n.invalidInput,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    RoamingActions(
                      keyActions: [
                        OutlinedButton.icon(
                          onPressed: _fieldsDisabled
                              ? null
                              : () {
                                  _psk.text =
                                      TranslationRoamingCrypto.generatePreSharedKey();
                                  _settingsChanged();
                                },
                          icon: const Icon(Icons.key_outlined),
                          label: Text(l10n.translationRoamingGenerateKey),
                        ),
                        OutlinedButton.icon(
                          onPressed: _fieldsDisabled ? null : _copyKey,
                          icon: const Icon(Icons.copy_outlined),
                          label: Text(l10n.copyToClipboard),
                        ),
                      ],
                      testAction: OutlinedButton.icon(
                        onPressed: _fieldsDisabled || unsupported
                            ? null
                            : _test,
                        icon: _testing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.science_outlined),
                        label: Text(l10n.test),
                      ),
                      uploadAction: Tooltip(
                        key: _uploadTooltip,
                        message: !_fieldsDisabled && uploadNeedsSave
                            ? l10n.translationSaveBeforeUse
                            : '',
                        triggerMode: TooltipTriggerMode.manual,
                        excludeFromSemantics: !uploadNeedsSave,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: !_fieldsDisabled && uploadNeedsSave
                              ? _showUploadSaveHint
                              : null,
                          child: OutlinedButton.icon(
                            onPressed:
                                _fieldsDisabled ||
                                    uploadNeedsSave ||
                                    unsupported ||
                                    draft == null ||
                                    !draft.isValid ||
                                    !_secrets.isValidFor(draft) ||
                                    !widget.runtime.canUploadLocalTranslations
                                ? null
                                : () => context.push(
                                    '/rooms/settings/translation/roaming/upload',
                                  ),
                            icon: const Icon(Icons.cloud_upload_outlined),
                            label: Text(l10n.translationRoamingUploadLocal),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoamingFields extends StatelessWidget {
  final List<Widget> children;

  const _RoamingFields({required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = 12.0;
      final minimumWidth = MediaQuery.textScalerOf(context).scale(188);
      final width = constraints.maxWidth >= minimumWidth * 2 + spacing
          ? (constraints.maxWidth - spacing) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: spacing,
        runSpacing: 12,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}
