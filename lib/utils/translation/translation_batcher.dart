// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:uuid/uuid.dart';

import 'translation_api_client.dart';
import 'translation_models.dart';

class TranslationBatchKey {
  final String roomId;
  final String providerId;
  final TranslationProtocol protocol;
  final String model;
  final String sourceLanguage;
  final String targetLanguage;
  final int promptRevision;
  final int runtimeRevision;

  const TranslationBatchKey({
    required this.roomId,
    required this.providerId,
    required this.protocol,
    required this.model,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.promptRevision,
    required this.runtimeRevision,
  });

  @override
  bool operator ==(Object other) =>
      other is TranslationBatchKey &&
      roomId == other.roomId &&
      providerId == other.providerId &&
      protocol == other.protocol &&
      model == other.model &&
      sourceLanguage == other.sourceLanguage &&
      targetLanguage == other.targetLanguage &&
      promptRevision == other.promptRevision &&
      runtimeRevision == other.runtimeRevision;

  @override
  int get hashCode => Object.hash(
    roomId,
    providerId,
    protocol,
    model,
    sourceLanguage,
    targetLanguage,
    promptRevision,
    runtimeRevision,
  );
}

class TranslationBatchTask {
  final String requestId;
  final String source;
  final String messageType;
  final bool Function() isValid;
  final Object? metadata;
  final Completer<String> completer = Completer<String>();

  TranslationBatchTask({
    required this.source,
    this.messageType = 'm.text',
    required this.isValid,
    this.metadata,
    String? requestId,
  }) : requestId = requestId ?? const Uuid().v4();
}

typedef TranslationBatchSender =
    Future<Map<String, String>> Function(
      TranslationBatchKey key,
      Map<String, TranslationRequestMessage> messages,
      bool Function() isStillValid,
    );

typedef TranslationBatchPersister =
    Future<void> Function(Map<TranslationBatchTask, String> results);

class TranslationBatcher {
  final TranslationBatchSender sender;
  final TranslationBatchSettings Function() settings;
  final TranslationBatchPersister? persister;
  final Map<TranslationBatchKey, List<TranslationBatchTask>> _pending = {};
  final Map<TranslationBatchKey, Timer> _timers = {};
  bool _disposed = false;

  TranslationBatcher({
    required this.sender,
    required this.settings,
    this.persister,
  });

  Future<String> add(TranslationBatchKey key, TranslationBatchTask task) {
    if (_disposed) {
      return Future.error(StateError('Translation batcher is disposed'));
    }
    _pending.putIfAbsent(key, () => []).add(task);
    _schedule(key);
    return task.completer.future;
  }

  void settingsChanged() {
    for (final key in _pending.keys.toList()) {
      _timers.remove(key)?.cancel();
      _schedule(key);
    }
  }

  void cancelPending([Object? error]) {
    final reason = error ?? StateError('Translation runtime changed');
    for (final task in _pending.values.expand((tasks) => tasks)) {
      if (!task.completer.isCompleted) task.completer.completeError(reason);
    }
    _pending.clear();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  void dispose() {
    _disposed = true;
    cancelPending(StateError('Translation batcher is disposed'));
  }

  void _schedule(TranslationBatchKey key) {
    if (_timers.containsKey(key)) return;
    final delay = settings().mergeWindowMs;
    if (delay == 0) {
      scheduleMicrotask(() => _flush(key));
      return;
    }
    _timers[key] = Timer(Duration(milliseconds: delay), () => _flush(key));
  }

  Future<void> _flush(TranslationBatchKey key) async {
    _timers.remove(key)?.cancel();
    final tasks = _pending.remove(key);
    if (tasks == null || tasks.isEmpty) return;
    final valid = tasks.where((task) => task.isValid()).toList();
    for (final task in tasks.where((task) => !task.isValid())) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(StateError('Translation task expired'));
      }
    }
    final current = settings();
    final batches = _partition(valid, current);
    for (final batch in batches) {
      await _sendWithFallback(key, batch, current.malformedResponseRetries);
    }
  }

  List<List<TranslationBatchTask>> _partition(
    List<TranslationBatchTask> tasks,
    TranslationBatchSettings limits,
  ) {
    final result = <List<TranslationBatchTask>>[];
    var current = <TranslationBatchTask>[];
    var characters = 0;
    for (final task in tasks) {
      final length = unicodeCodePointLength(task.source);
      if (current.isNotEmpty &&
          (current.length >= limits.maxMessages ||
              characters + length > limits.maxCharacters)) {
        result.add(current);
        current = [];
        characters = 0;
      }
      current.add(task);
      characters += length;
      if (length > limits.maxCharacters) {
        result.add(current);
        current = [];
        characters = 0;
      }
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }

  Future<void> _sendWithFallback(
    TranslationBatchKey key,
    List<TranslationBatchTask> tasks,
    int retries,
  ) async {
    try {
      Map<String, String>? result;
      for (var attempt = 0; attempt <= retries; attempt++) {
        try {
          if (!tasks.every((task) => task.isValid())) {
            throw StateError('Translation task expired');
          }
          final taskIds = tasks.map((task) => task.requestId).toList();
          if (taskIds.toSet().length != taskIds.length) {
            throw const TranslationProtocolException(
              'Duplicate translation request ID',
            );
          }
          result = await sender(key, {
            for (final task in tasks)
              task.requestId: TranslationRequestMessage(
                text: task.source,
                messageType: task.messageType,
              ),
          }, () => tasks.every((task) => task.isValid()));
          final expectedIds = tasks.map((task) => task.requestId).toSet();
          if (result.length != expectedIds.length ||
              expectedIds.length != tasks.length ||
              result.keys.toSet().length != expectedIds.length ||
              !result.keys.toSet().containsAll(expectedIds)) {
            throw const TranslationProtocolException(
              'Translation IDs are incomplete or contain extra items',
            );
          }
          break;
        } on TranslationProtocolException {
          if (attempt == retries) rethrow;
        } on FormatException {
          if (attempt == retries) rethrow;
        }
      }
      if (result == null) throw StateError('Translation returned no result');
      final completedResults = <TranslationBatchTask, String>{};
      for (final task in tasks) {
        if (!task.isValid()) {
          if (!task.completer.isCompleted) {
            task.completer.completeError(
              StateError('Translation task expired'),
            );
          }
          continue;
        }
        final value = result[task.requestId];
        if (value == null) {
          throw const TranslationProtocolException('Missing result ID');
        }
        completedResults[task] = value;
      }
      if (completedResults.isNotEmpty) {
        await persister?.call(completedResults);
      }
      for (final entry in completedResults.entries) {
        if (!entry.key.isValid()) {
          if (!entry.key.completer.isCompleted) {
            entry.key.completer.completeError(
              StateError('Translation task expired'),
            );
          }
        } else if (!entry.key.completer.isCompleted) {
          entry.key.completer.complete(entry.value);
        }
      }
    } on TranslationProtocolException catch (error) {
      if (tasks.length > 1) {
        for (final task in tasks) {
          await _sendWithFallback(key, [task], 0);
        }
        return;
      }
      _completeError(tasks, error);
    } on FormatException catch (error) {
      if (tasks.length > 1) {
        for (final task in tasks) {
          await _sendWithFallback(key, [task], 0);
        }
        return;
      }
      _completeError(tasks, error);
    } catch (error, stackTrace) {
      for (final task in tasks) {
        if (!task.completer.isCompleted) {
          task.completer.completeError(error, stackTrace);
        }
      }
    }
  }

  static void _completeError(List<TranslationBatchTask> tasks, Object error) {
    for (final task in tasks) {
      if (!task.completer.isCompleted) task.completer.completeError(error);
    }
  }
}
