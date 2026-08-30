// SPDX-FileCopyrightText: 2026 OMF Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fluffychat/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/reset_database_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'reset removes only the selected SQLite database and its sidecars',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fluffychat-database-reset-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final databasePath = path.join(directory.path, 'account.sqlite');
      final databaseFiles = [
        for (final suffix in const ['', '-wal', '-shm', '-journal'])
          File('$databasePath$suffix'),
      ];
      for (final file in databaseFiles) {
        await file.writeAsString('data');
      }
      final unrelatedFile = File(path.join(directory.path, 'other.sqlite'));
      await unrelatedFile.writeAsString('keep');

      await resetDatabaseStore('account', nativePath: databasePath);

      for (final file in databaseFiles) {
        expect(await file.exists(), isFalse);
      }
      expect(await unrelatedFile.readAsString(), 'keep');
    },
  );
}
