import 'dart:io';

import '../account_directory.dart';
import '../request_budget.dart';
import 'auth_store.dart';
import 'clients.dart';
import 'http_support.dart';
import 'jwt.dart';
import 'metadata.dart';
import 'revocations.dart';
import 'signing_keys.dart';

/// `POST /token`: the authorization code exchange and the refresh grant, for
/// public clients (no secret; the PKCE verifier is the proof).
class TokenEndpoint {
  TokenEndpoint({
    required ClientRegistry clients,
    required AuthStore store,
    required Revocations revocations,
    required AccessTokens accessTokens,
    required AccountDirectory accounts,
    required RequestBudget budget,
    required this.resource,
    DateTime Function() now = DateTime.now,
  }) : _clients = clients,
       _store = store,
       _revocations = revocations,
       _accessTokens = accessTokens,
       _accounts = accounts,
       _budget = budget,
       _now = now;

  static const refreshLifetime = Duration(days: 30);

  final ClientRegistry _clients;
  final AuthStore _store;
  final Revocations _revocations;
  final AccessTokens _accessTokens;
  final AccountDirectory _accounts;
  final RequestBudget _budget;
  final String resource;
  final DateTime Function() _now;

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'POST') {
      return _error(response, 405, 'invalid_request', 'Use POST.');
    }
    final wait = _budget.spend();
    if (wait != null) {
      response.headers.set('Retry-After', (wait.inMilliseconds / 1000).ceil());
      return _error(response, 429, 'invalid_request', 'Too many requests.');
    }
    final form = _form(await readBody(request));
    if (form == null) {
      return _error(response, 400, 'invalid_request', 'Expected a form body.');
    }
    final client = _clients.find(form['client_id']);
    if (client == null) {
      return _error(response, 400, 'invalid_client', 'Unknown client.');
    }
    final requestedResource = form['resource'];
    if (requestedResource != null && requestedResource != resource) {
      return _error(response, 400, 'invalid_target', 'Unknown resource.');
    }
    return switch (form['grant_type']) {
      'authorization_code' => _exchangeCode(response, client, form),
      'refresh_token' => _refresh(response, client, form),
      _ => _error(
        response,
        400,
        'unsupported_grant_type',
        'Use authorization_code or refresh_token.',
      ),
    };
  }

  Future<void> _exchangeCode(
    HttpResponse response,
    OAuthClient client,
    Map<String, String> form,
  ) async {
    final presented = form['code'];
    final verifier = form['code_verifier'];
    if (presented == null || verifier == null) {
      return _error(
        response,
        400,
        'invalid_request',
        'code and code_verifier.',
      );
    }
    final redemption = await _store.redeemCode(sha256Hex(presented), _now());
    switch (redemption) {
      case Unknown():
        return _invalidGrant(response);
      case Reused(:final grantId):
        await _revocations.revoke(grantId);
        return _invalidGrant(response);
      case Redeemed(:final value):
        final matches =
            value.clientId == client.id &&
            value.redirectUri == form['redirect_uri'] &&
            _verifies(verifier, value.codeChallenge);
        if (!matches) return _invalidGrant(response);
        final account = await _accounts.verify(value.uid);
        if (account == null) return _invalidGrant(response);
        return _issue(
          response,
          RefreshGrant(
            grantId: value.grantId,
            uid: value.uid,
            clientId: value.clientId,
            resource: value.resource,
            canSave: value.canSave,
            expiresAt: _now().add(refreshLifetime),
          ),
        );
    }
  }

  Future<void> _refresh(
    HttpResponse response,
    OAuthClient client,
    Map<String, String> form,
  ) async {
    final presented = form['refresh_token'];
    if (presented == null) {
      return _error(response, 400, 'invalid_request', 'refresh_token.');
    }
    final successor = randomSecret();
    final redemption = await _store.rotateRefreshToken(
      sha256Hex(presented),
      clientId: client.id,
      successorHash: sha256Hex(successor),
      successorExpiresAt: _now().add(refreshLifetime),
      now: _now(),
    );
    switch (redemption) {
      case Unknown():
        return _invalidGrant(response);
      case Reused(:final grantId):
        await _revocations.revoke(grantId);
        return _invalidGrant(response);
      case Redeemed(:final value):
        if (await _revocations.isRevoked(value.grantId)) {
          return _invalidGrant(response);
        }
        if (await _accounts.verify(value.uid) == null) {
          return _invalidGrant(response);
        }
        return _respond(response, value, successor);
    }
  }

  Future<void> _issue(HttpResponse response, RefreshGrant grant) async {
    final refreshToken = randomSecret();
    await _store.saveRefreshToken(sha256Hex(refreshToken), grant);
    return _respond(response, grant, refreshToken);
  }

  Future<void> _respond(
    HttpResponse response,
    RefreshGrant grant,
    String refreshToken,
  ) => sendNoStoreJson(response, 200, {
    'access_token': _accessTokens.issue(
      AccessClaims(
        uid: grant.uid,
        grantId: grant.grantId,
        clientId: grant.clientId,
        canSave: grant.canSave,
      ),
    ),
    'token_type': 'Bearer',
    'expires_in': AccessTokens.lifetime.inSeconds,
    'refresh_token': refreshToken,
    'scope': oauthScope,
  });

  bool _verifies(String verifier, String challenge) =>
      RegExp(r'^[A-Za-z0-9\-._~]{43,128}$').hasMatch(verifier) &&
      sha256Base64Url(verifier) == challenge;

  Map<String, String>? _form(String? body) {
    if (body == null) return null;
    try {
      return Uri.splitQueryString(body);
    } on FormatException {
      return null;
    }
  }

  Future<void> _invalidGrant(HttpResponse response) => _error(
    response,
    400,
    'invalid_grant',
    'The grant is invalid, expired or already used.',
  );

  Future<void> _error(
    HttpResponse response,
    int status,
    String error,
    String description,
  ) => sendNoStoreJson(response, status, {
    'error': error,
    'error_description': description,
  });
}
