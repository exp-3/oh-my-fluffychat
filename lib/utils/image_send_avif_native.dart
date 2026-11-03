// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:avif_native/avif_native.dart' as avif;
import 'package:image/image.dart' as img;

Uint8List encodeAvifForSending(Uint8List png) {
  final image = img.decodePng(png);
  if (image == null) throw StateError('Unable to read the prepared image');
  return avif.encodeAvifFrames(
    width: image.width,
    height: image.height,
    frames: [
      avif.AvifEncodeFrame(
        rgba: image.getBytes(order: img.ChannelOrder.rgba),
        duration: const Duration(seconds: 1),
      ),
    ],
    options: const avif.AvifEncodeOptions(
      minQuantizer: 25,
      maxQuantizer: 40,
      minQuantizerAlpha: 0,
      maxQuantizerAlpha: 0,
    ),
  );
}

Uint8List? decodeAvifForSending(Uint8List bytes) {
  final decoder = avif.AvifDecoder(bytes);
  try {
    if (decoder.frameCount != 1) return null;
    final frame = decoder.getNextFrame();
    return img.encodePng(
      img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: frame.rgba.buffer,
        bytesOffset: frame.rgba.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      ),
    );
  } finally {
    decoder.dispose();
  }
}
