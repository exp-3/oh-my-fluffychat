// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'translation_cache.dart';
import 'translation_languages.dart';
import 'translation_roaming.dart';

enum TranslationRoamingUploadPhase {
  scanning,
  ready,
  uploading,
  complete,
  stopped,
  failed,
}

class TranslationRoamingUploadRoom {
  final String roomId;
  final Set<String> userIds;
  final int count;

  const TranslationRoamingUploadRoom({
    required this.roomId,
    required this.userIds,
    required this.count,
  });
}

/// One explicit import, with its own connection and no persistent job state.
class TranslationRoamingUploadSession extends ChangeNotifier {
  final TranslationCache cache;
  final TranslationSourceResolver resolveSource;
  final TranslationRoamingService service;
  final Listenable lifecycle;
  final bool Function() isCurrent;
  final bool Function(TranslationCacheExportReference) canAccess;
  final VoidCallback? onDispose;
  final DateTime Function() _now;
  final _candidates = <String, List<TranslationCacheExportReference>>{};
  List<TranslationRoamingUploadRoom> _rooms = const [];
  List<TranslationCacheExportReference> _selectedReferences = const [];
  TranslationRoamingUploadPhase _phase = TranslationRoamingUploadPhase.scanning;
  bool _disposed = false;
  int _total = 0;
  int _processed = 0;
  int _uploaded = 0;
  int _existing = 0;
  int _skipped = 0;
  int _failed = 0;
  TranslationRoamingException? _error;

  TranslationRoamingUploadSession({
    required this.cache,
    required this.resolveSource,
    required this.service,
    required this.lifecycle,
    required this.isCurrent,
    required this.canAccess,
    this.onDispose,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    lifecycle.addListener(_checkCurrent);
  }

  TranslationRoamingUploadPhase get phase => _phase;
  List<TranslationRoamingUploadRoom> get rooms => _rooms;
  int get total => _total;
  int get processed => _processed;
  int get uploaded => _uploaded;
  int get existing => _existing;
  int get skipped => _skipped;
  int get failed => _failed;
  TranslationRoamingException? get error => _error;

  bool get _active =>
      !_disposed &&
      _phase != TranslationRoamingUploadPhase.stopped &&
      isCurrent() &&
      _selectedReferences.every(canAccess);

  static String _identity(TranslationCacheExportEntry entry) => sha256
      .convert(
        utf8.encode(jsonEncode([entry.key.source, entry.key.targetLanguage])),
      )
      .toString();

  /// Round down the remaining lifetime, rather than extending it at boundaries.
  int remainingSeconds(DateTime messageTimestamp) {
    final window = (service.config.ttlSeconds + 7 * 86400).clamp(
      1,
      9007199254740991,
    );
    final age =
        _now().millisecondsSinceEpoch - messageTimestamp.millisecondsSinceEpoch;
    return window - (age <= 0 ? 0 : (age + 999) ~/ 1000);
  }

  void _checkCurrent() {
    if (!_active && !_disposed) cancel();
  }

  Future<void> scan() async {
    if (_disposed || _phase != TranslationRoamingUploadPhase.scanning) return;
    final identitiesByRoom = <String, Set<String>>{};
    final ownersByRoom = <String, Set<String>>{};
    try {
      Object? cursor;
      do {
        if (!_active) {
          cancel();
          return;
        }
        final page = await cache.exportPage(
          resolveSource,
          after: cursor,
          isValid: () => _active,
        );
        if (!_active) {
          cancel();
          return;
        }
        for (final entry in page.entries) {
          if (!canAccess(entry.reference) ||
              !isTranslationLanguage(entry.key.targetLanguage) ||
              remainingSeconds(entry.messageTimestamp) <= 0) {
            continue;
          }
          final identity = _identity(entry);
          _candidates.putIfAbsent(identity, () => []).add(entry.reference);
          identitiesByRoom
              .putIfAbsent(entry.key.roomId, () => {})
              .add(identity);
          ownersByRoom
              .putIfAbsent(entry.key.roomId, () => {})
              .add(entry.key.userId);
        }
        cursor = page.nextCursor;
        // Let cancellation, navigation and Matrix sync run between pages.
        await Future<void>.delayed(Duration.zero);
      } while (cursor != null);
      if (!_active) {
        cancel();
        return;
      }
      _rooms = List.unmodifiable([
        for (final room in identitiesByRoom.entries)
          TranslationRoamingUploadRoom(
            roomId: room.key,
            userIds: Set.unmodifiable(ownersByRoom[room.key]!),
            count: room.value.length,
          ),
      ]);
      _phase = TranslationRoamingUploadPhase.ready;
    } catch (_) {
      if (!_active) {
        cancel();
        return;
      }
      _phase = TranslationRoamingUploadPhase.failed;
      service.dispose();
      _clearCandidates();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> upload(Set<String> roomIds) async {
    if (_disposed ||
        _phase != TranslationRoamingUploadPhase.ready ||
        roomIds.isEmpty) {
      return;
    }
    final groups = [
      for (final group in _candidates.entries)
        if (group.value.any((ref) => roomIds.contains(ref.roomId)))
          (
            identity: group.key,
            references: group.value
                .where((ref) => roomIds.contains(ref.roomId))
                .toList(),
          ),
    ];
    _selectedReferences = [for (final group in groups) ...group.references];
    if (!_active) {
      cancel();
      return;
    }
    _total = groups.length;
    _phase = TranslationRoamingUploadPhase.uploading;
    notifyListeners();
    try {
      for (final group in groups) {
        if (!_active) break;
        final entries = <TranslationCacheExportEntry>[];
        for (final reference in group.references) {
          if (!_active) break;
          final entry = await cache.refreshExportEntry(
            reference,
            resolveSource,
            isValid: () => _active,
          );
          if (entry != null &&
              _identity(entry) == group.identity &&
              remainingSeconds(entry.messageTimestamp) > 0) {
            entries.add(entry);
          }
        }
        if (!_active) break;
        entries.sort(_compareTranslations);
        final TranslationRoamingUploadResult result;
        if (entries.isEmpty) {
          result = const TranslationRoamingUploadResult(
            TranslationRoamingUploadStatus.skipped,
          );
        } else {
          final entry = entries.last;
          int ttlSeconds() {
            var ttl = 0;
            for (final current in entries) {
              if (!cache.isExportReferenceCurrent(current.reference) ||
                  !canAccess(current.reference)) {
                continue;
              }
              final remaining = remainingSeconds(current.messageTimestamp);
              if (remaining > ttl) ttl = remaining;
            }
            return ttl;
          }

          result = await service.uploadIfAbsent(
            source: entry.key.source,
            targetLanguage: entry.key.targetLanguage,
            translation: entry.translation,
            ttlSeconds: ttlSeconds,
            isValid: () =>
                _active && cache.isExportReferenceCurrent(entry.reference),
          );
        }
        if (_disposed) return;
        switch (result.status) {
          case TranslationRoamingUploadStatus.uploaded:
            _uploaded++;
          case TranslationRoamingUploadStatus.existing:
            _existing++;
          case TranslationRoamingUploadStatus.skipped:
            _skipped++;
          case TranslationRoamingUploadStatus.failed:
            _failed++;
            _error = result.error;
        }
        _processed++;
        notifyListeners();
        if (result.error?.error == TranslationRoamingError.authentication ||
            result.error?.error == TranslationRoamingError.configuration) {
          _phase = TranslationRoamingUploadPhase.failed;
          service.dispose();
          _clearCandidates();
          notifyListeners();
          return;
        }
      }
      if (!_active) {
        cancel();
        return;
      }
      _phase = TranslationRoamingUploadPhase.complete;
    } catch (_) {
      if (!_active) {
        cancel();
        return;
      }
      _phase = TranslationRoamingUploadPhase.failed;
    }
    service.dispose();
    _clearCandidates();
    if (!_disposed) notifyListeners();
  }

  static int _compareTranslations(
    TranslationCacheExportEntry a,
    TranslationCacheExportEntry b,
  ) {
    final written = (a.writtenAt ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(b.writtenAt ?? DateTime.fromMillisecondsSinceEpoch(0));
    if (written != 0) return written;
    final message = a.messageTimestamp.compareTo(b.messageTimestamp);
    if (message != 0) return message;
    return a.reference.referenceKey.compareTo(b.reference.referenceKey);
  }

  void cancel() {
    if (_disposed ||
        _phase == TranslationRoamingUploadPhase.stopped ||
        _phase == TranslationRoamingUploadPhase.complete ||
        _phase == TranslationRoamingUploadPhase.failed) {
      return;
    }
    _phase = TranslationRoamingUploadPhase.stopped;
    service.dispose();
    _clearCandidates();
    notifyListeners();
  }

  void _clearCandidates() {
    _candidates.clear();
    _selectedReferences = const [];
  }

  @override
  void dispose() {
    _disposed = true;
    lifecycle.removeListener(_checkCurrent);
    service.dispose();
    _clearCandidates();
    onDispose?.call();
    super.dispose();
  }
}
