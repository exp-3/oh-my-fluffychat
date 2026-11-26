// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/chat_search_models.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';

class ChatSearchStatusController extends ChangeNotifier {
  static const scrollThreshold = 24.0;

  bool _collapsed = false;
  bool _disposed = false;
  bool _userScrolling = false;
  bool _visibilityUpdatePending = false;
  bool? _pendingCollapsed;
  double _scrollDistance = 0;
  double _expandedHeight = 0;
  int _selectedTab = 0;
  int _queryRevision = -1;
  String _query = '';
  ChatSearchRunState _runState = ChatSearchRunState.idle;

  bool get collapsed => _collapsed;

  // Keep the full bar's space at the list's end even while it is collapsed.
  double get bottomInset => _query.isEmpty ? 0 : _expandedHeight;

  void updateSearch({
    required String query,
    required int queryRevision,
    required ChatSearchRunState runState,
  }) {
    final wasEmpty = _query.isEmpty;
    final newQuery = queryRevision != _queryRevision || query != _query;
    final terminalState =
        runState != _runState &&
        const {
          ChatSearchRunState.failed,
          ChatSearchRunState.exhausted,
        }.contains(runState);
    _query = query;
    _queryRevision = queryRevision;
    _runState = runState;
    if (newQuery || terminalState) {
      _resetScroll();
      _pendingCollapsed = null;
      final wasCollapsed = _collapsed;
      _collapsed = false;
      if (wasCollapsed || wasEmpty != query.isEmpty) notifyListeners();
    }
  }

  void reset() {
    updateSearch(
      query: '',
      queryRevision: -1,
      runState: ChatSearchRunState.idle,
    );
  }

  void selectTab(int index) {
    if (_selectedTab == index) return;
    _selectedTab = index;
    expand();
  }

  void updateExpandedHeight(double height) {
    if (_disposed || !height.isFinite || height <= 0) return;
    if ((_expandedHeight - height).abs() < 0.5) return;
    _expandedHeight = height;
    if (_query.isNotEmpty) notifyListeners();
  }

  void expand() {
    _resetScroll();
    _setCollapsed(false);
  }

  void collapse() {
    _resetScroll();
    _setCollapsed(true);
  }

  void _setCollapsed(bool value) {
    _pendingCollapsed = null;
    if (_disposed || _query.isEmpty || _collapsed == value) return;
    _collapsed = value;
    notifyListeners();
  }

  void _resetScroll() {
    _userScrolling = false;
    _scrollDistance = 0;
  }

  void _scheduleCollapsed(bool value) {
    _pendingCollapsed = value;
    if (_visibilityUpdatePending) return;
    _visibilityUpdatePending = true;
    // Scroll notifications can arrive during layout. Only update the overlay
    // after the frame, without changing the list's viewport or scroll extent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityUpdatePending = false;
      final pending = _pendingCollapsed;
      if (_disposed || pending == null) return;
      _setCollapsed(pending);
    });
  }

  bool onScrollNotification(int tab, ScrollNotification notification) {
    if (_disposed ||
        _query.isEmpty ||
        tab != _selectedTab ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    switch (notification) {
      case UserScrollNotification():
        _userScrolling = notification.direction != ScrollDirection.idle;
        if (_userScrolling &&
            notification.metrics.pixels <=
                notification.metrics.minScrollExtent) {
          _scheduleCollapsed(false);
        }
        return false;
      case ScrollStartNotification() when notification.dragDetails != null:
        _userScrolling = true;
        return false;
      case ScrollEndNotification():
        _userScrolling = false;
        return false;
      case ScrollUpdateNotification()
          when _userScrolling || notification.dragDetails != null:
        if (notification.metrics.pixels <=
            notification.metrics.minScrollExtent) {
          _scrollDistance = 0;
          _scheduleCollapsed(false);
          return false;
        }
        final delta = notification.scrollDelta ?? 0;
        if (delta == 0 || notification.metrics.outOfRange) return false;
        if (_scrollDistance.sign != delta.sign) _scrollDistance = 0;
        _scrollDistance += delta;
        if (_scrollDistance.abs() >= scrollThreshold) {
          _scheduleCollapsed(_scrollDistance > 0);
          _scrollDistance = 0;
        }
        return false;
      case OverscrollNotification()
          when (_userScrolling || notification.dragDetails != null) &&
              notification.metrics.pixels <=
                  notification.metrics.minScrollExtent:
        _scheduleCollapsed(false);
        return false;
      default:
        return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingCollapsed = null;
    super.dispose();
  }
}
