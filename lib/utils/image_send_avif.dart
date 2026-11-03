// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

// Conditional imports let unused-code analysis track both implementations.
import 'image_send_avif_stub.dart'
    if (dart.library.io) 'image_send_avif_native.dart'
    as avif;

Uint8List encodeAvifForSending(Uint8List png) => avif.encodeAvifForSending(png);

Uint8List? decodeAvifForSending(Uint8List bytes) =>
    avif.decodeAvifForSending(bytes);
