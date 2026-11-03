// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';

enum ImageFormatPolicy { preserve, legacyOnly, preferred }

enum ImageOutputFormat {
  png('PNG', 'png', 'image/png'),
  jpeg('JPEG', 'jpg', 'image/jpeg'),
  webp('WEBP', 'webp', 'image/webp'),
  heic('HEIC', 'heic', 'image/heic'),
  avif('AVIF', 'avif', 'image/avif');

  final String label;
  final String extension;
  final String mimeType;

  const ImageOutputFormat(this.label, this.extension, this.mimeType);
}

class ImageSendOptions {
  static const defaultMaxDimension = 1600;
  static const basicFormats = {
    ImageOutputFormat.png,
    ImageOutputFormat.jpeg,
    ImageOutputFormat.webp,
  };

  final ImageFormatPolicy formatPolicy;
  final ImageOutputFormat preferredFormat;
  final int maxDimension;

  const ImageSendOptions({
    this.formatPolicy = ImageFormatPolicy.preserve,
    this.preferredFormat = ImageOutputFormat.webp,
    this.maxDimension = defaultMaxDimension,
  }) : assert(maxDimension > 0);

  factory ImageSendOptions.fromSettings() {
    final dimension = AppSettings.imageMaxDimension.value;
    return ImageSendOptions(
      formatPolicy:
          ImageFormatPolicy.values
              .where(
                (value) => value.name == AppSettings.imageFormatPolicy.value,
              )
              .firstOrNull ??
          ImageFormatPolicy.preserve,
      preferredFormat:
          ImageOutputFormat.values
              .where(
                (value) => value.name == AppSettings.preferredImageFormat.value,
              )
              .firstOrNull ??
          ImageOutputFormat.webp,
      maxDimension: dimension > 0 ? dimension : defaultMaxDimension,
    );
  }

  String targetMimeType(
    String originalMimeType, {
    required bool hasTransparency,
    required Set<ImageOutputFormat> supportedFormats,
  }) {
    if (formatPolicy == ImageFormatPolicy.preserve ||
        (formatPolicy == ImageFormatPolicy.legacyOnly &&
            !{
              'image/png',
              'image/bmp',
              'image/tiff',
            }.contains(originalMimeType))) {
      return originalMimeType;
    }
    final preferred = supportedFormats.contains(preferredFormat)
        ? preferredFormat
        : ImageOutputFormat.webp;
    if (hasTransparency && preferred == ImageOutputFormat.jpeg) {
      return originalMimeType;
    }
    return preferred.mimeType;
  }
}
