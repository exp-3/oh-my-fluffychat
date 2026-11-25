// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:avif_native/avif_native.dart' as avif;
import 'package:fluffychat/utils/compatible_memory_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List avifImage({
    bool animated = false,
    int repetitionCount = -1,
    Duration firstDuration = const Duration(milliseconds: 70),
  }) {
    Uint8List pixels(int red, int blue) => Uint8List.fromList([
      for (var i = 0; i < 32; i++) ...[red, 0, blue, 127],
    ]);
    final bytes = avif.encodeAvifFrames(
      width: 8,
      height: 4,
      frames: [
        avif.AvifEncodeFrame(rgba: pixels(255, 0), duration: firstDuration),
        if (animated)
          avif.AvifEncodeFrame(
            rgba: pixels(0, 255),
            duration: const Duration(milliseconds: 130),
          ),
      ],
      options: avif.AvifEncodeOptions(
        // libavif accepts unknown repetition metadata when reading, but its
        // encoder only writes infinite or nonnegative repetition counts.
        repetitionCount: repetitionCount == -2 ? 0 : repetitionCount,
        minQuantizer: 0,
        maxQuantizer: 0,
        minQuantizerAlpha: 0,
        maxQuantizerAlpha: 0,
      ),
    );
    return repetitionCount == -2 ? _withoutAvifEditLists(bytes) : bytes;
  }

  test('static AVIF preserves alpha and independent image handles', () async {
    final bytes = avifImage();
    final original = Uint8List.fromList(bytes);
    final codec = await instantiateImageCodecWithFallback(bytes);
    try {
      expect(codec.frameCount, 1);
      await _expectAvifFrame(await codec.getNextFrame());
      // A second request owns a separate image handle, even after disposing
      // the first frame and then the codec itself.
      final second = await codec.getNextFrame();
      codec.dispose();
      await _expectAvifFrame(second);
      expect(bytes, original);
    } finally {
      codec.dispose();
    }
  });

  test('AVIF provider bypasses the encoded platform decoder', () async {
    final bytes = avifImage();
    final provider = CompatibleMemoryImage(bytes, scale: 2);
    var decodeCalls = 0;
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      decodeCalls++;
      buffer.dispose();
      throw UnsupportedError('The platform must not decode AVIF or PNG');
    });
    final info = await _firstImage(ImageStream()..setCompleter(completer));
    try {
      expect((info.image.width, info.image.height), (8, 4));
      expect(info.scale, 2);
      expect(decodeCalls, 0);
    } finally {
      info.dispose();
    }
  });

  testWidgets('Image renders AVIF through normal provider resolution', (
    tester,
  ) async {
    final provider = CompatibleMemoryImage(avifImage());
    await tester.runAsync(() async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: provider),
        ),
      );
      final info = await _firstImage(
        provider.resolve(ImageConfiguration.empty),
      );
      info.dispose();
    });
    await tester.pump();
    final rendered = tester.widget<RawImage>(find.byType(RawImage));
    expect(rendered.image, isNotNull);
    expect((rendered.image!.width, rendered.image!.height), (8, 4));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await provider.evict();
  });

  for (final repetitions in [-2, -1, 0, 2]) {
    test('AVIF keeps frame order, timing and repeat $repetitions', () async {
      final codec = await instantiateImageCodecWithFallback(
        avifImage(animated: true, repetitionCount: repetitions),
      );
      try {
        expect(codec.frameCount, 2);
        expect(codec.repetitionCount, repetitions == -2 ? 0 : repetitions);
        for (var i = 0; i < 4; i++) {
          await _expectAvifFrame(
            await codec.getNextFrame(),
            blue: i.isOdd,
            duration: Duration(milliseconds: i.isEven ? 70 : 130),
          );
        }
      } finally {
        codec.dispose();
      }
    });
  }

  test('AVIF frame durations are not limited by APNG milliseconds', () async {
    const duration = Duration(milliseconds: 70000);
    final codec = await instantiateImageCodecWithFallback(
      avifImage(animated: true, firstDuration: duration),
    );
    try {
      await _expectAvifFrame(await codec.getNextFrame(), duration: duration);
      await _expectAvifFrame(
        await codec.getNextFrame(),
        blue: true,
        duration: const Duration(milliseconds: 130),
      );
    } finally {
      codec.dispose();
    }
  });

  test('concurrent AVIF requests keep frame order across a loop', () async {
    final codec = await instantiateImageCodecWithFallback(
      avifImage(animated: true),
    );
    try {
      final frames = await Future.wait([
        codec.getNextFrame(),
        codec.getNextFrame(),
        codec.getNextFrame(),
      ], cleanUp: (frame) => frame.image.dispose());
      try {
        for (var i = 0; i < frames.length; i++) {
          await _expectAvifFrame(
            frames[i],
            blue: i.isOdd,
            duration: Duration(milliseconds: i.isEven ? 70 : 130),
          );
        }
      } finally {
        for (final frame in frames) {
          if (!frame.image.debugDisposed) frame.image.dispose();
        }
      }
    } finally {
      codec.dispose();
    }
  });

  test('AVIF disposal rejects pending and later frame requests', () async {
    final codec = await instantiateImageCodecWithFallback(
      avifImage(animated: true),
    );
    final pending = expectLater(codec.getNextFrame(), throwsStateError);
    codec.dispose();
    expect(codec.dispose, returnsNormally);
    await pending;
    await expectLater(codec.getNextFrame(), throwsStateError);
  });

  test('AVIF metadata loads before corrupt samples are decoded', () async {
    final codec = await instantiateImageCodecWithFallback(
      _corruptAvifSamples(avifImage(animated: true)),
    );
    try {
      // BMFF metadata remains valid, but the AV1 sample payloads are invalid.
      // Eager pixel decoding would fail before returning this codec.
      expect(codec.frameCount, 2);
      await expectLater(
        codec.getNextFrame().timeout(const Duration(seconds: 10)),
        throwsStateError,
      );
      await expectLater(
        codec.getNextFrame().timeout(const Duration(seconds: 10)),
        throwsStateError,
      );
      expect(codec.dispose, returnsNormally);
    } finally {
      codec.dispose();
    }
  });

  test('provider disposes a codec resolved after stream removal', () async {
    final provider = CompatibleMemoryImage(
      img.encodePng(img.Image(width: 8, height: 4)),
    );
    final decoderStarted = Completer<void>();
    final ready = Completer<ui.Codec>();
    final tracked = _TrackedCodec();
    final completer = provider.loadImage(provider, (buffer, {getTargetSize}) {
      buffer.dispose();
      decoderStarted.complete();
      return ready.future;
    });
    final listener = ImageStreamListener((info, _) => info.dispose());
    completer.addListener(listener);
    await decoderStarted.future;
    completer.removeListener(listener);
    ready.complete(tracked);
    await tracked.disposed.future.timeout(const Duration(seconds: 10));
    expect(tracked.disposeCount, 1);
    expect(tracked.frameRequests, 0);
  });

  test('provider disposes a frame completed after stream removal', () async {
    final png = img.encodePng(img.Image(width: 8, height: 4));
    final platform = await ui.instantiateImageCodec(png);
    final frame = await platform.getNextFrame();
    platform.dispose();
    final pending = Completer<ui.FrameInfo>();
    final tracked = _TrackedCodec(pendingFrame: pending.future);
    final provider = CompatibleMemoryImage(png);
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      buffer.dispose();
      return tracked;
    });
    final listener = ImageStreamListener((info, _) => info.dispose());
    completer.addListener(listener);
    try {
      await tracked.frameRequested.future.timeout(const Duration(seconds: 10));
      completer.removeListener(listener);
      pending.complete(frame);
      // Let the already requested frame finish after codec disposal.
      await Future<void>.delayed(Duration.zero);
      expect(frame.image.debugDisposed, isTrue);
      expect(tracked.disposeCount, 1);
    } finally {
      if (!frame.image.debugDisposed) frame.image.dispose();
    }
  });

  test('ordinary GIFs retain platform animation timing', () async {
    final image = img.Image(width: 8, height: 4)
      ..loopCount = 3
      ..frameDuration = 70;
    image.addFrame(img.Image(width: 8, height: 4)..frameDuration = 130);
    final bytes = img.encodeGif(image);
    final platform = await ui.instantiateImageCodec(bytes);
    final compatible = await instantiateImageCodecWithFallback(bytes);
    try {
      expect(compatible.frameCount, platform.frameCount);
      expect(compatible.repetitionCount, platform.repetitionCount);
      for (final duration in [70, 130]) {
        final expected = await platform.getNextFrame();
        final actual = await compatible.getNextFrame();
        try {
          expect(actual.duration, expected.duration);
          expect(actual.duration, Duration(milliseconds: duration));
        } finally {
          expected.image.dispose();
          actual.image.dispose();
        }
      }
    } finally {
      platform.dispose();
      compatible.dispose();
    }
  });

  for (final format in ['png', 'jpg']) {
    test('ordinary $format images still use the platform decoder', () async {
      final bytes = img.encodeNamedImage(
        'picture.$format',
        img.Image(width: 8, height: 4),
      )!;
      final provider = CompatibleMemoryImage(bytes);
      var decodeCalls = 0;
      final completer = provider.loadImage(provider, (buffer, {getTargetSize}) {
        decodeCalls++;
        return PaintingBinding.instance.instantiateImageCodecWithSize(
          buffer,
          getTargetSize: getTargetSize,
        );
      });
      final info = await _firstImage(ImageStream()..setCompleter(completer));
      try {
        expect(decodeCalls, 1);
        expect((info.image.width, info.image.height), (8, 4));
      } finally {
        info.dispose();
      }
    });
  }

  test('corrupt image data still fails without a decode loop', () async {
    await expectLater(
      instantiateImageCodecWithFallback(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
    await expectLater(
      instantiateImageCodecWithFallback(
        Uint8List.fromList([
          0,
          0,
          0,
          24,
          ...'ftypavif'.codeUnits,
          0,
          0,
          0,
          0,
          ...'avifmif1'.codeUnits,
        ]),
      ),
      throwsA(anything),
    );
  });
}

Uint8List _corruptAvifSamples(Uint8List bytes) {
  final corrupted = Uint8List.fromList(bytes);
  var sampleBytes = 0;
  _visitAvifBoxes(corrupted, (type, start, end) {
    if (type == 'mdat') {
      corrupted.fillRange(start + 8, end, 0);
      sampleBytes += end - start - 8;
    }
  });
  expect(sampleBytes, greaterThan(0));
  return corrupted;
}

Uint8List _withoutAvifEditLists(Uint8List bytes) {
  final unknownRepetitions = Uint8List.fromList(bytes);
  var editLists = 0;
  _visitAvifBoxes(unknownRepetitions, (type, start, end) {
    if (type == 'edts') {
      // Without an edit list libavif exposes the repetition count as unknown.
      // Renaming preserves all absolute offsets into the media samples.
      unknownRepetitions.setRange(start + 4, start + 8, 'free'.codeUnits);
      editLists++;
    }
  });
  expect(editLists, greaterThan(0));
  return unknownRepetitions;
}

void _visitAvifBoxes(
  Uint8List bytes,
  void Function(String type, int start, int end) visit, {
  int start = 0,
  int? end,
}) {
  final data = ByteData.sublistView(bytes);
  final limit = end ?? bytes.length;
  var offset = start;
  // The tiny, locally encoded fixtures use ordinary 32-bit BMFF box sizes.
  while (offset + 8 <= limit) {
    final size = data.getUint32(offset);
    expect(size, greaterThanOrEqualTo(8));
    final boxEnd = offset + size;
    expect(boxEnd, lessThanOrEqualTo(limit));
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    visit(type, offset, boxEnd);
    if (type == 'moov' || type == 'trak') {
      _visitAvifBoxes(bytes, visit, start: offset + 8, end: boxEnd);
    }
    offset = boxEnd;
  }
}

Future<void> _expectAvifFrame(
  ui.FrameInfo frame, {
  bool blue = false,
  Duration? duration,
}) async {
  try {
    expect((frame.image.width, frame.image.height), (8, 4));
    if (duration != null) expect(frame.duration, duration);
    final rgba = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(rgba, isNotNull);
    expect(rgba!.getUint8(3), 127);
    // rawRgba is premultiplied: a half-transparent saturated color must be
    // around 127 rather than 255 in its active channel.
    expect(rgba.getUint8(blue ? 2 : 0), closeTo(127, 3));
    expect(rgba.getUint8(blue ? 0 : 2), lessThanOrEqualTo(3));
    expect(rgba.getUint8(1), lessThanOrEqualTo(3));
  } finally {
    frame.image.dispose();
  }
}

Future<ImageInfo> _firstImage(ImageStream stream) async {
  final result = Completer<ImageInfo>();
  final listener = ImageStreamListener(
    (info, _) {
      if (!result.isCompleted) result.complete(info.clone());
      info.dispose();
    },
    onError: (Object error, StackTrace? stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  try {
    return await result.future.timeout(const Duration(seconds: 10));
  } finally {
    stream.removeListener(listener);
  }
}

class _TrackedCodec implements ui.Codec {
  _TrackedCodec({this.pendingFrame});

  final Future<ui.FrameInfo>? pendingFrame;
  final disposed = Completer<void>();
  final frameRequested = Completer<void>();
  var disposeCount = 0;
  var frameRequests = 0;

  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    frameRequests++;
    if (!frameRequested.isCompleted) frameRequested.complete();
    final pending = pendingFrame;
    if (pending != null) return pending;
    throw StateError('A closed image stream must not request any frames');
  }

  @override
  void dispose() {
    disposeCount++;
    if (!disposed.isCompleted) disposed.complete();
  }
}
