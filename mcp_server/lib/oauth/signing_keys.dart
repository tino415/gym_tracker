import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What a signed token is for. The same keys sign every kind, and the `typ`
/// header keeps a token of one kind from being accepted as another.
enum TokenType {
  accessToken('at+jwt'),
  pendingRequest('gym-request+jwt');

  const TokenType(this.header);

  final String header;
}

/// HS256 compact tokens over a set of keys. [currentKid] signs; every kid in
/// [keys] verifies, so a key can be rotated in before the old one is removed.
class SigningKeys {
  SigningKeys(
    this.keys,
    this.currentKid, {
    DateTime Function() now = DateTime.now,
  }) : _now = now {
    if (!keys.containsKey(currentKid)) {
      throw ArgumentError('No signing key named $currentKid');
    }
  }

  factory SigningKeys.fromJson(
    String json,
    String currentKid, {
    DateTime Function() now = DateTime.now,
  }) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded.isEmpty) {
      throw ArgumentError(
        'MCP_SIGNING_KEYS must be a JSON object of kid: secret',
      );
    }
    final keys = {
      for (final e in decoded.entries) e.key as String: e.value as String,
    };
    for (final entry in keys.entries) {
      if (entry.value.length < minimumSecretLength) {
        throw ArgumentError(
          'Signing key ${entry.key} must be at least $minimumSecretLength characters.',
        );
      }
    }
    return SigningKeys(keys, currentKid, now: now);
  }

  static const minimumSecretLength = 32;

  final Map<String, String> keys;
  final String currentKid;
  final DateTime Function() _now;

  String sign(TokenType type, Map<String, Object?> claims) {
    final header = _encode({
      'alg': 'HS256',
      'typ': type.header,
      'kid': currentKid,
    });
    final payload = _encode(claims);
    return '$header.$payload.${_signature('$header.$payload', keys[currentKid]!)}';
  }

  /// The claims of a token of [type] that was signed with one of the keys and
  /// has not expired, or null.
  Map<String, Object?>? verify(TokenType type, String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final header = _decode(parts[0]);
    final payload = _decode(parts[1]);
    if (header == null || payload == null) return null;
    if (header['alg'] != 'HS256' || header['typ'] != type.header) return null;
    final secret = keys[header['kid']];
    if (secret == null) return null;
    final expected = _signature('${parts[0]}.${parts[1]}', secret);
    if (!_sameText(expected, parts[2])) return null;
    final exp = payload['exp'];
    if (exp is! int || exp * 1000 <= _now().millisecondsSinceEpoch) return null;
    return payload;
  }

  static String _signature(String signingInput, String secret) => base64Url
      .encode(
        Hmac(
          sha256,
          utf8.encode(secret),
        ).convert(utf8.encode(signingInput)).bytes,
      )
      .replaceAll('=', '');

  static String _encode(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

  static Map<String, Object?>? _decode(String segment) {
    try {
      final json = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segment))),
      );
      return json is Map ? json.cast() : null;
    } on FormatException {
      return null;
    }
  }

  static bool _sameText(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

String sha256Base64Url(String value) => base64Url
    .encode(sha256.convert(utf8.encode(value)).bytes)
    .replaceAll('=', '');
