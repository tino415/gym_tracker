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
    List<Map<String, dynamic>> exercises = const [],
    List<Map<String, dynamic>> completions = const [],
  }) => wcol().doc(id).set({
    'syncId': id,
    'routineSyncId': null,
    'startedAtMs': startedAtMs,
    'endedAtMs': endedAtMs,
    'exercises': exercises,
    'completions': completions,
    'avgHeartRate': null,
    'maxHeartRate': null,
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

  test('watchRecentWorkouts is newest-first', () async {
    await seed('a', startedAtMs: 1000);
    await seed('b', startedAtMs: 3000);
    await seed('c', startedAtMs: 2000);
    final list = await workouts.watchRecentWorkouts().first;
    expect(list.map((w) => w.syncId), ['b', 'c', 'a']);
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

  test('findWorkoutImprovements is a deferred no-op (empty)', () async {
    await seed('w1');
    expect(await workouts.findWorkoutImprovements('w1'), isEmpty);
  });
}
