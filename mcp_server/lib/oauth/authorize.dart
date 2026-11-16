import 'dart:io';

import 'clients.dart';
import 'http_support.dart';
import 'signed_request.dart';

/// `GET /authorize`. Checks the request and hands the browser to the web app's
/// `/connect` page; nothing is stored until the user consents there.
class AuthorizeEndpoint {
  AuthorizeEndpoint({
    required ClientRegistry clients,
    required PendingRequests pending,
    required this.appUrl,
    required this.issuer,
    required this.resource,
  }) : _clients = clients,
       _pending = pending;

  final ClientRegistry _clients;
  final PendingRequests _pending;
  final String appUrl;
  final String issuer;
  final String resource;

  Future<void> handle(HttpRequest request) async {
    final params = request.uri.queryParametersAll;
    String? one(String name) {
      final values = params[name];
      return values != null && values.length == 1 ? values.single : null;
    }

    final client = _clients.find(one('client_id'));
    final redirectUri = one('redirect_uri');
    if (client == null) return _errorPage(request, 'Unknown client.');
    if (redirectUri == null || !client.allows(redirectUri)) {
      return _errorPage(request, 'This redirect address is not allowed.');
    }
    final state = one('state');
    Future<void> fail(String error, String description) => _redirect(
      request,
      withQuery(redirectUri, {
        'error': error,
        'error_description': description,
        'state': state,
        'iss': issuer,
      }),
    );

    if (params.values.any((values) => values.length > 1)) {
      return fail('invalid_request', 'A parameter was sent twice.');
    }
    if (one('response_type') != 'code') {
      return fail('unsupported_response_type', 'Only response_type=code.');
    }
    final challenge = one('code_challenge');
    if (challenge == null || !_isChallenge(challenge)) {
      return fail('invalid_request', 'A PKCE code_challenge is required.');
    }
    if (one('code_challenge_method') != 'S256') {
      return fail('invalid_request', 'code_challenge_method must be S256.');
    }
    final requestedResource = one('resource');
    if (requestedResource != null && requestedResource != resource) {
      return fail('invalid_target', 'Unknown resource.');
    }
    final sealed = _pending.seal(
      PendingRequest(
        clientId: client.id,
        clientName: client.displayName,
        redirectUri: redirectUri,
        codeChallenge: challenge,
        state: state,
        resource: resource,
      ),
    );
    return _redirect(
      request,
      '$appUrl/#/connect?request=${Uri.encodeQueryComponent(sealed)}',
    );
  }

  bool _isChallenge(String value) =>
      value.length == 43 && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

  Future<void> _redirect(HttpRequest request, String location) async {
    request.response
      ..statusCode = 302
      ..headers.set('Location', location)
      ..headers.set('Cache-Control', 'no-store');
    await request.response.close();
  }

  Future<void> _errorPage(HttpRequest request, String message) async {
    request.response
      ..statusCode = 400
      ..headers.contentType = ContentType.html
      ..write(
        '<!doctype html><meta charset="utf-8"><title>GymTracker</title>'
        '<p>$message GymTracker did not connect.</p>',
      );
    await request.response.close();
  }
}
