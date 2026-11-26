// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/translation/translation_api_client.dart';
import 'package:fluffychat/utils/translation/translation_batcher.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:flutter_test/flutter_test.dart';

const key = TranslationBatchKey(
  roomId: '!room:example.test',
  providerId: 'provider',
  protocol: TranslationProtocol.responses,
  model: 'model',
  sourceLanguage: 'auto',
  targetLanguage: 'en',
  promptRevision: 1,
  runtimeRevision: 1,
);

void main() {
  test('reasoning settings separate request batches', () async {
    TranslationBatchKey configuredKey({
      TranslationReasoningEffort reasoningEffort =
          TranslationReasoningEffort.high,
    }) => TranslationBatchKey(
      roomId: key.roomId,
      providerId: key.providerId,
      protocol: key.protocol,
      model: key.model,
      reasoningEffort: reasoningEffort,
      sourceLanguage: key.sourceLanguage,
      targetLanguage: key.targetLanguage,
      promptRevision: key.promptRevision,
      runtimeRevision: key.runtimeRevision,
    );
    final batches = <TranslationBatchKey, List<String>>{};
    final batcher = TranslationBatcher(
      settings: () => const TranslationBatchSettings(mergeWindowMs: 0),
      sender: (batchKey, messages, _) async {
        batches[batchKey] = messages.values
            .map((message) => message.text)
            .toList();
        return messages.map((id, message) => MapEntry(id, message.text));
      },
    );
    addTearDown(batcher.dispose);
    Future<String> add(TranslationBatchKey batchKey, String source) =>
        batcher.add(
          batchKey,
          TranslationBatchTask(source: source, isValid: () => true),
        );

    expect(
      await Future.wait([
        add(configuredKey(), 'first'),
        add(configuredKey(), 'second'),
        add(
          configuredKey(reasoningEffort: TranslationReasoningEffort.low),
          'low',
        ),
      ]),
      ['first', 'second', 'low'],
    );

    expect(batches, hasLength(2));
    expect(batches[configuredKey()], ['first', 'second']);
    expect(
      batches[configuredKey(reasoningEffort: TranslationReasoningEffort.low)],
      ['low'],
    );
  });

  test(
    'splits by message and Unicode character limits without truncation',
    () async {
      final batches = <Map<String, TranslationRequestMessage>>[];
      final batcher = TranslationBatcher(
        settings: () => const TranslationBatchSettings(
          mergeWindowMs: 0,
          maxMessages: 2,
          maxCharacters: 100,
        ),
        sender: (_, messages, isStillValid) async {
          expect(isStillValid(), isTrue);
          batches.add(messages);
          return messages.map((id, message) => MapEntry(id, message.text));
        },
      );
      final values = ['a' * 60, '😀' * 60, 'x' * 101];
      await Future.wait(
        values.map(
          (source) => batcher.add(
            key,
            TranslationBatchTask(source: source, isValid: () => true),
          ),
        ),
      );
      expect(batches.map((batch) => batch.length), [1, 1, 1]);
      expect(batches.last.values.single.text, values.last);
    },
  );

  test(
    'malformed batch retries then falls back to individual requests',
    () async {
      var batchedAttempts = 0;
      var individualAttempts = 0;
      final batcher = TranslationBatcher(
        settings: () => const TranslationBatchSettings(
          mergeWindowMs: 0,
          malformedResponseRetries: 1,
        ),
        sender: (_, messages, isStillValid) async {
          expect(isStillValid(), isTrue);
          if (messages.length > 1) {
            batchedAttempts++;
            throw const TranslationProtocolException('bad structure');
          }
          individualAttempts++;
          return {messages.keys.single: 'ok'};
        },
      );
      final results = await Future.wait([
        batcher.add(
          key,
          TranslationBatchTask(source: 'one', isValid: () => true),
        ),
        batcher.add(
          key,
          TranslationBatchTask(source: 'two', isValid: () => true),
        ),
      ]);
      expect(results, ['ok', 'ok']);
      expect(batchedAttempts, 2);
      expect(individualAttempts, 2);
    },
  );

  test('extra batch IDs are rejected before individual fallback', () async {
    var batchedAttempts = 0;
    var individualAttempts = 0;
    final batcher = TranslationBatcher(
      settings: () => const TranslationBatchSettings(
        mergeWindowMs: 0,
        malformedResponseRetries: 1,
      ),
      sender: (_, messages, _) async {
        if (messages.length > 1) {
          batchedAttempts++;
          return {
            ...messages.map((id, message) => MapEntry(id, 'T:${message.text}')),
            'unexpected-id': 'unexpected',
          };
        }
        individualAttempts++;
        return {messages.keys.single: 'ok'};
      },
    );

    final results = await Future.wait([
      batcher.add(
        key,
        TranslationBatchTask(source: 'one', isValid: () => true),
      ),
      batcher.add(
        key,
        TranslationBatchTask(source: 'two', isValid: () => true),
      ),
    ]);

    expect(results, ['ok', 'ok']);
    expect(batchedAttempts, 2);
    expect(individualAttempts, 2);
  });

  test('duplicate task IDs are rejected and fall back individually', () async {
    var individualAttempts = 0;
    final batcher = TranslationBatcher(
      settings: () => const TranslationBatchSettings(
        mergeWindowMs: 0,
        malformedResponseRetries: 0,
      ),
      sender: (_, messages, _) async {
        individualAttempts++;
        return {messages.keys.single: 'ok'};
      },
    );
    final results = await Future.wait([
      batcher.add(
        key,
        TranslationBatchTask(
          source: 'one',
          requestId: 'same-id',
          isValid: () => true,
        ),
      ),
      batcher.add(
        key,
        TranslationBatchTask(
          source: 'two',
          requestId: 'same-id',
          isValid: () => true,
        ),
      ),
    ]);

    expect(results, ['ok', 'ok']);
    expect(individualAttempts, 2);
  });

  test('sender validity callback rejects an expired response', () async {
    var valid = true;
    late bool Function() isStillValid;
    final senderEntered = Completer<void>();
    final releaseSender = Completer<void>();
    final batcher = TranslationBatcher(
      settings: () => const TranslationBatchSettings(mergeWindowMs: 0),
      sender: (_, messages, validity) async {
        isStillValid = validity;
        senderEntered.complete();
        await releaseSender.future;
        return {messages.keys.single: 'translated'};
      },
    );
    final result = batcher.add(
      key,
      TranslationBatchTask(source: 'one', isValid: () => valid),
    );
    final expectation = expectLater(result, throwsA(isA<StateError>()));

    await senderEntered.future;
    expect(isStillValid(), isTrue);
    valid = false;
    expect(isStillValid(), isFalse);
    releaseSender.complete();

    await expectation;
  });

  test(
    'a revised task still sends after pending tasks are cancelled',
    () async {
      final sentRevisions = <int>[];
      final batcher = TranslationBatcher(
        settings: () => const TranslationBatchSettings(mergeWindowMs: 0),
        sender: (batchKey, messages, isStillValid) async {
          expect(isStillValid(), isTrue);
          sentRevisions.add(batchKey.runtimeRevision);
          return {messages.keys.single: 'translated'};
        },
      );
      final cancelled = batcher.add(
        key,
        TranslationBatchTask(source: 'old', isValid: () => true),
      );
      final cancelledExpectation = expectLater(
        cancelled,
        throwsA(isA<StateError>()),
      );
      batcher.cancelPending();

      const revisedKey = TranslationBatchKey(
        roomId: '!room:example.test',
        providerId: 'provider',
        protocol: TranslationProtocol.responses,
        model: 'model',
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        promptRevision: 1,
        runtimeRevision: 2,
      );
      final revised = batcher.add(
        revisedKey,
        TranslationBatchTask(source: 'new', isValid: () => true),
      );

      await cancelledExpectation;
      expect(await revised, 'translated');
      expect(sentRevisions, [2]);
    },
  );
}
