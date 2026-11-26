// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/translation/translation_roaming_upload.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'translation_roaming_upload_view.dart';
import 'translation_test_feedback.dart';

class TranslationRoamingUploadPage extends StatefulWidget {
  final TranslationRuntime? runtime;

  const TranslationRoamingUploadPage({super.key, this.runtime});

  @override
  State<TranslationRoamingUploadPage> createState() =>
      TranslationRoamingUploadController();
}

class TranslationRoamingUploadController
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
    unawaited(load());
  }

  Future<void> load() async {
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

  Future<void> upload() async {
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

  void back() {
    _session?.cancel();
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/rooms/settings/translation/roaming');
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

  TranslationRoamingUploadSession? get session => _session;
  TextEditingController get search => _search;
  bool get unavailable => _unavailable;
  bool get scanning =>
      _loading || _session?.phase == TranslationRoamingUploadPhase.scanning;
  bool get canUpload => _selected.isNotEmpty;

  List<({TranslationRoamingUploadRoom candidate, String name})>
  get visibleRooms {
    final l10n = L10n.of(context);
    final rooms = [
      for (final room in _session?.rooms ?? <TranslationRoamingUploadRoom>[])
        (candidate: room, name: _roomName(room, l10n)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final filter = _search.text.trim().toLowerCase();
    return rooms
        .where((room) => room.name.toLowerCase().contains(filter))
        .toList();
  }

  bool? get selectAllValue {
    final visible = visibleRooms;
    final selectedCount = visible
        .where((room) => _selected.contains(room.candidate.roomId))
        .length;
    if (selectedCount == 0) return false;
    return selectedCount == visible.length ? true : null;
  }

  void searchChanged(String value) => setState(() {});

  bool isSelected(String roomId) => _selected.contains(roomId);

  void changeSelection(String roomId, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(roomId);
        return;
      }
      _selected.remove(roomId);
    });
  }

  void toggleVisibleSelection(bool? value) {
    final ids = visibleRooms.map((room) => room.candidate.roomId).toSet();
    setState(() {
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
        return;
      }
      _selected.addAll(ids);
    });
  }

  void cancelUpload() => _session?.cancel();

  void onPopInvoked(bool didPop, Object? result) {
    if (!didPop) return;
    cancelUpload();
  }

  @override
  Widget build(BuildContext context) => TranslationRoamingUploadView(this);
}
