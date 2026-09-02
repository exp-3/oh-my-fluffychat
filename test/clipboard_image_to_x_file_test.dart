// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:fluffychat/pages/chat/utils/clipboard_image_to_x_file.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  final bitmapBytes = Uint8List.fromList([0x42, 0x4d, 0x00, 0x00]);

  test('adds BMP metadata to Windows clipboard images', () async {
    final file = clipboardImageToXFile(bitmapBytes, isWindows: true);

    expect(file.mimeType, 'image/bmp');
    expect(file.path, 'clipboard.bmp');
    expect(file.name, 'clipboard.bmp');
    expect(await file.length(), bitmapBytes.length);
    expect(await file.readAsBytes(), bitmapBytes);
  });

  test('classifies Windows clipboard images as Matrix images', () async {
    final xFile = clipboardImageToXFile(bitmapBytes, isWindows: true);
    final file = MatrixFile(
      bytes: await xFile.readAsBytes(),
      name: xFile.name,
      mimeType: xFile.mimeType,
    ).detectFileType;

    expect(file, isA<MatrixImageFile>());
    expect(file.msgType, MessageTypes.Image);
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
