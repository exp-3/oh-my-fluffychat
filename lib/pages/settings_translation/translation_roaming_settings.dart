// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Edits a local draft. No connection is opened until a test or saved use.
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
  bool _saving = false;
  bool _testing = false;

  bool get _busy => _loading || _saving || _testing;

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
      final secrets = await widget.runtime.readRoamingSecrets();
      if (!mounted) return;
      _password.text = secrets.redisPassword;
      _token.text = secrets.restToken;
      _psk.text = secrets.preSharedKey.isEmpty
          ? TranslationRoamingCrypto.generatePreSharedKey()
          : secrets.preSharedKey;
      _loadFailed = false;
    } catch (_) {
      if (!mounted) return;
      _loadFailed = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  TranslationRoamingConfig? get _draft {
    final port = int.tryParse(_port.text);
    final database = int.tryParse(_database.text);
    final days = int.tryParse(_days.text);
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        database == null ||
        database < 0 ||
        database > 2147483647 ||
        days == null ||
        days < 1 ||
        days > 104249991374 ||
        _prefix.text.trim().isEmpty) {
      return null;
    }
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

  Future<void> _save() async {
    if (_busy || _loadFailed) return;
    final l10n = L10n.of(context);
    final config = _draft;
    final secrets = _secrets;
    if (config == null ||
        (config.enabled &&
            (!config.isValid ||
                !config.supportedOnPlatform ||
                !secrets.isValidFor(config)))) {
      _message(l10n.invalidInput);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.runtime.saveRoaming(config, secrets);
      if (!mounted) return;
      _saved = config;
      _message(l10n.translationRoamingSaved);
    } catch (_) {
      _message(l10n.oopsSomethingWentWrong);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    if (_busy || _loadFailed) return;
    final l10n = L10n.of(context);
    final config = _draft;
    final secrets = _secrets;
    if (config == null ||
        !config.isValid ||
        !config.supportedOnPlatform ||
        !secrets.isValidFor(config)) {
      _message(l10n.invalidInput);
      return;
    }
    setState(() => _testing = true);
    try {
      await widget.runtime.testRoaming(config, secrets);
      _message(l10n.translationRoamingTestPassed);
    } catch (_) {
      _message(l10n.oopsSomethingWentWrong);
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

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final unsupported = !_saved.copyWith(type: _type).supportedOnPlatform;
    return Column(
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
          onChanged: _busy || _loadFailed
              ? null
              : (value) => setState(() => _enabled = value),
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
                onChanged: _busy || _loadFailed
                    ? null
                    : (value) {
                        if (value != null) setState(() => _type = value);
                      },
              ),
              if (unsupported)
                Text(
                  l10n.translationRoamingWebUnsupported,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (_type == TranslationRoamingType.redis) ...[
                _RoamingFields(
                  children: [
                    TextField(
                      controller: _host,
                      enabled: !_busy && !_loadFailed,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingHost,
                      ),
                    ),
                    TextField(
                      controller: _port,
                      enabled: !_busy && !_loadFailed,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingPort,
                      ),
                    ),
                    TextField(
                      controller: _username,
                      enabled: !_busy && !_loadFailed,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingUsername,
                      ),
                    ),
                    TextField(
                      controller: _password,
                      enabled: !_busy && !_loadFailed,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(labelText: l10n.password),
                    ),
                    TextField(
                      controller: _database,
                      enabled: !_busy && !_loadFailed,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.translationRoamingDatabase,
                      ),
                    ),
                  ],
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('TLS'),
                  value: _tls,
                  onChanged: _busy || _loadFailed
                      ? null
                      : (value) => setState(() => _tls = value),
                ),
              ] else ...[
                TextField(
                  controller: _endpoint,
                  enabled: !_busy && !_loadFailed,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l10n.translationEndpoint,
                    hintText: 'https://example.upstash.io',
                  ),
                ),
                TextField(
                  controller: _token,
                  enabled: !_busy && !_loadFailed,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: l10n.translationRoamingToken,
                  ),
                ),
              ],
              _RoamingFields(
                children: [
                  TextField(
                    controller: _prefix,
                    enabled: !_busy && !_loadFailed,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.translationRoamingKeyPrefix,
                    ),
                  ),
                  TextField(
                    controller: _days,
                    enabled: !_busy && !_loadFailed,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.translationRoamingRetentionDays,
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _psk,
                enabled: !_busy && !_loadFailed,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: l10n.translationRoamingPreSharedKey,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy || _loadFailed
                        ? null
                        : () {
                            _psk.text =
                                TranslationRoamingCrypto.generatePreSharedKey();
                          },
                    icon: const Icon(Icons.key_outlined),
                    label: Text(l10n.translationRoamingGenerateKey),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _loadFailed ? null : _copyKey,
                    icon: const Icon(Icons.copy_outlined),
                    label: Text(l10n.copyToClipboard),
                  ),
                ],
              ),
              Text(l10n.translationRoamingSaveHint),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy || _loadFailed || unsupported
                        ? null
                        : _test,
                    child: _testing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.test),
                  ),
                  FilledButton(
                    onPressed: _busy || _loadFailed ? null : _save,
                    child: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.saveChanges),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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
