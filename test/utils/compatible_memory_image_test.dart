// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:avif_native/avif_native.dart' as avif;
import 'package:fluffychat/utils/compatible_memory_image.dart';
import 'package:fluffychat/utils/image_avif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List avifImage({bool animated = false, int repetitionCount = -1}) {
    Uint8List pixels(int red, int blue) => Uint8List.fromList([
      for (var i = 0; i < 32; i++) ...[red, 0, blue, 127],
    ]);
    return avif.encodeAvifFrames(
      width: 8,
      height: 4,
      frames: [
        avif.AvifEncodeFrame(
          rgba: pixels(255, 0),
          duration: const Duration(milliseconds: 70),
        ),
        if (animated)
          avif.AvifEncodeFrame(
            rgba: pixels(0, 255),
            duration: const Duration(milliseconds: 130),
          ),
      ],
      options: avif.AvifEncodeOptions(
        repetitionCount: repetitionCount,
        minQuantizerAlpha: 0,
        maxQuantizerAlpha: 0,
      ),
    );
  }

  test('AVIF opens through the image editor codec path', () async {
    final codec = await instantiateImageCodecWithFallback(avifImage());
    try {
      expect(codec.frameCount, 1);
      final frame = await codec.getNextFrame();
      try {
        expect((frame.image.width, frame.image.height), (8, 4));
        final rgba = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(rgba!.getUint8(3), 127);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });

  test('provider retries AVIF after a platform decode failure', () async {
    final bytes = avifImage();
    final original = Uint8List.fromList(bytes);
    final provider = CompatibleMemoryImage(bytes);
    var decodeCalls = 0;
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      decodeCalls++;
      if (decodeCalls == 1) {
        buffer.dispose();
        throw UnsupportedError('No platform AVIF decoder');
      }
      return PaintingBinding.instance.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: getTargetSize,
      );
    });
    final result = Completer<ImageInfo>();
    final listener = ImageStreamListener(
      (info, _) => result.complete(info.clone()),
      onError: result.completeError,
    );
    completer.addListener(listener);
    try {
      final info = await result.future;
      try {
        expect((info.image.width, info.image.height), (8, 4));
        expect(decodeCalls, 2);
        expect(bytes, original);
      } finally {
        info.dispose();
      }
    } finally {
      completer.removeListener(listener);
    }
  });

  for (final repetitions in [-1, 0, 2]) {
    test('animated AVIF retains timing and repeats $repetitions', () async {
      final bytes = avifImage(animated: true, repetitionCount: repetitions);
      final png = await compute(decodeAvifForDisplay, bytes);
      final codec = await ui.instantiateImageCodec(png!);
      try {
        expect(codec.frameCount, 2);
        expect(codec.repetitionCount, repetitions);
        for (final duration in [70, 130]) {
          final frame = await codec.getNextFrame();
          try {
            expect(frame.duration, Duration(milliseconds: duration));
            final rgba = await frame.image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            expect(rgba!.getUint8(3), 127);
          } finally {
            frame.image.dispose();
          }
        }
        expect(decodeAvifForSending(bytes), isNull);
      } finally {
        codec.dispose();
      }
    });
  }

  test('ordinary animated GIFs retain their codec and timing', () async {
    final image = img.Image(width: 8, height: 4)
      ..loopCount = 3
      ..frameDuration = 70;
    image.addFrame(img.Image(width: 8, height: 4)..frameDuration = 130);
    final bytes = img.encodeGif(image);
    final codec = await instantiateImageCodecWithFallback(bytes);
    try {
      expect(codec.frameCount, 2);
      for (final duration in [70, 130]) {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.duration, Duration(milliseconds: duration));
        } finally {
          frame.image.dispose();
        }
      }
    } finally {
      codec.dispose();
    }
  });

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
