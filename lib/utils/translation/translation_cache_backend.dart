// SPDX-FileCopyrightText: 2026 OMF Project
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

export 'translation_cache_backend_native.dart'
    if (dart.library.html) 'translation_cache_backend_web.dart';
