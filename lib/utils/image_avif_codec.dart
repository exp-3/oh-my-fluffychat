// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'image_avif_codec_stub.dart'
    if (dart.library.io) 'image_avif_codec_native.dart'
    as avif;

Future<ui.Codec> createAvifCodec(Uint8List bytes) =>
    avif.createAvifCodec(bytes);
