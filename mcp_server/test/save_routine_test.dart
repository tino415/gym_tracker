import 'dart:convert';
import 'dart:io';

import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:gym_tracker_mcp/config.dart';
import 'package:gym_tracker_mcp/emulator_client.dart';
import 'package:gym_tracker_mcp/firestore_values.dart';
import 'package:gym_tracker_mcp/gym_mcp_server.dart';
import 'package:gym_tracker_mcp/oauth/jwt.dart';
import 'package:gym_tracker_mcp/oauth/signing_keys.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'support/emulators.dart';

const _versionMoved =
    'The routine changed since you read it: it is at version 2. Read it again '
    'with get_routine and redo the change.';
const _changedDuringSave =
    'The routine changed while it was being saved. Read it again with '
    'get_routine and redo the change.';
const _connectAgain =
    'This connection was made before GymTracker could save routines. Remove '
    "GymTracker in the assistant's settings and connect it again.";

void main() {
  late Emulators emulators;
  final running = <GymMcpServer>[];
  final clients = <McpClient>[];
  final clock = DateTime.utc(2026, 11, 28, 10, 0, 0, 123);

  final adminClient = EmulatorAdminClient();
  late fs.FirestoreApi firestore;

  setUpAll(() {
    emulators = Emulators();
    firestore = fs.FirestoreApi(
      adminClient,
      rootUrl: emulators.config.backend.firestoreRoot.toString(),
    );
  });
  tearDownAll(() {
    emulators.close();
    adminClient.close();
  });
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
    String uid, {
    Future<void> Function()? beforeCommit,
  }) async {
    var ids = 0;
    final base = emulators.config;
    final server = GymMcpServer(
      ServerConfig(
        host: base.host,
        port: 0,
        projectId: base.projectId,
        backend: base.backend,
        issuer: base.issuer,
        appUrl: base.appUrl,
        signingKeys: base.signingKeys,
        signingKid: base.signingKid,
        devToken: StaticToken('dev-token', uid),
        allowedHosts: base.allowedHosts,
      ),
      client: EmulatorAdminClient(_BeforeCommit(beforeCommit)),
      now: () => clock,
      newId: () => 'id-${++ids}',
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

  Future<CallToolResult> save(McpClient client, Map<String, Object?> draft) =>
      client.callTool(
        CallToolRequest(name: 'save_routine', arguments: {'routine': draft}),
      );

  Future<Map<String, Object?>> read(McpClient client, String id) async {
    final result = await client.callTool(
      CallToolRequest(name: 'get_routine', arguments: {'id': id}),
    );
    return (result.structuredContent!['routine'] as Map).cast();
  }

  String text(CallToolResult result) =>
      (result.content.single as TextContent).text;

  Future<void> exercise(
    String uid,
    String id,
    String name, {
    String kind = 'reps',
    List<String> muscles = const [],
    List<Object?>? params,
    int version = 1,
    int? deletedAtMs,
  }) => emulators.putDocument(uid, 'exercises', id, {
    'syncId': id,
    'name': name,
    'kind': kind,
    'params': ?params,
    'version': version,
    'createdAtMs': 1795000000000,
    'muscleSyncIds': muscles,
    'deletedAtMs': deletedAtMs,
  });

  Future<void> seedLibrary(String uid) async {
    await exercise(
      uid,
      'ex-bench',
      'Bench press',
      muscles: ['muscle:triceps', 'muscle:chest'],
      params: [
        {'id': 'p-incline', 'name': 'Incline'},
        {'builtin': 'weight'},
      ],
    );
    await exercise(uid, 'ex-dips', 'Dips');
    await exercise(uid, 'ex-plank', 'Plank', kind: 'time', muscles: ['muscle:abs']);
    await exercise(uid, 'ex-row', 'Row', muscles: ['muscle:back']);
  }

  final pushDay = <String, Object?>{
    'name': 'Push day',
    'exercises': [
      {
        'exerciseId': 'ex-bench',
        'restSeconds': 120,
        'circuitGroup': 1,
        'sets': [
          {
            'reps': 8,
            'weightKg': 60,
            'parameters': {'Incline': 30},
          },
          {'reps': 6, 'weightKg': 62.5},
        ],
        'alternatives': [
          {'exerciseId': 'ex-dips', 'sets': <Object?>[]},
        ],
      },
      {
        'exerciseId': 'ex-plank',
        'circuitGroup': 1,
        'sets': [
          {'seconds': 60},
        ],
      },
      {
        'newExercise': {
          'name': 'Cable fly',
          'kind': 'reps',
          'muscles': ['Chest'],
        },
        'sets': [
          {'reps': 12},
        ],
      },
    ],
  };

  Future<Map<String, Object?>?> stored(
    String uid,
    String collection,
    String id,
  ) async {
    try {
      final document = await firestore.projects.databases.documents.get(
        'projects/${emulators.config.projectId}/databases/(default)/documents/users/$uid/$collection/$id',
      );
      return documentToJson(document);
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<({String uid, McpClient client})> withPushDay() async {
    final uid = await emulators.createAccount();
    await seedLibrary(uid);
    final client = await connect(await serverFor(uid));
    final created = await save(client, pushDay);
    expect(created.isError, isNot(true), reason: text(created));
    return (uid: uid, client: client);
  }

  test('a create writes the fixture\'s document, at version 1', () async {
    final (:uid, :client) = await withPushDay();

    final fixture = jsonDecode(
      await File('../test/fixtures/save_routine_doc.json').readAsString(),
    );
    final document = await stored(uid, 'routines', 'id-1');
    expect(
      jsonEquals(document, fixture),
      isTrue,
      reason: const JsonEncoder.withIndent(' ').convert(document),
    );
  });

  test('the answer is the saved routine in the read shape', () async {
    final uid = await emulators.createAccount();
    await seedLibrary(uid);
    final client = await connect(await serverFor(uid));

    final result = await save(client, pushDay);

    expect(result.structuredContent!['routine'], await read(client, 'id-1'));
    expect(
      text(result),
      'Saved at version 1. Push day: Bench press, Plank, Cable fly',
    );
  });

  test('get_routine\'s answer sent back unchanged changes only the version', () async {
    final (:uid, :client) = await withPushDay();
    final before = await stored(uid, 'routines', 'id-1');

    final result = await save(client, await read(client, 'id-1'));

    expect(result.isError, isNot(true), reason: text(result));
    final after = await stored(uid, 'routines', 'id-1');
    expect(after!['version'], 2);
    expect(jsonEquals({...after, 'version': 1}, before), isTrue);
  });

  test('a kept slot keeps its id, its set ids and its alternatives; a new slot gets new ids', () async {
    final (:uid, :client) = await withPushDay();
    final draft = await read(client, 'id-1');
    final exercises = (draft['exercises'] as List).cast<Map>();
    final bench = {...exercises[0]}
      ..remove('alternatives')
      ..remove('circuitGroup');
    bench['sets'] = [
      ...(bench['sets'] as List),
      {'reps': 4, 'weightKg': 65},
    ];

    final result = await save(client, {
      ...draft,
      'exercises': [
        bench,
        {
          'exerciseId': 'ex-row',
          'sets': [
            {'reps': 10},
          ],
        },
      ],
    });

    expect(result.isError, isNot(true), reason: text(result));
    final routine = RoutineTemplateDto.fromJson(
      (await stored(uid, 'routines', 'id-1'))!,
    );
    final kept = routine.exercises[0];
    expect(kept.syncId, 'id-2');
    expect([for (final s in kept.plannedSets) s.syncId], ['id-3', 'id-4', 'id-11']);
    expect([for (final a in kept.alternatives) a.syncId], ['id-5']);
    final added = routine.exercises[1];
    expect(added.syncId, 'id-12');
    expect(added.exerciseSyncId, 'ex-row');
    expect([for (final s in added.plannedSets) s.syncId], ['id-13']);
    expect(added.alternatives, isEmpty);
    expect(added.circuitGroup, isNull);
  });

  test('alternatives present replace the stored ones, absent keep them', () async {
    final (:uid, :client) = await withPushDay();
    final draft = await read(client, 'id-1');
    final exercises = (draft['exercises'] as List).cast<Map>();

    final replaced = await save(client, {
      ...draft,
      'exercises': [
        {
          ...exercises[0],
          'alternatives': [
            {
              'exerciseId': 'ex-row',
              'sets': [
                {'reps': 10, 'weightKg': 50},
              ],
            },
          ],
        },
        ...exercises.skip(1),
      ],
    });

    expect(replaced.isError, isNot(true), reason: text(replaced));
    final routine = RoutineTemplateDto.fromJson(
      (await stored(uid, 'routines', 'id-1'))!,
    );
    final alternative = routine.exercises[0].alternatives.single;
    expect(alternative.exerciseSyncId, 'ex-row');
    expect(alternative.syncId, isNot('id-5'));
    expect(alternative.plannedSets.single.targetWeightKg, 50.0);
  });

  test('a stale version refuses with the version sentence and writes nothing', () async {
    final (:uid, :client) = await withPushDay();
    final draft = await read(client, 'id-1');
    final again = await save(client, draft);
    expect(again.isError, isNot(true), reason: text(again));
    final before = await stored(uid, 'routines', 'id-1');

    final stale = await save(client, {...draft, 'name': 'Push day B'});

    expect(stale.isError, isTrue);
    expect(text(stale), _versionMoved);
    expect(await stored(uid, 'routines', 'id-1'), before);
  });

  test('a document changed between read and commit refuses with the commit sentence', () async {
    final uid = await emulators.createAccount();
    await seedLibrary(uid);
    final first = await connect(await serverFor(uid));
    expect((await save(first, pushDay)).isError, isNot(true));
    final draft = await read(first, 'id-1');
    final fixture = (await stored(uid, 'routines', 'id-1'))!;
    final racing = await connect(
      await serverFor(
        uid,
        beforeCommit: () => emulators.putDocument(uid, 'routines', 'id-1', {
          ...fixture,
          'name': 'Edited on the phone',
        }),
      ),
    );

    final result = await save(racing, {...draft, 'name': 'Push day B'});

    expect(result.isError, isTrue);
    expect(text(result), _changedDuringSave);
    expect((await stored(uid, 'routines', 'id-1'))!['name'], 'Edited on the phone');
  });

  test('an unknown id, a deleted routine and a taken name each refuse with their sentence', () async {
    final (:uid, :client) = await withPushDay();
    await emulators.putDocument(uid, 'routines', 'r-gone', {
      'syncId': 'r-gone',
      'name': 'Gone',
      'version': 3,
      'createdAtMs': 1000,
      'exercises': <Object?>[],
      'deletedAtMs': 5000,
    });

    final unknown = await save(client, {...pushDay, 'id': 'nope', 'version': 1});
    final deleted = await save(client, {...pushDay, 'id': 'r-gone', 'version': 3});
    final taken = await save(client, {...pushDay, 'name': 'PUSH DAY'});
    final noVersion = await save(client, {...pushDay, 'id': 'id-1'});

    expect(text(unknown), 'No routine with that id.');
    expect(
      text(deleted),
      'That routine was deleted. Leave out id to create a new one.',
    );
    expect(text(taken), 'A routine named Push day exists: pass id id-1 to change it.');
    expect(text(noVersion), 'version is required when id is given.');
    expect((await stored(uid, 'routines', 'r-gone'))!['deletedAtMs'], 5000);
  });

  test('a new exercise is written with its muscles', () async {
    final (:uid, client: _) = await withPushDay();

    expect(await stored(uid, 'exercises', 'id-8'), {
      'syncId': 'id-8',
      'name': 'Cable fly',
      'kind': 'reps',
      'params': [
        {'builtin': 'weight'},
      ],
      'version': 1,
      'createdAtMs': 1795860000000,
      'muscleSyncIds': ['muscle:chest'],
      'deletedAtMs': null,
    });
  });

  test('a new exercise whose name is taken refuses with the id; the same new name twice is one exercise', () async {
    final uid = await emulators.createAccount();
    await seedLibrary(uid);
    final client = await connect(await serverFor(uid));
    Map<String, Object?> slot(String name) => {
      'newExercise': {'name': name, 'kind': 'reps'},
      'sets': [
        {'reps': 5},
      ],
    };

    final taken = await save(client, {
      'name': 'Pull',
      'exercises': [slot('row')],
    });
    final twice = await save(client, {
      'name': 'Pull',
      'exercises': [slot('Pull-up'), slot('pull-up')],
    });

    expect(text(taken), 'An exercise named Row exists: use exerciseId ex-row.');
    final routine = (twice.structuredContent!['routine'] as Map)['exercises'] as List;
    expect(
      {for (final e in routine) (e as Map)['exerciseId']},
      hasLength(1),
    );
  });

  test('a new exercise named like a deleted one revives it', () async {
    final uid = await emulators.createAccount();
    await exercise(uid, 'ex-old', 'Lunge', version: 4, deletedAtMs: 9000);
    final client = await connect(await serverFor(uid));

    final result = await save(client, {
      'name': 'Legs',
      'exercises': [
        {
          'newExercise': {
            'name': 'Lunge',
            'kind': 'time',
            'muscles': ['quads', 'Glutes'],
          },
          'sets': [
            {'seconds': 45},
          ],
        },
      ],
    });

    expect(result.isError, isNot(true), reason: text(result));
    final revived = (await stored(uid, 'exercises', 'ex-old'))!;
    expect(revived['deletedAtMs'], isNull);
    expect(revived['kind'], 'time');
    expect(revived['version'], 5);
    expect(revived['muscleSyncIds'], ['muscle:glutes', 'muscle:quads']);
    expect(
      ((result.structuredContent!['routine'] as Map)['exercises'] as List)
          .single['exerciseId'],
      'ex-old',
    );
  });

  test('a draft naming an exercise differently refuses, and the stored name is what the routine holds', () async {
    final (:uid, :client) = await withPushDay();
    final draft = await read(client, 'id-1');
    final exercises = (draft['exercises'] as List).cast<Map>();

    final renamed = await save(client, {
      ...draft,
      'exercises': [
        {...exercises[0], 'name': 'Flat bench'},
        ...exercises.skip(1),
      ],
    });
    final rekinded = await save(client, {
      ...draft,
      'exercises': [
        {...exercises[0], 'kind': 'time'},
        ...exercises.skip(1),
      ],
    });
    final unnamed = await save(client, {
      ...draft,
      'exercises': [
        {...exercises[0]}..remove('name'),
        ...exercises.skip(1),
      ],
    });

    const sentence = 'save_routine cannot rename an exercise or change its kind.';
    expect(text(renamed), sentence);
    expect(text(rekinded), sentence);
    expect(unnamed.isError, isNot(true), reason: text(unnamed));
    final routine = RoutineTemplateDto.fromJson(
      (await stored(uid, 'routines', 'id-1'))!,
    );
    expect(routine.exercises[0].exerciseName, 'Bench press');
  });

  test('an unknown slot, alternative or exercise refuses', () async {
    final (uid: _, :client) = await withPushDay();
    final draft = await read(client, 'id-1');
    final exercises = (draft['exercises'] as List).cast<Map>();

    final slot = await save(client, {
      ...draft,
      'exercises': [
        {...exercises[0], 'slotId': 'id-404'},
        ...exercises.skip(1),
      ],
    });
    final alternative = await save(client, {
      ...draft,
      'exercises': [
        {
          ...exercises[0],
          'alternatives': [
            {'alternativeId': 'id-404', 'exerciseId': 'ex-dips'},
          ],
        },
        ...exercises.skip(1),
      ],
    });
    final unknownExercise = await save(client, {
      'name': 'Other',
      'exercises': [
        {
          'exerciseId': 'ex-404',
          'sets': [
            {'reps': 5},
          ],
        },
      ],
    });

    expect(text(slot), 'No slot id-404 in this routine.');
    expect(text(alternative), 'No alternative id-404 in this slot.');
    expect(
      text(unknownExercise),
      'No exercise with id ex-404. Use find_exercises, or pass newExercise.',
    );
  });

  group('each limit and each set rule refuses', () {
    Map<String, Object?> routineOf(List<Map<String, Object?>> exercises) => {
      'name': 'Rules',
      'exercises': exercises,
    };
    Map<String, Object?> bench(List<Map<String, Object?>> sets) => {
      'exerciseId': 'ex-bench',
      'sets': sets,
    };
    Map<String, Object?> plank(List<Map<String, Object?>> sets) => {
      'exerciseId': 'ex-plank',
      'sets': sets,
    };

    final cases = <String, (Map<String, Object?>, String)>{
      'a reps set without reps': (
        routineOf([
          bench([
            {'weightKg': 50},
          ]),
        ]),
        'Bench press counts reps: each set needs reps and no seconds.',
      ),
      'a reps set with seconds': (
        routineOf([
          bench([
            {'reps': 5, 'seconds': 30},
          ]),
        ]),
        'Bench press counts reps: each set needs reps and no seconds.',
      ),
      'a time set with reps': (
        routineOf([
          plank([
            {'seconds': 30, 'reps': 1},
          ]),
        ]),
        'Plank is timed: each set needs seconds and no reps.',
      ),
      'an unknown parameter': (
        routineOf([
          bench([
            {
              'reps': 5,
              'parameters': {'Tempo': 3},
            },
          ]),
        ]),
        'Bench press has no parameter Tempo.',
      ),
      'reps above 1000': (
        routineOf([
          bench([
            {'reps': 1001},
          ]),
        ]),
        'reps must be a whole number from 1 to 1000.',
      ),
      'seconds above 86400': (
        routineOf([
          plank([
            {'seconds': 86401},
          ]),
        ]),
        'seconds must be a whole number from 1 to 86400.',
      ),
      'weight above 1000': (
        routineOf([
          bench([
            {'reps': 5, 'weightKg': 1000.5},
          ]),
        ]),
        'weightKg must be from 0 to 1000.',
      ),
      'rest above 3600': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'restSeconds': 3601,
          },
        ]),
        'restSeconds must be a whole number from 0 to 3600.',
      ),
      '21 sets': (
        routineOf([
          bench([
            for (var i = 0; i < 21; i++) {'reps': 5},
          ]),
        ]),
        'An exercise holds at most 20 sets.',
      ),
      '51 exercises': (
        routineOf([
          for (var i = 0; i < 51; i++)
            bench([
              {'reps': 5},
            ]),
        ]),
        'A routine holds at most 50 exercises.',
      ),
      '11 alternatives': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'alternatives': [
              for (var i = 0; i < 11; i++) {'exerciseId': 'ex-dips'},
            ],
          },
        ]),
        'A slot holds at most 10 alternatives.',
      ),
      'a name of 101 characters': (
        {
          ...routineOf([]),
          'name': 'x' * 101,
        },
        'A name must be 1 to 100 characters.',
      ),
      'an id that is not an id': (
        {
          ...routineOf([]),
          'id': 'routines/../x',
          'version': 1,
        },
        'id must be 1 to 64 letters, digits, _, : or -, as the read gave it.',
      ),
      'both exerciseId and newExercise': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'newExercise': {'name': 'X', 'kind': 'reps'},
          },
        ]),
        'Each exercise names either exerciseId or newExercise.',
      ),
      'an unknown muscle': (
        routineOf([
          {
            'newExercise': {
              'name': 'X',
              'kind': 'reps',
              'muscles': ['Neck'],
            },
            'sets': [
              {'reps': 5},
            ],
          },
        ]),
        'Unknown muscle Neck. Use one of: Chest, Back, Shoulders, Biceps, '
            'Triceps, Forearms, Abs, Quads, Hamstrings, Glutes, Calves.',
      ),
      'an alternative that is the slot\'s own exercise': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'alternatives': [
              {'exerciseId': 'ex-bench'},
            ],
          },
        ]),
        "An alternative cannot be the slot's own exercise or repeat another "
            'alternative.',
      ),
      'an alternative given twice': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'alternatives': [
              {'exerciseId': 'ex-dips'},
              {'exerciseId': 'ex-dips'},
            ],
          },
        ]),
        "An alternative cannot be the slot's own exercise or repeat another "
            'alternative.',
      ),
      'an alternative of another kind without sets': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'alternatives': [
              {'exerciseId': 'ex-plank'},
            ],
          },
        ]),
        'The alternative Plank is of another kind than Bench press, so it '
            'needs sets of its own.',
      ),
      'a circuit of one': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'circuitGroup': 1,
          },
        ]),
        'The exercises of circuit 1 must be next to each other, and at least '
            'two.',
      ),
      'a circuit split by another exercise': (
        routineOf([
          {
            ...bench([
              {'reps': 5},
            ]),
            'circuitGroup': 1,
          },
          plank([
            {'seconds': 30},
          ]),
          {
            'exerciseId': 'ex-dips',
            'circuitGroup': 1,
            'sets': [
              {'reps': 5},
            ],
          },
        ]),
        'The exercises of circuit 1 must be next to each other, and at least '
            'two.',
      ),
    };

    for (final MapEntry(key: name, value: (draft, sentence)) in cases.entries) {
      test(name, () async {
        final uid = await emulators.createAccount();
        await seedLibrary(uid);
        final client = await connect(await serverFor(uid));

        final result = await save(client, draft);

        expect(result.isError, isTrue);
        expect(text(result), sentence);
        expect(await stored(uid, 'routines', 'id-1'), isNull);
      });
    }
  });

  test('a read made before an exercise was renamed saves, and the routine takes the library\'s names, kept alternatives too', () async {
    final (:uid, :client) = await withPushDay();
    final draft = await read(client, 'id-1');
    await exercise(uid, 'ex-dips', 'Ring dips', version: 2);
    await exercise(uid, 'ex-plank', 'Front plank', kind: 'time', muscles: ['muscle:abs'], version: 2);
    final exercises = (draft['exercises'] as List).cast<Map>();

    final result = await save(client, {
      ...draft,
      'exercises': [
        {...exercises[0]}..remove('alternatives'),
        ...exercises.skip(1),
      ],
    });

    expect(result.isError, isNot(true), reason: text(result));
    final routine = RoutineTemplateDto.fromJson(
      (await stored(uid, 'routines', 'id-1'))!,
    );
    expect(routine.exercises[1].exerciseName, 'Front plank');
    expect(routine.exercises[0].alternatives.single.exerciseName, 'Ring dips');
  });

  test('a circuit the phone left with one member saves as it is; a new one of one still refuses', () async {
    final (:uid, :client) = await withPushDay();
    final before = (await stored(uid, 'routines', 'id-1'))!;
    final slots = (before['exercises'] as List).cast<Map>();
    await emulators.putDocument(uid, 'routines', 'id-1', {
      ...before,
      'exercises': [slots[0], slots[2]],
    });
    final draft = await read(client, 'id-1');

    final kept = await save(client, draft);
    final added = await save(client, {
      ...await read(client, 'id-1'),
      'exercises': [
        ...(draft['exercises'] as List),
        {
          'exerciseId': 'ex-row',
          'circuitGroup': 2,
          'sets': [
            {'reps': 10},
          ],
        },
      ],
    });

    expect(kept.isError, isNot(true), reason: text(kept));
    expect(
      text(added),
      'The exercises of circuit 2 must be next to each other, and at least two.',
    );
  });

  test('a replace cannot take the name of another live routine', () async {
    final (uid: _, :client) = await withPushDay();
    final pull = await save(client, {
      'name': 'Pull day',
      'exercises': [
        {
          'exerciseId': 'ex-row',
          'sets': [
            {'reps': 10},
          ],
        },
      ],
    });
    final pullId =
        (pull.structuredContent!['routine'] as Map)['id'] as String;

    final renamed = await save(client, {
      ...await read(client, 'id-1'),
      'name': 'pull DAY',
    });

    expect(
      text(renamed),
      'A routine named Pull day exists: pass id $pullId to change it.',
    );
  });

  test('the same new exercise given twice with another kind refuses', () async {
    final uid = await emulators.createAccount();
    await seedLibrary(uid);
    final client = await connect(await serverFor(uid));

    final result = await save(client, {
      'name': 'Holds',
      'exercises': [
        {
          'newExercise': {'name': 'Hold', 'kind': 'reps'},
          'sets': [
            {'reps': 5},
          ],
        },
        {
          'newExercise': {'name': 'hold', 'kind': 'time'},
          'sets': [
            {'seconds': 30},
          ],
        },
      ],
    });

    expect(
      text(result),
      'The new exercise hold is given twice with a different kind or muscles.',
    );
  });

  test('a routine without exercises refuses and writes nothing', () async {
    final uid = await emulators.createAccount();
    final client = await connect(await serverFor(uid));

    final result = await save(client, {'name': 'Empty'});

    expect(result.isError, isTrue);
    expect(await stored(uid, 'routines', 'id-1'), isNull);
  });

  test('a session opened without the save right is not resumed by a token that has it', () async {
    final uid = await emulators.createAccount();
    final server = await serverFor(uid);
    final config = emulators.config;
    final readOnly = AccessTokens(
      SigningKeys(config.signingKeys, config.signingKid),
      issuer: config.issuer,
      audience: config.mcpUrl,
      now: () => clock,
    ).issue(AccessClaims(uid: uid, grantId: 'g-read', clientId: 'c'));
    final client = await connect(
      server,
      token: readOnly,
      protocol: McpProtocol.legacy,
    );
    final session =
        (client.transport as StreamableHttpClientTransport).sessionId;

    final response = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Authorization': 'Bearer dev-token',
        'mcp-session-id': session!,
      },
      body: jsonEncode({'jsonrpc': '2.0', 'id': 9, 'method': 'tools/list'}),
    );

    expect(response.statusCode, 404);
  });

  test('a token without the save right refuses with the connection sentence, and get_routine still answers', () async {
    final (:uid, client: _) = await withPushDay();
    final server = await serverFor(uid);
    final config = emulators.config;
    final readOnly = AccessTokens(
      SigningKeys(config.signingKeys, config.signingKid),
      issuer: config.issuer,
      audience: config.mcpUrl,
      now: () => clock,
    ).issue(AccessClaims(uid: uid, grantId: 'g-read', clientId: 'c'));
    final client = await connect(server, token: readOnly);

    final refused = await save(client, {...pushDay, 'name': 'Another'});

    expect(refused.isError, isTrue);
    expect(text(refused), _connectAgain);
    expect((await read(client, 'id-1'))['name'], 'Push day');
  });

  test('tools/list shows save_routine with readOnlyHint false and destructiveHint true', () async {
    final uid = await emulators.createAccount();
    final client = await connect(await serverFor(uid));

    final tool = (await client.listTools()).tools.singleWhere(
      (t) => t.name == 'save_routine',
    );

    final annotations = tool.toJson()['annotations'] as Map;
    expect(annotations['readOnlyHint'], isFalse);
    expect(annotations['destructiveHint'], isTrue);
    expect(annotations['openWorldHint'], isFalse);
  });
}

/// Runs [_hook] once, before the first commit of a user document, so a test
/// can write between save_routine's read and its commit.
class _BeforeCommit extends http.BaseClient {
  _BeforeCommit(this._hook);

  Future<void> Function()? _hook;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final hook = _hook;
    if (hook != null && request.url.path.endsWith(':commit')) {
      _hook = null;
      await hook();
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
