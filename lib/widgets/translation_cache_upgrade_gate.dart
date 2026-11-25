// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class TranslationCacheUpgradeGate extends StatefulWidget {
  final List<Client> clients;
  final VoidCallback onReady;
  final Widget child;

  const TranslationCacheUpgradeGate({
    required this.clients,
    required this.onReady,
    required this.child,
    super.key,
  });

  @override
  State<TranslationCacheUpgradeGate> createState() =>
      _TranslationCacheUpgradeGateState();
}

class _TranslationCacheUpgradeGateState
    extends State<TranslationCacheUpgradeGate> {
  var _ready = false;
  var _upgrading = false;
  var _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _upgrading = false;
      _error = null;
    });
    try {
      await TranslationRuntime.instance.prepareCacheForStartup(
        widget.clients,
        onUpgrade: () async {
          if (!mounted) return;
          setState(() => _upgrading = true);
          await WidgetsBinding.instance.endOfFrame;
        },
      );
      if (!mounted) return;
      widget.onReady();
      setState(() => _ready = true);
    } catch (error, stackTrace) {
      Logs().e('Unable to upgrade the translation cache', error, stackTrace);
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    final l10n = L10n.of(context);
    final error = _error;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (error == null) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 24),
                    Text(
                      _upgrading
                          ? l10n.translationCacheUpgrading
                          : l10n.loadingPleaseWait,
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
                    Text(
                      l10n.translationCacheUpgradeFailed,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      error.toString(),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _prepare,
                      child: Text(l10n.tryAgain),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
