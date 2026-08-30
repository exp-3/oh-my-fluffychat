// SPDX-FileCopyrightText: 2026 OMF Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> resetDatabaseStore(String databaseName, {String? nativePath}) {
  final indexedDb = web.window.indexedDB;
  final request = indexedDb.deleteDatabase(databaseName);
  final completer = Completer<void>();

  request.onsuccess = (web.Event event) {
    if (!completer.isCompleted) completer.complete();
  }.toJS;
  request.onerror = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(
        request.error ?? StateError('Unable to reset the IndexedDB database'),
      );
    }
  }.toJS;
  request.onblocked = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('Resetting the IndexedDB database is blocked'),
      );
    }
  }.toJS;

  return completer.future;
}
