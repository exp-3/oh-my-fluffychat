// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

XFile clipboardImageToXFile(Uint8List image, {required bool isWindows}) {
  if (!isWindows) return XFile.fromData(image);

  // On Windows, pasteboard serializes CF_DIB clipboard images as BMP bytes.
  return XFile.fromData(
    image,
    mimeType: 'image/bmp',
    path: 'clipboard.bmp',
    length: image.length,
  );
}
