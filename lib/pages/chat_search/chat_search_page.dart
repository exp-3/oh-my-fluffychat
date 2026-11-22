// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/pages/chat_search/chat_search_status_controller.dart';
import 'package:fluffychat/pages/chat_search/chat_search_view.dart';
import 'package:fluffychat/utils/chat_search_session.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatSearchPage extends StatefulWidget {
  final String roomId;
  const ChatSearchPage({required this.roomId, super.key});

  @override
  ChatSearchController createState() => ChatSearchController();
}

class ChatSearchMediaState {
  final List<Event> events = [];
  String? nextBatch;
  bool initialized = false;
  bool isLoading = false;
  bool endReached = false;
  DateTime? searchedUntil;
  Object? error;
}

class ChatSearchController extends State<ChatSearchPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Room? get room => Matrix.of(context).client.getRoomById(widget.roomId);

  final TextEditingController searchController = TextEditingController();
  late final TabController tabController;
  final statusController = ChatSearchStatusController();

  ChatSearchSession? session;
  ChatSearchMediaState imagesState = ChatSearchMediaState();
  ChatSearchMediaState filesState = ChatSearchMediaState();
  int _selectedTab = 0;
  int _bindingRevision = 0;
  bool _availabilityUpdatePending = false;

  void submitQuery() => session?.submitQuery(searchController.text);

  void pauseSearch() {
    statusController.expand();
    session?.pause();
  }

  void resumeSearch() {
    statusController.expand();
    session?.resume();
  }

  Future<void> loadImages() => _loadMedia(imagesState, images: true);

  Future<void> loadFiles() => _loadMedia(filesState, images: false);

  Future<void> _loadMedia(
    ChatSearchMediaState state, {
    required bool images,
  }) async {
    final searchRoom = room;
    if (searchRoom == null ||
        !searchRoom.client.isLogged() ||
        searchRoom.membership != Membership.join ||
        state.isLoading ||
        state.endReached) {
      return;
    }
    final revision = _bindingRevision;
    setState(() {
      state.initialized = true;
      state.isLoading = true;
      state.error = null;
    });
    bool isCurrent() =>
        mounted &&
        revision == _bindingRevision &&
        identical(room, searchRoom) &&
        searchRoom.client.isLogged() &&
        searchRoom.membership == Membership.join;
    try {
      final result = await searchRoom.searchEvents(
        searchFunc: images
            ? (event) => const {
                MessageTypes.Image,
                MessageTypes.Video,
              }.contains(event.messageType)
            : (event) =>
                  event.messageType == MessageTypes.File ||
                  (event.messageType == MessageTypes.Audio &&
                      !event.content.containsKey('org.matrix.msc3245.voice')),
        nextBatch: state.nextBatch,
      );
      if (!isCurrent()) return;
      setState(() {
        final merged = <String, Event>{
          for (final event in state.events) event.eventId: event,
          for (final event in result.events) event.eventId: event,
        };
        state.events
          ..clear()
          ..addAll(merged.values);
        state.nextBatch = result.nextBatch;
        state.endReached = result.nextBatch == null;
        state.searchedUntil = result.searchedUntil;
      });
    } catch (error, stackTrace) {
      if (!isCurrent()) return;
      Logs().w('Unable to search room media', error, stackTrace);
      setState(() {
        state.error = error;
      });
    } finally {
      if (isCurrent()) {
        setState(() {
          state.isLoading = false;
        });
      }
    }
  }

  void _onTabChanged() {
    final index = tabController.index;
    if (index == _selectedTab) return;
    statusController.selectTab(index);
    setState(() {
      _selectedTab = index;
    });
    switch (index) {
      case 1:
        if (!imagesState.initialized) unawaited(loadImages());
        break;
      case 2:
        if (!filesState.initialized) unawaited(loadFiles());
        break;
    }
  }

  void _onSessionChanged() {
    if (!mounted) return;
    final currentSession = session;
    if (currentSession == null) return;
    statusController.updateSearch(
      query: currentSession.query,
      queryRevision: currentSession.queryRevision,
      runState: currentSession.runState,
    );
    if (_availabilityUpdatePending) return;
    final searchRoom = currentSession.room;
    if (identical(room, searchRoom) &&
        searchRoom.client.isLogged() &&
        searchRoom.membership == Membership.join) {
      return;
    }
    // Progress only rebuilds the results and overlay. Rebuild the enclosing
    // page once when its account/room is no longer available.
    _availabilityUpdatePending = true;
    scheduleMicrotask(() {
      _availabilityUpdatePending = false;
      if (!mounted) return;
      setState(() {
        _bindingRevision++;
        imagesState = ChatSearchMediaState();
        filesState = ChatSearchMediaState();
      });
    });
  }

  void _bindSession() {
    final candidate = room;
    final searchRoom =
        candidate != null &&
            candidate.client.isLogged() &&
            candidate.membership == Membership.join
        ? candidate
        : null;
    if (identical(session?.room, searchRoom)) return;
    _bindingRevision++;
    session?.removeListener(_onSessionChanged);
    session?.dispose();
    session = null;
    statusController.reset();
    imagesState = ChatSearchMediaState();
    filesState = ChatSearchMediaState();
    searchController.clear();
    if (searchRoom == null) return;
    final nextSession = ChatSearchSession(searchRoom);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    nextSession.setForeground(
      lifecycle == null || lifecycle == AppLifecycleState.resumed,
    );
    nextSession.addListener(_onSessionChanged);
    session = nextSession;
    if (_selectedTab == 1 || _selectedTab == 2) {
      final revision = _bindingRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _bindingRevision) return;
        if (_selectedTab == 1) unawaited(loadImages());
        if (_selectedTab == 2) unawaited(loadFiles());
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tabController = TabController(initialIndex: 0, length: 3, vsync: this);
    tabController.addListener(_onTabChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindSession();
  }

  @override
  void didUpdateWidget(covariant ChatSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId) _bindSession();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    session?.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    _bindingRevision++;
    WidgetsBinding.instance.removeObserver(this);
    session?.removeListener(_onSessionChanged);
    session?.dispose();
    tabController.removeListener(_onTabChanged);
    searchController.dispose();
    tabController.dispose();
    statusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Matrix.of intentionally does not listen to active-account changes.
    // Reconcile on parent rebuilds as well as dependency/widget changes.
    _bindSession();
    return ChatSearchView(this);
  }
}
