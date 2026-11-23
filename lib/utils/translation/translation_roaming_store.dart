// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Transports only receive Redis keys, encrypted values and authentication
/// credentials. Plaintext sources and the PSK never cross this interface.
abstract interface class TranslationRoamingStore {
  Future<String?> getEx(String key, int ttlSeconds);

  Future<void> set(String key, String value, int ttlSeconds);

  Future<void> delete(String key);

  /// Abandon pending I/O while allowing a subsequent operation to reconnect.
  void reset();

  void dispose();
}
