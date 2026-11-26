// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'translation_roaming_settings_view.dart';
import 'translation_test_feedback.dart';
import 'translation_unsaved_changes_dialog.dart';

class TranslationRoamingSettings extends StatefulWidget {
  final TranslationRuntime runtime;

  const TranslationRoamingSettings({super.key, required this.runtime});

  @override
  State<TranslationRoamingSettings> createState() =>
      TranslationRoamingSettingsController();
}

class TranslationRoamingSettingsController
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
    unawaited(loadSecrets());
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

  Future<void> loadSecrets() async {
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

  void settingsChanged() {
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

  Future<void> save() async {
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

  Future<void> requestBack() async {
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
          await save();
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

  void setEnabled(bool value) {
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

  Future<void> test() async {
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

  Future<void> copyKey() async {
    try {
      await Clipboard.setData(ClipboardData(text: _psk.text.trim()));
      if (mounted) _message(L10n.of(context).copiedToClipboard);
    } catch (_) {
      if (mounted) _message(L10n.of(context).oopsSomethingWentWrong);
    }
  }

  void showUploadSaveHint() {
    _uploadTooltip.currentState?.ensureTooltipVisible();
  }

  bool get busy => _busy;
  bool get fieldsDisabled => _fieldsDisabled;
  bool get loading => _loading;
  bool get loadFailed => _loadFailed;
  bool get saving => _saving;
  bool get saveFailed => _saveFailed;
  bool get testing => _testing;
  bool get enabled => _enabled;
  bool get tls => _tls;
  TranslationRoamingType get type => _type;
  bool get passwordVisible => _passwordVisible;
  bool get tokenVisible => _tokenVisible;
  bool get pskVisible => _pskVisible;
  GlobalKey<TooltipState> get uploadTooltip => _uploadTooltip;
  TextEditingController get host => _host;
  TextEditingController get port => _port;
  TextEditingController get username => _username;
  TextEditingController get password => _password;
  TextEditingController get database => _database;
  TextEditingController get endpoint => _endpoint;
  TextEditingController get token => _token;
  TextEditingController get prefix => _prefix;
  TextEditingController get psk => _psk;
  TextEditingController get days => _days;
  bool get unsupported => !_saved.copyWith(type: _type).supportedOnPlatform;
  bool get invalidInput =>
      _validationRequested && !_loading && !_loadFailed && !_canSave(_draft);
  bool get uploadNeedsSave => _dirty || !_hasSavedKey;

  bool get canUpload {
    if (_fieldsDisabled || uploadNeedsSave || unsupported) return false;
    final draft = _draft;
    return draft != null &&
        draft.isValid &&
        _secrets.isValidFor(draft) &&
        widget.runtime.canUploadLocalTranslations;
  }

  void changeType(TranslationRoamingType? value) {
    if (value == null || value == _type) return;
    _type = value;
    settingsChanged();
  }

  void changeTls(bool? value) {
    if (value == null || value == _tls) return;
    _tls = value;
    settingsChanged();
  }

  void togglePasswordVisibility() =>
      setState(() => _passwordVisible = !_passwordVisible);

  void toggleTokenVisibility() =>
      setState(() => _tokenVisible = !_tokenVisible);

  void togglePskVisibility() => setState(() => _pskVisible = !_pskVisible);

  void generateKey() {
    _psk.text = TranslationRoamingCrypto.generatePreSharedKey();
    settingsChanged();
  }

  void openUpload() =>
      unawaited(context.push('/rooms/settings/translation/roaming/upload'));

  @override
  Widget build(BuildContext context) => TranslationRoamingSettingsView(this);
}
