import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';

import 'account_directory.dart';
import 'bearer_auth.dart';
import 'config.dart';
import 'oauth/auth_store.dart';
import 'oauth/authorize.dart';
import 'oauth/clients.dart';
import 'oauth/connect.dart';
import 'oauth/http_support.dart';
import 'oauth/jwt.dart';
import 'oauth/metadata.dart';
import 'oauth/revocations.dart';
import 'oauth/signed_request.dart';
import 'oauth/signing_keys.dart';
import 'oauth/token.dart';
import 'request_budget.dart';
import 'tools/find_exercises.dart';
import 'tools/get_routine.dart';
import 'tools/get_workout.dart';
import 'tools/list_routines.dart';
import 'tools/list_workouts.dart';
import 'tools/read_tool.dart';
import 'user_scope.dart';

/// Streamable HTTP front for the MCP server. `StreamableMcpServer` would do the
/// routing, but a tool can't learn which user a request belongs to there, so
/// this owns the session map: every session and every stateless request gets an
/// `McpServer` built for the verified account that made it.
class GymMcpServer {
  GymMcpServer(
    this._config, {
    required http.Client client,
    DateTime Function() now = DateTime.now,
  }) : _client = client {
    _accounts = AccountDirectory(
      client: _client,
      identityToolkitRoot: _config.backend.identityToolkitRoot,
      projectId: _config.projectId,
      webApiKey: _config.webApiKey,
      now: now,
    );
    _firestore = fs.FirestoreApi(
      _client,
      rootUrl: _config.backend.firestoreRoot.toString(),
    );
    final keys = SigningKeys(_config.signingKeys, _config.signingKid, now: now);
    final store = AuthStore(_firestore, _config.projectId);
    final revocations = Revocations(store, now: now);
    final accessTokens = AccessTokens(
      keys,
      issuer: _config.issuer,
      audience: _config.mcpUrl,
      now: now,
    );
    final clients = ClientRegistry.allowlist();
    final pending = PendingRequests(keys, now: now);
    final authBudget = RequestBudget.perMinuteAndDay(
      perMinute: _config.authRequestsPerMinute,
      perDay: _config.authRequestsPerDay,
      now: now,
    );
    _authenticator = BearerAuthenticator(
      tokens: accessTokens,
      revocations: revocations,
      accounts: _accounts,
      perAccount: KeyedBudgets(
        () => RequestBudget.perMinuteAndDay(
          perMinute: _config.requestsPerMinute,
          perDay: _config.requestsPerDay,
          now: now,
        ),
      ),
      overall: RequestBudget.perMinuteAndDay(
        perMinute: _config.allRequestsPerMinute,
        perDay: _config.allRequestsPerDay,
        now: now,
      ),
      devToken: _config.devToken,
    );
    _authorize = AuthorizeEndpoint(
      clients: clients,
      pending: pending,
      appUrl: _config.appUrl,
      issuer: _config.issuer,
      resource: _config.mcpUrl,
    );
    _connect = ConnectEndpoint(
      clients: clients,
      pending: pending,
      accounts: _accounts,
      store: store,
      budget: authBudget,
      appUrl: _config.appUrl,
      issuer: _config.issuer,
      now: now,
    );
    _token = TokenEndpoint(
      clients: clients,
      store: store,
      revocations: revocations,
      accessTokens: accessTokens,
      accounts: _accounts,
      budget: authBudget,
      resource: _config.mcpUrl,
      now: now,
    );
  }

  final ServerConfig _config;
  final http.Client _client;
  late final AccountDirectory _accounts;
  late final BearerAuthenticator _authenticator;
  late final fs.FirestoreApi _firestore;
  late final AuthorizeEndpoint _authorize;
  late final ConnectEndpoint _connect;
  late final TokenEndpoint _token;
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
      switch (request.uri.path) {
        case '/mcp':
          return await _handleMcp(request);
        case '/authorize' when request.method == 'GET':
          return await _authorize.handle(request);
        case '/connect':
          return await _connect.handle(request);
        case '/token':
          return await _token.handle(request);
        case '/.well-known/oauth-protected-resource/mcp' ||
            '/.well-known/oauth-protected-resource':
          return await _metadata(
            request,
            protectedResourceMetadata(
              issuer: _config.issuer,
              resource: _config.mcpUrl,
            ),
          );
        case '/.well-known/oauth-authorization-server':
          return await _metadata(
            request,
            authorizationServerMetadata(_config.issuer),
          );
        default:
          return await _plain(request, 404, 'Not Found');
      }
    } catch (e, st) {
      stderr.writeln('request failed: $e\n$st');
      try {
        await _plain(request, 500, 'Internal Server Error');
      } catch (_) {}
    }
  }

  Future<void> _metadata(HttpRequest request, Map<String, Object?> body) async {
    if (request.method != 'GET')
      return _plain(request, 405, 'Method Not Allowed');
    await sendJson(request.response, 200, body);
  }

  Future<void> _handleMcp(HttpRequest request) async {
    final outcome = await _authenticator.authenticate(request.headers);
    switch (outcome) {
      case Rejected(:final reason, :final tokenPresented):
        return _unauthorized(request, reason, tokenPresented);
      case Throttled(:final retryAfter):
        return _tooManyRequests(request, retryAfter);
      case Authenticated(:final account):
        return await _route(request, account);
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
    final context = ToolContext(
      UserScope(account, _firestore, _config.projectId),
      () async => await _accounts.verify(account.uid) != null,
    );
    registerListRoutines(server, context);
    registerGetRoutine(server, context);
    registerListWorkouts(server, context);
    registerGetWorkout(server, context);
    registerFindExercises(server, context);
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

  Future<void> _unauthorized(
    HttpRequest request,
    String reason,
    bool tokenPresented,
  ) async {
    final challenge = [
      'Bearer resource_metadata="${protectedResourceMetadataUrl(_config.issuer)}"',
      if (tokenPresented) 'error="invalid_token"',
    ].join(', ');
    request.response
      ..statusCode = 401
      ..headers.set('WWW-Authenticate', challenge)
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({'error': 'unauthorized', 'error_description': reason}),
      );
    await request.response.close();
  }

  Future<void> _tooManyRequests(HttpRequest request, Duration wait) async {
    request.response
      ..statusCode = 429
      ..headers.set('Retry-After', (wait.inMilliseconds / 1000).ceil())
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': 'rate_limited'}));
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
