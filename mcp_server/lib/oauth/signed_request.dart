import 'signing_keys.dart';

/// What `/authorize` checked, carried to `/connect` in the page address instead
/// of a database row: nothing is stored until the user consents.
class PendingRequest {
  PendingRequest({
    required this.clientId,
    required this.clientName,
    required this.redirectUri,
    required this.codeChallenge,
    required this.state,
    required this.resource,
  });

  final String clientId;
  final String clientName;
  final String redirectUri;
  final String codeChallenge;
  final String? state;
  final String resource;
}

class PendingRequests {
  PendingRequests(this._keys, {DateTime Function() now = DateTime.now})
    : _now = now;

  static const lifetime = Duration(minutes: 10);

  final SigningKeys _keys;
  final DateTime Function() _now;

  String seal(PendingRequest request) => _keys.sign(TokenType.pendingRequest, {
    'client_id': request.clientId,
    'client_name': request.clientName,
    'redirect_uri': request.redirectUri,
    'code_challenge': request.codeChallenge,
    'state': request.state,
    'resource': request.resource,
    'exp': _now().add(lifetime).millisecondsSinceEpoch ~/ 1000,
  });

  PendingRequest? open(String sealed) {
    final claims = _keys.verify(TokenType.pendingRequest, sealed);
    if (claims == null) return null;
    final clientId = claims['client_id'];
    final clientName = claims['client_name'];
    final redirectUri = claims['redirect_uri'];
    final codeChallenge = claims['code_challenge'];
    final state = claims['state'];
    final resource = claims['resource'];
    if (clientId is! String ||
        clientName is! String ||
        redirectUri is! String ||
        codeChallenge is! String ||
        resource is! String ||
        (state != null && state is! String)) {
      return null;
    }
    return PendingRequest(
      clientId: clientId,
      clientName: clientName,
      redirectUri: redirectUri,
      codeChallenge: codeChallenge,
      state: state as String?,
      resource: resource,
    );
  }
}
