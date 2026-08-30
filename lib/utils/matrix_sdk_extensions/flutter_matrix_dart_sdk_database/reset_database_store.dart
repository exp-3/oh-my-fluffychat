// SPDX-FileCopyrightText: 2026 OMF Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'reset_database_store_native.dart'
    if (dart.library.js_interop) 'reset_database_store_web.dart'
    as platform;

Future<void> resetDatabaseStore(String databaseName, {String? nativePath}) =>
    platform.resetDatabaseStore(databaseName, nativePath: nativePath);
