// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:image/image.dart' as img;

import 'image_send_options.dart';

/// Runs on a worker isolate on native platforms. A null result means that the
/// input cannot safely be processed (including animations and multipage TIFFs).
ImageSendRaster? decodeImageForSending(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null || decoder.startDecode(bytes) == null) return null;
  if (decoder.numFrames() != 1) return null;
  final image = decoder.decodeFrame(0);
  if (image == null) return null;
  final mimeType = switch (decoder.format) {
    img.ImageFormat.jpg => 'image/jpeg',
    img.ImageFormat.png => 'image/png',
    img.ImageFormat.webp => 'image/webp',
    img.ImageFormat.bmp => 'image/bmp',
    img.ImageFormat.tiff => 'image/tiff',
    img.ImageFormat.gif => 'image/gif',
    _ => null,
  };
  if (mimeType == null) return null;
  return ImageSendRaster(img.bakeOrientation(image), mimeType);
}

class ImageSendRaster {
  final img.Image image;
  final String originalMimeType;

  const ImageSendRaster(this.image, this.originalMimeType);
}

class ImageRasterRequest {
  final ImageSendRaster raster;
  final ImageSendOptions options;
  final Set<ImageOutputFormat> supportedFormats;
  final int thumbnailDimension;

  const ImageRasterRequest({
    required this.raster,
    required this.options,
    required this.supportedFormats,
    required this.thumbnailDimension,
  });
}

class EncodedImageRaster {
  final Uint8List bytes;
  final String mimeType;
  final int width, height;
  final bool resized;
  final bool needsPlatformEncoding;
  final bool hasTransparency;
  final Uint8List thumbnail;
  final int thumbnailWidth, thumbnailHeight;
  final String blurhash;

  const EncodedImageRaster({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.resized,
    required this.needsPlatformEncoding,
    required this.hasTransparency,
    required this.thumbnail,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    required this.blurhash,
  });
}

img.Image _scaleDown(img.Image image, int maxDimension) {
  final longest = math.max(image.width, image.height);
  if (longest <= maxDimension) return image;
  return img.copyResize(
    image,
    width: math.max(1, (image.width * maxDimension / longest).round()),
    height: math.max(1, (image.height * maxDimension / longest).round()),
    interpolation: img.Interpolation.average,
  );
}

/// HEIC/AVIF return an oriented, resized PNG for their platform encoder. Other
/// formats are encoded here so pixels are resized and encoded only once.
EncodedImageRaster? encodeImageForSending(ImageRasterRequest request) {
  final original = request.raster.image;
  final transparent =
      original.hasAlpha && original.any((pixel) => pixel.aNormalized < 1);
  final mimeType = request.options.targetMimeType(
    request.raster.originalMimeType,
    hasTransparency: transparent,
    supportedFormats: request.supportedFormats,
  );
  final image = _scaleDown(original, request.options.maxDimension);
  final platformEncoding = {'image/heic', 'image/avif'}.contains(mimeType);
  final Uint8List bytes;
  switch (mimeType) {
    case 'image/png':
    case 'image/heic':
    case 'image/avif':
      bytes = img.encodePng(image, level: 9);
    case 'image/jpeg':
      bytes = img.encodeJpg(image, quality: 75);
    case 'image/webp':
      bytes = img.encodeWebP(image, lossless: false, quality: 75);
    default:
      final extension = switch (mimeType) {
        'image/bmp' => 'bmp',
        'image/tiff' => 'tiff',
        'image/gif' => 'gif',
        _ => null,
      };
      if (extension == null) return null;
      final encoded = img.encodeNamedImage('image.$extension', image);
      if (encoded == null) return null;
      bytes = encoded;
  }
  final thumbnail = _scaleDown(image, request.thumbnailDimension);
  final blurhashImage = _scaleDown(thumbnail, 64);
  return EncodedImageRaster(
    bytes: bytes,
    mimeType: mimeType,
    width: image.width,
    height: image.height,
    resized: original.width != image.width || original.height != image.height,
    needsPlatformEncoding: platformEncoding,
    hasTransparency: transparent,
    thumbnail: img.encodePng(thumbnail),
    thumbnailWidth: thumbnail.width,
    thumbnailHeight: thumbnail.height,
    blurhash: BlurHash.encode(blurhashImage, numCompX: 4, numCompY: 3).hash,
  );
}
