// SPDX-FileCopyrightText: 2026 OMF Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/custom_scroll_behaviour.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

typedef DatabaseRecoveryCallback =
    Future<void> Function(
      MatrixDatabaseInitializationFailure failure, {
      required bool reset,
    });

class DatabaseRecoveryApp extends StatelessWidget {
  final MatrixDatabaseInitializationFailure failure;
  final DatabaseRecoveryCallback recover;

  const DatabaseRecoveryApp({
    required this.failure,
    required this.recover,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ThemeBuilder(
      builder: (context, themeMode, primaryColor) => MaterialApp(
        title: AppSettings.applicationName.value,
        themeMode: themeMode,
        theme: FluffyThemes.buildTheme(context, Brightness.light, primaryColor),
        darkTheme: FluffyThemes.buildTheme(
          context,
          Brightness.dark,
          primaryColor,
        ),
        scrollBehavior: CustomScrollBehavior(),
        localizationsDelegates: [
          ...L10n.localizationsDelegates,
          ...GlobalMaterialLocalizations.delegates,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        supportedLocales: L10n.supportedLocales,
        home: _DatabaseRecoveryPage(failure: failure, recover: recover),
      ),
    );
  }
}

class _DatabaseRecoveryPage extends StatefulWidget {
  final MatrixDatabaseInitializationFailure failure;
  final DatabaseRecoveryCallback recover;

  const _DatabaseRecoveryPage({required this.failure, required this.recover});

  @override
  State<_DatabaseRecoveryPage> createState() => _DatabaseRecoveryPageState();
}

class _DatabaseRecoveryPageState extends State<_DatabaseRecoveryPage> {
  late MatrixDatabaseInitializationFailure _failure = widget.failure;
  Object? _operationError;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _confirmReset());
  }

  Future<void> _confirmReset() async {
    if (_busy || !mounted) return;
    final l10n = L10n.of(context);
    final result = await showOkCancelAlertDialog(
      context: context,
      title: l10n.databaseInitializationFailed,
      message: l10n.databaseInitializationFailedBody(_failure.clientName),
      okLabel: l10n.reset,
      cancelLabel: l10n.cancel,
      isDestructive: true,
    );
    if (result == OkCancelResult.ok) await _recover(reset: true);
  }

  Future<void> _recover({required bool reset}) async {
    if (_busy) return;
    var recovered = false;
    setState(() {
      _busy = true;
      _operationError = null;
    });
    try {
      await widget.recover(_failure, reset: reset);
      recovered = true;
    } catch (error, stackTrace) {
      Logs().e('Unable to recover the local archive', error, stackTrace);
      if (!mounted) return;
      setState(() {
        if (error is MatrixDatabaseInitializationFailure) {
          _failure = error;
          _operationError = error.cause;
        } else {
          _operationError = error;
        }
      });
    } finally {
      if (!recovered && mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final colorScheme = Theme.of(context).colorScheme;
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
                  Icon(
                    Icons.storage_rounded,
                    size: 64,
                    color: colorScheme.error,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.databaseInitializationFailed,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.databaseInitializationFailedBody(_failure.clientName),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    (_operationError ?? _failure.cause).toString(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (_busy)
                    const CircularProgressIndicator()
                  else
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton(
                          onPressed: () => _recover(reset: false),
                          child: Text(l10n.tryAgain),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: colorScheme.error,
                            foregroundColor: colorScheme.onError,
                          ),
                          onPressed: _confirmReset,
                          child: Text(l10n.reset),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
