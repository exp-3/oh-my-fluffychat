// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

import 'image_avif.dart';
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
        raster = await _decodeAvif(original.bytes);
      }
      if (raster == null) return PreparedImageSend(original);

      final formats = {...ImageSendOptions.basicFormats};
      // Ordinary images with the default policy never wait for native probes.
      final target = settings.targetMimeType(
        raster.originalMimeType,
        hasTransparency: false,
        supportedFormats: ImageOutputFormat.values.toSet(),
      );
      if (target == ImageOutputFormat.avif.mimeType &&
          await _supports(ImageOutputFormat.avif)) {
        formats.add(ImageOutputFormat.avif);
      }
      // Preserving an optional format must not accidentally change it to PNG.
      if (target == 'image/avif' &&
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
        final format = ImageOutputFormat.values.byName(
          encoded.mimeType.split('/').last,
        );
        bytes = await _encoder.encode(bytes, format);
        if (_specialMimeType(bytes) != encoded.mimeType) {
          throw StateError('The encoder returned a different image format');
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
  return null;
}

Future<ImageSendRaster?> _decodeAvif(Uint8List bytes) async {
  final png = await compute(decodeAvifForSending, bytes);
  if (png == null) return null;
  final raster = await compute(decodeImageForSending, png);
  return raster == null ? null : ImageSendRaster(raster.image, 'image/avif');
}
