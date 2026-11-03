// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

Uint8List encodeAvifForSending(Uint8List png) =>
    throw UnsupportedError('AVIF encoding is unavailable on this platform');

Uint8List? decodeAvifForSending(Uint8List bytes) => null;
