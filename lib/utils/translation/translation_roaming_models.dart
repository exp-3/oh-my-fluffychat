// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

enum TranslationRoamingType { redis, upstash }

enum TranslationRoamingLookupStatus { hit, miss, unavailable }

enum TranslationRoamingError {
  configuration,
  unsupportedPlatform,
  connection,
  authentication,
  protocol,
  timeout,
  disposed,
}

/// Only classified errors may leave a transport. Server errors can contain
/// credentials or submitted command arguments and must never be exposed.
class TranslationRoamingException implements Exception {
  final TranslationRoamingError error;

  const TranslationRoamingException(this.error);

  @override
  String toString() => 'TranslationRoamingException: ${error.name}';
}

class TranslationRoamingLookup {
  final TranslationRoamingLookupStatus status;
  final String? translation;

  const TranslationRoamingLookup(this.status, {this.translation});

  static const miss = TranslationRoamingLookup(
    TranslationRoamingLookupStatus.miss,
  );
  static const unavailable = TranslationRoamingLookup(
    TranslationRoamingLookupStatus.unavailable,
  );
}

/// Non-secret preferences. This type must never contain a PSK or credential.
class TranslationRoamingConfig {
  static const _isWeb = bool.fromEnvironment('dart.library.js_interop');

  final bool enabled;
  final TranslationRoamingType type;
  final String host;
  final int port;
  final bool tls;
  final String username;
  final int database;
  final String endpoint;
  final String keyPrefix;
  final int retentionDays;

  const TranslationRoamingConfig({
    this.enabled = false,
    this.type = TranslationRoamingType.redis,
    this.host = '',
    this.port = 6379,
    this.tls = true,
    this.username = '',
    this.database = 0,
    this.endpoint = '',
    this.keyPrefix = 'fluffychat:translation',
    this.retentionDays = 30,
  });

  bool get supportedOnPlatform =>
      !_isWeb || type != TranslationRoamingType.redis;

  int get ttlSeconds => retentionDays * 86400;

  bool get hasSafeEndpoint {
    // Also protect incomplete drafts and the inactive connection type. A REST
    // endpoint must never become an alternate ordinary-storage credential.
    if (endpoint.contains(RegExp(r'[@?#]'))) return false;
    final uri = Uri.tryParse(endpoint.trim());
    return uri == null ||
        (uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment);
  }

  bool get isValid {
    // Keep command integers exactly representable on both Dart VM and Web.
    if (!hasSafeEndpoint ||
        keyPrefix.trim().isEmpty ||
        retentionDays < 1 ||
        retentionDays > 104249991374) {
      return false;
    }
    if (type == TranslationRoamingType.redis) {
      return host.trim().isNotEmpty &&
          !host.contains(RegExp(r'[\s/]')) &&
          port >= 1 &&
          port <= 65535 &&
          database >= 0 &&
          database <= 2147483647;
    }
    final uri = Uri.tryParse(endpoint.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  TranslationRoamingConfig copyWith({
    bool? enabled,
    TranslationRoamingType? type,
    String? host,
    int? port,
    bool? tls,
    String? username,
    int? database,
    String? endpoint,
    String? keyPrefix,
    int? retentionDays,
  }) => TranslationRoamingConfig(
    enabled: enabled ?? this.enabled,
    type: type ?? this.type,
    host: host ?? this.host,
    port: port ?? this.port,
    tls: tls ?? this.tls,
    username: username ?? this.username,
    database: database ?? this.database,
    endpoint: endpoint ?? this.endpoint,
    keyPrefix: keyPrefix ?? this.keyPrefix,
    retentionDays: retentionDays ?? this.retentionDays,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'type': type.name,
    'host': host,
    'port': port,
    'tls': tls,
    'username': username,
    'database': database,
    'endpoint': endpoint,
    'keyPrefix': keyPrefix,
    'retentionDays': retentionDays,
  };

  factory TranslationRoamingConfig.fromJson(Map<String, Object?> json) =>
      TranslationRoamingConfig(
        enabled: json['enabled'] == true,
        type: json['type'] == 'upstash'
            ? TranslationRoamingType.upstash
            : TranslationRoamingType.redis,
        host: json['host'] is String ? json['host']! as String : '',
        port: json['port'] is int ? json['port']! as int : 6379,
        tls: json['tls'] != false,
        username: json['username'] is String ? json['username']! as String : '',
        database: json['database'] is int ? json['database']! as int : 0,
        endpoint: json['endpoint'] is String ? json['endpoint']! as String : '',
        keyPrefix: json['keyPrefix'] is String
            ? json['keyPrefix']! as String
            : 'fluffychat:translation',
        retentionDays: json['retentionDays'] is int
            ? json['retentionDays']! as int
            : 30,
      );
}

class TranslationRoamingSecrets {
  final String redisPassword;
  final String restToken;
  final String preSharedKey;

  const TranslationRoamingSecrets({
    this.redisPassword = '',
    this.restToken = '',
    this.preSharedKey = '',
  });

  Uint8List? get decodedPreSharedKey {
    final encoded = preSharedKey.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(encoded)) return null;
    try {
      final decoded = base64Url.decode(base64Url.normalize(encoded));
      if (decoded.length != 32 ||
          base64UrlEncode(decoded).replaceAll('=', '') != encoded) {
        return null;
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  bool isValidFor(TranslationRoamingConfig config) {
    final encoded = preSharedKey.trim();
    if (decodedPreSharedKey == null ||
        encoded == redisPassword.trim() ||
        encoded == restToken.trim()) {
      return false;
    }
    return config.type != TranslationRoamingType.upstash ||
        restToken.trim().isNotEmpty;
  }

  TranslationRoamingSecrets copyWith({
    String? redisPassword,
    String? restToken,
    String? preSharedKey,
  }) => TranslationRoamingSecrets(
    redisPassword: redisPassword ?? this.redisPassword,
    restToken: restToken ?? this.restToken,
    preSharedKey: preSharedKey ?? this.preSharedKey,
  );

  @override
  String toString() => 'TranslationRoamingSecrets(<redacted>)';
}
