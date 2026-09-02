// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'translation_api_client.dart';
import 'translation_batcher.dart';
import 'translation_cache.dart';
import 'translation_languages.dart';
import 'translation_models.dart';
import 'translation_preferences.dart';

enum RoomTranslationLockReason {
  none,
  globallyDisabled,
  allRooms,
  unencryptedOnly,
  encryptedExcluded,
  manualOnly,
}

class RoomTranslationControl {
  final bool value;
  final bool canChange;
  final RoomTranslationLockReason reason;
  final bool? overrideValue;

  const RoomTranslationControl(
    this.value,
    this.canChange,
    this.reason, {
    this.overrideValue,
  });
}

class TranslationRuntime extends ChangeNotifier {
  static final TranslationRuntime instance = TranslationRuntime._();
  static const promptRevision = 1;

  TranslationRuntime._();

  @visibleForTesting
  TranslationRuntime.forTesting();

  TranslationPreferences? _preferences;
  TranslationCache? _cache;
  TranslationApiClient? _apiClient;
  TranslationBatcher? _batcher;
  TranslationBatcher? _inputBatcher;
  final Map<String, ValueNotifier<TranslationResultState>> _states = {};
  final Map<String, ({int revision, Future<String> future})> _inFlight = {};
  final Map<String, Set<String>> _knownEditChains = {};
  final Map<Client, List<StreamSubscription<Object?>>> _clientSubscriptions =
      {};
  final Map<Client, Set<String>> _knownClientRoomIds = {};
  List<Client> _clients = const [];
  List<TranslationProviderConfig> _providers = const [];
  TranslationProviderConfig? _activeProvider;
  bool _initialized = false;
  bool _enabled = false;
  bool _privacyAccepted = false;
  TranslationScope _scope = TranslationScope.none;
  TranslationDisplayMode _displayMode = TranslationDisplayMode.bilingual;
  TranslationBilingualColor _bilingualColor =
      TranslationBilingualColor.tertiary;
  TranslationBilingualStyle _bilingualStyle = TranslationBilingualStyle.divider;
  TranslationBatchSettings _batchSettings = TranslationBatchSettings.defaults;
  String _sourceLanguage = 'auto';
  String _targetLanguage = systemTranslationLanguageCode;
  String _systemTargetLanguage = 'en';
  bool _preferRoomLanguageForSource = false;
  bool _preferRoomLanguageForInputTarget = true;
  InputTranslationMode _inputMode = InputTranslationMode.disabled;
  InputTranslationScope _inputScope = InputTranslationScope.automaticRooms;
  String _inputSourceLanguage = 'auto';
  String _inputTargetLanguage = 'en';
  InputTranslationTrigger _inputTrigger = InputTranslationTrigger.button;
  InputTranslationSendMode _inputSendMode =
      InputTranslationSendMode.shortOriginalLongTranslated;
  int _revision = 0;
  bool _providerMutationInProgress = false;
  int _enabledMutationToken = 0;

  bool get initialized => _initialized;
  bool get enabled => _enabled;
  bool get privacyAccepted => _privacyAccepted;
  TranslationScope get scope => _scope;
  TranslationDisplayMode get displayMode => _displayMode;
  TranslationBilingualColor get bilingualColor => _bilingualColor;
  TranslationBilingualStyle get bilingualStyle => _bilingualStyle;
  TranslationBatchSettings get batchSettings => _batchSettings;
  String get sourceLanguage => _sourceLanguage;
  String get targetLanguage => _targetLanguage;
  InputTranslationMode get inputMode => _inputMode;
  TranslationInputMode get inputTranslationMode => _inputMode;
  InputTranslationScope get inputScope => _inputScope;
  TranslationInputScope get inputTranslationScope => _inputScope;
  String get inputSourceLanguage => _inputSourceLanguage;
  String get inputTranslationSourceLanguage => _inputSourceLanguage;
  String get inputTargetLanguage => _inputTargetLanguage;
  String get inputTranslationTargetLanguage => _inputTargetLanguage;
  bool get preferRoomLanguageForSource => _preferRoomLanguageForSource;
  bool get preferRoomLanguageForInputTarget =>
      _preferRoomLanguageForInputTarget;
  InputTranslationTrigger get inputTrigger => _inputTrigger;
  TranslationInputTrigger get inputTranslationTrigger => _inputTrigger;
  InputTranslationSendMode get inputSendMode => _inputSendMode;
  TranslationInputSendMode get inputTranslationSendMode => _inputSendMode;
  InputTranslationAutoSendMode get inputTranslationAutoSendMode =>
      _inputSendMode;
  int get revision => _revision;
  List<TranslationProviderConfig> get providers =>
      List.unmodifiable(_providers);
  TranslationProviderConfig? get activeProvider => _activeProvider;
  TranslationCache get cache =>
      _cache ?? (throw StateError('Translation runtime is not initialized'));
  TranslationPreferences get preferences =>
      _preferences ??
      (throw StateError('Translation runtime is not initialized'));

  Future<void> initialize(
    SharedPreferences store, {
    String defaultTargetLanguage = 'en',
    TranslationSecretStore secrets = const SecureTranslationSecretStore(),
    TranslationApiClient? apiClient,
    TranslationCache? cache,
  }) async {
    if (_initialized) return;
    final preferences = _preferences = TranslationPreferences(store, secrets);
    _cache = cache ?? TranslationCache(secrets);
    _apiClient = apiClient ?? TranslationApiClient();
    _providers = preferences.providers;
    _activeProvider = _findProvider(preferences.selectedProviderId);
    _scope = preferences.scope;
    _preferRoomLanguageForSource = preferences.preferRoomLanguageForSource;
    _preferRoomLanguageForInputTarget =
        preferences.preferRoomLanguageForInputTarget;
    _displayMode = preferences.displayMode;
    _bilingualColor = preferences.bilingualColor;
    _bilingualStyle = preferences.bilingualStyle;
    _batchSettings = preferences.batchSettings.isValid
        ? preferences.batchSettings
        : TranslationBatchSettings.defaults;
    final savedSourceLanguage = preferences.sourceLanguage;
    _sourceLanguage =
        savedSourceLanguage == 'auto' ||
            isTranslationLanguage(savedSourceLanguage)
        ? savedSourceLanguage
        : 'auto';
    final savedTargetLanguage = preferences.targetLanguage;
    _systemTargetLanguage = isTranslationLanguage(defaultTargetLanguage)
        ? defaultTargetLanguage
        : 'en';
    _targetLanguage =
        savedTargetLanguage != null &&
            isTranslationTargetLanguage(savedTargetLanguage)
        ? savedTargetLanguage
        : systemTranslationLanguageCode;
    _inputMode = preferences.inputMode;
    _inputScope = preferences.inputScope;
    final savedInputSourceLanguage = preferences.inputSourceLanguage;
    _inputSourceLanguage =
        savedInputSourceLanguage == 'auto' ||
            isTranslationLanguage(savedInputSourceLanguage)
        ? savedInputSourceLanguage
        : 'auto';
    final savedInputTargetLanguage = preferences.inputTargetLanguage;
    _inputTargetLanguage =
        savedInputTargetLanguage != null &&
            isTranslationLanguage(savedInputTargetLanguage)
        ? savedInputTargetLanguage
        : isTranslationLanguage(defaultTargetLanguage)
        ? defaultTargetLanguage
        : 'en';
    _inputTrigger = preferences.inputTrigger;
    _inputSendMode = preferences.inputSendMode;
    _privacyAccepted = preferences.privacyAccepted;
    _enabled =
        _privacyAccepted &&
        preferences.enabled &&
        await _activeProviderHasKey();
    if (preferences.enabled && !_enabled) await preferences.setEnabled(false);
    _batcher = TranslationBatcher(
      sender: _sendBatch,
      settings: () => _batchSettings,
      persister: (results) {
        final validResults = Map<TranslationBatchTask, String>.fromEntries(
          results.entries.where((entry) => entry.key.isValid()),
        );
        if (validResults.isEmpty) return Future.value();
        return _cache!.writeAll(
          {
            for (final entry in validResults.entries)
              entry.key.metadata! as TranslationCacheKey: entry.value,
          },
          isValid: () =>
              _enabled && validResults.keys.every((task) => task.isValid()),
        );
      },
    );
    _inputBatcher = TranslationBatcher(
      sender: _sendBatch,
      settings: () => _batchSettings,
    );
    _initialized = true;
  }

  void attachClients(List<Client> clients) {
    _clients = List<Client>.from(clients);
    for (final client in clients) {
      attachClient(client);
    }
  }

  void attachClient(Client client) {
    if (!_clients.contains(client)) {
      _clients = [..._clients, client];
    }
    _knownClientRoomIds
        .putIfAbsent(client, () => client.rooms.map((room) => room.id).toSet())
        .addAll(client.rooms.map((room) => room.id));
    if (_clientSubscriptions.containsKey(client)) return;
    // Stored in _clientSubscriptions and cancelled when the client logs out.
    // ignore: cancel_subscriptions
    final timeline = client.onTimelineEvent.stream.listen((event) {
      _knownClientRoomIds[client]?.add(event.room.id);
      unawaited(_handleTimelineEvent(event).catchError((_) {}));
    });
    // ignore: cancel_subscriptions
    final sync = client.onSync.stream.listen((update) {
      final knownRoomIds = _knownClientRoomIds.putIfAbsent(client, () => {});
      knownRoomIds.addAll(update.rooms?.join?.keys ?? const <String>[]);
      knownRoomIds.addAll(update.rooms?.invite?.keys ?? const <String>[]);
      final leftRoomIds = update.rooms?.leave?.keys;
      if (leftRoomIds == null) return;
      for (final roomId in leftRoomIds) {
        knownRoomIds.remove(roomId);
        scheduleMicrotask(() {
          unawaited(
            invalidateRoomUnlessLocallyReferenced(
              roomId,
              excludingClient: client,
            ).catchError((_) {}),
          );
        });
      }
    });
    // ignore: cancel_subscriptions
    final roomState = client.onRoomState.stream.listen((update) {
      _knownClientRoomIds[client]?.add(update.roomId);
      if (update.state.type != EventTypes.Encryption) return;
      _clearRoomStates(update.roomId);
      _bumpRevision(clearPending: true, clearStates: false);
    });
    _clientSubscriptions[client] = [timeline, sync, roomState];
  }

  Future<void> detachLoggedOutClient(Client client) async {
    final roomIds = {
      ...?_knownClientRoomIds.remove(client),
      ...client.rooms.map((room) => room.id),
    };
    // Drop per-room presentation/edit-chain state immediately. The shared
    // cache may remain valid for another logged-in client, but no state tied
    // to the logged-out account should survive in memory while that cleanup
    // decision is awaited.
    for (final roomId in roomIds) {
      _clearRoomStates(roomId);
    }
    _bumpRevision(clearPending: true, clearStates: false);
    for (final subscription
        in _clientSubscriptions.remove(client) ?? const []) {
      await subscription.cancel();
    }
    _clients = _clients.where((item) => item != client).toList(growable: false);
    for (final roomId in roomIds) {
      await invalidateRoomUnlessLocallyReferenced(
        roomId,
        excludingClient: client,
        invalidateRuntime: false,
      );
    }
  }

  Future<bool> setEnabled(bool value) async {
    final mutationToken = ++_enabledMutationToken;
    if (value == _enabled) return true;
    final candidateProvider = _activeProvider;
    if (value) {
      if (!_privacyAccepted || _providerMutationInProgress) return false;
      if (!await _activeProviderHasKey() ||
          mutationToken != _enabledMutationToken ||
          _providerMutationInProgress ||
          candidateProvider == null ||
          !_sameProviderConfiguration(
            candidateProvider,
            _activeProvider ?? candidateProvider,
          )) {
        return false;
      }
    }
    if (mutationToken != _enabledMutationToken) return false;
    _enabled = value;
    _bumpRevision(clearPending: true, clearStates: true);
    try {
      await preferences.setEnabled(value);
    } catch (_) {
      if (value) {
        _enabled = false;
        _bumpRevision(clearPending: true, clearStates: true);
      }
      rethrow;
    }
    return true;
  }

  Future<void> setScope(TranslationScope value) async {
    if (value == _scope) return;
    _scope = value;
    _bumpRevision(clearPending: true, clearStates: true);
    try {
      await preferences.setScope(value);
    } catch (_) {
      _enabled = false;
      await preferences.setEnabled(false);
      _bumpRevision(clearPending: true, clearStates: true);
      rethrow;
    }
  }

  Future<void> setDisplayMode(TranslationDisplayMode value) async {
    if (value == _displayMode) return;
    _displayMode = value;
    await preferences.setDisplayMode(value);
    notifyListeners();
  }

  Future<void> setBilingualStyle(TranslationBilingualStyle value) async {
    if (value == _bilingualStyle) return;
    _bilingualStyle = value;
    await preferences.setBilingualStyle(value);
    notifyListeners();
  }

  Future<void> setBilingualColor(TranslationBilingualColor value) async {
    if (value == _bilingualColor) return;
    _bilingualColor = value;
    await preferences.setBilingualColor(value);
    notifyListeners();
  }

  Future<void> setLanguages({
    required String source,
    required String target,
  }) async {
    final cleanSource = source.trim().isEmpty ? 'auto' : source.trim();
    final cleanTarget = target.trim();
    if (cleanTarget.isEmpty) throw ArgumentError.value(target, 'target');
    if (cleanSource == _sourceLanguage && cleanTarget == _targetLanguage) {
      return;
    }
    _sourceLanguage = cleanSource;
    _targetLanguage = cleanTarget;
    _bumpRevision(clearPending: true, clearStates: true);
    try {
      await preferences.setSourceLanguage(cleanSource);
      await preferences.setTargetLanguage(cleanTarget);
    } catch (_) {
      _enabled = false;
      await preferences.setEnabled(false);
      _bumpRevision(clearPending: true, clearStates: true);
      rethrow;
    }
  }

  Future<void> setInputMode(InputTranslationMode value) async {
    if (value == _inputMode) return;
    _inputMode = value;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setInputMode(value);
  }

  Future<void> setInputTranslationMode(TranslationInputMode value) =>
      setInputMode(value);

  Future<void> setInputScope(InputTranslationScope value) async {
    if (value == _inputScope) return;
    _inputScope = value;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setInputScope(value);
  }

  Future<void> setInputTranslationScope(TranslationInputScope value) =>
      setInputScope(value);

  Future<void> setPreferRoomLanguageForSource(bool value) async {
    if (value == _preferRoomLanguageForSource) return;
    _preferRoomLanguageForSource = value;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setPreferRoomLanguageForSource(value);
  }

  Future<void> setPreferRoomLanguageForInputTarget(bool value) async {
    if (value == _preferRoomLanguageForInputTarget) return;
    _preferRoomLanguageForInputTarget = value;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setPreferRoomLanguageForInputTarget(value);
  }

  Future<void> setInputLanguages({
    required String source,
    required String target,
  }) async {
    final cleanSource = source.trim().isEmpty ? 'auto' : source.trim();
    final cleanTarget = target.trim();
    if (cleanTarget.isEmpty) throw ArgumentError.value(target, 'target');
    if (cleanSource == _inputSourceLanguage &&
        cleanTarget == _inputTargetLanguage) {
      return;
    }
    _inputSourceLanguage = cleanSource;
    _inputTargetLanguage = cleanTarget;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setInputSourceLanguage(cleanSource);
    await preferences.setInputTargetLanguage(cleanTarget);
  }

  Future<void> setInputTranslationLanguages({
    required String source,
    required String target,
  }) => setInputLanguages(source: source, target: target);

  Future<void> setInputTrigger(InputTranslationTrigger value) async {
    if (value == _inputTrigger) return;
    _inputTrigger = value;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setInputTrigger(value);
  }

  Future<void> setInputTranslationTrigger(TranslationInputTrigger value) =>
      setInputTrigger(value);

  Future<void> setInputSendMode(InputTranslationSendMode value) async {
    if (value == _inputSendMode) return;
    _inputSendMode = value;
    _bumpRevision(clearPending: true, clearStates: true);
    await preferences.setInputSendMode(value);
  }

  Future<void> setInputTranslationSendMode(TranslationInputSendMode value) =>
      setInputSendMode(value);

  Future<void> setInputTranslationAutoSendMode(
    InputTranslationAutoSendMode value,
  ) => setInputSendMode(value);

  Future<void> acceptPrivacyNotice() async {
    _privacyAccepted = true;
    await preferences.acceptPrivacyNotice();
    notifyListeners();
  }

  Future<void> saveBatchSettings(TranslationBatchSettings value) async {
    if (!value.isValid) throw ArgumentError.value(value, 'value');
    await preferences.saveBatchSettings(value);
    _batchSettings = value;
    _batcher?.settingsChanged();
    _inputBatcher?.settingsChanged();
    notifyListeners();
  }

  Future<void> saveProvider(
    TranslationProviderConfig provider, {
    String? apiKey,
  }) async {
    if (!provider.isValid) throw ArgumentError.value(provider, 'provider');
    final providers = [..._providers];
    final index = providers.indexWhere((item) => item.id == provider.id);
    if (index < 0) {
      providers.add(provider);
    } else {
      providers[index] = provider;
    }
    final becomesActive =
        _activeProvider == null || _activeProvider?.id == provider.id;
    _beginProviderMutation();
    _providers = providers;
    if (becomesActive) _activeProvider = provider;
    try {
      await preferences.saveProviders(providers);
      if (becomesActive) await preferences.selectProvider(provider.id);
      if (apiKey != null && apiKey.trim().isNotEmpty) {
        await preferences.writeApiKey(provider.id, apiKey.trim());
      }
    } catch (_) {
      if (_enabled) {
        _enabled = false;
        await preferences.setEnabled(false);
      }
      rethrow;
    } finally {
      _endProviderMutation();
    }
  }

  Future<void> deleteProvider(String providerId) async {
    _beginProviderMutation();
    final providers = _providers
        .where((provider) => provider.id != providerId)
        .toList(growable: false);
    _providers = providers;
    try {
      await preferences.deleteApiKey(providerId);
      await preferences.saveProviders(providers);
      if (_activeProvider?.id == providerId) {
        TranslationProviderConfig? replacement;
        for (final candidate in providers) {
          final key = await preferences.readApiKey(candidate.id);
          if (key != null && key.trim().isNotEmpty) {
            replacement = candidate;
            break;
          }
        }
        _activeProvider = replacement ?? providers.firstOrNull;
        await preferences.selectProvider(_activeProvider?.id);
      }
      if (_enabled && !await _activeProviderHasKey()) {
        _enabled = false;
        await preferences.setEnabled(false);
      }
    } catch (_) {
      if (_enabled) {
        _enabled = false;
        await preferences.setEnabled(false);
      }
      rethrow;
    } finally {
      _endProviderMutation();
    }
  }

  Future<bool> selectProvider(String providerId) async {
    final provider = _findProvider(providerId);
    if (provider == null) return false;
    _beginProviderMutation();
    _activeProvider = provider;
    try {
      await preferences.selectProvider(providerId);
      if (_enabled && !await _activeProviderHasKey()) {
        _enabled = false;
        await preferences.setEnabled(false);
      }
    } catch (_) {
      if (_enabled) {
        _enabled = false;
        await preferences.setEnabled(false);
      }
      rethrow;
    } finally {
      _endProviderMutation();
    }
    return true;
  }

  Future<void> testProvider(
    TranslationProviderConfig provider,
    String apiKey,
  ) async {
    final enteredApiKey = apiKey.trim();
    final resolvedApiKey = enteredApiKey.isNotEmpty
        ? enteredApiKey
        : await preferences.readApiKey(provider.id);
    if (!provider.isValid || resolvedApiKey == null || resolvedApiKey.isEmpty) {
      throw ArgumentError('Provider and API key are required');
    }
    await _apiClient!.translate(
      provider: provider,
      apiKey: resolvedApiKey,
      messages: const {
        'test': TranslationRequestMessage(
          text: 'Hello',
          messageType: MessageTypes.Text,
        ),
      },
      sourceLanguage: 'en',
      targetLanguage: 'fr',
    );
  }

  RoomTranslationControl roomControl(Room room) {
    final overrideValue = preferences.roomTranslationOverride(
      room.client.userID ?? '',
      room.id,
    );
    if (!_enabled) {
      return RoomTranslationControl(
        false,
        false,
        RoomTranslationLockReason.globallyDisabled,
        overrideValue: overrideValue,
      );
    }
    final defaultValue = switch (_scope) {
      TranslationScope.allRooms => true,
      TranslationScope.unencryptedRooms => !room.encrypted,
      TranslationScope.none => false,
    };
    return RoomTranslationControl(
      overrideValue ?? defaultValue,
      true,
      RoomTranslationLockReason.none,
      overrideValue: overrideValue,
    );
  }

  Future<void> setRoomSelected(Room room, bool value) async {
    await setRoomTranslationOverride(room, value);
  }

  Future<void> setRoomTranslationOverride(Room room, bool? value) async {
    if (!_enabled) return;
    final write = preferences.setRoomTranslationOverride(
      room.client.userID ?? '',
      room.id,
      value,
    );
    _clearRoomStates(room.id);
    _bumpRevision(clearPending: true, clearStates: false);
    await write;
  }

  String? roomLanguage(Room room) =>
      switch (preferences.roomLanguage(room.client.userID ?? '', room.id)) {
        final value when value != null && isTranslationLanguage(value) => value,
        _ => null,
      };

  Future<void> setRoomLanguage(Room room, String? value) async {
    final clean = value?.trim();
    if (clean != null && clean.isNotEmpty && !isTranslationLanguage(clean)) {
      throw ArgumentError.value(value, 'value');
    }
    if (roomLanguage(room) == clean) return;
    await preferences.setRoomLanguage(room.client.userID ?? '', room.id, clean);
    _clearRoomStates(room.id);
    _bumpRevision(clearPending: true, clearStates: false);
  }

  bool canTranslateInput(Room room) {
    if (!_enabled ||
        _providerMutationInProgress ||
        _activeProvider?.isValid != true ||
        _inputMode == InputTranslationMode.disabled) {
      return false;
    }
    return switch (_inputScope) {
      InputTranslationScope.automaticRooms => roomControl(room).value,
      InputTranslationScope.allRooms => true,
    };
  }

  bool canTranslateInputInRoom(Room room) => canTranslateInput(room);

  bool canManuallyTranslateInput(Room room) =>
      _inputMode == InputTranslationMode.manual && canTranslateInput(room);

  bool shouldAutoTranslateInput(Room room) =>
      _inputMode == InputTranslationMode.automatic && canTranslateInput(room);

  Future<String> translateInputText(Room room, String text) async {
    if (text.trim().isEmpty) throw ArgumentError.value(text, 'text');
    if (!canTranslateInput(room)) {
      throw StateError('Input translation is not available in this room');
    }
    final taskRevision = _revision;
    final provider = _activeProvider!;
    final sourceLanguage = _inputSourceLanguage;
    final targetLanguage = _inputTargetLanguageForRoom(room);
    bool isValid() => _inputTaskValid(
      room,
      taskRevision,
      provider,
      sourceLanguage,
      targetLanguage,
    );
    final result = await _inputBatcher!.add(
      TranslationBatchKey(
        roomId: room.id,
        providerId: provider.id,
        protocol: provider.protocol,
        model: provider.model,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        promptRevision: promptRevision,
        runtimeRevision: taskRevision,
      ),
      TranslationBatchTask(
        source: text,
        messageType: MessageTypes.Text,
        isValid: isValid,
      ),
    );
    if (!isValid()) throw StateError('Input translation task expired');
    if (result.trim().isEmpty) {
      throw StateError('Input translation returned empty text');
    }
    return result;
  }

  bool canTranslateEvent(Event event) =>
      _enabled &&
      !_providerMutationInProgress &&
      !event.redacted &&
      event.eventId.isNotEmpty &&
      {
        MessageTypes.Text,
        MessageTypes.Notice,
        MessageTypes.Emote,
      }.contains(event.messageType) &&
      event.body.trim().isNotEmpty;

  String sourceForEvent(Event event) =>
      event.isRichMessage ? event.formattedText : event.body;

  bool shouldAutoTranslate(Event event) =>
      canTranslateEvent(event) && roomControl(event.room).value;

  ValueListenable<TranslationResultState> stateForEvent(Event event) {
    if (!_enabled) return _disabledState;
    return _states.putIfAbsent(
      _stateKey(event),
      () => ValueNotifier(TranslationResultState.idle),
    );
  }

  Future<String?> translateEvent(Event event, {required bool manual}) async {
    if (!canTranslateEvent(event) || (!manual && !shouldAutoTranslate(event))) {
      return null;
    }
    final stateKey = _stateKey(event);
    final state = _states.putIfAbsent(
      stateKey,
      () => ValueNotifier(TranslationResultState.idle),
    );
    if (state.value.status == TranslationStatus.translated) {
      return state.value.translation;
    }
    final existing = _inFlight[stateKey];
    if (existing != null && existing.revision == _revision) {
      return existing.future;
    }
    final operation = _translate(event, manual: manual, state: state);
    _inFlight[stateKey] = (revision: _revision, future: operation);
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[stateKey]?.future, operation)) {
        _inFlight.remove(stateKey);
      }
    }
  }

  Future<String> _translate(
    Event event, {
    required bool manual,
    required ValueNotifier<TranslationResultState> state,
  }) async {
    final source = sourceForEvent(event);
    final messageType = event.messageType;
    final eventId = event.eventId;
    final taskRevision = _revision;
    final provider = _activeProvider!;
    final cacheKey = _cacheKey(event, source, provider);
    state.value = TranslationResultState.loading;
    try {
      final cached = await cache.read(cacheKey);
      if (cached != null &&
          _eventTaskValid(
            event,
            source,
            messageType,
            eventId,
            taskRevision,
            manual,
          )) {
        state.value = TranslationResultState.translated(cached);
        return cached;
      }
      if (!_eventTaskValid(
        event,
        source,
        messageType,
        eventId,
        taskRevision,
        manual,
      )) {
        throw StateError('Translation task expired');
      }
      final batchKey = TranslationBatchKey(
        roomId: event.room.id,
        providerId: provider.id,
        protocol: provider.protocol,
        model: provider.model,
        sourceLanguage: _sourceLanguageForRoom(event.room),
        targetLanguage: _effectiveTargetLanguage,
        promptRevision: promptRevision,
        runtimeRevision: taskRevision,
      );
      final result = await _batcher!.add(
        batchKey,
        TranslationBatchTask(
          source: source,
          messageType: event.messageType,
          metadata: cacheKey,
          isValid: () => _eventTaskValid(
            event,
            source,
            messageType,
            eventId,
            taskRevision,
            manual,
          ),
        ),
      );
      if (!_eventTaskValid(
        event,
        source,
        messageType,
        eventId,
        taskRevision,
        manual,
      )) {
        throw StateError('Translation task expired');
      }
      state.value = TranslationResultState.translated(result);
      return result;
    } catch (error) {
      if (_enabled && taskRevision == _revision) {
        state.value = TranslationResultState.failed(error);
      }
      rethrow;
    }
  }

  Future<Map<String, String>> _sendBatch(
    TranslationBatchKey key,
    Map<String, TranslationRequestMessage> messages,
    bool Function() isStillValid,
  ) async {
    _ensureBatchValid(key, isStillValid);
    final provider = _activeProvider;
    if (provider == null || !_providerMatchesBatch(provider, key)) {
      throw StateError('Translation provider changed');
    }
    final apiKey = await preferences.readApiKey(provider.id);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw StateError('Translation provider has no API key');
    }
    _ensureBatchValid(key, isStillValid);
    final currentProvider = _activeProvider;
    if (currentProvider == null ||
        !_sameProviderConfiguration(provider, currentProvider) ||
        !_providerMatchesBatch(currentProvider, key)) {
      throw StateError('Translation provider changed');
    }
    return _apiClient!.translate(
      provider: provider,
      apiKey: apiKey.trim(),
      messages: messages,
      sourceLanguage: key.sourceLanguage,
      targetLanguage: key.targetLanguage,
    );
  }

  Future<void> invalidateEventIfExists(String roomId, String eventId) async {
    final prefix = '$roomId\u0000$eventId\u0000';
    _states.removeWhere((key, notifier) {
      final remove = key.startsWith(prefix);
      if (remove) notifier.dispose();
      return remove;
    });
    _bumpRevision(clearPending: true, clearStates: false);
    await cache.invalidateEventIfExists(roomId, eventId);
  }

  Future<void> invalidateRoomUnlessLocallyReferenced(
    String roomId, {
    Client? excludingClient,
    bool invalidateRuntime = true,
  }) async {
    if (invalidateRuntime) {
      _clearRoomStates(roomId);
      _bumpRevision(clearPending: true, clearStates: false);
    }
    final referenced = _clients.any((client) {
      if (identical(client, excludingClient)) return false;
      if (!client.isLogged()) return false;
      final room = client.getRoomById(roomId);
      return room != null && room.membership == Membership.join;
    });
    if (referenced) return;
    await cache.invalidateRoomIfExists(roomId);
  }

  void _clearRoomStates(String roomId) {
    final prefix = '$roomId\u0000';
    _states.removeWhere((key, notifier) {
      final remove = key.startsWith(prefix);
      if (remove) notifier.dispose();
      return remove;
    });
    _knownEditChains.removeWhere((key, _) => key.startsWith(prefix));
  }

  Future<TranslationCacheCleanupResult> cleanInvalidCache() =>
      cache.cleanInvalid((roomId, eventId) async {
        for (final client in _clients) {
          if (!client.isLogged()) continue;
          final room = client.getRoomById(roomId);
          if (room == null || room.membership != Membership.join) continue;
          final event = await client.database.getEventById(eventId, room);
          if (event != null &&
              !event.redacted &&
              event.relationshipType != RelationshipTypes.edit) {
            return _sourceForCachedEvent(event);
          }
        }
        return null;
      });

  Future<void> clearCache() => cache.deleteIfExists();

  Future<void> _handleTimelineEvent(Event event) async {
    if (event.type == EventTypes.Redaction && event.redacts != null) {
      final targetId = event.redacts!;
      // The first invalidation bumps the runtime revision before any local
      // database await, so translations of the redacted event or its edits
      // cannot be written back by a late response.
      await invalidateEventIfExists(event.room.id, targetId);
      final chainKey = '${event.room.id}\u0000$targetId';
      final relatedEditIds = {
        ...?_knownEditChains.remove(chainKey),
        ...await _locallyKnownEditIds(event.room, targetId),
      };
      for (final editId in relatedEditIds) {
        await invalidateEventIfExists(event.room.id, editId);
      }
      for (final edits in _knownEditChains.values) {
        edits.remove(targetId);
      }
    }
    if (event.relationshipType == RelationshipTypes.edit) {
      final originalId = event.relationshipEventId;
      if (originalId != null) {
        await invalidateEventIfExists(event.room.id, originalId);
        final chainKey = '${event.room.id}\u0000$originalId';
        final knownEdits = _knownEditChains.putIfAbsent(chainKey, () => {});
        knownEdits.addAll(await _locallyKnownEditIds(event.room, originalId));
        for (final editId in knownEdits) {
          await invalidateEventIfExists(event.room.id, editId);
        }
        knownEdits.add(event.eventId);
      }
      await invalidateEventIfExists(event.room.id, event.eventId);
    }
  }

  String _sourceForCachedEvent(Event event) {
    if (event.relationshipType != RelationshipTypes.edit) {
      return sourceForEvent(event);
    }
    final newContent = event.content.tryGetMap<String, Object?>(
      'm.new_content',
    );
    if (newContent == null) return sourceForEvent(event);
    final formatted = newContent.tryGet<String>('formatted_body');
    if (newContent.tryGet<String>('format') == 'org.matrix.custom.html' &&
        formatted != null) {
      return formatted;
    }
    return newContent.tryGet<String>('body') ?? sourceForEvent(event);
  }

  bool _eventTaskValid(
    Event event,
    String source,
    String messageType,
    String eventId,
    int taskRevision,
    bool manual,
  ) =>
      _enabled &&
      !_providerMutationInProgress &&
      taskRevision == _revision &&
      _activeProvider?.isValid == true &&
      event.room.client.isLogged() &&
      event.room.membership == Membership.join &&
      canTranslateEvent(event) &&
      event.eventId == eventId &&
      sourceForEvent(event) == source &&
      event.messageType == messageType &&
      (manual || shouldAutoTranslate(event));

  bool _inputTaskValid(
    Room room,
    int taskRevision,
    TranslationProviderConfig provider,
    String sourceLanguage,
    String targetLanguage,
  ) =>
      taskRevision == _revision &&
      _inputSourceLanguage == sourceLanguage &&
      _inputTargetLanguageForRoom(room) == targetLanguage &&
      _activeProvider != null &&
      _sameProviderConfiguration(provider, _activeProvider!) &&
      canTranslateInput(room);

  TranslationCacheKey _cacheKey(
    Event event,
    String source,
    TranslationProviderConfig provider,
  ) => TranslationCacheKey(
    roomId: event.room.id,
    eventId: event.eventId,
    source: source,
    sourceLanguage: _sourceLanguageForRoom(event.room),
    targetLanguage: _effectiveTargetLanguage,
    semanticRevision: semanticRevisionForProvider(provider),
    messageType: event.messageType,
  );

  /// Encodes every semantic provider field as a separate JSON value so user
  /// supplied colons or other delimiters cannot make two configurations share
  /// a cache namespace.
  static String semanticRevisionForProvider(
    TranslationProviderConfig provider,
  ) => jsonEncode([
    provider.id,
    provider.protocol.name,
    provider.model,
    provider.requestEndpoint.toString(),
    promptRevision,
  ]);

  String _stateKey(Event event) {
    final provider = _activeProvider;
    return [
      event.room.id,
      event.eventId,
      sourceForEvent(event),
      event.messageType,
      _sourceLanguageForRoom(event.room),
      _effectiveTargetLanguage,
      provider?.id ?? '',
      provider?.protocol.name ?? '',
      provider?.model ?? '',
      provider?.requestEndpoint.toString() ?? '',
      promptRevision.toString(),
    ].join('\u0000');
  }

  String get _effectiveTargetLanguage =>
      _targetLanguage == systemTranslationLanguageCode
      ? _systemTargetLanguage
      : _targetLanguage;

  String _sourceLanguageForRoom(Room room) {
    final language = roomLanguage(room);
    return _preferRoomLanguageForSource && language != null
        ? language
        : _sourceLanguage;
  }

  String _inputTargetLanguageForRoom(Room room) {
    final language = roomLanguage(room);
    return _preferRoomLanguageForInputTarget && language != null
        ? language
        : _inputTargetLanguage;
  }

  TranslationProviderConfig? _findProvider(String? id) {
    if (_providers.isEmpty) return null;
    if (id == null) return _providers.first;
    for (final provider in _providers) {
      if (provider.id == id) return provider;
    }
    return _providers.first;
  }

  Future<bool> _activeProviderHasKey() async {
    final provider = _activeProvider;
    if (provider == null || !provider.isValid) return false;
    final apiKey = await preferences.readApiKey(provider.id);
    return apiKey != null && apiKey.trim().isNotEmpty;
  }

  void _beginProviderMutation() {
    if (_providerMutationInProgress) {
      throw StateError('Another translation provider update is in progress');
    }
    _providerMutationInProgress = true;
    _bumpRevision(clearPending: true, clearStates: true);
  }

  void _endProviderMutation() {
    _providerMutationInProgress = false;
    _bumpRevision(clearPending: true, clearStates: true);
  }

  void _ensureBatchValid(
    TranslationBatchKey key,
    bool Function() isStillValid,
  ) {
    if (!_enabled ||
        _providerMutationInProgress ||
        key.runtimeRevision != _revision ||
        !isStillValid()) {
      throw StateError('Translation runtime changed');
    }
  }

  static bool _providerMatchesBatch(
    TranslationProviderConfig provider,
    TranslationBatchKey key,
  ) =>
      provider.isValid &&
      provider.id == key.providerId &&
      provider.protocol == key.protocol &&
      provider.model == key.model;

  static bool _sameProviderConfiguration(
    TranslationProviderConfig first,
    TranslationProviderConfig second,
  ) =>
      first.id == second.id &&
      first.requestEndpoint == second.requestEndpoint &&
      first.protocol == second.protocol &&
      first.model == second.model;

  Future<Set<String>> _locallyKnownEditIds(Room room, String originalId) async {
    final result = <String>{};
    const pageSize = 200;
    var start = 0;
    while (true) {
      final events = await room.client.database.getEventList(
        room,
        start: start,
        limit: pageSize,
      );
      for (final event in events) {
        if (event.relationshipType == RelationshipTypes.edit &&
            event.relationshipEventId == originalId) {
          result.add(event.eventId);
        }
      }
      if (events.length < pageSize) break;
      start += events.length;
    }
    return result;
  }

  void _clearAllStates() {
    for (final notifier in _states.values) {
      notifier.dispose();
    }
    _states.clear();
  }

  void _bumpRevision({required bool clearPending, required bool clearStates}) {
    _revision++;
    if (clearPending) {
      _batcher?.cancelPending();
      _inputBatcher?.cancelPending();
    }
    if (clearStates) _clearAllStates();
    notifyListeners();
  }

  static final ValueNotifier<TranslationResultState> _disabledState =
      ValueNotifier(TranslationResultState.idle);
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
