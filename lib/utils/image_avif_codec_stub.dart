// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

Future<ui.Codec> createAvifCodec(Uint8List bytes) =>
    Future.error(UnsupportedError('Native AVIF decoding is unavailable'));
