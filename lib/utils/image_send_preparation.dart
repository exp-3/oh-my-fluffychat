// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:platform_image_converter/platform_image_converter.dart';

import 'image_send_avif.dart';
import 'image_send_options.dart';
import 'image_send_raster.dart';

/// Platform codecs receive a PNG with orientation and size already applied.
/// Keeping this boundary injectable also lets tests exercise codec failures.
abstract interface class ImageSendEncoder {
  Future<Uint8List> encode(Uint8List png, ImageOutputFormat format);
}

class PlatformImageSendEncoder implements ImageSendEncoder {
  @override
  Future<Uint8List> encode(Uint8List png, ImageOutputFormat format) {
    switch (format) {
      case ImageOutputFormat.heic:
        return ImageConverter.convert(
          inputData: png,
          format: OutputFormat.heic,
          quality: 75,
        );
      case ImageOutputFormat.avif:
        return compute(encodeAvifForSending, png);
      default:
        throw UnsupportedError('Not a platform image format: $format');
    }
  }
}

class PreparedImageSend {
  final MatrixFile file;
  final MatrixImageFile? thumbnail;

  const PreparedImageSend(this.file, {this.thumbnail});
}

class ImageSendPreparation {
  static final instance = ImageSendPreparation();

  final ImageSendEncoder _encoder;
  final _capabilities = <ImageOutputFormat, Future<bool>>{};

  ImageSendPreparation({ImageSendEncoder? encoder})
    : _encoder = encoder ?? PlatformImageSendEncoder();

  Future<bool> _supports(ImageOutputFormat format) {
    if (ImageSendOptions.basicFormats.contains(format)) {
      return Future.value(true);
    }
    return _capabilities.putIfAbsent(format, () async {
      try {
        final probe = img.encodePng(img.Image(width: 64, height: 64));
        final bytes = await _encoder
            .encode(probe, format)
            .timeout(const Duration(seconds: 15));
        return _specialMimeType(bytes) == format.mimeType;
      } catch (_) {
        return false;
      }
    });
  }

  Future<Set<ImageOutputFormat>> supportedFormats() async {
    final supported = await Future.wait(
      ImageOutputFormat.values.map(_supports),
    );
    return {
      for (var i = 0; i < supported.length; i++)
        if (supported[i]) ImageOutputFormat.values[i],
    };
  }

  Future<PreparedImageSend> prepare(
    MatrixFile file, {
    required bool compress,
    ImageSendOptions? options,
  }) async {
    // Share providers and keyboards may label images as generic binary files.
    final mimeType = file.mimeType == 'application/octet-stream'
        ? lookupMimeType(file.name, headerBytes: file.bytes) ?? file.mimeType
        : file.mimeType;
    if (!mimeType.startsWith('image/')) return PreparedImageSend(file);
    final original = file is MatrixImageFile && file.mimeType == mimeType
        ? file
        : MatrixImageFile(
            bytes: file.bytes,
            name: file.name,
            mimeType: mimeType,
          );
    if (!compress) return PreparedImageSend(original);

    try {
      final settings = options ?? ImageSendOptions.fromSettings();
      var raster = await compute(decodeImageForSending, original.bytes);
      if (raster == null) {
        final specialMime = _specialMimeType(original.bytes);
        if (specialMime == null) return PreparedImageSend(original);
        raster = await _decodeSpecial(original.bytes, specialMime);
      }
      if (raster == null) return PreparedImageSend(original);

      final formats = {...ImageSendOptions.basicFormats};
      // Ordinary images with the default policy never wait for native probes.
      final target = settings.targetMimeType(
        raster.originalMimeType,
        hasTransparency: false,
        supportedFormats: ImageOutputFormat.values.toSet(),
      );
      for (final format in [ImageOutputFormat.heic, ImageOutputFormat.avif]) {
        if (format.mimeType == target && await _supports(format)) {
          formats.add(format);
        }
      }
      // Preserving an optional format must not accidentally change it to PNG.
      if ({'image/heic', 'image/avif'}.contains(target) &&
          !formats.any((format) => format.mimeType == target) &&
          target == raster.originalMimeType) {
        return PreparedImageSend(original);
      }
      final encoded = await compute(
        encodeImageForSending,
        ImageRasterRequest(
          raster: raster,
          options: settings,
          supportedFormats: formats,
          thumbnailDimension: Client.defaultThumbnailSize,
        ),
      );
      if (encoded == null) return PreparedImageSend(original);
      var bytes = encoded.bytes;
      if (encoded.needsPlatformEncoding) {
        final format = ImageOutputFormat.values.firstWhere(
          (format) => format.mimeType == encoded.mimeType,
        );
        bytes = await _encoder.encode(bytes, format);
        if (_specialMimeType(bytes) != encoded.mimeType) {
          throw StateError('The encoder returned a different image format');
        }
        if (encoded.mimeType == 'image/heic' && encoded.hasTransparency) {
          final decoded = await _decodeSpecial(bytes, 'image/heic');
          if (decoded == null ||
              !decoded.image.any((pixel) => pixel.aNormalized < 1)) {
            throw StateError('The HEIC encoder did not preserve transparency');
          }
        }
      }
      if (bytes.isEmpty) return PreparedImageSend(original);
      if (!encoded.resized &&
          encoded.mimeType == raster.originalMimeType &&
          bytes.length >= original.bytes.length) {
        return PreparedImageSend(original);
      }
      final extension = switch (encoded.mimeType) {
        'image/jpeg' => 'jpg',
        'image/tiff' => 'tiff',
        _ => encoded.mimeType.split('/').last,
      };
      final dot = original.name.lastIndexOf('.');
      final base = dot > 0 ? original.name.substring(0, dot) : original.name;
      final name = '${base.isEmpty ? 'image' : base}.$extension';
      return PreparedImageSend(
        MatrixImageFile(
          bytes: bytes,
          name: name,
          mimeType: encoded.mimeType,
          width: encoded.width,
          height: encoded.height,
          blurhash: encoded.blurhash,
        ),
        thumbnail: MatrixImageFile(
          bytes: encoded.thumbnail,
          name: '$name.thumbnail.png',
          mimeType: 'image/png',
          width: encoded.thumbnailWidth,
          height: encoded.thumbnailHeight,
          blurhash: encoded.blurhash,
        ),
      );
    } catch (error, stackTrace) {
      Logs().w('Unable to optimize image; sending original', error, stackTrace);
      return PreparedImageSend(original);
    }
  }
}

String? _specialMimeType(Uint8List bytes) {
  if (bytes.length < 16 ||
      String.fromCharCodes(bytes.sublist(4, 8)) != 'ftyp') {
    return null;
  }
  final boxSize = ByteData.sublistView(bytes).getUint32(0);
  final end = min(boxSize, bytes.length);
  final brands = <String>{};
  for (var i = 8; i + 4 <= end; i += 4) {
    if (i != 12) brands.add(String.fromCharCodes(bytes.sublist(i, i + 4)));
  }
  // Sequence brands must never pass through a still-image converter.
  if (brands.contains('avis') || brands.contains('msf1')) return null;
  if (brands.contains('avif')) return 'image/avif';
  if (brands.any({'heic', 'heix', 'heim', 'heis'}.contains)) {
    return 'image/heic';
  }
  return null;
}

Future<ImageSendRaster?> _decodeSpecial(
  Uint8List bytes,
  String mimeType,
) async {
  ui.Image? image;
  ui.Codec? codec;
  try {
    if (mimeType == 'image/avif') {
      final png = await compute(decodeAvifForSending, bytes);
      if (png == null) return null;
      final raster = await compute(decodeImageForSending, png);
      return raster == null ? null : ImageSendRaster(raster.image, mimeType);
    } else {
      codec = await ui.instantiateImageCodec(bytes);
      if (codec.frameCount != 1) return null;
      image = (await codec.getNextFrame()).image;
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    final raster = await compute(
      decodeImageForSending,
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    return raster == null ? null : ImageSendRaster(raster.image, mimeType);
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
