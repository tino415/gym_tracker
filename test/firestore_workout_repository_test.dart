import 'package:drift/drift.dart' show Value;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/firestore_repositories.dart';

void main() {
  late FakeFirebaseFirestore fs;
  late FirestoreWorkoutRepository workouts;

  setUp(() {
    fs = FakeFirebaseFirestore();
    workouts = FirestoreWorkoutRepository(uid: 'u1', firestore: fs);
  });

  wcol() => fs.collection('users').doc('u1').collection('workouts');

  Future<void> seed(
    String id, {
    int startedAtMs = 1000,
    int? endedAtMs = 2000,
    String? routineSyncId,
    List<Map<String, dynamic>> exercises = const [],
    List<Map<String, dynamic>> completions = const [],
    int? version,
    int? deletedAtMs,
  }) => wcol().doc(id).set({
    'syncId': id,
    'routineSyncId': routineSyncId,
    'startedAtMs': startedAtMs,
    'endedAtMs': endedAtMs,
    'exercises': exercises,
    'completions': completions,
    'avgHeartRate': null,
    'maxHeartRate': null,
    'version': ?version,
    'deletedAtMs': deletedAtMs,
  });

  Map<String, dynamic> exercise(String id, {List<Map<String, dynamic>> sets = const []}) => {
    'syncId': id,
    'exerciseSyncId': 'ex-$id',
    'exerciseName': 'Bench',
    'kind': 'reps',
    'orderIndex': 0,
    'restSeconds': 90,
    'supersetGroup': null,
    'sets': sets,
    'routineExerciseSyncId': null,
  };

  Map<String, dynamic> wset(String id) => {
    'syncId': id,
    'setIndex': 0,
    'targetReps': 8,
    'targetWeightKg': 40.0,
    'targetSeconds': null,
  };

  // --- Improvement helpers: routine docs + fully-linked workout snapshots ---

  rcol() => fs.collection('users').doc('u1').collection('routines');

  Map<String, dynamic> pset(
    String id, {
    int idx = 0,
    int? reps,
    double? weight,
    int? seconds,
  }) => {
    'syncId': id,
    'setIndex': idx,
    'targetReps': reps,
    'targetWeightKg': weight,
    'targetSeconds': seconds,
  };

  Map<String, dynamic> altRef(
    String id, {
    required String exId,
    List<Map<String, dynamic>> plannedSets = const [],
  }) => {
    'syncId': id,
    'exerciseSyncId': exId,
    'exerciseName': 'Alt',
    'exerciseKind': 'reps',
    'orderIndex': 0,
    'plannedSets': plannedSets,
  };

  Map<String, dynamic> rexercise(
    String id, {
    required String exId,
    String kind = 'reps',
    List<Map<String, dynamic>> plannedSets = const [],
    List<Map<String, dynamic>> alternatives = const [],
  }) => {
    'syncId': id,
    'exerciseSyncId': exId,
    'exerciseName': 'Bench',
    'exerciseKind': kind,
    'orderIndex': 0,
    'restSeconds': 90,
    'supersetGroup': null,
    'plannedSets': plannedSets,
    'alternatives': alternatives,
    'muscleSyncIds': <String>[],
  };

  Future<void> seedRoutine(
    String id, {
    int version = 1,
    int? deletedAtMs,
    List<Map<String, dynamic>> exercises = const [],
  }) => rcol().doc(id).set({
    'syncId': id,
    'name': 'R',
    'version': version,
    'createdAtMs': 0,
    'deletedAtMs': deletedAtMs,
    'exercises': exercises,
  });

  Map<String, dynamic> wexercise(
    String id, {
    required String exId,
    String? reId,
    String kind = 'reps',
    List<Map<String, dynamic>> sets = const [],
  }) => {
    'syncId': id,
    'exerciseSyncId': exId,
    'exerciseName': 'Bench',
    'kind': kind,
    'orderIndex': 0,
    'restSeconds': 90,
    'supersetGroup': null,
    'sets': sets,
    'routineExerciseSyncId': reId,
  };

  Map<String, dynamic> wsetIdx(String id, {int idx = 0}) => {
    'syncId': id,
    'setIndex': idx,
    'targetReps': 0,
    'targetWeightKg': 0.0,
    'targetSeconds': null,
  };

  Map<String, dynamic> completion(
    String id, {
    required String wsId,
    int? reps,
    double? weight,
    int? seconds,
  }) => {
    'syncId': id,
    'workoutSetSyncId': wsId,
    'actualReps': reps,
    'actualWeightKg': weight,
    'actualSeconds': seconds,
    'completedAtMs': 1500,
    'avgHeartRate': null,
    'maxHeartRate': null,
  };

  test('watchRecentWorkouts is newest-first', () async {
    await seed('a', startedAtMs: 1000);
    await seed('b', startedAtMs: 3000);
    await seed('c', startedAtMs: 2000);
    final list = await workouts.watchRecentWorkouts().first;
    expect(list.map((w) => w.syncId), ['b', 'c', 'a']);
  });

  test('routineName from the doc surfaces on the workout row', () async {
    await wcol().doc('w1').set({
      'syncId': 'w1',
      'routineSyncId': 'r1',
      'routineName': 'Leg Day',
      'startedAtMs': 1000,
      'endedAtMs': 2000,
      'exercises': <Object?>[],
      'completions': <Object?>[],
      'avgHeartRate': null,
      'maxHeartRate': null,
    });
    final w = (await workouts.watchRecentWorkouts().first).single;
    expect(w.routineName, 'Leg Day');
  });

  test('createWorkout snapshots a routine into a new workout doc', () async {
    await seedRoutine('r1', exercises: [
      rexercise('re1', exId: 'exA', plannedSets: [pset('ps1', reps: 5, weight: 100.0)]),
    ]);
    final started = DateTime(2026, 7, 20, 18);
    final w = await workouts.createWorkout(
      routineId: 'r1',
      startedAt: started,
      endedAt: started,
    );
    expect(w.routineName, 'R'); // seedRoutine names it 'R'
    expect(w.endedAt, started);

    final full = (await workouts.watchFullWorkout(w.syncId).first)!;
    expect(full.exercises.single.workoutExercise.exerciseName, 'Bench');
    expect(full.exercises.single.sets.single.workoutSet.targetReps, 5);
    expect(full.exercises.single.sets.single.completion, isNull);
  });

  test('createWorkout with no routine is empty', () async {
    final w = await workouts.createWorkout(startedAt: DateTime(2026, 7, 20));
    expect(w.routineId, isNull);
    final full = (await workouts.watchFullWorkout(w.syncId).first)!;
    expect(full.exercises, isEmpty);
  });

  test('watchInProgressWorkout returns the open one', () async {
    await seed('done', endedAtMs: 2000);
    await seed('open', endedAtMs: null);
    final w = await workouts.watchInProgressWorkout().first;
    expect(w!.syncId, 'open');
    expect(w.endedAt, isNull);
  });

  test('watchFullWorkout builds the tree with completions attached', () async {
    await seed(
      'w1',
      exercises: [exercise('we1', sets: [wset('ws1')])],
      completions: [
        {
          'syncId': 'c1',
          'workoutSetSyncId': 'ws1',
          'actualReps': 8,
          'actualWeightKg': 40.0,
          'actualSeconds': null,
          'completedAtMs': 1500,
          'avgHeartRate': null,
          'maxHeartRate': null,
        },
      ],
    );
    final full = (await workouts.watchFullWorkout('w1').first)!;
    final slot = full.exercises.single;
    expect(slot.workoutExercise.exerciseName, 'Bench');
    expect(slot.sets.single.workoutSet.targetReps, 8);
    expect(slot.sets.single.completion!.actualReps, 8);
  });

  test('upsertSetCompletion inserts then updates in place', () async {
    await seed('w1', exercises: [exercise('we1', sets: [wset('ws1')])]);

    await workouts.upsertSetCompletion(
      workoutId: 'w1',
      workoutSetId: 'ws1',
      actualReps: 10,
      actualWeightKg: 50,
      avgHeartRate: const Value(120),
    );
    var full = (await workouts.watchFullWorkout('w1').first)!;
    expect(full.exercises.single.sets.single.completion!.actualReps, 10);
    expect(full.exercises.single.sets.single.completion!.avgHeartRate, 120);

    await workouts.upsertSetCompletion(
      workoutId: 'w1',
      workoutSetId: 'ws1',
      actualReps: 12,
      actualWeightKg: 55,
    );
    full = (await workouts.watchFullWorkout('w1').first)!;
    // still one completion, updated
    final doc = await wcol().doc('w1').get();
    expect((doc.data()!['completions'] as List).length, 1);
    expect(full.exercises.single.sets.single.completion!.actualReps, 12);
  });

  test('addWorkoutSet / removeWorkoutSet also drops the set completion', () async {
    await seed('w1', exercises: [exercise('we1')]);
    final ws = await workouts.addWorkoutSet(
      workoutExerciseId: 'we1',
      targetReps: 5,
      targetWeightKg: 100,
    );
    await workouts.upsertSetCompletion(
      workoutId: 'w1',
      workoutSetId: ws.syncId,
      actualReps: 5,
      actualWeightKg: 100,
    );

    var full = (await workouts.watchFullWorkout('w1').first)!;
    expect(full.exercises.single.sets.single.completion, isNotNull);

    await workouts.removeWorkoutSet(ws.syncId);
    full = (await workouts.watchFullWorkout('w1').first)!;
    expect(full.exercises.single.sets, isEmpty);
    final doc = await wcol().doc('w1').get();
    expect((doc.data()!['completions'] as List), isEmpty);
  });

  test('updateWorkoutTimes and deleteWorkout', () async {
    await seed('w1', startedAtMs: 1000, endedAtMs: 2000);
    await workouts.updateWorkoutTimes(
      workoutId: 'w1',
      startedAt: DateTime.fromMillisecondsSinceEpoch(500),
      endedAt: null,
    );
    final w = (await workouts.watchFullWorkout('w1').first)!.workout;
    expect(w.startedAt.millisecondsSinceEpoch, 500);
    expect(w.endedAt, isNull);

    await workouts.deleteWorkout('w1');
    expect(await workouts.watchFullWorkout('w1').first, isNull);
  });

  test('no routine link yields no improvements', () async {
    await seed('w1'); // routineSyncId null
    expect(await workouts.findWorkoutImprovements('w1'), isEmpty);
  });

  test('finds a primary-exercise improvement, then apply promotes it', () async {
    await seedRoutine(
      'r1',
      exercises: [
        rexercise('re1', exId: 'exA', plannedSets: [
          pset('ps1', reps: 8, weight: 40.0),
        ]),
      ],
    );
    await seed(
      'w1',
      routineSyncId: 'r1',
      exercises: [
        wexercise('we1', exId: 'exA', reId: 're1', sets: [wsetIdx('ws1')]),
      ],
      // 10 reps at the same 40kg beats the target of 8 reps.
      completions: [completion('c1', wsId: 'ws1', reps: 10, weight: 40.0)],
    );

    final found = await workouts.findWorkoutImprovements('w1');
    expect(found, hasLength(1));
    expect(found.single.targetPlannedSetId, 'ps1');
    expect(found.single.targetIsAlternative, isFalse);
    expect(found.single.oldReps, 8);
    expect(found.single.newReps, 10);

    await workouts.applyWorkoutImprovements('w1');
    final r = (await rcol().doc('r1').get()).data()!;
    final ps = ((r['exercises'] as List).single as Map)['plannedSets'] as List;
    expect((ps.single as Map)['targetReps'], 10);
    expect(r['version'], 2); // bumped for LWW propagation

    // Idempotent: targets now equal actuals, so nothing left to promote.
    expect(await workouts.findWorkoutImprovements('w1'), isEmpty);
  });

  test('attributes the improvement to the alternative that was performed', () async {
    await seedRoutine(
      'r1',
      exercises: [
        rexercise(
          're1',
          exId: 'exA',
          plannedSets: [pset('ps1', reps: 8, weight: 40.0)],
          alternatives: [
            altRef('alt1', exId: 'exB', plannedSets: [
              pset('aps1', reps: 6, weight: 30.0),
            ]),
          ],
        ),
      ],
    );
    await seed(
      'w1',
      routineSyncId: 'r1',
      // Performed the alternative exB, not the primary exA.
      exercises: [
        wexercise('we1', exId: 'exB', reId: 're1', sets: [wsetIdx('ws1')]),
      ],
      completions: [completion('c1', wsId: 'ws1', reps: 8, weight: 30.0)],
    );

    final found = await workouts.findWorkoutImprovements('w1');
    expect(found, hasLength(1));
    expect(found.single.targetPlannedSetId, 'aps1');
    expect(found.single.targetIsAlternative, isTrue);

    await workouts.applyWorkoutImprovements('w1');
    final r = (await rcol().doc('r1').get()).data()!;
    final re = (r['exercises'] as List).single as Map;
    final aps = ((re['alternatives'] as List).single as Map)['plannedSets'] as List;
    expect((aps.single as Map)['targetReps'], 8);
    // Primary planned set is untouched.
    final ps = re['plannedSets'] as List;
    expect((ps.single as Map)['targetReps'], 8);
  });

  test('a matched-but-not-beaten set is not an improvement', () async {
    await seedRoutine(
      'r1',
      exercises: [
        rexercise('re1', exId: 'exA', plannedSets: [
          pset('ps1', reps: 8, weight: 40.0),
        ]),
      ],
    );
    await seed(
      'w1',
      routineSyncId: 'r1',
      exercises: [
        wexercise('we1', exId: 'exA', reId: 're1', sets: [wsetIdx('ws1')]),
      ],
      // Exactly on target — no gain on either axis.
      completions: [completion('c1', wsId: 'ws1', reps: 8, weight: 40.0)],
    );
    expect(await workouts.findWorkoutImprovements('w1'), isEmpty);
  });

  test('a tombstoned routine yields no improvements', () async {
    await seedRoutine(
      'r1',
      deletedAtMs: 999,
      exercises: [
        rexercise('re1', exId: 'exA', plannedSets: [
          pset('ps1', reps: 8, weight: 40.0),
        ]),
      ],
    );
    await seed(
      'w1',
      routineSyncId: 'r1',
      exercises: [
        wexercise('we1', exId: 'exA', reId: 're1', sets: [wsetIdx('ws1')]),
      ],
      completions: [completion('c1', wsId: 'ws1', reps: 10, weight: 40.0)],
    );
    expect(await workouts.findWorkoutImprovements('w1'), isEmpty);
  });

  group('workout versioning (version-LWW)', () {
    Future<int> versionOf(String id) async {
      final doc = await wcol().doc(id).get();
      return (doc.data()!['version'] as num?)?.toInt() ?? 1;
    }

    test('createWorkout seeds version 1', () async {
      final w = await workouts.createWorkout(startedAt: DateTime(2026, 1, 1));
      expect(await versionOf(w.syncId), 1);
    });

    test('a direct edit bumps the version', () async {
      await seed('w1', version: 1);
      await workouts.updateWorkoutTimes(
        workoutId: 'w1',
        startedAt: DateTime.fromMillisecondsSinceEpoch(500),
        endedAt: null,
      );
      expect(await versionOf('w1'), 2);
    });

    test('an edit found by child id bumps the owning workout', () async {
      await seed('w1', version: 4, exercises: [exercise('we1')]);
      await workouts.addWorkoutSet(
        workoutExerciseId: 'we1',
        targetReps: 5,
        targetWeightKg: 60,
      );
      expect(await versionOf('w1'), 5);
    });

    test('a legacy doc with no version edits to version 2', () async {
      // seed() omits 'version' entirely unless asked — a legacy doc.
      await seed('w1');
      await workouts.updateWorkoutTimes(
        workoutId: 'w1',
        startedAt: DateTime.fromMillisecondsSinceEpoch(500),
        endedAt: null,
      );
      expect(await versionOf('w1'), 2);
    });

    test('deleteWorkout writes a tombstone instead of removing the doc',
        () async {
      await seed(
        'w1',
        version: 2,
        exercises: [exercise('we1', sets: [wset('s1')])],
        completions: [completion('c1', wsId: 's1', reps: 5)],
      );

      await workouts.deleteWorkout('w1');

      final doc = await wcol().doc('w1').get();
      expect(doc.exists, isTrue, reason: 'a removal would never reach peers');
      expect(doc.data()!['deletedAtMs'], isNotNull);
      expect(doc.data()!['version'], 3);
      expect(doc.data()!['exercises'], isEmpty);
      expect(doc.data()!['completions'], isEmpty);
    });

    test('a tombstoned workout is hidden from every read', () async {
      await seed('w1', endedAtMs: null, exercises: [exercise('we1')]);
      await workouts.deleteWorkout('w1');

      expect(await workouts.watchRecentWorkouts().first, isEmpty);
      expect(await workouts.watchFullWorkout('w1').first, isNull);
      expect(await workouts.watchInProgressWorkout().first, isNull);
      expect(await workouts.findWorkoutImprovements('w1'), isEmpty);
    });
  });
}
