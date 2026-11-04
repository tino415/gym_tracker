import 'package:http/http.dart' as http;

/// The emulators treat `Bearer owner` as an admin, which is how the Admin SDK
/// gets past the security rules in production too.
class EmulatorAdminClient extends http.BaseClient {
  EmulatorAdminClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer owner';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
