import 'dart:convert';
import 'dart:io';

import '../account_directory.dart';
import '../request_budget.dart';
import 'auth_store.dart';
import 'clients.dart';
import 'http_support.dart';
import 'signed_request.dart';
import 'signing_keys.dart';

/// `POST /connect`, called by the web app's consent page with the signed
/// request, the signed-in user's Firebase ID token and their decision. It
/// answers with the address to send the browser to. There are no cookies, so
/// the only origin allowed to call it is the web app's.
class ConnectEndpoint {
  ConnectEndpoint({
    required ClientRegistry clients,
    required PendingRequests pending,
    required AccountDirectory accounts,
    required AuthStore store,
    required RequestBudget budget,
    required this.appUrl,
    required this.issuer,
    DateTime Function() now = DateTime.now,
  }) : _clients = clients,
       _pending = pending,
       _accounts = accounts,
       _store = store,
       _budget = budget,
       _now = now;

  static const codeLifetime = Duration(minutes: 5);

  final ClientRegistry _clients;
  final PendingRequests _pending;
  final AccountDirectory _accounts;
  final AuthStore _store;
  final RequestBudget _budget;
  final String appUrl;
  final String issuer;
  final DateTime Function() _now;

  Future<void> handle(HttpRequest request) async {
    final response = request.response
      ..headers.set('Access-Control-Allow-Origin', Uri.parse(appUrl).origin)
      ..headers.set('Vary', 'Origin');
    if (request.method == 'OPTIONS') {
      response
        ..statusCode = 204
        ..headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS')
        ..headers.set('Access-Control-Allow-Headers', 'Content-Type')
        ..headers.set('Access-Control-Max-Age', '600');
      return response.close();
    }
    if (request.method != 'POST')
      return _fail(response, 405, 'invalid_request');
    final wait = _budget.spend();
    if (wait != null) return _tooMany(response, wait);

    final body = _parse(await readBody(request));
    if (body == null) return _fail(response, 400, 'invalid_request');
    final pending = _pending.open(body.request);
    final client = pending == null ? null : _clients.find(pending.clientId);
    if (pending == null ||
        client == null ||
        !client.allows(pending.redirectUri)) {
      return _fail(response, 400, 'invalid_request');
    }
    if (body.decision == 'deny') {
      return sendNoStoreJson(response, 200, {
        'redirect': _answer(pending, {'error': 'access_denied'}),
      });
    }
    final VerifiedAccount? account;
    try {
      account = await _accounts.verifyIdToken(body.idToken);
    } on StateError {
      return _fail(response, 503, 'temporarily_unavailable');
    }
    if (account == null) return _fail(response, 401, 'invalid_token');
    final code = randomSecret();
    await _store.saveCode(
      sha256Hex(code),
      GrantedCode(
        grantId: randomSecret(16),
        uid: account.uid,
        clientId: pending.clientId,
        redirectUri: pending.redirectUri,
        codeChallenge: pending.codeChallenge,
        resource: pending.resource,
        expiresAt: _now().add(codeLifetime),
      ),
    );
    return sendNoStoreJson(response, 200, {
      'redirect': _answer(pending, {'code': code}),
    });
  }

  String _answer(PendingRequest pending, Map<String, String> params) =>
      withQuery(pending.redirectUri, {
        ...params,
        'state': pending.state,
        'iss': issuer,
      });

  _ConnectBody? _parse(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final request = json['request'];
      final decision = json['decision'];
      final idToken = json['idToken'];
      if (request is! String || (decision != 'allow' && decision != 'deny')) {
        return null;
      }
      if (decision == 'allow' && (idToken is! String || idToken.isEmpty)) {
        return null;
      }
      return _ConnectBody(
        request,
        decision as String,
        idToken as String? ?? '',
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _fail(HttpResponse response, int status, String error) =>
      sendNoStoreJson(response, status, {'error': error});

  Future<void> _tooMany(HttpResponse response, Duration wait) async {
    response.headers.set('Retry-After', (wait.inMilliseconds / 1000).ceil());
    await sendNoStoreJson(response, 429, {'error': 'rate_limited'});
  }
}

class _ConnectBody {
  _ConnectBody(this.request, this.decision, this.idToken);

  final String request;
  final String decision;
  final String idToken;
}
