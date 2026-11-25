// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/translation/translation_cache.dart';
import 'package:fluffychat/utils/translation/translation_models.dart';
import 'package:fluffychat/utils/translation/translation_preferences.dart';
import 'package:fluffychat/utils/translation/translation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'translation_test_backend.dart';

const _inputSource = 'chat.fluffy.translation.input.source_language';
const _inputTarget = 'chat.fluffy.translation.input.target_language';
const _mergeWindow = 'chat.fluffy.translation.batch.merge_ms';
const _maxMessages = 'chat.fluffy.translation.batch.max_messages';
const _maxCharacters = 'chat.fluffy.translation.batch.max_characters';
const _retries = 'chat.fluffy.translation.batch.structure_retries';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('input saves register before notifying and preserve pairs', () async {
    final fixture = await _SettingsFixture.create();
    final runtime = fixture.runtime;
    final store = fixture.store;
    final gate = store.gate = _WriteGate(_inputTarget, 'fr');
    Future<void>? listenerSave;
    var listenerReady = false;
    runtime.addListener(() {
      listenerSave ??= runtime.waitForInputLanguageSaves().then((_) {
        listenerReady = true;
      });
    });
    final revision = runtime.revision;

    final first = runtime.setInputLanguages(source: 'de', target: 'fr');
    await gate.started.future;
    final second = runtime.setInputLanguages(source: 'ja', target: 'es');
    var reopenedReady = false;
    final reopened = runtime.waitForInputLanguageSaves().then((_) {
      reopenedReady = true;
      return (runtime.inputSourceLanguage, runtime.inputTargetLanguage);
    });
    await Future<void>.delayed(Duration.zero);

    expect(runtime.inputSourceLanguage, 'ja');
    expect(runtime.inputTargetLanguage, 'es');
    expect(runtime.revision, revision + 2);
    expect(listenerReady, isFalse);
    expect(reopenedReady, isFalse);
    expect(store.writes, [(_inputSource, 'de'), (_inputTarget, 'fr')]);

    gate.release.complete();
    await Future.wait([first, second, listenerSave!]);
    expect(await reopened, ('ja', 'es'));
    expect(store.writes, [
      (_inputSource, 'de'),
      (_inputTarget, 'fr'),
      (_inputSource, 'ja'),
      (_inputTarget, 'es'),
    ]);
    expect(store.getString(_inputSource), 'ja');
    expect(store.getString(_inputTarget), 'es');
  });

  test('batch saves finish before reopened settings are read', () async {
    final fixture = await _SettingsFixture.create();
    final runtime = fixture.runtime;
    final initialSettings = runtime.batchSettings;
    final store = fixture.store;
    final gate = store.gate = _WriteGate(_mergeWindow, 250);
    const firstSettings = TranslationBatchSettings(mergeWindowMs: 250);
    const lastSettings = TranslationBatchSettings(
      mergeWindowMs: 500,
      maxMessages: 10,
      maxCharacters: 5000,
      malformedResponseRetries: 3,
    );

    final first = runtime.saveBatchSettings(firstSettings);
    await gate.started.future;
    final second = runtime.saveBatchSettings(lastSettings);
    var reopenedReady = false;
    final reopened = runtime.waitForBatchSettingsSaves().then((_) {
      reopenedReady = true;
      return runtime.batchSettings;
    });
    await Future<void>.delayed(Duration.zero);

    expect(store.writes.length, 4);
    expect(runtime.batchSettings, same(initialSettings));
    expect(reopenedReady, isFalse);

    gate.release.complete();
    await Future.wait([first, second]);
    expect(await reopened, same(lastSettings));
    expect(store.writes.length, 8);
    expect(store.getInt(_mergeWindow), 500);
    expect(store.getInt(_maxMessages), 10);
    expect(store.getInt(_maxCharacters), 5000);
    expect(store.getInt(_retries), 3);
  });

  for (final blockInput in [true, false]) {
    test(
      '${blockInput ? 'batch' : 'input'} saves do not wait for the other group',
      () async {
        final fixture = await _SettingsFixture.create();
        final runtime = fixture.runtime;
        final gate = fixture.store.gate = blockInput
            ? _WriteGate(_inputSource, 'de')
            : _WriteGate(_mergeWindow, 250);
        const settings = TranslationBatchSettings(mergeWindowMs: 250);
        final blocked = blockInput
            ? runtime.setInputLanguages(source: 'de', target: 'fr')
            : runtime.saveBatchSettings(settings);
        await gate.started.future;

        if (blockInput) {
          await runtime.saveBatchSettings(settings);
          await runtime.waitForBatchSettingsSaves();
          expect(runtime.batchSettings, same(settings));
        } else {
          await runtime.setInputLanguages(source: 'de', target: 'fr');
          await runtime.waitForInputLanguageSaves();
          expect(fixture.store.getString(_inputTarget), 'fr');
        }

        gate.release.complete();
        await blocked;
      },
    );
  }

  test('input save failures do not block later saves', () async {
    final fixture = await _SettingsFixture.create();
    final runtime = fixture.runtime;
    final store = fixture.store;
    final gate = store.gate = _WriteGate(_inputSource, 'de', fail: true);
    final first = runtime.setInputLanguages(source: 'de', target: 'fr');
    final failure = expectLater(first, throwsStateError);
    await gate.started.future;
    final second = runtime.setInputLanguages(source: 'ja', target: 'es');
    final reopened = runtime.waitForInputLanguageSaves();

    gate.release.complete();
    await failure;
    await second;
    await reopened;
    expect(store.getString(_inputSource), 'ja');
    expect(store.getString(_inputTarget), 'es');
    expect(runtime.inputSourceLanguage, 'ja');
    expect(runtime.inputTargetLanguage, 'es');
  });

  test('a batch save reports its error without blocking later saves', () async {
    final fixture = await _SettingsFixture.create();
    final runtime = fixture.runtime;
    final store = fixture.store;
    final gate = store.gate = _WriteGate(_mergeWindow, 250, fail: true);
    const firstSettings = TranslationBatchSettings(mergeWindowMs: 250);
    const lastSettings = TranslationBatchSettings(mergeWindowMs: 500);
    final first = runtime.saveBatchSettings(firstSettings);
    final failure = expectLater(first, throwsStateError);
    await gate.started.future;
    final second = runtime.saveBatchSettings(lastSettings);
    final reopened = runtime.waitForBatchSettingsSaves();

    gate.release.complete();
    await failure;
    await second;
    await reopened;
    expect(runtime.batchSettings, same(lastSettings));
    expect(store.getInt(_mergeWindow), 500);
  });

  test('stale batch snapshots do not write preferences', () async {
    final fixture = await _SettingsFixture.create();
    final runtime = fixture.runtime;
    final initialSettings = runtime.batchSettings;
    var version = 1;
    final skipped = runtime.saveBatchSettings(
      const TranslationBatchSettings(mergeWindowMs: 250),
      isCurrent: () => version == 1,
    );
    version++;

    await skipped;
    await runtime.waitForBatchSettingsSaves();
    expect(fixture.store.writes, isEmpty);
    expect(runtime.batchSettings, same(initialSettings));

    const latest = TranslationBatchSettings(mergeWindowMs: 500);
    await runtime.saveBatchSettings(latest, isCurrent: () => version == 2);
    expect(runtime.batchSettings, same(latest));
    expect(fixture.store.getInt(_mergeWindow), 500);
  });
}

class _SettingsFixture {
  final TranslationRuntime runtime;
  final _ControlledPreferences store;

  const _SettingsFixture(this.runtime, this.store);

  static Future<_SettingsFixture> create() async {
    final store = _ControlledPreferences();
    final secrets = _MemorySecrets();
    final runtime = TranslationRuntime.forTesting();
    addTearDown(runtime.dispose);
    await runtime.initialize(
      store,
      secrets: secrets,
      cache: TranslationCache(secrets, MemoryTranslationBackend()),
    );
    return _SettingsFixture(runtime, store);
  }
}

class _WriteGate {
  final String key;
  final Object value;
  final bool fail;
  final started = Completer<void>();
  final release = Completer<void>();

  _WriteGate(this.key, this.value, {this.fail = false});

  Future<void> beforeWrite(String writtenKey, Object writtenValue) async {
    if (writtenKey != key || writtenValue != value || started.isCompleted) {
      return;
    }
    started.complete();
    await release.future;
    if (fail) throw StateError('Preference write failed');
  }
}

class _ControlledPreferences implements SharedPreferences {
  final _values = <String, Object>{};
  final writes = <(String, Object)>[];
  _WriteGate? gate;

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  int? getInt(String key) => _values[key] as int?;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Set<String> getKeys() => _values.keys.toSet();

  @override
  Future<bool> setBool(String key, bool value) => _write(key, value);

  @override
  Future<bool> setInt(String key, int value) => _write(key, value);

  @override
  Future<bool> setString(String key, String value) => _write(key, value);

  Future<bool> _write(String key, Object value) async {
    writes.add((key, value));
    await gate?.beforeWrite(key, value);
    _values[key] = value;
    return true;
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected preference call: ${invocation.memberName}',
  );
}

class _MemorySecrets implements TranslationSecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
