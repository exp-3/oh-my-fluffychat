// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../file_description.dart';
import 'translation_api_client.dart';
import 'translation_batcher.dart';
import 'translation_cache.dart';
import 'translation_languages.dart';
import 'translation_models.dart';
import 'translation_preferences.dart';
import 'translation_roaming.dart';

typedef TranslationRoamingServiceFactory =
    TranslationRoamingService Function(
      TranslationRoamingConfig config,
      TranslationRoamingSecrets secrets,
    );

typedef _RoamingResult = ({
  int revision,
  int roamingRevision,
  int order,
  TranslationResultState result,
});

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

class TranslationRuntime extends ChangeNotifier with WidgetsBindingObserver {
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
  TranslationRoamingPreferences? _roamingPreferences;
  TranslationRoamingConfig _roamingConfig = const TranslationRoamingConfig();
  TranslationRoamingService? _roamingService;
  Future<TranslationRoamingService?>? _roamingLoading;
  TranslationRoamingServiceFactory _roamingFactory = (config, secrets) =>
      TranslationRoamingService(config: config, secrets: secrets);
  void Function(VoidCallback)? _afterRoamingFrame;
  Future<void> _roamingSaveTail = Future.value();
  int _roamingRevision = 0;
  int _roamingPendingMutations = 0;
  bool _roamingMutationInProgress = false;
  bool _disposed = false;
  final Map<String, ValueNotifier<TranslationResultState>> _states = {};
  final Map<String, ({int revision, bool forced, Future<String?> future})>
  _inFlight = {};
  final Map<String, TranslationCacheKey> _observed = {};
  final Map<String, Future<TranslationCacheLookup>> _cacheReads = {};
  final Map<String, int> _requestOrders = {};
  final Map<String, int> _manualRequests = {};
  final Map<String, _RoamingResult> _roamingResults = {};
  final Map<String, TranslationResultState> _roamingSaveRequests = {};
  final Map<Client, String> _clientUserIds = {};
  StreamSubscription<void>? _cacheSubscription;
  final Map<String, Future<List<Event>>> _localHistories = {};
  final Map<String, Set<String>> _knownEditChains = {};
  final Map<String, String> _originalEventIds = {};
  final Map<Client, List<StreamSubscription<Object?>>> _clientSubscriptions =
      {};
  final Map<Client, Set<String>> _knownClientRoomIds = {};
  final Set<Future<void>> _safetyFutures = {};
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
  int _safetyOperations = 0;

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
  bool get manualInputTranslationEnabled =>
      _inputMode == InputTranslationMode.manual ||
      _inputMode == InputTranslationMode.manualAndAutomatic;
  bool get automaticInputTranslationEnabled =>
      _inputMode == InputTranslationMode.automatic ||
      _inputMode == InputTranslationMode.manualAndAutomatic;
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

  TranslationRoamingConfig get roamingConfig => _roamingConfig;

  Future<TranslationRoamingSecrets> readRoamingSecrets() =>
      _roamingPreferences!.readSecrets();

  Future<({TranslationRoamingConfig config, TranslationRoamingSecrets secrets})>
  readRoamingSettings() {
    if (_disposed) {
      return Future.error(StateError('Translation runtime has been disposed'));
    }
    final operation = _roamingSaveTail.then((_) async {
      if (_disposed) throw StateError('Translation runtime has been disposed');
      final secrets = await _roamingPreferences!.readSecrets();
      if (_disposed) throw StateError('Translation runtime has been disposed');
      return (config: _roamingConfig, secrets: secrets);
    });
    // Later writes must wait until both parts of the snapshot have been read.
    _roamingSaveTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> saveRoaming(
    TranslationRoamingConfig config,
    TranslationRoamingSecrets secrets, {
    bool Function()? isCurrent,
  }) => _mutateRoaming(() async {
    if (isCurrent != null && !isCurrent()) return;
    if (config.enabled &&
        (!config.isValid ||
            !config.supportedOnPlatform ||
            !secrets.isValidFor(config))) {
      throw ArgumentError('Invalid translation roaming configuration');
    }
    try {
      await _roamingPreferences!.save(config, secrets);
      if (!_disposed) _roamingConfig = config;
    } catch (_) {
      // A partially saved configuration must never reuse an old connection.
      if (!_disposed) {
        _roamingConfig = _roamingConfig.copyWith(enabled: false);
      }
      rethrow;
    }
  });

  Future<void> setRoamingEnabled(bool enabled) => _mutateRoaming(() async {
    try {
      final config = await _roamingPreferences!.saveEnabled(enabled);
      if (!_disposed) _roamingConfig = config;
    } catch (_) {
      if (!_disposed) {
        _roamingConfig = _roamingConfig.copyWith(enabled: false);
      }
      rethrow;
    }
  });

  Future<void> _mutateRoaming(Future<void> Function() mutation) {
    if (_disposed) return Future.value();
    _roamingPendingMutations++;
    _roamingMutationInProgress = true;
    _resetRoaming();
    final operation = _roamingSaveTail.then((_) async {
      try {
        if (!_disposed) await mutation();
      } finally {
        _roamingPendingMutations--;
        _roamingMutationInProgress = _roamingPendingMutations != 0;
        if (!_disposed && !_roamingMutationInProgress) notifyListeners();
      }
    });
    _roamingSaveTail = operation.catchError((Object _) {});
    // Publish the queue entry before notifying potentially reentrant listeners.
    _bumpRevision(clearPending: true, clearStates: false);
    return operation;
  }

  Future<void> testRoaming(
    TranslationRoamingConfig config,
    TranslationRoamingSecrets secrets,
  ) async {
    if (!config.isValid ||
        !config.supportedOnPlatform ||
        !secrets.isValidFor(config)) {
      throw ArgumentError('Invalid translation roaming configuration');
    }
    final service = _roamingFactory(config, secrets);
    try {
      await service.testConnection();
    } finally {
      service.dispose();
    }
  }

  void _resetRoaming() {
    _roamingRevision++;
    _roamingLoading = null;
    _roamingService?.dispose();
    _roamingService = null;
  }

  Future<TranslationRoamingService?> _getRoaming() {
    if (_disposed ||
        !_enabled ||
        _roamingMutationInProgress ||
        !_roamingConfig.enabled ||
        !_roamingConfig.isValid ||
        !_roamingConfig.supportedOnPlatform) {
      return Future.value();
    }
    final existing = _roamingService;
    if (existing != null) return Future.value(existing);
    return _roamingLoading ??= _loadRoaming(_roamingRevision);
  }

  Future<TranslationRoamingService?> _loadRoaming(int revision) async {
    try {
      final secrets = await readRoamingSecrets();
      if (_disposed ||
          !_enabled ||
          revision != _roamingRevision ||
          !secrets.isValidFor(_roamingConfig)) {
        return null;
      }
      return _roamingService = _roamingFactory(_roamingConfig, secrets);
    } catch (_) {
      return null;
    } finally {
      if (revision == _roamingRevision) _roamingLoading = null;
    }
  }

  Future<void> initialize(
    SharedPreferences store, {
    String defaultTargetLanguage = 'en',
    TranslationSecretStore secrets = const SecureTranslationSecretStore(),
    TranslationApiClient? apiClient,
    TranslationCache? cache,
    TranslationRoamingServiceFactory? roamingFactory,
    void Function(VoidCallback)? afterRoamingFrame,
  }) async {
    if (_initialized) return;
    final preferences = _preferences = TranslationPreferences(store, secrets);
    _roamingPreferences = TranslationRoamingPreferences(store, secrets);
    _roamingConfig = _roamingPreferences!.config;
    if (roamingFactory != null) _roamingFactory = roamingFactory;
    _afterRoamingFrame = afterRoamingFrame;
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
    _enabled = _privacyAccepted && preferences.enabled;
    if (preferences.enabled && !_privacyAccepted) {
      await preferences.setEnabled(false);
    }
    _cache!.safetyPreferences = preferences;
    _cacheSubscription = _cache!.externalChanges.listen(
      (_) => _recheckExternalCache(),
    );
    WidgetsBinding.instance.addObserver(this);
    _batcher = TranslationBatcher(
      sender: _sendBatch,
      settings: () => _batchSettings,
    );
    _inputBatcher = TranslationBatcher(
      sender: _sendBatch,
      settings: () => _batchSettings,
    );
    _initialized = true;
  }

  Future<void> prepareCacheForStartup(
    List<Client> clients, {
    required Future<void> Function() onUpgrade,
  }) async {
    if (!_initialized) throw StateError('Translation runtime not initialized');
    _clients = List<Client>.from(clients);
    final startupUserIds = <Client, String>{};
    for (final client in clients) {
      final userId = _clientUserIds[client] ?? client.userID;
      if (userId == null) continue;
      startupUserIds[client] = userId;
      _clientUserIds[client] = userId;
      _knownClientRoomIds
          .putIfAbsent(client, () => {})
          .addAll(client.rooms.map((room) => room.id));
    }
    _safetyOperations++;
    _bumpRevision(clearPending: true, clearStates: true);
    try {
      for (final client in clients.where((client) => client.isLogged())) {
        await client.roomsLoading;
        await client.accountDataLoading;
      }
      // SDK clients can keep syncing while the router is gated. Subscribe
      // before reading the archive so edits and redactions queue cleanup.
      attachClients(clients);
      if (await cache.needsUpgrade()) {
        await onUpgrade();
        await cache.upgrade(
          (userId, roomId, eventId) =>
              _localSource(userId, roomId, eventId, strict: true),
          userIds: startupUserIds.values.toSet(),
        );
      }
    } finally {
      try {
        // Do not drain inside upgrade: its serial cache operation must finish
        // before the event-driven cleanup queued behind it can run.
        while (true) {
          final loggedOut = startupUserIds.entries
              .where(
                (entry) =>
                    !entry.key.isLogged() || entry.key.userID != entry.value,
              )
              .toList();
          for (final entry in loggedOut) {
            startupUserIds.remove(entry.key);
            _clientUserIds[entry.key] = entry.value;
            await detachLoggedOutClient(entry.key);
          }
          await _drainSafetyFutures();
          if (!startupUserIds.entries.any(
            (entry) =>
                !entry.key.isLogged() || entry.key.userID != entry.value,
          )) {
            break;
          }
        }
      } finally {
        _localHistories.clear();
        _safetyOperations--;
        _bumpRevision(clearPending: true, clearStates: true);
      }
    }
  }

  void _trackSafetyFuture(Future<void> operation) {
    late final Future<void> tracked;
    tracked = operation.catchError((Object _) {}).whenComplete(() {
      _safetyFutures.remove(tracked);
    });
    _safetyFutures.add(tracked);
    unawaited(tracked);
  }

  Future<void> _drainSafetyFutures() async {
    while (_safetyFutures.isNotEmpty) {
      await Future.wait(_safetyFutures.toList(growable: false));
    }
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
    if (client.userID != null) _clientUserIds[client] = client.userID!;
    _knownClientRoomIds
        .putIfAbsent(client, () => client.rooms.map((room) => room.id).toSet())
        .addAll(client.rooms.map((room) => room.id));
    if (_clientSubscriptions.containsKey(client)) return;
    // Stored in _clientSubscriptions and cancelled when the client logs out.
    // ignore: cancel_subscriptions
    final timeline = client.onTimelineEvent.stream.listen((event) {
      _knownClientRoomIds[client]?.add(event.room.id);
      _trackSafetyFuture(_handleTimelineEvent(event));
    });
    // ignore: cancel_subscriptions
    final history = client.onHistoryEvent.stream.listen((event) {
      _trackSafetyFuture(_handleTimelineEvent(event));
    });
    // The SDK currently exposes delayed decryption updates only on onEvent.
    // ignore: deprecated_member_use, cancel_subscriptions
    final decrypted = client.onEvent.stream.listen((update) {
      if (update.type != EventUpdateType.decryptedTimelineQueue) return;
      final room = client.getRoomById(update.roomID);
      if (room == null) return;
      _trackSafetyFuture(
        _handleTimelineEvent(Event.fromJson(update.content, room)),
      );
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
        _trackSafetyFuture(
          Future<void>.microtask(
            () => invalidateRoomUnlessLocallyReferenced(
              roomId,
              excludingClient: client,
            ),
          ),
        );
      }
    });
    // ignore: cancel_subscriptions
    final roomState = client.onRoomState.stream.listen((update) {
      _knownClientRoomIds[client]?.add(update.roomId);
      if (update.state.type != EventTypes.Encryption) return;
      _clearRoomStates(update.roomId);
      _bumpRevision(clearPending: true, clearStates: false);
    });
    _clientSubscriptions[client] = [
      timeline,
      history,
      decrypted,
      sync,
      roomState,
    ];
  }

  Future<void> detachLoggedOutClient(Client client) async {
    final userId = _clientUserIds.remove(client) ?? client.userID;
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
    if (userId != null &&
        !_clients.any((other) => other.isLogged() && other.userID == userId)) {
      await cache.invalidateUserIfExists(userId);
    }
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
    if (value && !_privacyAccepted) return false;
    if (value) {
      // A disabled context deliberately ignores cache activity. Refresh its
      // connection/key before making restored translations visible again.
      try {
        await cache.refreshSafetyState();
      } catch (_) {
        // Storage availability does not change the user's global preference.
      }
    }
    if (mutationToken != _enabledMutationToken) return false;
    _enabled = value;
    if (!value) _resetRoaming();
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
    _bumpRevision(clearPending: true, clearStates: false);
    await preferences.setScope(value);
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
    _bumpRevision(clearPending: true, clearStates: false);
    await preferences.setInputMode(value);
  }

  Future<void> setInputTranslationMode(TranslationInputMode value) =>
      setInputMode(value);

  Future<void> setManualInputTranslationEnabled(bool value) =>
      _setInputTranslationEnabled(value, automaticInputTranslationEnabled);

  Future<void> setAutomaticInputTranslationEnabled(bool value) =>
      _setInputTranslationEnabled(manualInputTranslationEnabled, value);

  Future<void> _setInputTranslationEnabled(bool manual, bool automatic) =>
      setInputMode(switch ((manual, automatic)) {
        (true, true) => InputTranslationMode.manualAndAutomatic,
        (true, false) => InputTranslationMode.manual,
        (false, true) => InputTranslationMode.automatic,
        (false, false) => InputTranslationMode.disabled,
      });

  Future<void> setInputScope(InputTranslationScope value) async {
    if (value == _inputScope) return;
    _inputScope = value;
    _bumpRevision(clearPending: true, clearStates: false);
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
    _bumpRevision(clearPending: true, clearStates: false);
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
    _bumpRevision(clearPending: true, clearStates: false);
    await preferences.setInputTrigger(value);
  }

  Future<void> setInputTranslationTrigger(TranslationInputTrigger value) =>
      setInputTrigger(value);

  Future<void> setInputSendMode(InputTranslationSendMode value) async {
    if (value == _inputSendMode) return;
    _inputSendMode = value;
    _bumpRevision(clearPending: true, clearStates: false);
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
      manualInputTranslationEnabled && canTranslateInput(room);

  bool shouldAutoTranslateInput(Room room) =>
      automaticInputTranslationEnabled && canTranslateInput(room);

  bool shouldTranslateInputOnSend(Room room, {bool? requested}) {
    if (!shouldAutoTranslateInput(room)) return false;
    return requested ??
        _inputSendMode == InputTranslationSendMode.shortTranslatedLongOriginal;
  }

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
        reasoningEffort: provider.reasoningEffort,
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

  /// Cache display is independent of provider configuration and room auto mode.
  bool canTranslateEvent(Event event) {
    if (_disposed ||
        !_enabled ||
        _safetyOperations != 0 ||
        (event.type != EventTypes.Message &&
            event.type != EventTypes.Sticker) ||
        event.redacted ||
        event.eventId.isEmpty ||
        event.room.client.userID == null) {
      return false;
    }
    final replacement = _replacementEvent(event);
    if (_isMediaEvent(replacement)) {
      return replacement.fileDescription?.trim().isNotEmpty == true;
    }
    return const {
          MessageTypes.Text,
          MessageTypes.Notice,
          MessageTypes.Emote,
        }.contains(event.messageType) &&
        event.body.trim().isNotEmpty;
  }

  String sourceForEvent(Event event) {
    final replacement = _replacementEvent(event);
    if (_isMediaEvent(replacement)) return replacement.fileDescription ?? '';
    return event.isRichMessage ? event.formattedText : event.body;
  }

  bool _isMediaEvent(Event event) =>
      event.type == EventTypes.Sticker ||
      const {
        MessageTypes.Image,
        MessageTypes.File,
        MessageTypes.Video,
        MessageTypes.Audio,
        MessageTypes.Sticker,
      }.contains(event.messageType);

  Event _replacementEvent(Event event) {
    if (event.relationshipType != RelationshipTypes.edit) return event;
    final content = event.content.tryGetMap<String, Object?>('m.new_content');
    if (content == null) return event;
    return Event(
      content: content,
      type: event.type,
      eventId: event.eventId,
      senderId: event.senderId,
      originServerTs: event.originServerTs,
      room: event.room,
    );
  }

  bool shouldAutoTranslate(Event event) =>
      canTranslateEvent(event) && roomControl(event.room).value;

  /// Matrix display events omit the edit relationship. Keep the original ID
  /// supplied by the timeline so cache references survive a later redaction.
  void observeDisplayEvent(Event original, Event displayed) {
    if (!_enabled || original.eventId == displayed.eventId) return;
    _originalEventIds[jsonEncode([
          displayed.room.client.userID,
          displayed.room.id,
          displayed.eventId,
        ])] =
        original.eventId;
    _knownEditChains
        .putIfAbsent('${original.room.id}\u0000${original.eventId}', () => {})
        .add(displayed.eventId);
  }

  ValueListenable<TranslationResultState> stateForEvent(Event event) {
    if (!canTranslateEvent(event)) return _disabledState;
    final key = _stateKey(event);
    _observed[key] = _cacheKey(event, sourceForEvent(event));
    final contentKey = _contentKey(_observed[key]!);
    final restored = _roamingResults[contentKey];
    final current =
        restored != null &&
            restored.revision == _revision &&
            restored.roamingRevision == _roamingRevision &&
            restored.order == _requestOrders[contentKey]
        ? restored.result
        : TranslationResultState.idle;
    return _states.putIfAbsent(key, () => ValueNotifier(current));
  }

  String _contentKey(TranslationCacheKey key) =>
      jsonEncode([key.userId, ...key.identity(key.source)]);

  bool _displayTaskValid(Event event, TranslationCacheKey key) =>
      canTranslateEvent(event) &&
      event.room.client.isLogged() &&
      event.room.membership == Membership.join &&
      event.room.client.userID == key.userId &&
      event.eventId == key.eventId &&
      sourceForEvent(event) == key.source &&
      event.messageType == key.messageType &&
      _sourceLanguageForRoom(event.room) == key.sourceLanguage &&
      _effectiveTargetLanguage == key.targetLanguage;

  /// Called for loaded messages even in rooms with automatic translation off.
  /// Unavailable storage is deliberately distinct from a genuine cache miss.
  Future<String?> restoreEvent(Event event) =>
      translateEvent(event, manual: false);

  Future<String?> translateEvent(
    Event event, {
    required bool manual,
    bool? forceRefresh,
  }) async {
    if (!canTranslateEvent(event)) return null;
    final state = stateForEvent(event) as ValueNotifier<TranslationResultState>;
    final key = _observed[_stateKey(event)]!;
    final contentKey = _contentKey(key);
    final taskRevision = _revision;
    final previous = state.value.translation;
    final force = manual && (forceRefresh ?? previous != null);
    final joining = _inFlight[contentKey];
    if (manual && joining == null) {
      // Let a deliberate retry recover from temporarily unavailable storage.
      _cacheReads.remove(_stateKey(event));
    }
    // Read once per loaded message/revision. Every alias records a reference,
    // including misses that might be translated by an in-flight request.
    final lookupFuture = _cacheReads.putIfAbsent(
      _stateKey(event),
      () => cache.lookup(key),
    );
    final cached = await lookupFuture;
    if (!_displayTaskValid(event, key) || taskRevision != _revision) {
      return null;
    }
    // Even aliases joining a running request must first register their own
    // reference. Otherwise a deletion after restart could miss shared content.
    // Preserve a join even if the request completed while this alias was
    // recording its reference; one click must not become a second refresh.
    final pending = _inFlight[contentKey] ?? joining;
    if (pending != null &&
        pending.revision == taskRevision &&
        (!force || pending.forced)) {
      if (manual) {
        // A user click upgrades an automatic cloud lookup while it is pending.
        // Otherwise a miss in an auto-off room could silently consume the click.
        _manualRequests[contentKey] = _requestOrders[contentKey] ?? 0;
      }
      if (state.value.translation == null && cached.translation != null) {
        state.value = TranslationResultState.refreshing(cached.translation!);
      }
      final result = await pending.future;
      if (taskRevision != _revision || !_displayTaskValid(event, key)) {
        return null;
      }
      if (result == null && manual) {
        // The automatic miss may have completed while this alias registered
        // its local reference, before the manual intent could be upgraded.
        return translateEvent(event, manual: true, forceRefresh: true);
      }
      _saveObservedRoaming(event, key, cached, contentKey, state.value);
      return result;
    }
    if (!force) {
      final current = state.value.translation;
      if (current != null) {
        _saveObservedRoaming(event, key, cached, contentKey, state.value);
        return current;
      }
      if (cached.status == TranslationCacheLookupStatus.hit) {
        _publish(
          contentKey,
          TranslationResultState.translated(cached.translation!),
        );
        return cached.translation;
      }
    }
    if (cached.status == TranslationCacheLookupStatus.unavailable ||
        cached.ticket == null) {
      if (!manual) return null;
      state.value = TranslationResultState.failed(
        StateError('Translation cache unavailable'),
        previous: previous,
      );
      return null;
    }
    final order = (_requestOrders[contentKey] ?? 0) + 1;
    _requestOrders[contentKey] = order;
    if (manual) _manualRequests[contentKey] = order;
    final operation = _restoreOrTranslate(
      event,
      key,
      cached.ticket!,
      contentKey,
      order,
      manual,
      force,
    );
    _inFlight[contentKey] = (
      revision: taskRevision,
      forced: force,
      future: operation,
    );
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[contentKey]?.future, operation)) {
        _inFlight.remove(contentKey);
      }
    }
  }

  void _publish(String contentKey, TranslationResultState result) {
    for (final entry in _observed.entries) {
      if (_contentKey(entry.value) == contentKey) {
        _states[entry.key]?.value = result;
      }
    }
  }

  Future<String?> _restoreOrTranslate(
    Event event,
    TranslationCacheKey key,
    TranslationCacheTicket ticket,
    String contentKey,
    int order,
    bool manual,
    bool force,
  ) async {
    final taskRevision = _revision;
    final roamingRevision = _roamingRevision;
    bool valid() =>
        taskRevision == _revision &&
        roamingRevision == _roamingRevision &&
        _requestOrders[contentKey] == order &&
        _displayTaskValid(event, key);
    if (!force && _roamingConfig.enabled) {
      final roaming = await _getRoaming();
      if (!valid()) return null;
      if (roaming != null) {
        final restored = await roaming.lookup(
          source: key.source,
          targetLanguage: key.targetLanguage,
        );
        if (!valid()) return null;
        if (restored.status == TranslationRoamingLookupStatus.hit &&
            restored.translation != null) {
          final result = TranslationResultState.translated(
            restored.translation!,
          );
          _roamingResults[contentKey] = (
            revision: taskRevision,
            roamingRevision: roamingRevision,
            order: order,
            result: result,
          );
          _publish(contentKey, result);
          _saveRoamingAfterFrame(
            key,
            ticket,
            contentKey,
            _stateKey(event),
            result,
            valid,
          );
          return restored.translation;
        }
      }
    }
    final requestedManually = manual || _manualRequests[contentKey] == order;
    if (!valid() || (!requestedManually && !shouldAutoTranslate(event))) {
      return null;
    }
    return _translate(event, key, ticket, contentKey, order, requestedManually);
  }

  void _saveRoamingAfterFrame(
    TranslationCacheKey key,
    TranslationCacheTicket ticket,
    String contentKey,
    String stateKey,
    TranslationResultState result,
    bool Function() isValid,
  ) {
    if (identical(_roamingSaveRequests[stateKey], result)) return;
    _roamingSaveRequests[stateKey] = result;
    void save() {
      if (!isValid()) return;
      unawaited(_persistRoaming(key, ticket, contentKey, result, isValid));
    }

    final scheduler = _afterRoamingFrame;
    if (scheduler != null) {
      scheduler(save);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => save());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _saveObservedRoaming(
    Event event,
    TranslationCacheKey key,
    TranslationCacheLookup cached,
    String contentKey,
    TranslationResultState current,
  ) {
    final restored = _roamingResults[contentKey];
    if (restored == null ||
        !identical(current, restored.result) ||
        cached.status != TranslationCacheLookupStatus.miss ||
        cached.ticket == null) {
      return;
    }
    // An alias may appear before the first disk save. Reuse memory and save
    // its own reference without another GETEX or a duplicate per-event write.
    _saveRoamingAfterFrame(
      key,
      cached.ticket!,
      contentKey,
      _stateKey(event),
      restored.result,
      () =>
          restored.revision == _revision &&
          restored.roamingRevision == _roamingRevision &&
          restored.order == _requestOrders[contentKey] &&
          _displayTaskValid(event, key),
    );
  }

  Future<void> _persistRoaming(
    TranslationCacheKey key,
    TranslationCacheTicket ticket,
    String contentKey,
    TranslationResultState result,
    bool Function() isValid,
  ) async {
    try {
      await cache.write(
        key,
        result.translation!,
        ticket: ticket,
        isValid: isValid,
      );
      if (isValid()) _forgetCacheReads(key);
    } on TranslationCacheWriteInvalidated {
      // Runtime changes already decide whether visible results should remain.
      // A superseded save must not undo that decision (e.g. auto mode off).
      if (!isValid()) return;
      if (identical(_roamingResults[contentKey]?.result, result)) {
        _roamingResults.remove(contentKey);
      }
      // Never let a late save erase a newer result from a deliberate refresh.
      for (final entry in _observed.entries) {
        if (_contentKey(entry.value) != contentKey) continue;
        final state = _states[entry.key];
        if (state != null && identical(state.value, result)) {
          state.value = TranslationResultState.idle;
          _cacheReads.remove(entry.key);
        }
      }
    } catch (_) {
      // An ordinary disk failure does not undo a valid, visible translation.
    }
  }

  void _forgetCacheReads(TranslationCacheKey key) {
    final identity = jsonEncode(key.identity(key.source));
    _cacheReads.removeWhere(
      (stateKey, _) =>
          _observed[stateKey] != null &&
          jsonEncode(
            _observed[stateKey]!.identity(_observed[stateKey]!.source),
          ) == identity,
    );
  }

  Future<void> _uploadRoaming(
    TranslationCacheKey key,
    String translation,
    int roamingRevision,
    bool Function() isValid,
  ) async {
    try {
      if (!isValid() || roamingRevision != _roamingRevision) return;
      final roaming = await _getRoaming();
      if (roaming == null ||
          !isValid() ||
          roamingRevision != _roamingRevision) {
        return;
      }
      await roaming.upload(
        source: key.source,
        targetLanguage: key.targetLanguage,
        translation: translation,
        isValid: () => isValid() && roamingRevision == _roamingRevision,
      );
    } catch (_) {
      // Roaming is optional: upload failure cannot fail local translation.
    }
  }

  Future<String> _translate(
    Event event,
    TranslationCacheKey key,
    TranslationCacheTicket ticket,
    String contentKey,
    int order,
    bool manual,
  ) async {
    final taskRevision = _revision;
    final roamingRevision = _roamingRevision;
    final provider = _activeProvider;
    final previous = _states[_stateKey(event)]?.value.translation;
    bool valid() =>
        taskRevision == _revision &&
        _requestOrders[contentKey] == order &&
        _displayTaskValid(event, key) &&
        !_providerMutationInProgress &&
        provider != null &&
        _activeProvider != null &&
        _sameProviderConfiguration(provider, _activeProvider!) &&
        (manual || shouldAutoTranslate(event));
    _publish(
      contentKey,
      previous == null
          ? TranslationResultState.loading
          : TranslationResultState.refreshing(previous),
    );
    try {
      if (provider == null || !provider.isValid || !valid()) {
        throw StateError('Translation provider unavailable');
      }
      final result = await _batcher!.add(
        TranslationBatchKey(
          roomId: event.room.id,
          providerId: provider.id,
          protocol: provider.protocol,
          model: provider.model,
          reasoningEffort: provider.reasoningEffort,
          sourceLanguage: key.sourceLanguage,
          targetLanguage: key.targetLanguage,
          promptRevision: promptRevision,
          runtimeRevision: taskRevision,
        ),
        TranslationBatchTask(
          source: key.source,
          messageType: key.messageType,
          isValid: valid,
        ),
      );
      if (!valid()) throw StateError('Translation task expired');
      final writeKey = _cacheKey(event, key.source, model: provider.model);
      await cache.write(writeKey, result, ticket: ticket, isValid: valid);
      if (!valid()) throw StateError('Translation task expired');
      _forgetCacheReads(writeKey);
      _publish(contentKey, TranslationResultState.translated(result));
      unawaited(_uploadRoaming(writeKey, result, roamingRevision, valid));
      return result;
    } catch (error) {
      if (taskRevision == _revision &&
          _requestOrders[contentKey] == order &&
          _displayTaskValid(event, key)) {
        _publish(
          contentKey,
          TranslationResultState.failed(error, previous: previous),
        );
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

  Future<void> invalidateEventIfExists(
    String roomId,
    String eventId,
  ) async {
    final affected = _observed.entries
        .where(
          (entry) =>
              entry.value.roomId == roomId &&
              (entry.value.eventId == eventId ||
                  entry.value.originalEventId == eventId),
        )
        .toList();
    for (final entry in affected) {
      _observed.remove(entry.key);
    }
    // Discard obsolete snapshots, every displayed result and queued request
    // before awaiting any database operation.
    _bumpRevision(clearPending: true, clearStates: true);
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
    final userIds = {
      if (excludingClient != null && excludingClient.userID != null)
        excludingClient.userID!,
      for (final client in _clients)
        if (client.userID != null) client.userID!,
    };
    for (final userId in userIds) {
      final userHasRoom = _clients.any((client) {
        if (identical(client, excludingClient) ||
            !client.isLogged() || client.userID != userId) {
          return false;
        }
        return client.getRoomById(roomId)?.membership == Membership.join;
      });
      if (!userHasRoom) {
        await cache.invalidateRoomIfExists(roomId, userId: userId);
      }
    }
    if (referenced) return;
    await cache.invalidateRoomIfExists(roomId);
  }

  void _clearRoomStates(String roomId) {
    final keys = _observed.entries
        .where((entry) => entry.value.roomId == roomId)
        .map((entry) => entry.key)
        .toSet();
    for (final key in keys) {
      _states.remove(key)?.value = TranslationResultState.idle;
      _observed.remove(key);
      _cacheReads.remove(key);
    }
    _knownEditChains.removeWhere((key, _) => key.startsWith('$roomId\u0000'));
    _originalEventIds.removeWhere(
      (key, _) => (jsonDecode(key) as List)[1] == roomId,
    );
    _localHistories.removeWhere(
      (key, _) => (jsonDecode(key) as List)[1] == roomId,
    );
  }

  Future<TranslationLocalSource> _localSource(
    String userId,
    String roomId,
    String eventId, {
    bool strict = false,
  }) async {
    for (final client in _clients) {
      if (!client.isLogged() ||
          (userId.isNotEmpty && client.userID != userId)) {
        continue;
      }
      final room = client.getRoomById(roomId);
      if (room == null || room.membership != Membership.join) continue;
      try {
        final event = await client.database.getEventById(eventId, room);
        if (event == null) return TranslationLocalSource.unavailable;
        if (event.redacted) return TranslationLocalSource.obsolete;
        if ((event.type != EventTypes.Message &&
                event.type != EventTypes.Sticker) ||
            (!_isMediaEvent(_replacementEvent(event)) &&
                event.body.trim().isEmpty)) {
          return TranslationLocalSource.unavailable;
        }
        final rootId = event.relationshipType == RelationshipTypes.edit
            ? event.relationshipEventId
            : event.eventId;
        if (rootId == null) return TranslationLocalSource.unavailable;
        final history = await _localHistory(room);
        final edits =
            history
                .where(
                  (item) =>
                      item.relationshipType == RelationshipTypes.edit &&
                      item.relationshipEventId == rootId &&
                      !item.redacted &&
                      item.senderId == event.senderId,
                )
                .toList()
              ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
        if (event.relationshipType == RelationshipTypes.edit) {
          final original = await client.database.getEventById(rootId, room);
          if (original == null) return TranslationLocalSource.unavailable;
          if (original.type != EventTypes.Message &&
              original.type != EventTypes.Sticker &&
              !original.redacted) {
            return TranslationLocalSource.unavailable;
          }
          if (original.redacted ||
              (edits.isNotEmpty && edits.last.eventId != event.eventId)) {
            return TranslationLocalSource.obsolete;
          }
          return _localSourceForEvent(event, originalEventId: rootId);
        }
        return _localSourceForEvent(edits.isEmpty ? event : edits.last);
      } catch (_) {
        if (strict) rethrow;
        return TranslationLocalSource.unavailable;
      }
    }
    return TranslationLocalSource.unavailable;
  }

  Future<TranslationCacheCleanupResult> cleanInvalidCache() async {
    _localHistories.clear();
    _bumpRevision(clearPending: true, clearStates: true);
    final result = await cache.cleanInvalid(_localSource);
    if (result.deleted > 0) {
      _bumpRevision(clearPending: true, clearStates: true);
    }
    return result;
  }

  Future<void> clearCache() async {
    _bumpRevision(clearPending: true, clearStates: true);
    await cache.deleteIfExists();
  }

  void _recheckExternalCache() {
    if (!_enabled) return;
    unawaited(cache.refreshSafetyState().catchError((_) {}));
    _bumpRevision(clearPending: true, clearStates: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _recheckExternalCache();
  }

  Future<void> _handleTimelineEvent(Event event) async {
    _localHistories.remove(
      jsonEncode([event.room.client.userID, event.room.id]),
    );
    if (event.type != EventTypes.Redaction &&
        event.relationshipType != RelationshipTypes.edit) {
      return;
    }
    // Another tab can have a request in flight before the first database is
    // created. Invalidate its runtime even when this context has no store.
    cache.backend.signalInvalidation();
    final hasMemory = _observed.values.any(
      (key) => key.roomId == event.room.id,
    );
    if (!hasMemory) {
      try {
        if (!await cache.backend.exists()) return;
      } catch (_) {
        /* Queue safety cleanup below. */
      }
    }
    // Block translation while mappings for the edit chain are detached.
    _safetyOperations++;
    _bumpRevision(clearPending: true, clearStates: true);
    try {
      if (event.type == EventTypes.Redaction && event.redacts != null) {
        final targetId = event.redacts!;
        var originalId =
            _originalEventIds[jsonEncode([
              event.room.client.userID,
              event.room.id,
              targetId,
            ])] ??
            targetId;
        await invalidateEventIfExists(
          event.room.id,
          targetId,
        );
        try {
          final target = await event.room.client.database.getEventById(
            targetId,
            event.room,
          );
          if (target?.relationshipType == RelationshipTypes.edit) {
            originalId = target!.relationshipEventId ?? targetId;
            await invalidateEventIfExists(
              event.room.id,
              originalId,
            );
          }
        } catch (_) {
          /* Persisted references still invalidate the direct target. */
        }
        final chainKey = '${event.room.id}\u0000$originalId';
        final relatedEditIds = {
          ...?_knownEditChains.remove(chainKey),
          ...await _locallyKnownEditIds(event.room, originalId),
        };
        for (final editId in relatedEditIds) {
          await invalidateEventIfExists(
            event.room.id,
            editId,
          );
        }
        for (final edits in _knownEditChains.values) {
          edits.remove(targetId);
        }
      }
      if (event.relationshipType == RelationshipTypes.edit) {
        final originalId = event.relationshipEventId;
        if (originalId != null) {
          await invalidateEventIfExists(
            event.room.id,
            originalId,
          );
          final chainKey = '${event.room.id}\u0000$originalId';
          final knownEdits = _knownEditChains.putIfAbsent(chainKey, () => {});
          knownEdits.addAll(await _locallyKnownEditIds(event.room, originalId));
          for (final editId in knownEdits) {
            if (editId == event.eventId) continue;
            await invalidateEventIfExists(
              event.room.id,
              editId,
            );
          }
          knownEdits.add(event.eventId);
        }
        await invalidateEventIfExists(event.room.id, event.eventId);
      }
    } finally {
      _safetyOperations--;
      if (_safetyOperations == 0) {
        _bumpRevision(clearPending: true, clearStates: true);
      }
    }
  }

  String _sourceForCachedEvent(Event event) {
    final replacement = _replacementEvent(event);
    if (_isMediaEvent(replacement)) return sourceForEvent(replacement);
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

  TranslationLocalSource _localSourceForEvent(
    Event event, {
    String? originalEventId,
  }) {
    final source = _sourceForCachedEvent(event);
    if (_isMediaEvent(_replacementEvent(event)) && source.trim().isEmpty) {
      return TranslationLocalSource.obsolete;
    }
    return TranslationLocalSource.valid(
      source,
      originalEventId: originalEventId,
    );
  }

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

  TranslationCacheKey _cacheKey(Event event, String source, {String? model}) =>
      TranslationCacheKey(
        userId: event.room.client.userID ?? '',
        originalEventId: event.relationshipType == RelationshipTypes.edit
            ? event.relationshipEventId
            : _originalEventIds[jsonEncode([
                event.room.client.userID,
                event.room.id,
                event.eventId,
              ])],
        roomId: event.room.id,
        eventId: event.eventId,
        source: source,
        sourceLanguage: _sourceLanguageForRoom(event.room),
        targetLanguage: _effectiveTargetLanguage,
        messageType: event.messageType,
        model: model,
      );

  String _stateKey(Event event) => jsonEncode([
    event.room.client.userID,
    event.room.id,
    event.eventId,
    sourceForEvent(event),
    event.messageType,
    _sourceLanguageForRoom(event.room),
    _effectiveTargetLanguage,
  ]);

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

  void _beginProviderMutation() {
    if (_providerMutationInProgress) {
      throw StateError('Another translation provider update is in progress');
    }
    _providerMutationInProgress = true;
    _bumpRevision(clearPending: true, clearStates: false);
  }

  void _endProviderMutation() {
    _providerMutationInProgress = false;
    _bumpRevision(clearPending: true, clearStates: false);
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
      provider.model == key.model &&
      provider.reasoningEffort == key.reasoningEffort;

  static bool _sameProviderConfiguration(
    TranslationProviderConfig first,
    TranslationProviderConfig second,
  ) =>
      first.id == second.id &&
      first.requestEndpoint == second.requestEndpoint &&
      first.protocol == second.protocol &&
      first.model == second.model &&
      first.reasoningEffort == second.reasoningEffort;

  Future<List<Event>> _localHistory(Room room) => _localHistories.putIfAbsent(
    jsonEncode([room.client.userID, room.id]),
    () async {
      final result = <Event>[];
      final seen = <String>{};
      const pageSize = 200;
      var start = 0;
      while (true) {
        final events = await room.client.database.getEventList(
          room,
          start: start,
          limit: pageSize,
        );
        result.addAll(events.where((event) => seen.add(event.eventId)));
        if (events.length < pageSize) return result;
        // SDK sending events are prepended only to page zero and must not
        // advance the stored timeline offset.
        start += pageSize;
      }
    },
  );

  Future<Set<String>> _locallyKnownEditIds(Room room, String originalId) async {
    try {
      return {
        for (final event in await _localHistory(room))
          if (event.relationshipType == RelationshipTypes.edit &&
              event.relationshipEventId == originalId)
            event.eventId,
      };
    } catch (_) {
      // Translation safety must never break ordinary timeline processing.
      return {};
    }
  }

  void _clearAllStates() {
    for (final notifier in _states.values) {
      notifier.value = TranslationResultState.idle;
    }
    _states.clear();
    _cacheReads.clear();
  }

  void _bumpRevision({required bool clearPending, required bool clearStates}) {
    _revision++;
    _roamingResults.clear();
    _roamingSaveRequests.clear();
    _cacheReads.clear();
    if (clearPending) {
      _batcher?.cancelPending();
      _inputBatcher?.cancelPending();
      _inFlight.clear();
      _requestOrders.clear();
      _manualRequests.clear();
      for (final notifier in _states.values) {
        if (notifier.value.status == TranslationStatus.loading) {
          final previous = notifier.value.translation;
          notifier.value = previous == null
              ? TranslationResultState.idle
              : TranslationResultState.translated(previous);
        }
      }
    }
    if (clearStates) _clearAllStates();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _resetRoaming();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cacheSubscription?.cancel());
    _batcher?.dispose();
    _inputBatcher?.dispose();
    for (final subscriptions in _clientSubscriptions.values) {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    }
    for (final notifier in _states.values) {
      notifier.dispose();
    }
    _observed.clear();
    _roamingResults.clear();
    _roamingSaveRequests.clear();
    _originalEventIds.clear();
    _localHistories.clear();
    _knownEditChains.clear();
    unawaited(_cache?.dispose());
    super.dispose();
  }

  static final ValueNotifier<TranslationResultState> _disabledState =
      ValueNotifier(TranslationResultState.idle);
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
