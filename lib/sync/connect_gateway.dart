import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// The MCP server the consent page talks to. Fixed when the app is built: a
/// server taken from the page address would let a crafted link send the user's
/// ID token anywhere.
const String mcpServerUrl = String.fromEnvironment('MCP_SERVER_URL');

enum ConnectDecision { allow, deny }

abstract class ConnectGateway {
  Future<Uri> decide(String request, ConnectDecision decision);
}

class ConnectRefused implements Exception {
  ConnectRefused(this.status);

  final int status;

  @override
  String toString() => 'The server answered $status';
}

class HttpConnectGateway implements ConnectGateway {
  HttpConnectGateway(
    this._serverUrl, {
    http.Client? client,
    Future<String?> Function()? idToken,
  }) : _client = client ?? http.Client(),
       _idToken = idToken ?? _firebaseIdToken;

  final String _serverUrl;
  final http.Client _client;
  final Future<String?> Function() _idToken;

  static Future<String?> _firebaseIdToken() =>
      FirebaseAuth.instance.currentUser?.getIdToken() ?? Future.value(null);

  @override
  Future<Uri> decide(String request, ConnectDecision decision) async {
    final response = await _client.post(
      Uri.parse('$_serverUrl/connect'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'request': request,
        'idToken': decision == ConnectDecision.allow ? await _idToken() : null,
        'decision': decision.name,
      }),
    );
    if (response.statusCode != 200) throw ConnectRefused(response.statusCode);
    final redirect = (jsonDecode(response.body) as Map)['redirect'] as String;
    return Uri.parse(redirect);
  }
}

final connectGatewayProvider = Provider<ConnectGateway?>(
  (_) => mcpServerUrl.isEmpty ? null : HttpConnectGateway(mcpServerUrl),
);

final connectRedirectProvider = Provider<Future<void> Function(Uri)>(
  (_) =>
      (uri) => launchUrl(uri, webOnlyWindowName: '_self'),
);

/// The assistant's name in a signed request, for display only: the server
/// checks the request again when it is answered.
String? clientNameOf(String request) {
  final parts = request.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final name = payload is Map ? payload['client_name'] : null;
    return name is String && name.isNotEmpty ? name : null;
  } on FormatException {
    return null;
  }
}
