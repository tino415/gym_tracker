import 'dart:convert';

import 'package:gym_tracker_mcp/config.dart';
import 'package:gym_tracker_mcp/gym_mcp_server.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'support/emulators.dart';

void main() {
  late Emulators emulators;
  final running = <GymMcpServer>[];
  final clients = <McpClient>[];
  var clock = DateTime(2026, 11, 4);

  setUpAll(() => emulators = Emulators());
  tearDownAll(() => emulators.close());
  setUp(() => clock = DateTime(2026, 11, 4));
  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    clients.clear();
    for (final s in running) {
      await s.stop();
    }
    running.clear();
  });

  Future<GymMcpServer> serverFor(
    String? uid, {
    String token = 'dev-token',
  }) async {
    final server = GymMcpServer(
      _configWith(emulators.config, uid: uid, token: token),
      now: () => clock,
    );
    await server.start();
    running.add(server);
    return server;
  }

  Future<McpClient> connect(
    GymMcpServer server, {
    String token = 'dev-token',
    McpProtocol protocol = McpProtocol.stable,
  }) async {
    final client = McpClient(
      const Implementation(name: 'test', version: '1'),
      options: McpClientOptions(protocol: protocol),
    );
    clients.add(client);
    await client.connect(
      StreamableHttpClientTransport(
        Uri.parse('http://127.0.0.1:${server.port}/mcp'),
        opts: StreamableHttpClientTransportOptions(
          requestInit: {
            'headers': {'Authorization': 'Bearer $token'},
          },
        ),
      ),
    );
    return client;
  }

  Future<void> seedRoutine(
    String uid,
    String id,
    String name, {
    int? deletedAtMs,
  }) => emulators.putDocument(uid, 'routines', id, {
    'syncId': id,
    'name': name,
    'version': 1,
    'createdAtMs': 1,
    'deletedAtMs': deletedAtMs,
    'exercises': deletedAtMs != null
        ? <Object?>[]
        : [
            {
              'syncId': '$id-e1',
              'exerciseSyncId': 'ex-squat',
              'exerciseName': 'Squat',
              'exerciseKind': 'reps',
              'orderIndex': 0,
              'restSeconds': 90,
              'alternatives': <Object?>[],
              'muscleSyncIds': <Object?>[],
              'plannedSets': [
                {
                  'syncId': '$id-s1',
                  'setIndex': 0,
                  'targetReps': 5,
                  'targetWeightKg': 100.0,
                  'targetSeconds': null,
                },
              ],
            },
          ],
  });

  Future<Map<String, Object?>> listRoutines(McpClient client) async {
    final result = await client.callTool(
      const CallToolRequest(name: 'list_routines'),
    );
    return result.structuredContent!.cast();
  }

  Future<int> statusOf(GymMcpServer server, {String? authorization}) async {
    final response = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Authorization': ?authorization,
      },
      body: jsonEncode(_initialize),
    );
    return response.statusCode;
  }

  group('authentication', () {
    test('a missing token is refused', () async {
      final uid = await emulators.createAccount();
      expect(await statusOf(await serverFor(uid)), 401);
    });

    test('a wrong token is refused', () async {
      final uid = await emulators.createAccount();
      final server = await serverFor(uid);
      expect(await statusOf(server, authorization: 'Bearer nope'), 401);
      expect(await statusOf(server, authorization: 'Basic dev-token'), 401);
    });

    test('a uid that does not exist is refused', () async {
      final server = await serverFor('no-such-uid');
      expect(await statusOf(server, authorization: 'Bearer dev-token'), 401);
    });

    test('a deleted account stops working once the cache expires', () async {
      final uid = await emulators.createAccount();
      final server = await serverFor(uid);
      expect(await statusOf(server, authorization: 'Bearer dev-token'), 200);

      await emulators.deleteAccount(uid);
      expect(await statusOf(server, authorization: 'Bearer dev-token'), 200);

      clock = clock.add(const Duration(minutes: 2));
      expect(await statusOf(server, authorization: 'Bearer dev-token'), 401);
    });

    test('a disabled account stops working once the cache expires', () async {
      final uid = await emulators.createAccount();
      final server = await serverFor(uid);
      expect(await statusOf(server, authorization: 'Bearer dev-token'), 200);

      await emulators.disableAccount(uid);
      clock = clock.add(const Duration(minutes: 2));
      expect(await statusOf(server, authorization: 'Bearer dev-token'), 401);
    });

    test('the server will not start without the emulators', () {
      expect(() => ServerConfig.fromEnvironment({}), throwsStateError);
    });
  });

  group('list_routines', () {
    for (final protocol in [McpProtocol.stable, McpProtocol.legacy]) {
      test('lists the routines of the token\'s account ($protocol)', () async {
        final uid = await emulators.createAccount();
        await seedRoutine(uid, 'r-push', 'Push');
        await seedRoutine(uid, 'r-legs', 'Legs');
        await seedRoutine(uid, 'r-gone', 'Deleted', deletedAtMs: 5);

        final client = await connect(await serverFor(uid), protocol: protocol);
        final routines = (await listRoutines(client))['routines'] as List;

        expect(
          [for (final r in routines) (r as Map)['name']],
          ['Legs', 'Push'],
        );
        final legs = routines.first as Map;
        expect(legs['exercises'], [
          {
            'name': 'Squat',
            'kind': 'reps',
            'restSeconds': 90,
            'sets': [
              {'reps': 5, 'weightKg': 100.0},
            ],
          },
        ]);
      });
    }

    test('answers with a text summary too', () async {
      final uid = await emulators.createAccount();
      await seedRoutine(uid, 'r-push', 'Push');
      final client = await connect(await serverFor(uid));

      final result = await client.callTool(
        const CallToolRequest(name: 'list_routines'),
      );

      expect((result.content.single as TextContent).text, 'Push: Squat');
    });

    test('user A cannot reach the routines of user B', () async {
      final a = await emulators.createAccount();
      final b = await emulators.createAccount();
      await seedRoutine(a, 'r-a', 'A routine');
      await seedRoutine(b, 'r-b', 'B routine');

      final asA = await connect(await serverFor(a));
      final asB = await connect(await serverFor(b));

      expect(
        [
          for (final r in (await listRoutines(asA))['routines'] as List)
            (r as Map)['name'],
        ],
        ['A routine'],
      );
      expect(
        [
          for (final r in (await listRoutines(asB))['routines'] as List)
            (r as Map)['name'],
        ],
        ['B routine'],
      );
    });

    test('no tool takes a uid', () async {
      final uid = await emulators.createAccount();
      final client = await connect(await serverFor(uid));

      final tools = (await client.listTools()).tools;

      expect(tools, isNotEmpty);
      for (final tool in tools) {
        final names =
            ((tool.inputSchema.toJson()['properties'] as Map?) ?? {}).keys;
        expect(names.where((n) => n.toLowerCase().contains('uid')), isEmpty);
        expect(names.where((n) => n.toLowerCase().contains('user')), isEmpty);
      }
    });

    test('a session cannot be resumed by another account', () async {
      final a = await emulators.createAccount();
      final b = await emulators.createAccount();
      final asA = await connect(
        await serverFor(a),
        protocol: McpProtocol.legacy,
      );
      final serverB = await serverFor(b);
      final sessionOfA =
          (asA.transport as StreamableHttpClientTransport).sessionId;

      final response = await http.post(
        Uri.parse('http://127.0.0.1:${serverB.port}/mcp'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          'Authorization': 'Bearer dev-token',
          'mcp-session-id': sessionOfA!,
        },
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
      );

      expect(response.statusCode, 404);
    });
  });
}

ServerConfig _configWith(
  ServerConfig base, {
  String? uid,
  required String token,
}) => ServerConfig(
  host: base.host,
  port: 0,
  projectId: base.projectId,
  firestoreRoot: base.firestoreRoot,
  authRoot: base.authRoot,
  devToken: token,
  devUid: uid,
  allowedHosts: base.allowedHosts,
);

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
