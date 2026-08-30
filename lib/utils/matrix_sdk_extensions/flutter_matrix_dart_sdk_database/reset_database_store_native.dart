// SPDX-FileCopyrightText: 2026 OMF Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

Future<void> resetDatabaseStore(
  String databaseName, {
  String? nativePath,
}) async {
  if (nativePath == null) {
    throw ArgumentError.value(
      nativePath,
      'nativePath',
      'A native database path is required',
    );
  }

  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    final file = File('$nativePath$suffix');
    if (await file.exists()) await file.delete();
  }
}
