import 'dart:convert';

import 'package:gym_tracker_mcp/config.dart';
import 'package:gym_tracker_mcp/emulator_client.dart';
import 'package:gym_tracker_mcp/gym_mcp_server.dart';
import 'package:gym_tracker_mcp/oauth/jwt.dart';
import 'package:gym_tracker_mcp/oauth/signed_request.dart';
import 'package:gym_tracker_mcp/oauth/signing_keys.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'support/emulators.dart';

const _issuer = 'http://mcp.test';
const _mcpUrl = '$_issuer/mcp';
const _appUrl = 'http://app.test';
const _claudeAi = 'gym-tracker-claude-ai';
const _claudeAiRedirect = 'https://claude.ai/api/mcp/auth_callback';
const _claudeCode = 'https://claude.ai/oauth/claude-code-client-metadata';
const _chatGpt = 'gym-tracker-chatgpt';
const _chatGptRedirect =
    'https://chatgpt.com/connector_platform_oauth_redirect';
final _verifier = 'v' * 64;
final _challenge = sha256Base64Url(_verifier);

void main() {
  late Emulators emulators;
  final running = <GymMcpServer>[];
  final mcpClients = <McpClient>[];
  final httpClient = http.Client();
  var clock = DateTime(2026, 11, 16);

  setUpAll(() => emulators = Emulators());
  tearDownAll(() {
    emulators.close();
    httpClient.close();
  });
  setUp(() => clock = DateTime(2026, 11, 16));
  tearDown(() async {
    for (final c in mcpClients) {
      await c.close();
    }
    mcpClients.clear();
    for (final s in running) {
      await s.stop();
    }
    running.clear();
  });

  Future<GymMcpServer> serve({int authRequestsPerMinute = 30}) async {
    final base = emulators.config;
    final server = GymMcpServer(
      ServerConfig(
        host: base.host,
        port: 0,
        projectId: base.projectId,
        backend: base.backend,
        issuer: _issuer,
        appUrl: _appUrl,
        signingKeys: base.signingKeys,
        signingKid: base.signingKid,
        allowedHosts: base.allowedHosts,
        authRequestsPerMinute: authRequestsPerMinute,
      ),
      client: EmulatorAdminClient(),
      now: () => clock,
    );
    await server.start();
    running.add(server);
    return server;
  }

  Uri at(GymMcpServer server, String path) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(headers);
    return http.Response.fromStream(await httpClient.send(request));
  }

  Future<http.Response> authorize(
    GymMcpServer server, {
    String clientId = _claudeAi,
    String redirectUri = _claudeAiRedirect,
    Map<String, String?> overrides = const {},
  }) {
    final params = {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'code_challenge': _challenge,
      'code_challenge_method': 'S256',
      'state': 'abc',
      'resource': _mcpUrl,
      ...overrides,
    }..removeWhere((_, v) => v == null);
    return get(
      at(server, '/authorize').replace(
        queryParameters: {for (final e in params.entries) e.key: e.value!},
      ),
    );
  }

  String sealedRequestFrom(http.Response redirect) {
    expect(redirect.statusCode, 302);
    final location = Uri.parse(redirect.headers['location']!);
    expect('${location.origin}${location.path}', '$_appUrl/connect');
    return location.queryParameters['request']!;
  }

  Future<http.Response> postConnect(
    GymMcpServer server, {
    required String request,
    String? idToken,
    String decision = 'allow',
  }) => httpClient.post(
    at(server, '/connect'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'request': request,
      'idToken': ?idToken,
      'decision': decision,
    }),
  );

  Future<Map<String, String>> redirectParams(http.Response connect) async {
    expect(connect.statusCode, 200, reason: connect.body);
    final redirect = Uri.parse(
      (jsonDecode(connect.body) as Map)['redirect'] as String,
    );
    return redirect.queryParameters;
  }

  Future<http.Response> postToken(
    GymMcpServer server,
    Map<String, String> form,
  ) => httpClient.post(
    at(server, '/token'),
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: form,
  );

  Future<String> obtainCode(
    GymMcpServer server,
    String idToken, {
    String clientId = _claudeAi,
    String redirectUri = _claudeAiRedirect,
  }) async {
    final sealed = sealedRequestFrom(
      await authorize(server, clientId: clientId, redirectUri: redirectUri),
    );
    final params = await redirectParams(
      await postConnect(server, request: sealed, idToken: idToken),
    );
    expect(params['state'], 'abc');
    expect(params['iss'], _issuer);
    return params['code']!;
  }

  Map<String, String> codeForm(
    String code, {
    String clientId = _claudeAi,
    String redirectUri = _claudeAiRedirect,
    String? verifier,
  }) => {
    'grant_type': 'authorization_code',
    'code': code,
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'code_verifier': verifier ?? _verifier,
  };

  Map<String, String> refreshForm(
    String refreshToken, {
    String clientId = _claudeAi,
  }) => {
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': clientId,
  };

  Future<Map<String, Object?>> tokensFor(
    GymMcpServer server,
    String idToken, {
    String clientId = _claudeAi,
    String redirectUri = _claudeAiRedirect,
  }) async {
    final code = await obtainCode(
      server,
      idToken,
      clientId: clientId,
      redirectUri: redirectUri,
    );
    final response = await postToken(
      server,
      codeForm(code, clientId: clientId, redirectUri: redirectUri),
    );
    expect(response.statusCode, 200, reason: response.body);
    return (jsonDecode(response.body) as Map).cast();
  }

  Future<int> mcpStatus(GymMcpServer server, String accessToken) async {
    final response = await httpClient.post(
      at(server, '/mcp'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(_initialize),
    );
    return response.statusCode;
  }

  Future<McpClient> mcpClientFor(
    GymMcpServer server,
    String accessToken,
  ) async {
    final client = McpClient(const Implementation(name: 'test', version: '1'));
    mcpClients.add(client);
    await client.connect(
      StreamableHttpClientTransport(
        at(server, '/mcp'),
        opts: StreamableHttpClientTransportOptions(
          requestInit: {
            'headers': {'Authorization': 'Bearer $accessToken'},
          },
        ),
      ),
    );
    return client;
  }

  Future<void> seedRoutine(String uid, String id, String name) =>
      emulators.putDocument(uid, 'routines', id, {
        'syncId': id,
        'name': name,
        'version': 1,
        'createdAtMs': 1,
        'deletedAtMs': null,
        'exercises': <Object?>[],
      });

  Future<List<String>> routineNames(McpClient client) async {
    final result = await client.callTool(
      const CallToolRequest(name: 'list_routines'),
    );
    return [
      for (final r in result.structuredContent!['routines'] as List)
        (r as Map)['name'] as String,
    ];
  }

  SigningKeys keys() =>
      SigningKeys(emulators.config.signingKeys, emulators.config.signingKid);

  group('discovery', () {
    test(
      'protected resource metadata names the resource and the issuer',
      () async {
        final server = await serve();
        for (final path in [
          '/.well-known/oauth-protected-resource/mcp',
          '/.well-known/oauth-protected-resource',
        ]) {
          final body = jsonDecode((await get(at(server, path))).body) as Map;
          expect(body['resource'], _mcpUrl);
          expect(body['authorization_servers'], [_issuer]);
          expect(body['scopes_supported'], ['gym']);
        }
      },
    );

    test(
      'authorization server metadata advertises what the server does',
      () async {
        final server = await serve();
        final response = await get(
          at(server, '/.well-known/oauth-authorization-server'),
        );
        final body = jsonDecode(response.body) as Map;
        expect(body['issuer'], _issuer);
        expect(body['authorization_endpoint'], '$_issuer/authorize');
        expect(body['token_endpoint'], '$_issuer/token');
        expect(body['code_challenge_methods_supported'], ['S256']);
        expect(body['token_endpoint_auth_methods_supported'], ['none']);
        expect(body['client_id_metadata_document_supported'], isTrue);
        expect(body['authorization_response_iss_parameter_supported'], isTrue);
      },
    );

    test(
      'a request without a token gets a challenge that points at the metadata',
      () async {
        final server = await serve();
        final response = await httpClient.post(
          at(server, '/mcp'),
          body: jsonEncode(_initialize),
        );
        expect(response.statusCode, 401);
        expect(
          response.headers['www-authenticate'],
          'Bearer resource_metadata="$_issuer/.well-known/oauth-protected-resource/mcp"',
        );
      },
    );

    test('a request with a bad token says so in the challenge', () async {
      final server = await serve();
      final response = await httpClient.post(
        at(server, '/mcp'),
        headers: {'Authorization': 'Bearer nope'},
        body: jsonEncode(_initialize),
      );
      expect(response.statusCode, 401);
      expect(
        response.headers['www-authenticate'],
        contains('error="invalid_token"'),
      );
      expect(
        response.headers['www-authenticate'],
        contains('resource_metadata='),
      );
    });
  });

  group('the whole flow', () {
    test('an assistant signs in, reads routines and refreshes', () async {
      final server = await serve();
      final user = await emulators.signUp();
      await seedRoutine(user.uid, 'r1', 'Push day');

      final tokens = await tokensFor(server, user.idToken);
      expect(tokens['token_type'], 'Bearer');
      expect(tokens['expires_in'], 3600);

      final client = await mcpClientFor(
        server,
        tokens['access_token'] as String,
      );
      expect(await routineNames(client), ['Push day']);

      clock = clock.add(const Duration(minutes: 30));
      final refreshed = await postToken(
        server,
        refreshForm(tokens['refresh_token'] as String),
      );
      expect(refreshed.statusCode, 200, reason: refreshed.body);
      final next = (jsonDecode(refreshed.body) as Map).cast<String, Object?>();
      expect(next['refresh_token'], isNot(tokens['refresh_token']));
      final again = await mcpClientFor(server, next['access_token'] as String);
      expect(await routineNames(again), ['Push day']);
    });

    test(
      'Claude Code connects from a port of its own on the loopback',
      () async {
        final server = await serve();
        final user = await emulators.signUp();
        for (final redirect in [
          'http://localhost:53682/callback',
          'http://127.0.0.1:8123/callback',
        ]) {
          final tokens = await tokensFor(
            server,
            user.idToken,
            clientId: _claudeCode,
            redirectUri: redirect,
          );
          expect(
            await mcpStatus(server, tokens['access_token'] as String),
            200,
          );
        }
      },
    );

    test('ChatGPT connects on its fixed callback', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final tokens = await tokensFor(
        server,
        user.idToken,
        clientId: _chatGpt,
        redirectUri: _chatGptRedirect,
      );
      expect(await mcpStatus(server, tokens['access_token'] as String), 200);
    });

    test(
      'the consent screen can read the client name from the request',
      () async {
        final server = await serve();
        final sealed = sealedRequestFrom(
          await authorize(
            server,
            clientId: _claudeCode,
            redirectUri: 'http://localhost:1/callback',
          ),
        );
        final payload =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(base64Url.normalize(sealed.split('.')[1])),
                  ),
                )
                as Map;
        expect(payload['client_name'], 'Claude Code');
      },
    );

    test('user A never reaches user B', () async {
      final server = await serve();
      final a = await emulators.signUp();
      final b = await emulators.signUp();
      await seedRoutine(a.uid, 'ra', 'A routine');
      await seedRoutine(b.uid, 'rb', 'B routine');

      final asA = await mcpClientFor(
        server,
        (await tokensFor(server, a.idToken))['access_token'] as String,
      );
      final asB = await mcpClientFor(
        server,
        (await tokensFor(server, b.idToken))['access_token'] as String,
      );

      expect(await routineNames(asA), ['A routine']);
      expect(await routineNames(asB), ['B routine']);
    });
  });

  group('/authorize', () {
    test('an unknown client gets an error page, never a redirect', () async {
      final server = await serve();
      final response = await authorize(server, clientId: 'someone-else');
      expect(response.statusCode, 400);
      expect(response.headers, isNot(contains('location')));
    });

    test('a redirect that is not the client\'s gets an error page', () async {
      final server = await serve();
      for (final redirect in [
        'https://evil.test/callback',
        'https://claude.ai/api/mcp/auth_callback/../evil',
        'https://claude.ai.evil.test/api/mcp/auth_callback',
        'http://localhost/callback',
      ]) {
        final response = await authorize(server, redirectUri: redirect);
        expect(response.statusCode, 400, reason: redirect);
        expect(response.headers, isNot(contains('location')), reason: redirect);
      }
      for (final redirect in [
        'http://localhost.evil.test:1/callback',
        'http://localhost:1/elsewhere',
        'https://localhost:1/callback',
        'http://user@localhost:1/callback',
        'http://localhost:1/callback?x=1',
      ]) {
        final response = await authorize(
          server,
          clientId: _claudeCode,
          redirectUri: redirect,
        );
        expect(response.statusCode, 400, reason: redirect);
      }
      final other = await authorize(
        server,
        clientId: _chatGpt,
        redirectUri: _claudeAiRedirect,
      );
      expect(other.statusCode, 400);
    });

    test(
      'other mistakes redirect with the error, the state and the issuer',
      () async {
        final server = await serve();
        final cases = {
          'unsupported_response_type': {'response_type': 'token'},
          'invalid_request': {'code_challenge': null},
          'invalid_target': {'resource': 'http://mcp.test/other'},
        };
        for (final entry in cases.entries) {
          final response = await authorize(server, overrides: entry.value);
          expect(response.statusCode, 302, reason: entry.key);
          final location = Uri.parse(response.headers['location']!);
          expect('${location.origin}${location.path}', _claudeAiRedirect);
          expect(location.queryParameters['error'], entry.key);
          expect(location.queryParameters['state'], 'abc');
          expect(location.queryParameters['iss'], _issuer);
        }
        final plain = await authorize(
          server,
          overrides: {'code_challenge_method': 'plain'},
        );
        expect(
          Uri.parse(plain.headers['location']!).queryParameters['error'],
          'invalid_request',
        );
      },
    );

    test('a request without a resource is accepted', () async {
      final server = await serve();
      final response = await authorize(server, overrides: {'resource': null});
      expect(response.statusCode, 302);
      expect(
        response.headers['location'],
        startsWith('$_appUrl/connect?request='),
      );
    });
  });

  group('/connect', () {
    test('allows only the web app\'s origin to call it', () async {
      final server = await serve();
      final preflight = await httpClient.send(
        http.Request('OPTIONS', at(server, '/connect')),
      );
      expect(preflight.statusCode, 204);
      expect(preflight.headers['access-control-allow-origin'], _appUrl);
      expect(
        preflight.headers['access-control-allow-methods'],
        contains('POST'),
      );
    });

    test('a denial redirects with access_denied and writes nothing', () async {
      final server = await serve();
      final sealed = sealedRequestFrom(await authorize(server));
      final params = await redirectParams(
        await postConnect(server, request: sealed, decision: 'deny'),
      );
      expect(params['error'], 'access_denied');
      expect(params['state'], 'abc');
      expect(params['iss'], _issuer);
      expect(params, isNot(contains('code')));
    });

    test('a tampered request is refused', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final sealed = sealedRequestFrom(await authorize(server));
      final parts = sealed.split('.');
      final forged =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map;
      forged['redirect_uri'] = 'https://evil.test/callback';
      final payload = base64Url
          .encode(utf8.encode(jsonEncode(forged)))
          .replaceAll('=', '');
      final response = await postConnect(
        server,
        request: '${parts[0]}.$payload.${parts[2]}',
        idToken: user.idToken,
      );
      expect(response.statusCode, 400);
    });

    test(
      'a request signed with another key or another kind is refused',
      () async {
        final server = await serve();
        final user = await emulators.signUp();
        final stranger = SigningKeys(
          {'dev': 'x' * 40},
          'dev',
          now: () => clock,
        );
        final foreign = PendingRequests(stranger, now: () => clock).seal(
          PendingRequest(
            clientId: _claudeAi,
            clientName: 'Claude',
            redirectUri: _claudeAiRedirect,
            codeChallenge: _challenge,
            state: null,
            resource: _mcpUrl,
          ),
        );
        final accessToken = AccessTokens(
          keys(),
          issuer: _issuer,
          audience: _mcpUrl,
          now: () => clock,
        ).issue(AccessClaims(uid: user.uid, grantId: 'g', clientId: _claudeAi));
        for (final request in [foreign, accessToken, 'nonsense']) {
          final response = await postConnect(
            server,
            request: request,
            idToken: user.idToken,
          );
          expect(response.statusCode, 400);
        }
      },
    );

    test('a request expires after ten minutes', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final sealed = sealedRequestFrom(await authorize(server));
      clock = clock.add(const Duration(minutes: 11));
      final response = await postConnect(
        server,
        request: sealed,
        idToken: user.idToken,
      );
      expect(response.statusCode, 400);
    });

    test('an ID token that is not a real sign-in is refused', () async {
      final server = await serve();
      final sealed = sealedRequestFrom(await authorize(server));
      final response = await postConnect(
        server,
        request: sealed,
        idToken: 'not-a-token',
      );
      expect(response.statusCode, 401);
    });

    test('an allow without an ID token is refused', () async {
      final server = await serve();
      final sealed = sealedRequestFrom(await authorize(server));
      expect((await postConnect(server, request: sealed)).statusCode, 400);
    });

    test('a disabled account cannot connect', () async {
      final server = await serve();
      final user = await emulators.signUp();
      await emulators.disableAccount(user.uid);
      final sealed = sealedRequestFrom(await authorize(server));
      final response = await postConnect(
        server,
        request: sealed,
        idToken: user.idToken,
      );
      expect(response.statusCode, 401);
    });
  });

  group('/token, authorization_code', () {
    test('a wrong verifier is refused and burns the code', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final code = await obtainCode(server, user.idToken);
      final wrong = await postToken(server, codeForm(code, verifier: 'w' * 64));
      expect(wrong.statusCode, 400);
      expect((jsonDecode(wrong.body) as Map)['error'], 'invalid_grant');
      expect((await postToken(server, codeForm(code))).statusCode, 400);
    });

    test('a verifier that is too short is refused', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final code = await obtainCode(server, user.idToken);
      final response = await postToken(
        server,
        codeForm(code, verifier: 'short'),
      );
      expect(response.statusCode, 400);
    });

    test('a code is refused for another client or redirect', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final otherClient = await postToken(
        server,
        codeForm(
          await obtainCode(server, user.idToken),
          clientId: _chatGpt,
          redirectUri: _chatGptRedirect,
        ),
      );
      expect((jsonDecode(otherClient.body) as Map)['error'], 'invalid_grant');

      final otherRedirect = await postToken(
        server,
        codeForm(
          await obtainCode(server, user.idToken),
          redirectUri: 'https://claude.ai/api/mcp/other',
        ),
      );
      expect((jsonDecode(otherRedirect.body) as Map)['error'], 'invalid_grant');
    });

    test('an unknown client or a wrong resource is refused', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final code = await obtainCode(server, user.idToken);
      final unknown = await postToken(
        server,
        codeForm(code, clientId: 'someone-else'),
      );
      expect((jsonDecode(unknown.body) as Map)['error'], 'invalid_client');
      final resource = await postToken(server, {
        ...codeForm(code),
        'resource': 'http://mcp.test/other',
      });
      expect((jsonDecode(resource.body) as Map)['error'], 'invalid_target');
    });

    test('a code expires after five minutes', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final code = await obtainCode(server, user.idToken);
      clock = clock.add(const Duration(minutes: 6));
      final response = await postToken(server, codeForm(code));
      expect((jsonDecode(response.body) as Map)['error'], 'invalid_grant');
    });

    test(
      'a code used twice is refused and revokes what the first use got',
      () async {
        final server = await serve();
        final user = await emulators.signUp();
        final code = await obtainCode(server, user.idToken);
        final first =
            (jsonDecode((await postToken(server, codeForm(code))).body) as Map)
                .cast<String, Object?>();
        expect(await mcpStatus(server, first['access_token'] as String), 200);

        final second = await postToken(server, codeForm(code));
        expect((jsonDecode(second.body) as Map)['error'], 'invalid_grant');

        expect(await mcpStatus(server, first['access_token'] as String), 401);
        final refresh = await postToken(
          server,
          refreshForm(first['refresh_token'] as String),
        );
        expect((jsonDecode(refresh.body) as Map)['error'], 'invalid_grant');
      },
    );

    test('an unsupported grant type is refused', () async {
      final server = await serve();
      final response = await postToken(server, {
        'grant_type': 'password',
        'client_id': _claudeAi,
      });
      expect(
        (jsonDecode(response.body) as Map)['error'],
        'unsupported_grant_type',
      );
    });

    test('answers are not cached', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final response = await postToken(
        server,
        codeForm(await obtainCode(server, user.idToken)),
      );
      expect(response.headers['cache-control'], 'no-store');
    });

    test('/connect and /token share a budget', () async {
      final server = await serve(authRequestsPerMinute: 2);
      final user = await emulators.signUp();
      final code = await obtainCode(server, user.idToken);
      expect((await postToken(server, codeForm(code))).statusCode, 200);
      final throttled = await postToken(server, codeForm(code));
      expect(throttled.statusCode, 429);
      clock = clock.add(const Duration(minutes: 1));
      expect((await postToken(server, codeForm(code))).statusCode, 400);
    });
  });

  group('/token, refresh_token', () {
    test(
      'a refresh token is single use and each one is new for 30 days',
      () async {
        final server = await serve();
        final user = await emulators.signUp();
        var tokens = await tokensFor(server, user.idToken);
        for (var i = 0; i < 3; i++) {
          clock = clock.add(const Duration(days: 20));
          final response = await postToken(
            server,
            refreshForm(tokens['refresh_token'] as String),
          );
          expect(
            response.statusCode,
            200,
            reason: 'round $i: ${response.body}',
          );
          tokens = (jsonDecode(response.body) as Map).cast();
        }
        expect(await mcpStatus(server, tokens['access_token'] as String), 200);
      },
    );

    test('a refresh token expires after 30 days unused', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final tokens = await tokensFor(server, user.idToken);
      clock = clock.add(const Duration(days: 31));
      final response = await postToken(
        server,
        refreshForm(tokens['refresh_token'] as String),
      );
      expect((jsonDecode(response.body) as Map)['error'], 'invalid_grant');
    });

    test(
      'a reused refresh token revokes the grant, the new token too',
      () async {
        final server = await serve();
        final user = await emulators.signUp();
        final first = await tokensFor(server, user.idToken);
        final rotated =
            (jsonDecode(
                      (await postToken(
                        server,
                        refreshForm(first['refresh_token'] as String),
                      )).body,
                    )
                    as Map)
                .cast<String, Object?>();
        expect(await mcpStatus(server, rotated['access_token'] as String), 200);

        final replay = await postToken(
          server,
          refreshForm(first['refresh_token'] as String),
        );
        expect((jsonDecode(replay.body) as Map)['error'], 'invalid_grant');

        final successor = await postToken(
          server,
          refreshForm(rotated['refresh_token'] as String),
        );
        expect((jsonDecode(successor.body) as Map)['error'], 'invalid_grant');
        expect(await mcpStatus(server, rotated['access_token'] as String), 401);
        expect(await mcpStatus(server, first['access_token'] as String), 401);
      },
    );

    test(
      'another client\'s refresh token is refused and left usable',
      () async {
        final server = await serve();
        final user = await emulators.signUp();
        final tokens = await tokensFor(server, user.idToken);
        final stolen = await postToken(
          server,
          refreshForm(tokens['refresh_token'] as String, clientId: _chatGpt),
        );
        expect((jsonDecode(stolen.body) as Map)['error'], 'invalid_grant');
        final owner = await postToken(
          server,
          refreshForm(tokens['refresh_token'] as String),
        );
        expect(owner.statusCode, 200);
      },
    );

    test('an unknown refresh token is refused', () async {
      final server = await serve();
      final response = await postToken(server, refreshForm('nonsense'));
      expect((jsonDecode(response.body) as Map)['error'], 'invalid_grant');
    });

    test('a deleted account cannot refresh', () async {
      final server = await serve();
      final user = await emulators.signUp();
      final tokens = await tokensFor(server, user.idToken);
      await emulators.deleteAccount(user.uid);
      clock = clock.add(const Duration(minutes: 2));
      final response = await postToken(
        server,
        refreshForm(tokens['refresh_token'] as String),
      );
      expect((jsonDecode(response.body) as Map)['error'], 'invalid_grant');
    });
  });

  group('access tokens', () {
    Future<String> issued(
      GymMcpServer server, {
      String issuer = _issuer,
      String audience = _mcpUrl,
      String? uid,
      String grantId = 'grant-1',
      SigningKeys? signedWith,
    }) async {
      final user = uid ?? (await emulators.signUp()).uid;
      final tokens = AccessTokens(
        signedWith ?? keys(),
        issuer: issuer,
        audience: audience,
        now: () => clock,
      );
      return tokens.issue(
        AccessClaims(uid: user, grantId: grantId, clientId: _claudeAi),
      );
    }

    test('a token for this server is accepted', () async {
      final server = await serve();
      expect(await mcpStatus(server, await issued(server)), 200);
    });

    test('a token for another audience is refused', () async {
      final server = await serve();
      expect(
        await mcpStatus(
          server,
          await issued(server, audience: 'http://other.test/mcp'),
        ),
        401,
      );
    });

    test('a token from another issuer is refused', () async {
      final server = await serve();
      expect(
        await mcpStatus(
          server,
          await issued(server, issuer: 'http://other.test'),
        ),
        401,
      );
    });

    test('a token signed with another key is refused', () async {
      final server = await serve();
      final other = SigningKeys({'dev': 'y' * 40}, 'dev', now: () => clock);
      expect(
        await mcpStatus(server, await issued(server, signedWith: other)),
        401,
      );
    });

    test('a tampered token is refused', () async {
      final server = await serve();
      final parts = (await issued(server)).split('.');
      final forged =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map;
      forged['sub'] = (await emulators.signUp()).uid;
      final payload = base64Url
          .encode(utf8.encode(jsonEncode(forged)))
          .replaceAll('=', '');
      expect(await mcpStatus(server, '${parts[0]}.$payload.${parts[2]}'), 401);
    });

    test('an unsigned token is refused', () async {
      final server = await serve();
      final parts = (await issued(server)).split('.');
      final header = base64Url
          .encode(utf8.encode(jsonEncode({'alg': 'none', 'typ': 'at+jwt'})))
          .replaceAll('=', '');
      expect(await mcpStatus(server, '$header.${parts[1]}.'), 401);
    });

    test('an expired token is refused', () async {
      final server = await serve();
      final token = await issued(server);
      clock = clock.add(const Duration(minutes: 61));
      expect(await mcpStatus(server, token), 401);
    });

    test('a request blob is not an access token', () async {
      final server = await serve();
      final sealed = sealedRequestFrom(await authorize(server));
      expect(await mcpStatus(server, sealed), 401);
    });

    test(
      'a grant revoked by another instance stops working within a minute',
      () async {
        final server = await serve();
        final token = await issued(server, grantId: 'revoked-elsewhere');
        expect(await mcpStatus(server, token), 200);

        await emulators.putTopLevel('mcpRevokedGrants', 'revoked-elsewhere', {
          'expiresAt': clock.add(const Duration(days: 30)),
        });
        expect(await mcpStatus(server, token), 200);

        clock = clock.add(const Duration(seconds: 61));
        expect(await mcpStatus(server, token), 401);
      },
    );

    test('the dev token still works on the emulators', () async {
      final user = await emulators.signUp();
      final base = emulators.config;
      final server = GymMcpServer(
        ServerConfig(
          host: base.host,
          port: 0,
          projectId: base.projectId,
          backend: base.backend,
          issuer: _issuer,
          appUrl: _appUrl,
          signingKeys: base.signingKeys,
          signingKid: base.signingKid,
          allowedHosts: base.allowedHosts,
          devToken: StaticToken('dev-token', user.uid),
        ),
        client: EmulatorAdminClient(),
        now: () => clock,
      );
      await server.start();
      running.add(server);
      expect(await mcpStatus(server, 'dev-token'), 200);
      expect(await mcpStatus(server, 'other-token'), 401);
    });

    test('the dev token is refused when the config carries none', () async {
      final server = await serve();
      expect(await mcpStatus(server, 'dev-token'), 401);
    });
  });
}

const _initialize = {
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'initialize',
  'params': {
    'protocolVersion': '2025-11-25',
    'capabilities': <String, Object?>{},
    'clientInfo': {'name': 'test', 'version': '1'},
  },
};
