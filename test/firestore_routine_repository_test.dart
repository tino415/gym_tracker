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

  test('rest, circuit, and reorder operate by child syncId', () async {
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
    await routines.setCircuitGroup(b.syncId, 1);
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
    expect(bSlot.routineExercise.circuitGroup, 1);
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

  group('renaming an exercise reaches the routines that use it', () {
    /// Routine docs embed `exerciseName`/`exerciseKind` for sync
    /// self-containment, and web reads rendered that copy — so a rename never
    /// showed up in a routine. Worse, `SyncRepository` writes an incoming
    /// bundle's name onto the local exercise, so a stale routine doc renamed the
    /// exercise *back* on the phone.
    Future<List<Map<String, Object?>>> embeddedSlots(String routineId) async {
      final doc = await fs
          .collection('users')
          .doc('u1')
          .collection('routines')
          .doc(routineId)
          .get();
      return [
        for (final e in doc.data()!['exercises'] as List)
          (e as Map).cast<String, Object?>(),
      ];
    }

    test('the embedded copy is rewritten, and the version bumped', () async {
      final ex = await exercises.createExercise('Dumbbell row');
      final r = await routines.createRoutine('Pull');
      await routines.addExerciseToRoutine(
        routineId: r.syncId,
        exerciseId: ex.syncId,
      );
      final before = await routineVersion(r.syncId);

      await exercises.renameExercise(ex.syncId, 'Chest supported dumbbell row');

      expect((await embeddedSlots(r.syncId)).single['exerciseName'],
          'Chest supported dumbbell row');
      // The bump is what makes the rewrite win version-LWW against the copy a
      // peer still holds.
      expect(await routineVersion(r.syncId), greaterThan(before));
      final slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
      expect(slot.exercise.name, 'Chest supported dumbbell row');
    });

    test('alternatives are rewritten too', () async {
      final bench = await exercises.createExercise('Bench');
      final alt = await exercises.createExercise('Dumbbell Press');
      final r = await routines.createRoutine('Push');
      final re = await routines.addExerciseToRoutine(
        routineId: r.syncId,
        exerciseId: bench.syncId,
      );
      await routines.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: alt.syncId,
      );

      await exercises.renameExercise(alt.syncId, 'Dumbbell bench press');

      final slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
      expect(slot.alternatives.single.exercise.name, 'Dumbbell bench press');
    });

    test('a routine not using the exercise is left alone', () async {
      final ex = await exercises.createExercise('Squat');
      final other = await exercises.createExercise('Bench');
      final untouched = await routines.createRoutine('Push');
      await routines.addExerciseToRoutine(
        routineId: untouched.syncId,
        exerciseId: other.syncId,
      );
      final before = await routineVersion(untouched.syncId);

      await exercises.renameExercise(ex.syncId, 'Back squat');

      // A version bump on every routine would re-push the lot for nothing.
      expect(await routineVersion(untouched.syncId), before);
    });

    test('reads render the embedded copy, not a live join', () async {
      // Deliberate: the embedded copy is what the watch and the phone see, so a
      // read-time join would make a stale document look correct on the web while
      // the phone kept reverting the rename. Reading it straight means a stale
      // doc is visible as stale.
      final ex = await exercises.createExercise('Old name');
      final r = await routines.createRoutine('Pull');
      await routines.addExerciseToRoutine(
        routineId: r.syncId,
        exerciseId: ex.syncId,
      );
      // Bypass renameExercise, so the fan-out does not run.
      await fs
          .collection('users')
          .doc('u1')
          .collection('exercises')
          .doc(ex.syncId)
          .update({'name': 'New name'});

      final slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
      expect(slot.exercise.name, 'Old name');
    });

    test('the one-off repair brings stale docs back in line', () async {
      final ex = await exercises.createExercise('Old name');
      final other = await exercises.createExercise('Untouched');
      final stale = await routines.createRoutine('Pull');
      final fresh = await routines.createRoutine('Push');
      final re = await routines.addExerciseToRoutine(
        routineId: stale.syncId,
        exerciseId: ex.syncId,
      );
      await routines.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: ex.syncId,
      );
      await routines.addExerciseToRoutine(
        routineId: fresh.syncId,
        exerciseId: other.syncId,
      );
      // Rename the library entry behind the fan-out's back, the way every
      // rename behaved before it existed.
      await fs
          .collection('users')
          .doc('u1')
          .collection('exercises')
          .doc(ex.syncId)
          .update({'name': 'New name'});
      final freshVersionBefore = await routineVersion(fresh.syncId);

      expect(await routines.repairEmbeddedExerciseNames(), 1);

      final slot = (await routines.loadFullRoutine(stale.syncId))!
          .exercises
          .single;
      expect(slot.exercise.name, 'New name');
      expect(slot.alternatives.single.exercise.name, 'New name');
      // A routine that was already correct must not be bumped — that would
      // re-push it to every peer for nothing.
      expect(await routineVersion(fresh.syncId), freshVersionBefore);
    });

    test('the repair leaves an unknown exercise alone', () async {
      // A slot whose exercise is missing from the library keeps its embedded
      // name rather than being blanked.
      final ex = await exercises.createExercise('Ghost');
      final r = await routines.createRoutine('Pull');
      await routines.addExerciseToRoutine(
        routineId: r.syncId,
        exerciseId: ex.syncId,
      );
      await fs
          .collection('users')
          .doc('u1')
          .collection('exercises')
          .doc(ex.syncId)
          .delete();

      expect(await routines.repairEmbeddedExerciseNames(), 0);
      expect((await embeddedSlots(r.syncId)).single['exerciseName'], 'Ghost');
    });

    test('setExerciseKind propagates, since the run page branches on it',
        () async {
      final ex = await exercises.createExercise('Plank');
      final r = await routines.createRoutine('Core');
      await routines.addExerciseToRoutine(
        routineId: r.syncId,
        exerciseId: ex.syncId,
      );

      await exercises.setExerciseKind(ex.syncId, 'time');

      expect((await embeddedSlots(r.syncId)).single['exerciseKind'], 'time');
      final slot = (await routines.loadFullRoutine(r.syncId))!.exercises.single;
      expect(slot.exercise.kind, 'time');
    });
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
