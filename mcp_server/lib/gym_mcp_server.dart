import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';

import 'account_directory.dart';
import 'config.dart';
import 'dev_token_auth.dart';
import 'emulator_client.dart';
import 'tools/list_routines.dart';
import 'user_scope.dart';

/// Streamable HTTP front for the MCP server. `StreamableMcpServer` would do the
/// routing, but a tool can't learn which user a request belongs to there, so
/// this owns the session map: every session and every stateless request gets an
/// `McpServer` built for the verified account that made it.
class GymMcpServer {
  GymMcpServer(
    this._config, {
    http.Client? client,
    DateTime Function() now = DateTime.now,
  }) : _client = client ?? EmulatorAdminClient() {
    _accounts = AccountDirectory(
      client: _client,
      authRoot: _config.authRoot,
      projectId: _config.projectId,
      now: now,
    );
    _authenticator = DevTokenAuthenticator(_config, _accounts);
    _firestore = fs.FirestoreApi(
      _client,
      rootUrl: _config.firestoreRoot.toString(),
    );
  }

  final ServerConfig _config;
  final http.Client _client;
  late final AccountDirectory _accounts;
  late final DevTokenAuthenticator _authenticator;
  late final fs.FirestoreApi _firestore;
  final Map<String, _Session> _sessions = {};
  HttpServer? _http;

  int get port => _http!.port;

  Future<void> start() async {
    _http = await HttpServer.bind(_config.host, _config.port);
    _http!.listen(_handle);
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    for (final session in _sessions.values.toList()) {
      await session.transport.close();
    }
    _client.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path != '/mcp') return _plain(request, 404, 'Not Found');
      final outcome = await _authenticator.authenticate(request.headers);
      switch (outcome) {
        case Rejected(:final reason):
          return _unauthorized(request, reason);
        case Authenticated(:final account):
          return await _route(request, account);
      }
    } catch (e, st) {
      stderr.writeln('request failed: $e\n$st');
      try {
        await _plain(request, 500, 'Internal Server Error');
      } catch (_) {}
    }
  }

  Future<void> _route(HttpRequest request, VerifiedAccount account) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId != null) return _routeToSession(request, account, sessionId);
    switch (request.method) {
      case 'POST':
        final body = await _readJson(request);
        if (body == null) return _plain(request, 400, 'Parse error');
        if (_isInitialize(body)) {
          return _startSession(request, account, body);
        }
        return _handleStateless(request, account, body);
      case 'GET' || 'DELETE':
        return _plain(request, 400, 'Missing session ID');
      default:
        return _plain(request, 405, 'Method Not Allowed');
    }
  }

  Future<void> _routeToSession(
    HttpRequest request,
    VerifiedAccount account,
    String sessionId,
  ) async {
    final session = _sessions[sessionId];
    if (session == null || session.uid != account.uid) {
      return _plain(request, 404, 'Session not found');
    }
    final body = request.method == 'POST' ? await _readJson(request) : null;
    await session.transport.handleRequest(request, body);
  }

  Future<void> _startSession(
    HttpRequest request,
    VerifiedAccount account,
    Object body,
  ) async {
    late final StreamableHTTPServerTransport transport;
    transport = _transport(
      sessionIdGenerator: () => generateUUID(),
      onSessionInitialized: (id) =>
          _sessions[id] = _Session(account.uid, transport),
    );
    transport.onclose = () {
      final id = transport.sessionId;
      if (id != null) _sessions.remove(id);
    };
    await _serverFor(account).connect(transport);
    await transport.handleRequest(request, body);
  }

  Future<void> _handleStateless(
    HttpRequest request,
    VerifiedAccount account,
    Object body,
  ) async {
    final transport = _transport(sessionIdGenerator: () => null);
    await _serverFor(account).connect(transport);
    await transport.handleRequest(request, body);
  }

  StreamableHTTPServerTransport _transport({
    required String? Function() sessionIdGenerator,
    void Function(String)? onSessionInitialized,
  }) {
    final transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: sessionIdGenerator,
        onsessioninitialized: onSessionInitialized,
        enableDnsRebindingProtection: true,
        allowedHosts: _config.allowedHosts,
      ),
    );
    return transport;
  }

  McpServer _serverFor(VerifiedAccount account) {
    final server = McpServer(
      const Implementation(name: 'gym-tracker', version: '0.0.1'),
    );
    registerListRoutines(
      server,
      UserScope(account, _firestore, _config.projectId),
    );
    return server;
  }

  bool _isInitialize(Object body) =>
      body is Map && body['method'] == 'initialize';

  Future<Object?> _readJson(HttpRequest request) async {
    try {
      return jsonDecode(await utf8.decodeStream(request));
    } on FormatException {
      return null;
    }
  }

  Future<void> _unauthorized(HttpRequest request, String reason) async {
    request.response
      ..statusCode = 401
      ..headers.set('WWW-Authenticate', 'Bearer error="invalid_token"')
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({'error': 'unauthorized', 'error_description': reason}),
      );
    await request.response.close();
  }

  Future<void> _plain(HttpRequest request, int status, String text) async {
    request.response
      ..statusCode = status
      ..write(text);
    await request.response.close();
  }
}

class _Session {
  _Session(this.uid, this.transport);

  final String uid;
  final StreamableHTTPServerTransport transport;
}
