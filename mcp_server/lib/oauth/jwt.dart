import 'signing_keys.dart';

class AccessClaims {
  AccessClaims({
    required this.uid,
    required this.grantId,
    required this.clientId,
    this.canSave = false,
  });

  final String uid;
  final String grantId;
  final String clientId;
  final bool canSave;
}

class AccessTokens {
  AccessTokens(
    this._keys, {
    required this.issuer,
    required this.audience,
    DateTime Function() now = DateTime.now,
  }) : _now = now;

  static const lifetime = Duration(hours: 1);

  final SigningKeys _keys;
  final String issuer;
  final String audience;
  final DateTime Function() _now;

  String issue(AccessClaims claims) {
    final issuedAt = _now().millisecondsSinceEpoch ~/ 1000;
    return _keys.sign(TokenType.accessToken, {
      'iss': issuer,
      'aud': audience,
      'sub': claims.uid,
      'gid': claims.grantId,
      'client_id': claims.clientId,
      if (claims.canSave) 'wr': true,
      'iat': issuedAt,
      'exp': issuedAt + lifetime.inSeconds,
    });
  }

  AccessClaims? verify(String token) {
    final claims = _keys.verify(TokenType.accessToken, token);
    if (claims == null) return null;
    if (claims['iss'] != issuer || claims['aud'] != audience) return null;
    final uid = claims['sub'];
    final grantId = claims['gid'];
    final clientId = claims['client_id'];
    if (uid is! String || grantId is! String || clientId is! String)
      return null;
    if (uid.isEmpty || grantId.isEmpty) return null;
    return AccessClaims(
      uid: uid,
      grantId: grantId,
      clientId: clientId,
      canSave: claims['wr'] == true,
    );
  }
}
