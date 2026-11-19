import 'dart:convert';

/// A pending request as the MCP server seals it: only the client name in the
/// payload is read by the app, and the signature is the server's to check.
String fakeConnectRequest(String clientName) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'client_name': clientName})}.sig';
}
