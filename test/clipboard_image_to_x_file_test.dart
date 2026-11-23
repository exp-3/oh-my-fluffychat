// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:fluffychat/pages/chat/utils/clipboard_image_to_x_file.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  final bitmapBytes = Uint8List.fromList([0x42, 0x4d, 0x00, 0x00]);

  test('Windows clipboard images have BMP metadata and Matrix type', () async {
    final file = clipboardImageToXFile(bitmapBytes, isWindows: true);

    expect(file.mimeType, 'image/bmp');
    expect(file.path, 'clipboard.bmp');
    expect(file.name, 'clipboard.bmp');
    expect(await file.length(), bitmapBytes.length);
    final bytes = await file.readAsBytes();
    expect(bytes, bitmapBytes);

    final matrixFile = MatrixFile(
      bytes: bytes,
      name: file.name,
      mimeType: file.mimeType,
    ).detectFileType;

    expect(matrixFile, isA<MatrixImageFile>());
    expect(matrixFile.msgType, MessageTypes.Image);
  });

  test('keeps clipboard image metadata unchanged outside Windows', () async {
    final file = clipboardImageToXFile(bitmapBytes, isWindows: false);

    expect(file.mimeType, isNull);
    expect(file.path, isEmpty);
    expect(file.name, isEmpty);
    expect(await file.length(), bitmapBytes.length);
    expect(await file.readAsBytes(), bitmapBytes);
  });
}
