// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'image_avif.dart';

class CompatibleMemoryImage extends MemoryImage {
  const CompatibleMemoryImage(super.bytes, {super.scale});

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _decodeWithFallback(
        key.bytes,
        (bytes) async => decode(await ui.ImmutableBuffer.fromUint8List(bytes)),
      ),
      scale: key.scale,
      debugLabel: 'CompatibleMemoryImage(${describeIdentity(key.bytes)})',
    );
  }
}

Future<ui.Codec> instantiateImageCodecWithFallback(Uint8List bytes) =>
    _decodeWithFallback(bytes, ui.instantiateImageCodec);

Future<ui.Codec> _decodeWithFallback(
  Uint8List bytes,
  Future<ui.Codec> Function(Uint8List) decode,
) async {
  try {
    return await decode(bytes);
  } catch (_) {
    if (kIsWeb || !_isAvif(bytes)) rethrow;
    final png = await compute(decodeAvifForDisplay, bytes);
    if (png == null) rethrow;
    return decode(png);
  }
}

bool _isAvif(Uint8List bytes) {
  if (bytes.length < 16 ||
      String.fromCharCodes(bytes.sublist(4, 8)) != 'ftyp') {
    return false;
  }
  final boxSize = ByteData.sublistView(bytes).getUint32(0);
  final end = boxSize == 0 ? bytes.length : min(boxSize, bytes.length);
  for (var i = 8; i + 4 <= end; i += 4) {
    if (i == 12) continue;
    final brand = String.fromCharCodes(bytes.sublist(i, i + 4));
    if (brand == 'avif' || brand == 'avis') return true;
  }
  return false;
}
