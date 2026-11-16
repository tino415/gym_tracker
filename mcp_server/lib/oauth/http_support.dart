import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _random = Random.secure();

String randomSecret([int bytes = 32]) => base64Url
    .encode([for (var i = 0; i < bytes; i++) _random.nextInt(256)])
    .replaceAll('=', '');

/// Bodies on these endpoints are a few hundred bytes; anything past [limit]
/// is refused instead of buffered.
Future<String?> readBody(HttpRequest request, {int limit = 16 * 1024}) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
    if (bytes.length > limit) return null;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

Future<void> sendJson(
  HttpResponse response,
  int status,
  Object? body, {
  Map<String, String> headers = const {},
}) async {
  response
    ..statusCode = status
    ..headers.contentType = ContentType.json;
  headers.forEach(response.headers.set);
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> sendNoStoreJson(HttpResponse response, int status, Object? body) =>
    sendJson(
      response,
      status,
      body,
      headers: {'Cache-Control': 'no-store', 'Pragma': 'no-cache'},
    );

String withQuery(String uri, Map<String, String?> params) {
  final base = Uri.parse(uri);
  final query = {
    ...base.queryParameters,
    for (final e in params.entries)
      if (e.value != null) e.key: e.value!,
  };
  return base.replace(queryParameters: query).toString();
}
