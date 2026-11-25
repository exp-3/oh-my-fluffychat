// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat and Oh-My-FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/config/isrg_x1.dart';
import 'package:fluffychat/config/isrg_x2.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart' as retry;

/// Custom HTTP client that adds the ISRG Root certificates used by Let's
/// Encrypt. Older Android versions may not include these roots in their
/// trust store, so we ship them ourselves to ensure TLS connections to
/// Let's Encrypt–signed servers continue to work.
class CustomHttpClient {
  static HttpClient customHttpClient() {
    final context = SecurityContext.defaultContext;

    try {
      context.setTrustedCertificatesBytes(utf8.encode(ISRG_X1));
      context.setTrustedCertificatesBytes(utf8.encode(ISRG_X2));
    } on TlsException catch (e) {
      if (e.osError != null &&
          e.osError!.message.contains('CERT_ALREADY_IN_HASH_TABLE')) {
      } else {
        rethrow;
      }
    }

    return HttpClient(context: context);
  }

  static http.Client createHTTPClient() {
    final client = retry.RetryClient(
      PlatformInfos.isAndroid ? IOClient(customHttpClient()) : http.Client(),
    );
    return PlatformInfos.isWeb ? client : _OidcTokenUserAgentClient(client);
  }
}

class _OidcTokenUserAgentClient extends http.BaseClient {
  final http.Client _inner;
  Future<String>? _userAgent;

  _OidcTokenUserAgentClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // MAS derives device information from the login User-Agent and records it
    // again on token refresh. Keep the default UA for every other request.
    if (_isOidcTokenRequest(request)) {
      request.headers['user-agent'] = await (_userAgent ??= _buildUserAgent());
    }
    return _inner.send(request);
  }

  static bool _isOidcTokenRequest(http.BaseRequest request) {
    if (request is! http.Request || request.method != 'POST') return false;
    final contentType = request.headers['content-type']?.split(';').first;
    if (contentType?.trim().toLowerCase() !=
        'application/x-www-form-urlencoded') {
      return false;
    }

    try {
      final fields = request.bodyFields;
      final requiredFields = switch (fields['grant_type']) {
        'authorization_code' => const [
          'code',
          'client_id',
          'code_verifier',
          'redirect_uri',
        ],
        'refresh_token' => const ['refresh_token', 'client_id'],
        _ => null,
      };
      return requiredFields != null &&
          requiredFields.every((field) => fields[field]?.isNotEmpty ?? false);
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  static Future<String> _buildUserAgent() async {
    final version = await PlatformInfos.getVersion();
    final platform = switch (Platform.operatingSystem) {
      'android' => 'Android',
      'ios' => 'iOS',
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      _ => Platform.operatingSystem,
    };
    // MAS parses the whole UA as product/version (device; OS). Appending to
    // Dart's default UA would produce an incorrect device name.
    return 'FluffyChat/$version ($platform; $platform)';
  }

  @override
  void close() => _inner.close();
}
