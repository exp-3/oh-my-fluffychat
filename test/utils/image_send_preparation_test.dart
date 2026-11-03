// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/image_send_avif.dart';
import 'package:fluffychat/utils/image_send_options.dart';
import 'package:fluffychat/utils/image_send_preparation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  img.Image picture(int width, int height, {bool transparent = false}) {
    final image = img.Image(width: width, height: height, numChannels: 4);
    for (final pixel in image) {
      pixel.setRgba(
        pixel.x % 255,
        pixel.y % 255,
        (pixel.x + pixel.y) % 255,
        transparent ? 127 : 255,
      );
    }
    return image;
  }

  MatrixImageFile pngFile(
    int width,
    int height, {
    bool transparent = false,
    String name = 'picture.png',
  }) => MatrixImageFile(
    bytes: img.encodePng(picture(width, height, transparent: transparent)),
    name: name,
    mimeType: 'image/png',
  );

  test('format policies classify only PNG, BMP and TIFF as outdated', () {
    for (final policy in ImageFormatPolicy.values) {
      final options = ImageSendOptions(
        formatPolicy: policy,
        preferredFormat: ImageOutputFormat.avif,
      );
      for (final mime in [
        'image/png',
        'image/bmp',
        'image/tiff',
        'image/jpeg',
        'image/webp',
        'image/gif',
        'image/heic',
      ]) {
        final convert =
            policy == ImageFormatPolicy.preferred ||
            (policy == ImageFormatPolicy.legacyOnly &&
                {'image/png', 'image/bmp', 'image/tiff'}.contains(mime));
        expect(
          options.targetMimeType(
            mime,
            hasTransparency: false,
            supportedFormats: ImageOutputFormat.values.toSet(),
          ),
          convert ? 'image/avif' : mime,
        );
      }
    }
  });

  test('disabling compression keeps bytes, name and MIME unchanged', () async {
    final original = pngFile(80, 40);
    final encoder = _UnavailableEncoder();
    final result = await ImageSendPreparation(encoder: encoder).prepare(
      original,
      compress: false,
      options: const ImageSendOptions(
        formatPolicy: ImageFormatPolicy.preferred,
        maxDimension: 10,
      ),
    );
    expect(result.file, same(original));
    expect(result.thumbnail, isNull);
    expect(encoder.calls, 0);
  });

  for (final (width, height, expectedWidth, expectedHeight) in [
    (80, 40, 32, 16),
    (40, 80, 16, 32),
    (80, 80, 32, 32),
    (1, 100, 1, 32),
  ]) {
    test('resizes $width x $height without changing PNG format', () async {
      final result = await ImageSendPreparation().prepare(
        pngFile(width, height),
        compress: true,
        options: const ImageSendOptions(maxDimension: 32),
      );
      final image = img.decodePng(result.file.bytes)!;
      expect(image.width, expectedWidth);
      expect(image.height, expectedHeight);
      expect(result.file.mimeType, 'image/png');
      expect(result.file.info['w'], expectedWidth);
      expect(result.file.info['h'], expectedHeight);
      expect(result.thumbnail!.mimeType, 'image/png');
    });
  }

  test(
    'does not enlarge a small image or retain a larger recompression',
    () async {
      final original = pngFile(8, 4);
      final result = await ImageSendPreparation().prepare(
        original,
        compress: true,
        options: const ImageSendOptions(maxDimension: 32),
      );
      expect(result.file, same(original));
    },
  );

  for (final format in ImageSendOptions.basicFormats) {
    test(
      'output bytes, extension and MIME agree for ${format.label}',
      () async {
        final result = await ImageSendPreparation().prepare(
          pngFile(80, 40, name: 'clipboard'),
          compress: true,
          options: ImageSendOptions(
            formatPolicy: ImageFormatPolicy.preferred,
            preferredFormat: format,
            maxDimension: 32,
          ),
        );
        expect(result.file.name, 'clipboard.${format.extension}');
        expect(result.file.mimeType, format.mimeType);
        final decoded = img.decodeImage(result.file.bytes)!;
        expect(decoded.width, 32);
        expect(decoded.height, 16);
        expect(result.file.info['size'], result.file.bytes.length);
      },
    );
  }

  test('JPEG preference preserves transparent PNG and still resizes', () async {
    final result = await ImageSendPreparation().prepare(
      pngFile(80, 40, transparent: true),
      compress: true,
      options: const ImageSendOptions(
        formatPolicy: ImageFormatPolicy.preferred,
        preferredFormat: ImageOutputFormat.jpeg,
        maxDimension: 32,
      ),
    );
    final decoded = img.decodePng(result.file.bytes)!;
    expect(result.file.mimeType, 'image/png');
    expect(decoded.width, 32);
    expect(decoded.getPixel(0, 0).a, 127);
  });

  test('WebP conversion preserves the alpha channel', () async {
    final result = await ImageSendPreparation().prepare(
      pngFile(32, 16, transparent: true),
      compress: true,
      options: const ImageSendOptions(
        formatPolicy: ImageFormatPolicy.legacyOnly,
      ),
    );
    expect(result.file.mimeType, 'image/webp');
    expect(img.decodeWebP(result.file.bytes)!.getPixel(0, 0).a, 127);
  });

  test('legacy-only keeps JPEG while applying the dimension limit', () async {
    final original = MatrixImageFile(
      bytes: img.encodeJpg(picture(80, 40)),
      name: 'photo.jpeg',
    );
    final result = await ImageSendPreparation().prepare(
      original,
      compress: true,
      options: const ImageSendOptions(
        formatPolicy: ImageFormatPolicy.legacyOnly,
        maxDimension: 32,
      ),
    );
    expect(result.file.mimeType, 'image/jpeg');
    expect(img.decodeJpg(result.file.bytes)!.width, 32);
  });

  test('single-frame GIF follows the maximum dimension', () async {
    final original = MatrixImageFile(
      bytes: img.encodeGif(picture(80, 40)),
      name: 'still.gif',
      mimeType: 'image/gif',
    );
    final result = await ImageSendPreparation().prepare(
      original,
      compress: true,
      options: const ImageSendOptions(maxDimension: 32),
    );
    final decoded = img.decodeGif(result.file.bytes)!;
    expect(result.file.mimeType, 'image/gif');
    expect(result.file.name, 'still.gif');
    expect((decoded.width, decoded.height), (32, 16));
    expect(decoded.numFrames, 1);
    expect((result.file.info['w'], result.file.info['h']), (32, 16));
  });

  test(
    'animated GIF retains dimensions, frame timing and loop count',
    () async {
      final image = picture(80, 40)
        ..loopCount = 3
        ..frameDuration = 70;
      image.addFrame(picture(80, 40)..frameDuration = 130);
      final original = MatrixImageFile(
        bytes: img.encodeGif(image),
        name: 'animated.gif',
        mimeType: 'image/gif',
      );
      final result = await ImageSendPreparation().prepare(
        original,
        compress: true,
        options: const ImageSendOptions(
          formatPolicy: ImageFormatPolicy.preferred,
          preferredFormat: ImageOutputFormat.jpeg,
          maxDimension: 32,
        ),
      );
      final decoded = img.decodeGif(result.file.bytes)!;
      expect(result.file, same(original));
      expect((decoded.width, decoded.height), (80, 40));
      expect(decoded.numFrames, 2);
      expect(decoded.frames.map((frame) => frame.frameDuration), [70, 130]);
      expect(decoded.loopCount, 3);
    },
  );

  test(
    'image dimension and format settings do not change video files',
    () async {
      final original = MatrixVideoFile(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'video.mp4',
        mimeType: 'video/mp4',
        width: 3840,
        height: 2160,
        duration: 1000,
      );
      final encoder = _UnavailableEncoder();
      final result = await ImageSendPreparation(encoder: encoder).prepare(
        original,
        compress: true,
        options: const ImageSendOptions(
          formatPolicy: ImageFormatPolicy.preferred,
          preferredFormat: ImageOutputFormat.jpeg,
          maxDimension: 32,
        ),
      );
      expect(result.file, same(original));
      expect((result.file.info['w'], result.file.info['h']), (3840, 2160));
      expect(result.thumbnail, isNull);
      expect(encoder.calls, 0);
    },
  );

  for (final format in ['gif', 'png', 'tiff']) {
    test('preserves multiframe $format bytes', () async {
      final image = picture(32, 16)..addFrame(picture(32, 16));
      final bytes = format == 'tiff'
          ? _multipageTiff(image)
          : img.encodeNamedImage('image.$format', image)!;
      final original = MatrixImageFile(bytes: bytes, name: 'image.$format');
      final result = await ImageSendPreparation().prepare(
        original,
        compress: true,
        options: const ImageSendOptions(
          formatPolicy: ImageFormatPolicy.preferred,
          maxDimension: 8,
        ),
      );
      expect(result.file, same(original));
    });
  }

  test('unavailable codecs are hidden, cached and fall back to WebP', () async {
    final encoder = _UnavailableEncoder();
    final preparation = ImageSendPreparation(encoder: encoder);
    expect(await preparation.supportedFormats(), ImageSendOptions.basicFormats);
    expect(await preparation.supportedFormats(), ImageSendOptions.basicFormats);
    expect(encoder.calls, 2);
    final result = await preparation.prepare(
      pngFile(32, 16),
      compress: true,
      options: const ImageSendOptions(
        formatPolicy: ImageFormatPolicy.preferred,
        preferredFormat: ImageOutputFormat.avif,
      ),
    );
    expect(result.file.mimeType, 'image/webp');
    expect(encoder.calls, 2);
  });

  test(
    'a codec failure after a successful probe preserves the original',
    () async {
      final original = pngFile(32, 16);
      final result = await ImageSendPreparation(encoder: _FailAfterProbe())
          .prepare(
            original,
            compress: true,
            options: const ImageSendOptions(
              formatPolicy: ImageFormatPolicy.preferred,
              preferredFormat: ImageOutputFormat.avif,
            ),
          );
      expect(result.file, same(original));
    },
  );

  test('native AVIF encoding preserves size and alpha', () async {
    final result = await ImageSendPreparation().prepare(
      pngFile(80, 40, transparent: true),
      compress: true,
      options: const ImageSendOptions(
        formatPolicy: ImageFormatPolicy.preferred,
        preferredFormat: ImageOutputFormat.avif,
        maxDimension: 32,
      ),
    );
    expect(result.file.mimeType, 'image/avif');
    expect(result.file.name, 'picture.avif');
    final png = decodeAvifForSending(result.file.bytes)!;
    final decoded = img.decodePng(png)!;
    expect(decoded.width, 32);
    expect(decoded.height, 16);
    expect(decoded.getPixel(0, 0).a, 127);
  }, skip: kIsWeb);

  test('corrupt images and other files are passed through', () async {
    for (final file in [
      MatrixImageFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'broken.png'),
      MatrixFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'notes.txt'),
    ]) {
      final result = await ImageSendPreparation().prepare(
        file,
        compress: true,
        options: const ImageSendOptions(),
      );
      expect(result.file, same(file));
    }
  });
}

// The image package's TIFF encoder writes a single page. Link a second IFD to
// the same pixel data to make a real two-page TIFF rather than a flattened one.
Uint8List _multipageTiff(img.Image image) {
  final single = img.encodeTiff(image);
  final data = ByteData.sublistView(single);
  final endian = single[0] == 0x49 ? Endian.little : Endian.big;
  final ifd = data.getUint32(4, endian);
  final count = data.getUint16(ifd, endian);
  final ifdLength = 2 + count * 12 + 4;
  final bytes = Uint8List.fromList([
    ...single,
    ...single.sublist(ifd, ifd + ifdLength),
  ]);
  ByteData.sublistView(
    bytes,
  ).setUint32(ifd + ifdLength - 4, single.length, endian);
  return bytes;
}

class _UnavailableEncoder implements ImageSendEncoder {
  int calls = 0;

  @override
  Future<Uint8List> encode(Uint8List png, ImageOutputFormat format) async {
    calls++;
    throw UnsupportedError('Test codec unavailable');
  }
}

class _FailAfterProbe implements ImageSendEncoder {
  int calls = 0;

  @override
  Future<Uint8List> encode(Uint8List png, ImageOutputFormat format) async {
    if (calls++ > 0) throw StateError('Test codec failed');
    return Uint8List.fromList([
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
    ]);
  }
}
