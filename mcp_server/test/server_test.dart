import 'dart:async';
import 'dart:convert';

import 'package:googleapis/firestore/v1.dart' show FirestoreApi;
import 'package:gym_tracker_mcp/account_directory.dart';
import 'package:gym_tracker_mcp/config.dart';
import 'package:gym_tracker_mcp/emulator_client.dart';
import 'package:gym_tracker_mcp/gym_mcp_server.dart';
import 'package:gym_tracker_mcp/tools/list_routines.dart';
import 'package:gym_tracker_mcp/tools/read_tool.dart';
import 'package:gym_tracker_mcp/user_scope.dart';
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

  Future<void> seedWorkout(
    String uid,
    String id, {
    required int startedAtMs,
    String name = 'Push',
    int? deletedAtMs,
  }) => emulators.putDocument(uid, 'workouts', id, {
    'syncId': id,
    'routineSyncId': 'r-push',
    'routineName': name,
    'startedAtMs': startedAtMs,
    'endedAtMs': startedAtMs + 3600000,
    'version': 2,
    'deletedAtMs': deletedAtMs,
    'avgHeartRate': 118,
    'maxHeartRate': 171,
    'heartRateSamples': [
      for (var i = 0; i < 20; i++)
        {'tMs': startedAtMs + i * 1000, 'bpm': 100 + i, 'accuracy': 3},
    ],
    'exercises': [
      {
        'syncId': '$id-we1',
        'exerciseSyncId': 'ex-bench',
        'exerciseName': 'Bench press',
        'kind': 'reps',
        'orderIndex': 0,
        'restSeconds': 120,
        'circuitGroup': null,
        'sets': [
          {
            'syncId': '$id-ws1',
            'setIndex': 0,
            'targetReps': 8,
            'targetWeightKg': 60.0,
            'targetSeconds': null,
          },
          {
            'syncId': '$id-ws2',
            'setIndex': 1,
            'targetReps': 8,
            'targetWeightKg': 60.0,
            'targetSeconds': null,
          },
        ],
      },
    ],
    'completions': [
      {
        'syncId': '$id-c1',
        'workoutSetSyncId': '$id-ws1',
        'actualReps': 8,
        'actualWeightKg': 62.5,
        'actualSeconds': null,
        'completedAtMs': startedAtMs + 60000,
        'avgHeartRate': 140,
        'maxHeartRate': 160,
      },
    ],
  });

  Future<CallToolResult> call(
    McpClient client,
    String tool, [
    Map<String, dynamic> args = const {},
  ]) => client.callTool(CallToolRequest(name: tool, arguments: args));

  const day = 86400000;
  final jan1 = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;

  group('read tools', () {
    test(
      'tools come in a fixed, alphabetical order, each with an output schema',
      () async {
        final uid = await emulators.createAccount();
        final client = await connect(await serverFor(uid));

        final tools = (await client.listTools()).tools;

        expect(
          [for (final t in tools) t.name],
          [
            'find_exercises',
            'get_routine',
            'get_workout',
            'list_routines',
            'list_workouts',
          ],
        );
        for (final t in tools) {
          expect(t.outputSchema, isNotNull, reason: t.name);
          expect(t.toJson()['_meta']['securitySchemes'], [
            {'type': 'oauth2'},
          ], reason: t.name);
        }
      },
    );

    test(
      'list_workouts is newest first, skips tombstones, honours the window and limit',
      () async {
        final uid = await emulators.createAccount();
        await seedWorkout(uid, 'w1', startedAtMs: jan1);
        await seedWorkout(uid, 'w2', startedAtMs: jan1 + day);
        await seedWorkout(
          uid,
          'w3',
          startedAtMs: jan1 + 2 * day,
          deletedAtMs: 9,
        );
        await seedWorkout(uid, 'w4', startedAtMs: jan1 + 3 * day);
        final client = await connect(await serverFor(uid));

        List ids(CallToolResult r) => [
          for (final w in r.structuredContent!['workouts'] as List)
            (w as Map)['id'],
        ];

        expect(ids(await call(client, 'list_workouts')), ['w4', 'w2', 'w1']);
        expect(ids(await call(client, 'list_workouts', {'limit': 2})), [
          'w4',
          'w2',
        ]);
        expect(
          ids(
            await call(client, 'list_workouts', {
              'since': '2026-01-02',
              'until': '2026-01-03T12:00:00Z',
            }),
          ),
          ['w2'],
        );
        final first =
            (await call(client, 'list_workouts', {
                  'limit': 1,
                })).structuredContent!['workouts'][0]
                as Map;
        expect(first['routineName'], 'Push');
        expect(first['exercises'], ['Bench press']);
        expect(first['completedSets'], 1);
      },
    );

    test('list_workouts refuses a limit above 50 and a bad date', () async {
      final uid = await emulators.createAccount();
      final client = await connect(await serverFor(uid));

      expect(
        (await call(client, 'list_workouts', {'limit': 51})).isError,
        isTrue,
      );
      expect(
        (await call(client, 'list_workouts', {'limit': 0})).isError,
        isTrue,
      );
      final bad = await call(client, 'list_workouts', {'since': 'last week'});
      expect(bad.isError, isTrue);
    });

    test('get_workout shows targets and what was done', () async {
      final uid = await emulators.createAccount();
      await seedWorkout(uid, 'w1', startedAtMs: jan1);
      final client = await connect(await serverFor(uid));

      final result = await call(client, 'get_workout', {'id': 'w1'});

      final workout = result.structuredContent!['workout'] as Map;
      expect(workout['startedAt'], '2026-01-01T00:00:00.000Z');
      final sets =
          ((workout['exercises'] as List).single as Map)['sets'] as List;
      expect(sets, [
        {
          'targetReps': 8,
          'targetWeightKg': 60.0,
          'reps': 8,
          'weightKg': 62.5,
          'completedAt': '2026-01-01T00:01:00.000Z',
        },
        {'targetReps': 8, 'targetWeightKg': 60.0},
      ]);
      expect(
        (result.content.single as TextContent).text,
        contains('Bench press: 8 x 62.5 kg'),
      );
    });

    test(
      'get_workout and get_routine answer as errors for a missing, deleted or foreign id',
      () async {
        final a = await emulators.createAccount();
        final b = await emulators.createAccount();
        await seedWorkout(a, 'w-a', startedAtMs: jan1);
        await seedWorkout(b, 'w-gone', startedAtMs: jan1, deletedAtMs: 4);
        await seedRoutine(a, 'r-a', 'A routine');
        final asB = await connect(await serverFor(b));

        expect((await call(asB, 'get_workout', {'id': 'w-a'})).isError, isTrue);
        expect(
          (await call(asB, 'get_workout', {'id': 'w-gone'})).isError,
          isTrue,
        );
        expect(
          (await call(asB, 'get_workout', {'id': 'nope'})).isError,
          isTrue,
        );
        expect((await call(asB, 'get_routine', {'id': 'r-a'})).isError, isTrue);
      },
    );

    test('get_routine returns the routine', () async {
      final uid = await emulators.createAccount();
      await seedRoutine(uid, 'r-push', 'Push');
      await seedRoutine(uid, 'r-gone', 'Gone', deletedAtMs: 3);
      final client = await connect(await serverFor(uid));

      final routine =
          (await call(client, 'get_routine', {
                'id': 'r-push',
              })).structuredContent!['routine']
              as Map;
      expect(routine['name'], 'Push');
      expect(
        (await call(client, 'get_routine', {'id': 'r-gone'})).isError,
        isTrue,
      );
    });

    test(
      'find_exercises matches part of a name, ignoring case and tombstones',
      () async {
        final uid = await emulators.createAccount();
        Future<void> exercise(String id, String name, {int? deletedAtMs}) =>
            emulators.putDocument(uid, 'exercises', id, {
              'syncId': id,
              'name': name,
              'kind': 'reps',
              'version': 1,
              'createdAtMs': 1,
              'muscleSyncIds': <Object?>[],
              'deletedAtMs': deletedAtMs,
            });
        await exercise('e1', 'Bench press');
        await exercise('e2', 'Incline bench');
        await exercise('e3', 'Old bench', deletedAtMs: 2);
        await exercise('e4', 'Squat');
        final client = await connect(await serverFor(uid));

        final result = await call(client, 'find_exercises', {'query': 'BENCH'});

        expect(
          [
            for (final e in result.structuredContent!['exercises'] as List)
              (e as Map)['name'],
          ],
          ['Bench press', 'Incline bench'],
        );
      },
    );

    test('no tool returns a heart-rate field', () async {
      final uid = await emulators.createAccount();
      await seedWorkout(uid, 'w1', startedAtMs: jan1);
      final client = await connect(await serverFor(uid));

      final answers = [
        await call(client, 'list_workouts'),
        await call(client, 'get_workout', {'id': 'w1'}),
      ];

      for (final a in answers) {
        final text = jsonEncode(a.toJson()).toLowerCase();
        expect(text, isNot(contains('heart')));
        expect(text, isNot(contains('bpm')));
        expect(text, isNot(contains('hr')));
      }
    });

    test(
      'a call that finds the account gone answers with the www-authenticate challenge',
      () async {
        final uid = await emulators.createAccount();
        final directory = AccountDirectory(
          client: EmulatorAdminClient(),
          authRoot: emulators.config.authRoot,
          projectId: emulators.config.projectId,
        );
        final account = (await directory.verify(uid))!;
        final scope = UserScope(
          account,
          FirestoreApi(
            EmulatorAdminClient(),
            rootUrl: emulators.config.firestoreRoot.toString(),
          ),
          emulators.config.projectId,
        );
        final server = McpServer(const Implementation(name: 't', version: '1'));
        registerListRoutines(server, ToolContext(scope, () async => false));
        final toServer = StreamController<List<int>>();
        final toClient = StreamController<List<int>>();
        await server.connect(
          IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
        );
        final client = McpClient(const Implementation(name: 't', version: '1'));
        clients.add(client);
        await client.connect(
          IOStreamTransport(stream: toClient.stream, sink: toServer.sink),
        );

        final result = await call(client, 'list_routines');

        expect(result.isError, isTrue);
        expect(result.meta?['mcp/www_authenticate'], [
          'Bearer error="invalid_token"',
        ]);
      },
    );
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
