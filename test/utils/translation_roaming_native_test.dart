// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/translation/translation_roaming.dart';
import 'package:fluffychat/utils/translation/translation_roaming_store_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native transport authenticates, parses fragments and reconnects',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final tasks = <Future<void>>[];
      final commands = <List<String>>[];
      final subscription = server.listen((socket) {
        sockets.add(socket);
        tasks.add(_serve(socket, commands));
      });
      final store = NativeTranslationRoamingStore(
        TranslationRoamingConfig(
          enabled: true,
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          tls: false,
          username: 'tester',
          database: 2,
        ),
        'authentication',
      );
      addTearDown(() async {
        store.dispose();
        await subscription.cancel();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        await Future.wait(tasks);
      });

      expect(await store.getEx('鍵🌍', 30), '譯文 🌍');
      await store.set('鍵🌍', 'encrypted value', 40);
      await store.delete('鍵🌍');
      store.reset();
      expect(await store.getEx('鍵🌍', 50), '譯文 🌍');
      expect(sockets, hasLength(2));
      expect(commands, [
        ['AUTH', 'tester', 'authentication'],
        ['SELECT', '2'],
        ['GETEX', '鍵🌍', 'EX', '30'],
        ['SET', '鍵🌍', 'encrypted value', 'EX', '40'],
        ['DEL', '鍵🌍'],
        ['AUTH', 'tester', 'authentication'],
        ['SELECT', '2'],
        ['GETEX', '鍵🌍', 'EX', '50'],
      ]);
      store.dispose();
      await expectLater(
        store.getEx('unused', 30),
        throwsA(isA<TranslationRoamingException>()),
      );
    },
  );

  test(
    'native authentication errors retain reasons without credentials',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final tasks = <Future<void>>[];
      final subscription = server.listen((socket) {
        sockets.add(socket);
        tasks.add(
          _serve(
            socket,
            [],
            authenticationError: 'WRONGPASS invalid tester native-secret',
          ),
        );
      });
      final store = NativeTranslationRoamingStore(
        TranslationRoamingConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          tls: false,
          username: 'tester',
        ),
        'native-secret',
      );
      addTearDown(() async {
        store.dispose();
        await subscription.cancel();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        await Future.wait(tasks);
      });
      await expectLater(
        store.getEx('unused', 60),
        throwsA(
          isA<TranslationRoamingException>()
              .having(
                (error) => error.error,
                'classification',
                TranslationRoamingError.authentication,
              )
              .having(
                (error) => error.diagnosticDetails,
                'diagnostic details',
                allOf(
                  contains('WRONGPASS'),
                  isNot(contains('native-secret')),
                  isNot(contains('tester')),
                ),
              ),
        ),
      );
    },
  );
}

Future<void> _serve(
  Socket socket,
  List<List<String>> commands, {
  String? authenticationError,
}) async {
  final input = _RequestReader(socket);
  try {
    while (true) {
      final command = await input.read();
      if (command == null) return;
      commands.add(command);
      final response = switch (command.first) {
        'AUTH' when authenticationError != null => utf8.encode(
          '-$authenticationError\r\n',
        ),
        'AUTH' || 'SELECT' || 'SET' => utf8.encode('+OK\r\n'),
        'DEL' => utf8.encode(':1\r\n'),
        'GETEX' => [
          ...utf8.encode('\$${utf8.encode('譯文 🌍').length}\r\n'),
          ...utf8.encode('譯文 🌍'),
          13,
          10,
        ],
        _ => utf8.encode('-ERR unexpected test command\r\n'),
      };
      // Split even inside multibyte UTF-8 sequences and RESP delimiters.
      for (final byte in response) {
        socket.add([byte]);
        await socket.flush();
        await Future<void>.delayed(Duration.zero);
      }
    }
  } on SocketException {
    // The adapter deliberately destroys the old socket on reset/dispose.
  } finally {
    await input.dispose();
    socket.destroy();
  }
}

class _RequestReader {
  final StreamIterator<List<int>> input;
  final List<int> _buffer = [];

  _RequestReader(Socket socket) : input = StreamIterator(socket);

  Future<int?> _byte() async {
    while (_buffer.isEmpty) {
      if (!await input.moveNext()) return null;
      _buffer.addAll(input.current);
    }
    return _buffer.removeAt(0);
  }

  Future<String?> _line() async {
    final bytes = <int>[];
    while (true) {
      final byte = await _byte();
      if (byte == null) return null;
      if (byte == 13) {
        if (await _byte() != 10) throw const FormatException('RESP delimiter');
        return utf8.decode(bytes);
      }
      bytes.add(byte);
    }
  }

  Future<List<String>?> read() async {
    final count = await _line();
    if (count == null) return null;
    if (!count.startsWith('*')) throw const FormatException('RESP array');
    final command = <String>[];
    for (var i = 0; i < int.parse(count.substring(1)); i++) {
      final length = await _line();
      if (length == null || !length.startsWith('\$')) {
        throw const FormatException('RESP bulk string');
      }
      final bytes = <int>[];
      for (var j = 0; j < int.parse(length.substring(1)); j++) {
        final byte = await _byte();
        if (byte == null) throw const FormatException('Incomplete RESP data');
        bytes.add(byte);
      }
      if (await _byte() != 13 || await _byte() != 10) {
        throw const FormatException('RESP delimiter');
      }
      command.add(utf8.decode(bytes));
    }
    return command;
  }

  Future<void> dispose() => input.cancel();
}
