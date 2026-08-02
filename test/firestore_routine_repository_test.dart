import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/firestore_repositories.dart';
import 'package:gym_tracker/data/muscle_seeds.dart';

void main() {
  late FakeFirebaseFirestore fs;
  late FirestoreRoutineRepository routines;
  late FirestoreExerciseRepository exercises;

  setUp(() {
    fs = FakeFirebaseFirestore();
    routines = FirestoreRoutineRepository(uid: 'u1', firestore: fs);
    exercises = FirestoreExerciseRepository(uid: 'u1', firestore: fs);
  });

  Future<int> routineVersion(String id) async {
    final doc = await fs
        .collection('users')
        .doc('u1')
        .collection('routines')
        .doc(id)
        .get();
    return (doc.data()!['version'] as num).toInt();
  }

  /// Web used to sort ascending while the Drift query (phone/watch) sorted
  /// descending, so a routine created on the web appeared last there and first
  /// everywhere else. Both are newest-first now; `database_test.dart` pins the
  /// Drift half.
  test('summaries are newest-first, matching the Drift ordering', () async {
    final a = await routines.createRoutine('Oldest');
    final b = await routines.createRoutine('Middle');
    final c = await routines.createRoutine('Newest');
    // createRoutine stamps DateTime.now(), which can collide inside one test
    // run — set distinct values so this asserts ordering, not clock resolution.
    Future<void> stamp(String id, int ms) => fs
        .collection('users')
        .doc('u1')
        .collection('routines')
        .doc(id)
        .update({'createdAtMs': ms});
    await stamp(a.syncId, 1000);
    await stamp(b.syncId, 2000);
    await stamp(c.syncId, 3000);

    final sums = await routines.watchRoutineSummaries().first;
    expect(
      sums.map((s) => s.routine.name).toList(),
      ['Newest', 'Middle', 'Oldest'],
    );
  });

  test('createRoutine shows in summaries with exercise count 0', () async {
    final r = await routines.createRoutine('Push');
    final sums = await routines.watchRoutineSummaries().first;
    expect(sums.single.routine.syncId, r.syncId);
    expect(sums.single.routine.name, 'Push');
    expect(sums.single.exerciseCount, 0);
  });

  test('add exercise + sets builds the full routine tree and bumps version',
      () async {
    final ex = await exercises.createExercise('Bench');
    await exercises.setExerciseMuscles(ex.syncId, [muscleSyncId('Chest')]);
    final r = await routines.createRoutine('Push');
    final v0 = await routineVersion(r.syncId);

    final re = await routines.addExerciseToRoutine(
      routineId: r.syncId,
      exerciseId: ex.syncId,
    );
    await routines.addPlannedSet(
      routineExerciseId: re.syncId,
      targetReps: 8,
      targetWeightKg: 40,
    );
    await routines.addPlannedSet(
      routineExerciseId: re.syncId,
      targetReps: 6,
      targetWeightKg: 45,
    );

    final full = await routines.loadFullRoutine(r.syncId);
    final slot = full!.exercises.single;
    expect(slot.exercise.name, 'Bench');
    expect(slot.routineExercise.exerciseId, ex.syncId);
    expect(slot.plannedSets.map((s) => s.targetReps), [8, 6]);
    expect(slot.plannedSets.map((s) => s.setIndex), [0, 1]);
    // muscle tags denormalized from the exercise at add time, resolved via seeds
    expect(slot.muscles.map((m) => m.name), ['Chest']);
    // every child mutation bumped the routine version
    expect(await routineVersion(r.syncId), greaterThan(v0));
    expect(await routineVersion(r.syncId), v0 + 3); // add ex + 2 sets
  });

  test('update and delete a planned set', () async {
    final ex = await exercises.createExercise('Bench');
    final r = await routines.createRoutine('Push');
    final re = await routines.addExerciseToRoutine(
      routineId: r.syncId,
      exerciseId: ex.syncId,
    );
    final ps = await routines.addPlannedSet(
      routineExerciseId: re.syncId,
      targetReps: 8,
      targetWeightKg: 40,
    );

    await routines.updatePlannedSet(id: ps.syncId, targetReps: 12, targetWeightKg: 50);
    var slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
    expect(slot.plannedSets.single.targetReps, 12);
    expect(slot.plannedSets.single.targetWeightKg, 50);

    await routines.deletePlannedSet(ps.syncId);
    slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
    expect(slot.plannedSets, isEmpty);
  });

  test('rest, superset, and reorder operate by child syncId', () async {
    final ex = await exercises.createExercise('Bench');
    final r = await routines.createRoutine('Push');
    final a = await routines.addExerciseToRoutine(
      routineId: r.syncId,
      exerciseId: ex.syncId,
    );
    final b = await routines.addExerciseToRoutine(
      routineId: r.syncId,
      exerciseId: ex.syncId,
    );

    await routines.setRestSeconds(a.syncId, 120);
    await routines.setSupersetGroup(b.syncId, 1);
    await routines.reorderRoutineExercises(
      routineId: r.syncId,
      orderedIds: [b.syncId, a.syncId],
    );

    final full = await routines.loadFullRoutine(r.syncId);
    expect(full!.exercises.map((e) => e.routineExercise.syncId), [b.syncId, a.syncId]);
    expect(full.exercises.map((e) => e.routineExercise.orderIndex), [0, 1]);
    final aSlot = full.exercises.firstWhere((e) => e.routineExercise.syncId == a.syncId);
    final bSlot = full.exercises.firstWhere((e) => e.routineExercise.syncId == b.syncId);
    expect(aSlot.routineExercise.restSeconds, 120);
    expect(bSlot.routineExercise.supersetGroup, 1);
  });

  test('alternatives: add alternative + its planned set, then remove', () async {
    final bench = await exercises.createExercise('Bench');
    final db = await exercises.createExercise('Dumbbell Press');
    final r = await routines.createRoutine('Push');
    final re = await routines.addExerciseToRoutine(
      routineId: r.syncId,
      exerciseId: bench.syncId,
    );

    final alt = await routines.addRoutineExerciseAlternative(
      routineExerciseId: re.syncId,
      exerciseId: db.syncId,
    );
    await routines.addAlternativePlannedSet(
      alternativeId: alt.syncId,
      targetReps: 10,
      targetWeightKg: 20,
    );

    var slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
    expect(slot.alternatives.single.exercise.name, 'Dumbbell Press');
    expect(slot.alternatives.single.plannedSets.single.targetReps, 10);

    await routines.removeRoutineExerciseAlternative(alt.syncId);
    slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
    expect(slot.alternatives, isEmpty);
  });

  test('deleteRoutine tombstones: gone from summaries and watchFullRoutine',
      () async {
    final ex = await exercises.createExercise('Bench');
    final r = await routines.createRoutine('Push');
    await routines.addExerciseToRoutine(routineId: r.syncId, exerciseId: ex.syncId);

    await routines.deleteRoutine(r.syncId);

    expect(await routines.watchRoutineSummaries().first, isEmpty);
    expect(await routines.watchFullRoutine(r.syncId).first, isNull);
    expect(await routines.loadFullRoutine(r.syncId), isNull);
  });
}
