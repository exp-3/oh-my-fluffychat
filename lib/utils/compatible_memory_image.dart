// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'image_avif_codec.dart';

/// Native AVIF uses its intrinsic resolution; widget layout applies scaling.
class CompatibleMemoryImage extends MemoryImage {
  const CompatibleMemoryImage(super.bytes, {super.scale});

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    return _CompatibleImageStreamCompleter(
      codec: _decodeCompatible(
        key.bytes,
        (bytes) async => decode(await ui.ImmutableBuffer.fromUint8List(bytes)),
      ),
      scale: key.scale,
      debugLabel: 'CompatibleMemoryImage(${describeIdentity(key.bytes)})',
    );
  }
}

class _CompatibleImageStreamCompleter extends MultiFrameImageStreamCompleter {
  _CompatibleImageStreamCompleter({
    required Future<ui.Codec> codec,
    required double scale,
    required String debugLabel,
  }) : this._(_CodecLifetime(), codec, scale, debugLabel);

  _CompatibleImageStreamCompleter._(
    _CodecLifetime lifetime,
    Future<ui.Codec> codec,
    double scale,
    String debugLabel,
  ) : _lifetime = lifetime,
      super(codec: lifetime.guard(codec), scale: scale, debugLabel: debugLabel);

  final _CodecLifetime _lifetime;

  @override
  void reportError({
    DiagnosticsNode? context,
    required Object exception,
    StackTrace? stack,
    InformationCollector? informationCollector,
    bool silent = false,
  }) {
    if (_lifetime.isDisposed) return;
    super.reportError(
      context: context,
      exception: exception,
      stack: stack,
      informationCollector: informationCollector,
      silent: silent,
    );
  }

  @override
  void onDisposed() {
    _lifetime.dispose();
    super.onDisposed();
  }
}

class _CodecLifetime {
  bool _disposed = false;
  _ManagedCodec? _codec;

  bool get isDisposed => _disposed;

  Future<ui.Codec> guard(Future<ui.Codec> future) async {
    final codec = _ManagedCodec(await future);
    _codec = codec;
    if (_disposed) codec.dispose();
    return codec;
  }

  void dispose() {
    _disposed = true;
    _codec?.dispose();
  }
}

class _ManagedCodec implements ui.Codec {
  _ManagedCodec(this._codec)
    : frameCount = _codec.frameCount,
      repetitionCount = _codec.repetitionCount;

  final ui.Codec _codec;
  bool _disposed = false;

  @override
  final int frameCount;

  @override
  final int repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (_disposed) throw StateError('Image codec has been disposed');
    final frame = await _codec.getNextFrame();
    if (_disposed) {
      frame.image.dispose();
      throw StateError('Image codec has been disposed');
    }
    return frame;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _codec.dispose();
  }
}

Future<ui.Codec> instantiateImageCodecWithFallback(Uint8List bytes) =>
    _decodeCompatible(bytes, ui.instantiateImageCodec);

Future<ui.Codec> _decodeCompatible(
  Uint8List bytes,
  Future<ui.Codec> Function(Uint8List) decode,
) {
  if (!kIsWeb && _isAvif(bytes)) {
    return createAvifCodec(bytes);
  }
  return decode(bytes);
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
