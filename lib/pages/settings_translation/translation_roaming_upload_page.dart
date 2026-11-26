// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'translation_test_feedback.dart';

class TranslationRoamingUploadPage extends StatefulWidget {
  final TranslationRuntime? runtime;

  const TranslationRoamingUploadPage({super.key, this.runtime});

  @override
  State<TranslationRoamingUploadPage> createState() =>
      _TranslationRoamingUploadPageState();
}

class _TranslationRoamingUploadPageState
    extends State<TranslationRoamingUploadPage> {
  final _search = TextEditingController();
  final _selected = <String>{};
  TranslationRoamingUploadSession? _session;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _feedback;
  bool _loading = true;
  bool _unavailable = false;
  int _generation = 0;

  TranslationRuntime get _runtime =>
      widget.runtime ?? TranslationRuntime.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _feedback?.close();
    _feedback = null;
    _releaseSession();
    setState(() {
      _loading = true;
      _unavailable = false;
      _selected.clear();
      _search.clear();
    });
    try {
      final session = await _runtime.createRoamingUploadSession();
      if (!mounted || generation != _generation) {
        session.dispose();
        return;
      }
      _session = session;
      session.addListener(_sessionChanged);
      setState(() => _loading = false);
      await session.scan();
    } catch (_) {
      if (!mounted || generation != _generation) {
        return;
      }
      _releaseSession();
      setState(() {
        _loading = false;
        _unavailable = true;
      });
    }
  }

  void _sessionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _releaseSession() {
    final session = _session;
    _session = null;
    session?.removeListener(_sessionChanged);
    session?.dispose();
  }

  Future<void> _upload() async {
    final session = _session;
    if (session == null || _selected.isEmpty) {
      return;
    }
    _feedback?.close();
    await session.upload(Set.of(_selected));
    if (!mounted || !identical(session, _session) || session.error == null) {
      return;
    }
    _feedback = showTranslationTestFeedback(
      context,
      message: L10n.of(context).oopsSomethingWentWrong,
      error: session.error,
    );
  }

  void _back() {
    _session?.cancel();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/rooms/settings/translation/roaming');
    }
  }

  @override
  void dispose() {
    ++_generation;
    _feedback?.close();
    _releaseSession();
    _search.dispose();
    super.dispose();
  }

  String _roomName(TranslationRoamingUploadRoom candidate, L10n l10n) {
    for (final userId in candidate.userIds) {
      final room = _runtime.roamingUploadRoom(userId, candidate.roomId);
      if (room != null) {
        return room.getLocalizedDisplayname(MatrixLocals(l10n));
      }
    }
    return candidate.roomId;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final session = _session;
    final scanning =
        _loading || session?.phase == TranslationRoamingUploadPhase.scanning;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _session?.cancel();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text(l10n.translationRoamingUploadLocal),
        ),
        body: MaxWidthBody(
          withScrolling: false,
          child: Builder(
            builder: (context) {
              if (scanning) {
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(l10n.translationRoamingUploadScanning),
                        const SizedBox(height: 8),
                        TextButton(onPressed: _back, child: Text(l10n.cancel)),
                      ],
                    ),
                  ),
                );
              }
              if (_unavailable ||
                  session == null ||
                  (session.phase == TranslationRoamingUploadPhase.ready &&
                      session.rooms.isEmpty)) {
                final message = _unavailable || session == null
                    ? l10n.translationRoamingUploadUnavailable
                    : l10n.translationRoamingUploadEmpty;
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(message),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.tryAgain),
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (session.phase != TranslationRoamingUploadPhase.ready) {
                final uploading =
                    session.phase == TranslationRoamingUploadPhase.uploading;
                final failed =
                    session.phase == TranslationRoamingUploadPhase.failed;
                final stopped =
                    session.phase == TranslationRoamingUploadPhase.stopped;
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (uploading) ...[
                          LinearProgressIndicator(
                            value: session.total == 0
                                ? null
                                : session.processed / session.total,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l10n.translationRoamingUploadProgress(
                              session.processed,
                              session.total,
                            ),
                          ),
                        ] else if (failed)
                          Text(l10n.oopsSomethingWentWrong)
                        else if (stopped)
                          Text(l10n.translationRoamingUploadStopped),
                        const SizedBox(height: 12),
                        Text(
                          l10n.translationRoamingUploadResult(
                            session.uploaded,
                            session.existing,
                            session.skipped,
                            session.failed,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (uploading)
                          OutlinedButton(
                            onPressed: session.cancel,
                            child: Text(l10n.cancel),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh),
                            label: Text(l10n.tryAgain),
                          ),
                      ],
                    ),
                  ),
                );
              }
              final rooms =
                  [
                    for (final room in session.rooms)
                      (candidate: room, name: _roomName(room, l10n)),
                  ]..sort(
                    (a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                  );
              final filter = _search.text.trim().toLowerCase();
              final visible = rooms
                  .where((room) => room.name.toLowerCase().contains(filter))
                  .toList();
              final selectedVisible = visible
                  .where((room) => _selected.contains(room.candidate.roomId))
                  .length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  l10n.translationRoamingUploadDescription,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: TextField(
                                  controller: _search,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    hintText: l10n.search,
                                    prefixIcon: const Icon(
                                      Icons.search_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              CheckboxListTile.adaptive(
                                title: Text(
                                  l10n.translationRoamingUploadSelectAll,
                                ),
                                tristate: true,
                                value: selectedVisible == 0
                                    ? false
                                    : selectedVisible == visible.length
                                    ? true
                                    : null,
                                onChanged: visible.isEmpty
                                    ? null
                                    : (_) => setState(() {
                                        final ids = visible.map(
                                          (room) => room.candidate.roomId,
                                        );
                                        if (selectedVisible == visible.length) {
                                          _selected.removeAll(ids);
                                        } else {
                                          _selected.addAll(ids);
                                        }
                                      }),
                              ),
                            ],
                          ),
                        ),
                        SliverList.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final room = visible[index];
                            final id = room.candidate.roomId;
                            return CheckboxListTile.adaptive(
                              key: ValueKey(id),
                              title: Text(room.name),
                              subtitle: Text(
                                l10n.translationRoamingUploadCount(
                                  room.candidate.count,
                                ),
                              ),
                              value: _selected.contains(id),
                              onChanged: (value) => setState(() {
                                if (value == true) {
                                  _selected.add(id);
                                } else {
                                  _selected.remove(id);
                                }
                              }),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _selected.isEmpty ? null : _upload,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: Text(l10n.translationRoamingUploadLocal),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
