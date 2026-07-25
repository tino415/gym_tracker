import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('startWorkout snapshot', () {
    test('copies the routine into workout_exercises/workout_sets', () async {
      final ex = await db.createExercise('Bench Press');
      final routine = await db.createRoutine('Push Day');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 10,
        targetWeightKg: 60.0,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 8,
        targetWeightKg: 62.5,
      );

      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);

      expect(snap, isNotNull);
      expect(snap!.workout.routineId, routine.syncId);
      expect(snap.exercises, hasLength(1));
      expect(snap.exercises.single.workoutExercise.exerciseName, 'Bench Press');
      expect(snap.exercises.single.kind, exerciseKindReps);
      expect(snap.exercises.single.sets, hasLength(2));
      expect(snap.exercises.single.sets[0].workoutSet.targetReps, 10);
      expect(snap.exercises.single.sets[0].workoutSet.targetWeightKg, 60.0);
      expect(snap.exercises.single.sets[1].workoutSet.targetReps, 8);
    });

    test('captures the routine name, kept after the routine is deleted',
        () async {
      final ex = await db.createExercise('Row');
      final routine = await db.createRoutine('Pull Day');
      await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      final workout = await db.startWorkout(routine.syncId);
      expect(
        (await db.loadFullWorkout(workout.syncId))!.workout.routineName,
        'Pull Day',
      );

      // Deleting the routine severs routineId, but the snapshot name survives.
      await db.deleteRoutine(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap!.workout.routineId, isNull);
      expect(snap.workout.routineName, 'Pull Day');
    });

    test('captures superset_group and exercise kind', () async {
      final bench = await db.createExercise('Bench');
      final fly = await db.createExercise('Fly');
      final routine = await db.createRoutine('Push');
      final reBench = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      final reFly = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: fly.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: reBench.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addPlannedSet(
        routineExerciseId: reFly.syncId,
        targetReps: 12,
        targetWeightKg: 12,
      );
      await db.setSupersetGroup(reBench.syncId, 1);
      await db.setSupersetGroup(reFly.syncId, 1);

      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);

      expect(
        snap!.exercises.map((e) => e.workoutExercise.supersetGroup).toList(),
        [1, 1],
      );
    });

    test('time-kind exercise snapshots target_seconds + optional weight',
        () async {
      final plank = await db.createExercise(
        'Weighted plank',
        kind: exerciseKindTime,
      );
      final routine = await db.createRoutine('Core');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: plank.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetSeconds: 45,
        targetWeightKg: 5.0,
      );

      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final set = snap!.exercises.single.sets.single.workoutSet;

      expect(snap.exercises.single.kind, exerciseKindTime);
      expect(set.targetSeconds, 45);
      expect(set.targetWeightKg, 5.0);
      expect(set.targetReps, isNull);
    });
  });

  group('routine deletion preserves workouts', () {
    test('workout snapshot stays, workout.routine_id becomes null', () async {
      final ex = await db.createExercise('Squat');
      final routine = await db.createRoutine('Legs');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 100,
      );
      final workout = await db.startWorkout(routine.syncId);

      await db.deleteRoutine(routine.syncId);

      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap, isNotNull);
      expect(snap!.routine, isNull);
      expect(snap.workout.routineId, isNull);
      expect(snap.exercises, hasLength(1));
      expect(snap.exercises.single.workoutExercise.exerciseName, 'Squat');
      expect(snap.exercises.single.sets, hasLength(1));
    });

    test('soft-deleting the underlying exercise keeps the workout snapshot name',
        () async {
      final ex = await db.createExercise('Curl');
      final routine = await db.createRoutine('Arms');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 12,
        targetWeightKg: 15,
      );
      final workout = await db.startWorkout(routine.syncId);

      await db.deleteRoutine(routine.syncId);
      await db.deleteExercise(ex.syncId);

      // Exercise deletion is now a soft tombstone (version-LWW), so the row
      // survives: the workout snapshot still resolves it (exercise_id kept) and
      // renders its name. The exercise is only hidden from the library reads.
      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap, isNotNull);
      expect(snap!.exercises.single.workoutExercise.exerciseId, isNotNull);
      expect(snap.exercises.single.workoutExercise.exerciseName, 'Curl');

      final library = await db.loadExercisesWithMuscles();
      expect(library.where((e) => e.exercise.syncId == ex.syncId), isEmpty);
    });
  });

  group('createExercise reconciles by name (UNIQUE + soft delete)', () {
    test('re-creating a soft-deleted name revives the same row', () async {
      final first = await db.createExercise('Plank', kind: exerciseKindReps);
      await db.deleteExercise(first.syncId);
      // Tombstoned: hidden from the library, but the UNIQUE name is still taken.
      var library = await db.loadExercisesWithMuscles();
      expect(library.where((e) => e.exercise.name == 'Plank'), isEmpty);

      // Recreating that name must not throw on UNIQUE(name); it revives the
      // tombstone (same identity), clears deletedAt, and applies the new kind.
      final again = await db.createExercise('Plank', kind: exerciseKindTime);
      expect(again.syncId, first.syncId);
      expect(again.deletedAt, isNull);
      expect(again.kind, exerciseKindTime);
      expect(again.version, greaterThan(first.version));

      library = await db.loadExercisesWithMuscles();
      expect(library.where((e) => e.exercise.name == 'Plank'), hasLength(1));
    });

    test('creating a name that is already live returns the existing row',
        () async {
      final first = await db.createExercise('Bench');
      final again = await db.createExercise('Bench');
      expect(again.syncId, first.syncId);
      final library = await db.loadExercisesWithMuscles();
      expect(library.where((e) => e.exercise.name == 'Bench'), hasLength(1));
    });
  });

  group('completions', () {
    test('upsert for reps then update', () async {
      final ex = await db.createExercise('Deadlift');
      final routine = await db.createRoutine('Pull');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 100,
      );
      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final wsId = snap!.exercises.single.sets.single.workoutSet.syncId;

      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: wsId,
        actualReps: 5,
        actualWeightKg: 100.0,
      );
      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: wsId,
        actualReps: 4,
        actualWeightKg: 102.5,
      );

      final cs = await db.completionsForWorkout(workout.syncId);
      expect(cs, hasLength(1));
      expect(cs.single.actualReps, 4);
      expect(cs.single.actualWeightKg, 102.5);
    });

    test('time-kind completion records seconds and optional weight', () async {
      final ex = await db.createExercise(
        'Farmer walk',
        kind: exerciseKindTime,
      );
      final routine = await db.createRoutine('Conditioning');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(routineExerciseId: re.syncId, targetSeconds: 60);
      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final wsId = snap!.exercises.single.sets.single.workoutSet.syncId;

      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: wsId,
        actualSeconds: 75,
        actualWeightKg: 24.0,
      );

      final cs = await db.completionsForWorkout(workout.syncId);
      expect(cs.single.actualSeconds, 75);
      expect(cs.single.actualWeightKg, 24.0);
      expect(cs.single.actualReps, isNull);
    });

    test('deleteSetCompletionFor removes the row', () async {
      final ex = await db.createExercise('Row');
      final routine = await db.createRoutine('Pull');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 10,
        targetWeightKg: 40,
      );
      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final wsId = snap!.exercises.single.sets.single.workoutSet.syncId;

      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: wsId,
        actualReps: 10,
        actualWeightKg: 40,
      );
      expect(await db.completionsForWorkout(workout.syncId), hasLength(1));

      await db.deleteSetCompletionFor(
        workoutId: workout.syncId,
        workoutSetId: wsId,
      );
      expect(await db.completionsForWorkout(workout.syncId), isEmpty);
    });
  });

  group('workout edit (history page)', () {
    test('addWorkoutExercise + addWorkoutSet + completion round-trip',
        () async {
      final ex = await db.createExercise('Pullup');
      final routine = await db.createRoutine('Back');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 6,
        targetWeightKg: 0,
      );
      final workout = await db.startWorkout(routine.syncId);

      // Add an exercise after the fact.
      final extra = await db.createExercise('Chinup');
      final we = await db.addWorkoutExercise(
        workoutId: workout.syncId,
        exerciseId: extra.syncId,
      );
      final ws = await db.addWorkoutSet(
        workoutExerciseId: we.syncId,
        targetReps: 8,
        targetWeightKg: 0,
      );
      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: ws.syncId,
        actualReps: 8,
        actualWeightKg: 0,
      );

      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap!.exercises, hasLength(2));
      expect(snap.exercises[1].workoutExercise.exerciseName, 'Chinup');
      expect(snap.exercises[1].sets.single.completion?.actualReps, 8);
    });

    test('updateWorkoutTimes persists started/ended', () async {
      final ex = await db.createExercise('Press');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 50,
      );
      final workout = await db.startWorkout(routine.syncId);

      final newStart = DateTime(2026, 5, 1, 9, 0);
      final newEnd = DateTime(2026, 5, 1, 10, 15);
      await db.updateWorkoutTimes(
        workoutId: workout.syncId,
        startedAt: newStart,
        endedAt: newEnd,
      );

      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap!.workout.startedAt, newStart);
      expect(snap.workout.endedAt, newEnd);
    });
  });

  group('heart-rate persistence', () {
    test('upsertSetCompletion writes avg/max on insert', () async {
      final ex = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 60,
      );
      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final ws = snap!.exercises.single.sets.single.workoutSet;

      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: ws.syncId,
        actualReps: 5,
        actualWeightKg: 60,
        avgHeartRate: const Value(125),
        maxHeartRate: const Value(148),
      );

      final completions = await db.completionsForWorkout(workout.syncId);
      expect(completions.single.avgHeartRate, 125);
      expect(completions.single.maxHeartRate, 148);
    });

    test(
      'upsertSetCompletion with absent HR preserves prior values on update',
      () async {
        final ex = await db.createExercise('Bench');
        final routine = await db.createRoutine('Push');
        final re = await db.addExerciseToRoutine(
          routineId: routine.syncId,
          exerciseId: ex.syncId,
        );
        await db.addPlannedSet(
          routineExerciseId: re.syncId,
          targetReps: 5,
          targetWeightKg: 60,
        );
        final workout = await db.startWorkout(routine.syncId);
        final snap = await db.loadFullWorkout(workout.syncId);
        final ws = snap!.exercises.single.sets.single.workoutSet;

        await db.upsertSetCompletion(
          workoutId: workout.syncId,
          workoutSetId: ws.syncId,
          actualReps: 5,
          actualWeightKg: 60,
          avgHeartRate: const Value(130),
          maxHeartRate: const Value(150),
        );
        // Re-toggle without providing HR — existing values must survive.
        await db.upsertSetCompletion(
          workoutId: workout.syncId,
          workoutSetId: ws.syncId,
          actualReps: 6,
          actualWeightKg: 60,
        );

        final completions = await db.completionsForWorkout(workout.syncId);
        expect(completions.single.actualReps, 6);
        expect(completions.single.avgHeartRate, 130);
        expect(completions.single.maxHeartRate, 150);
      },
    );

    test('finishWorkout writes avg/max', () async {
      final ex = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 60,
      );
      final workout = await db.startWorkout(routine.syncId);

      await db.finishWorkout(
        workout.syncId,
        avgHeartRate: 132,
        maxHeartRate: 162,
      );

      final after = await db.loadFullWorkout(workout.syncId);
      expect(after!.workout.endedAt, isNotNull);
      expect(after.workout.avgHeartRate, 132);
      expect(after.workout.maxHeartRate, 162);
    });
  });

  group('watchInProgressWorkout', () {
    Future<Workout> seedWorkout(AppDatabase db, String routineName) async {
      final ex = await db.createExercise('Ex-$routineName');
      final routine = await db.createRoutine(routineName);
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 40,
      );
      return db.startWorkout(routine.syncId);
    }

    test('emits null when no workouts have been started', () async {
      expect(await db.watchInProgressWorkout().first, isNull);
    });

    test('emits the started workout, then null after finish', () async {
      final stream = db.watchInProgressWorkout();
      final w = await seedWorkout(db, 'A');

      final first = await stream.first;
      expect(first?.syncId, w.syncId);

      await db.finishWorkout(w.syncId);
      final next = await stream.first;
      expect(next, isNull);
    });

    test('returns most recent when multiple in-progress workouts exist',
        () async {
      final older = await seedWorkout(db, 'older');
      // Force a distinct startedAt so ordering is deterministic.
      await db.updateWorkoutTimes(
        workoutId: older.syncId,
        startedAt: DateTime(2024, 1, 1),
        endedAt: null,
      );
      final newer = await seedWorkout(db, 'newer');

      final w = await db.watchInProgressWorkout().first;
      expect(w?.syncId, newer.syncId);
    });
  });

  group('alternatives', () {
    test('loadFullRoutine returns alternatives in orderIndex', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final smith = await db.createExercise('Smith Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: smith.syncId,
      );

      final full = await db.loadFullRoutine(routine.syncId);
      expect(
        full!.exercises.single.alternatives
            .map((a) => a.exercise.name)
            .toList(),
        ['DB Bench', 'Smith Bench'],
      );
    });

    test('startWorkout sets routineExerciseId back-pointer', () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );

      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap!.exercises.single.workoutExercise.routineExerciseId, re.syncId);
    });

    test(
        'loadAlternativesForWorkoutExercise returns primary + alts minus current',
        () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final smith = await db.createExercise('Smith Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: smith.syncId,
      );

      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final weId = snap!.exercises.single.workoutExercise.syncId;

      // Active is the primary (Bench): list = alts only.
      var alts = await db.loadAlternativesForWorkoutExercise(weId);
      expect(alts.map((e) => e.name).toList(), ['DB Bench', 'Smith Bench']);

      // Swap to DB Bench: list = primary + Smith (DB Bench filtered out).
      await db.swapWorkoutExercise(
        workoutExerciseId: weId,
        newExerciseId: dbBench.syncId,
      );
      alts = await db.loadAlternativesForWorkoutExercise(weId);
      expect(alts.map((e) => e.name).toList(), ['Bench', 'Smith Bench']);
    });

    test('swapWorkoutExercise updates name+kind, leaves targets', () async {
      final bench = await db.createExercise('Bench');
      final plank =
          await db.createExercise('Plank', kind: exerciseKindTime);
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: plank.syncId,
      );

      final workout = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(workout.syncId);
      final we = snap!.exercises.single.workoutExercise;

      await db.swapWorkoutExercise(
        workoutExerciseId: we.syncId,
        newExerciseId: plank.syncId,
      );
      final after = await db.loadFullWorkout(workout.syncId);
      expect(after!.exercises.single.workoutExercise.exerciseName, 'Plank');
      expect(after.exercises.single.kind, exerciseKindTime);
      // Targets untouched.
      expect(after.exercises.single.sets.single.workoutSet.targetReps, 5);
      expect(after.exercises.single.sets.single.workoutSet.targetWeightKg, 80);
    });

    test('routine deletion sets routineExerciseId NULL on workout exercise',
        () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final workout = await db.startWorkout(routine.syncId);

      await db.deleteRoutine(routine.syncId);

      final snap = await db.loadFullWorkout(workout.syncId);
      expect(snap!.exercises.single.workoutExercise.routineExerciseId, isNull);
      // No alternatives surfaced — degrades gracefully.
      final alts = await db.loadAlternativesForWorkoutExercise(
        snap.exercises.single.workoutExercise.syncId,
      );
      expect(alts, isEmpty);
    });

    test('removeRoutineExerciseAlternative drops the row', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.removeRoutineExerciseAlternative(alt.syncId);
      final full = await db.loadFullRoutine(routine.syncId);
      expect(full!.exercises.single.alternatives, isEmpty);
    });
  });

  group('alternative planned sets', () {
    test('addAlternativePlannedSet round-trips through loadFullRoutine',
        () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 10,
        targetWeightKg: 35.0,
      );

      final full = await db.loadFullRoutine(routine.syncId);
      final ps = full!.exercises.single.alternatives.single.plannedSets;
      expect(ps, hasLength(2));
      expect(ps[0].targetReps, 12);
      expect(ps[0].targetWeightKg, 32.5);
      expect(ps[1].targetReps, 10);
      expect(ps[1].targetWeightKg, 35.0);
    });

    test('swap retargets uncompleted sets from alt planned sets', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 10,
        targetWeightKg: 35.0,
      );

      final workout = await db.startWorkout(routine.syncId);
      final weId = (await db.loadFullWorkout(workout.syncId))!
          .exercises
          .single
          .workoutExercise
          .syncId;

      await db.swapWorkoutExercise(
        workoutExerciseId: weId,
        newExerciseId: dbBench.syncId,
      );

      final after = await db.loadFullWorkout(workout.syncId);
      final sets = after!.exercises.single.sets;
      expect(sets, hasLength(2));
      expect(sets[0].workoutSet.targetReps, 12);
      expect(sets[0].workoutSet.targetWeightKg, 32.5);
      expect(sets[1].workoutSet.targetReps, 10);
      expect(sets[1].workoutSet.targetWeightKg, 35.0);
    });

    test('swap preserves targets of completed sets', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 10,
        targetWeightKg: 35.0,
      );

      final workout = await db.startWorkout(routine.syncId);
      final snap0 = (await db.loadFullWorkout(workout.syncId))!;
      final weId = snap0.exercises.single.workoutExercise.syncId;
      final firstSetId = snap0.exercises.single.sets.first.workoutSet.syncId;

      // Complete set 1 against the primary's targets.
      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: firstSetId,
        actualReps: 5,
        actualWeightKg: 80,
      );

      await db.swapWorkoutExercise(
        workoutExerciseId: weId,
        newExerciseId: dbBench.syncId,
      );

      final after = await db.loadFullWorkout(workout.syncId);
      final sets = after!.exercises.single.sets;
      // Set 0 was completed → original targets preserved + completion intact.
      expect(sets[0].workoutSet.targetReps, 5);
      expect(sets[0].workoutSet.targetWeightKg, 80);
      expect(sets[0].completion?.actualReps, 5);
      // Set 1 was unfinished → alt's target.
      expect(sets[1].workoutSet.targetReps, 10);
      expect(sets[1].workoutSet.targetWeightKg, 35.0);
    });

    test('swap with no alt planned sets is a no-op on targets', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );

      final workout = await db.startWorkout(routine.syncId);
      final weId = (await db.loadFullWorkout(workout.syncId))!
          .exercises
          .single
          .workoutExercise
          .syncId;

      await db.swapWorkoutExercise(
        workoutExerciseId: weId,
        newExerciseId: dbBench.syncId,
      );

      final after = await db.loadFullWorkout(workout.syncId);
      // Targets unchanged (fall-back to primary's), name swapped.
      expect(after!.exercises.single.workoutExercise.exerciseName, 'DB Bench');
      expect(after.exercises.single.sets.single.workoutSet.targetReps, 5);
      expect(after.exercises.single.sets.single.workoutSet.targetWeightKg, 80);
    });

    test('swap with more alt sets appends extras', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 10,
        targetWeightKg: 35.0,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 8,
        targetWeightKg: 37.5,
      );

      final workout = await db.startWorkout(routine.syncId);
      final weId = (await db.loadFullWorkout(workout.syncId))!
          .exercises
          .single
          .workoutExercise
          .syncId;

      await db.swapWorkoutExercise(
        workoutExerciseId: weId,
        newExerciseId: dbBench.syncId,
      );

      final after = await db.loadFullWorkout(workout.syncId);
      final sets = after!.exercises.single.sets;
      expect(sets, hasLength(3));
      expect(sets[2].workoutSet.targetReps, 8);
      expect(sets[2].workoutSet.targetWeightKg, 37.5);
    });

    test('routine deletion cascades to alternative planned sets', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );

      await db.deleteRoutine(routine.syncId);

      final remaining = await db.select(db.alternativePlannedSets).get();
      expect(remaining, isEmpty);
    });
  });

  group('muscles', () {
    test('seed list is present', () async {
      final list = await db.watchMuscles().first;
      expect(list.map((m) => m.name), contains('Chest'));
      expect(list.map((m) => m.name), contains('Triceps'));
    });

    test('setExerciseMuscles replaces the set', () async {
      final bench = await db.createExercise('Bench');
      final all = await db.watchMuscles().first;
      final chest = all.firstWhere((m) => m.name == 'Chest');
      final triceps = all.firstWhere((m) => m.name == 'Triceps');
      final shoulders = all.firstWhere((m) => m.name == 'Shoulders');

      await db.setExerciseMuscles(bench.syncId, [chest.syncId, triceps.syncId]);
      var mus = await db.musclesForExercise(bench.syncId);
      expect(mus.map((m) => m.name).toSet(), {'Chest', 'Triceps'});

      // Replace.
      await db.setExerciseMuscles(bench.syncId, [shoulders.syncId]);
      mus = await db.musclesForExercise(bench.syncId);
      expect(mus.map((m) => m.name).toList(), ['Shoulders']);
    });

    test('deleting exercise cascades exercise_muscles rows', () async {
      final bench = await db.createExercise('Bench');
      final all = await db.watchMuscles().first;
      final chest = all.firstWhere((m) => m.name == 'Chest');
      await db.setExerciseMuscles(bench.syncId, [chest.syncId]);

      await db.deleteExercise(bench.syncId);

      // Chest must still exist; the join row must be gone.
      final after = await db.watchMuscles().first;
      expect(after.map((m) => m.name), contains('Chest'));
    });

    test('loadFullRoutine surfaces muscles on each routine exercise',
        () async {
      final bench = await db.createExercise('Bench');
      final all = await db.watchMuscles().first;
      final chest = all.firstWhere((m) => m.name == 'Chest');
      final triceps = all.firstWhere((m) => m.name == 'Triceps');
      await db.setExerciseMuscles(bench.syncId, [chest.syncId, triceps.syncId]);

      final routine = await db.createRoutine('Push');
      await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );

      final full = await db.loadFullRoutine(routine.syncId);
      expect(full!.exercises.single.muscles.map((m) => m.name).toSet(),
          {'Chest', 'Triceps'});
    });
  });

  group('lastCompletionForExerciseAtSetIndex', () {
    test('returns null when no prior completion exists', () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final workout = await db.startWorkout(routine.syncId);

      final r = await db.lastCompletionForExerciseAtSetIndex(
        exerciseId: bench.syncId,
        setIndex: 0,
        excludeWorkoutId: workout.syncId,
      );
      expect(r, isNull);
    });

    test('returns most recent across multiple prior finished workouts',
        () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );

      // Workout A — older.
      final wA = await db.startWorkout(routine.syncId);
      final snapA = await db.loadFullWorkout(wA.syncId);
      await db.upsertSetCompletion(
        workoutId: wA.syncId,
        workoutSetId: snapA!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 5,
        actualWeightKg: 80,
      );
      await db.finishWorkout(wA.syncId);
      await db.updateWorkoutTimes(
        workoutId: wA.syncId,
        startedAt: DateTime(2026, 5, 1),
        endedAt: DateTime(2026, 5, 1, 1),
      );

      // Workout B — newer, different actuals.
      final wB = await db.startWorkout(routine.syncId);
      final snapB = await db.loadFullWorkout(wB.syncId);
      await db.upsertSetCompletion(
        workoutId: wB.syncId,
        workoutSetId: snapB!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 7,
        actualWeightKg: 82.5,
      );
      await db.finishWorkout(wB.syncId);
      await db.updateWorkoutTimes(
        workoutId: wB.syncId,
        startedAt: DateTime(2026, 5, 10),
        endedAt: DateTime(2026, 5, 10, 1),
      );

      // Querying from a fresh in-progress workout.
      final wC = await db.startWorkout(routine.syncId);
      final r = await db.lastCompletionForExerciseAtSetIndex(
        exerciseId: bench.syncId,
        setIndex: 0,
        excludeWorkoutId: wC.syncId,
      );
      expect(r, isNotNull);
      expect(r!.actualReps, 7);
      expect(r.actualWeightKg, 82.5);
    });

    test('excludes the current workoutId', () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final w = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 5,
        actualWeightKg: 80,
      );
      await db.finishWorkout(w.syncId);

      final r = await db.lastCompletionForExerciseAtSetIndex(
        exerciseId: bench.syncId,
        setIndex: 0,
        excludeWorkoutId: w.syncId,
      );
      expect(r, isNull);
    });

    test('excludes unfinished workouts', () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final wInProg = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(wInProg.syncId);
      await db.upsertSetCompletion(
        workoutId: wInProg.syncId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 5,
        actualWeightKg: 80,
      );
      // Do NOT finish.

      // A separate in-progress workout queries.
      final wOther = await db.startWorkout(routine.syncId);
      final r = await db.lastCompletionForExerciseAtSetIndex(
        exerciseId: bench.syncId,
        setIndex: 0,
        excludeWorkoutId: wOther.syncId,
      );
      expect(r, isNull);
    });

    test('matches on setIndex', () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final w = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(w.syncId);
      final sets = snap!.exercises.single.sets;
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: sets[0].workoutSet.syncId,
        actualReps: 5,
        actualWeightKg: 80,
      );
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: sets[1].workoutSet.syncId,
        actualReps: 4,
        actualWeightKg: 80,
      );
      await db.finishWorkout(w.syncId);

      final wNext = await db.startWorkout(routine.syncId);
      final r0 = await db.lastCompletionForExerciseAtSetIndex(
        exerciseId: bench.syncId,
        setIndex: 0,
        excludeWorkoutId: wNext.syncId,
      );
      final r1 = await db.lastCompletionForExerciseAtSetIndex(
        exerciseId: bench.syncId,
        setIndex: 1,
        excludeWorkoutId: wNext.syncId,
      );
      expect(r0!.actualReps, 5);
      expect(r1!.actualReps, 4);
    });
  });

  group('findWorkoutImprovements / applyWorkoutImprovements', () {
    Future<({String workoutId, String exerciseId, String routineId, String reId})>
        seedSingleSet({
      int targetReps = 5,
      double targetWeightKg = 80,
    }) async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
      );
      final w = await db.startWorkout(routine.syncId);
      return (
        workoutId: w.syncId,
        exerciseId: bench.syncId,
        routineId: routine.syncId,
        reId: re.syncId,
      );
    }

    test('detects pure rep increase', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 6,
        actualWeightKg: 80,
      );
      final imps = await db.findWorkoutImprovements(s.workoutId);
      expect(imps, hasLength(1));
      expect(imps.single.oldReps, 5);
      expect(imps.single.newReps, 6);
      expect(imps.single.targetIsAlternative, isFalse);
    });

    test('detects pure weight increase', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 5,
        actualWeightKg: 82.5,
      );
      final imps = await db.findWorkoutImprovements(s.workoutId);
      expect(imps, hasLength(1));
      expect(imps.single.oldWeightKg, 80);
      expect(imps.single.newWeightKg, 82.5);
    });

    test('detects both reps + weight increase', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 6,
        actualWeightKg: 82.5,
      );
      final imps = await db.findWorkoutImprovements(s.workoutId);
      expect(imps, hasLength(1));
    });

    test('ignores equal performance and regressions', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      // Equal.
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 5,
        actualWeightKg: 80,
      );
      expect(await db.findWorkoutImprovements(s.workoutId), isEmpty);
      // Regression.
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 4,
        actualWeightKg: 80,
      );
      expect(await db.findWorkoutImprovements(s.workoutId), isEmpty);
    });

    test('ignores ambiguous swap (more reps, less weight)', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 8,
        actualWeightKg: 70,
      );
      expect(await db.findWorkoutImprovements(s.workoutId), isEmpty);
    });

    test('returns empty when routineId is null', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 6,
        actualWeightKg: 80,
      );
      await db.deleteRoutine(s.routineId);
      expect(await db.findWorkoutImprovements(s.workoutId), isEmpty);
    });

    test('skips ad-hoc exercises (routineExerciseId null)', () async {
      final bench = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final workout = await db.startWorkout(routine.syncId);

      // Ad-hoc add.
      final extra = await db.createExercise('Curl');
      final adhocWe = await db.addWorkoutExercise(
        workoutId: workout.syncId,
        exerciseId: extra.syncId,
      );
      final adhocWs = await db.addWorkoutSet(
        workoutExerciseId: adhocWe.syncId,
        targetReps: 10,
        targetWeightKg: 15,
      );
      await db.upsertSetCompletion(
        workoutId: workout.syncId,
        workoutSetId: adhocWs.syncId,
        actualReps: 12,
        actualWeightKg: 15,
      );
      final imps = await db.findWorkoutImprovements(workout.syncId);
      expect(imps.where((i) => i.exerciseName == 'Curl'), isEmpty);
    });

    test('time-kind: seconds increase detected, equal ignored', () async {
      final plank =
          await db.createExercise('Plank', kind: exerciseKindTime);
      final routine = await db.createRoutine('Core');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: plank.syncId,
      );
      await db.addPlannedSet(routineExerciseId: re.syncId, targetSeconds: 45);
      final w = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(w.syncId);

      // Equal.
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualSeconds: 45,
      );
      expect(await db.findWorkoutImprovements(w.syncId), isEmpty);

      // Improvement.
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: snap.exercises.single.sets.single.workoutSet.syncId,
        actualSeconds: 60,
      );
      final imps = await db.findWorkoutImprovements(w.syncId);
      expect(imps, hasLength(1));
      expect(imps.single.newSeconds, 60);
    });

    test('skips swapped-to alternative that has no planned sets', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );

      final w = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(w.syncId);
      final we = snap!.exercises.single.workoutExercise;
      await db.swapWorkoutExercise(
        workoutExerciseId: we.syncId,
        newExerciseId: dbBench.syncId,
      );
      // Targets still come from the primary's planned set (no alt sets).
      final after = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: after!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 8,
        actualWeightKg: 35,
      );
      expect(await db.findWorkoutImprovements(w.syncId), isEmpty);
    });

    test('hits alternative planned sets when present', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      final altPs = await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );

      final w = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(w.syncId);
      final we = snap!.exercises.single.workoutExercise;
      await db.swapWorkoutExercise(
        workoutExerciseId: we.syncId,
        newExerciseId: dbBench.syncId,
      );
      final after = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: after!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 13,
        actualWeightKg: 32.5,
      );
      final imps = await db.findWorkoutImprovements(w.syncId);
      expect(imps, hasLength(1));
      expect(imps.single.targetIsAlternative, isTrue);
      expect(imps.single.targetPlannedSetId, altPs.syncId);
    });

    test('apply updates primary planned set, idempotent', () async {
      final s = await seedSingleSet();
      final snap = await db.loadFullWorkout(s.workoutId);
      await db.upsertSetCompletion(
        workoutId: s.workoutId,
        workoutSetId: snap!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 7,
        actualWeightKg: 82.5,
      );
      await db.applyWorkoutImprovements(s.workoutId);

      final full = await db.loadFullRoutine(s.routineId);
      expect(full!.exercises.single.plannedSets.single.targetReps, 7);
      expect(full.exercises.single.plannedSets.single.targetWeightKg, 82.5);
      // Idempotent.
      expect(await db.findWorkoutImprovements(s.workoutId), isEmpty);
    });

    test('apply updates alternative planned set', () async {
      final bench = await db.createExercise('Bench');
      final dbBench = await db.createExercise('DB Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 5,
        targetWeightKg: 80,
      );
      final alt = await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: dbBench.syncId,
      );
      final altPs = await db.addAlternativePlannedSet(
        alternativeId: alt.syncId,
        targetReps: 12,
        targetWeightKg: 32.5,
      );

      final w = await db.startWorkout(routine.syncId);
      final snap = await db.loadFullWorkout(w.syncId);
      await db.swapWorkoutExercise(
        workoutExerciseId: snap!.exercises.single.workoutExercise.syncId,
        newExerciseId: dbBench.syncId,
      );
      final after = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: after!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 13,
        actualWeightKg: 35,
      );

      await db.applyWorkoutImprovements(w.syncId);

      final updated = await db.select(db.alternativePlannedSets).get();
      final row = updated.firstWhere((p) => p.syncId == altPs.syncId);
      expect(row.targetReps, 13);
      expect(row.targetWeightKg, 35);
    });
  });

  group('reorderRoutineExercises', () {
    test('rewrites orderIndex in the given order and bumps version', () async {
      final exA = await db.createExercise('A');
      final exB = await db.createExercise('B');
      final exC = await db.createExercise('C');
      final routine = await db.createRoutine('R');
      final reA = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: exA.syncId,
      );
      final reB = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: exB.syncId,
      );
      final reC = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: exC.syncId,
      );
      final before = await (db.select(db.routines)
            ..where((t) => t.syncId.equals(routine.syncId)))
          .getSingle();

      await db.reorderRoutineExercises(
        routineId: routine.syncId,
        orderedIds: [reC.syncId, reA.syncId, reB.syncId],
      );

      final rows = await (db.select(db.routineExercises)
            ..where((t) => t.routineId.equals(routine.syncId))
            ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
          .get();
      expect(rows.map((r) => r.syncId).toList(), [reC.syncId, reA.syncId, reB.syncId]);
      expect(rows.map((r) => r.orderIndex).toList(), [0, 1, 2]);

      final after = await (db.select(db.routines)
            ..where((t) => t.syncId.equals(routine.syncId)))
          .getSingle();
      expect(after.version, greaterThan(before.version));
    });

    test('preserves superset_group on members kept consecutive', () async {
      final exA = await db.createExercise('A');
      final exB = await db.createExercise('B');
      final exC = await db.createExercise('C');
      final routine = await db.createRoutine('R');
      final reA = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: exA.syncId,
      );
      final reB = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: exB.syncId,
      );
      final reC = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: exC.syncId,
      );
      // A is standalone; B and C form a superset.
      await db.setSupersetGroup(reB.syncId, 7);
      await db.setSupersetGroup(reC.syncId, 7);

      // Move the {B, C} group ahead of A — they remain consecutive.
      await db.reorderRoutineExercises(
        routineId: routine.syncId,
        orderedIds: [reB.syncId, reC.syncId, reA.syncId],
      );

      final rows = await (db.select(db.routineExercises)
            ..where((t) => t.routineId.equals(routine.syncId))
            ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
          .get();
      expect(rows[0].syncId, reB.syncId);
      expect(rows[0].supersetGroup, 7);
      expect(rows[1].syncId, reC.syncId);
      expect(rows[1].supersetGroup, 7);
      expect(rows[2].supersetGroup, isNull);
    });

    test('routineId guard rejects ids from a different routine', () async {
      final exA = await db.createExercise('A');
      final exB = await db.createExercise('B');
      final r1 = await db.createRoutine('R1');
      final r2 = await db.createRoutine('R2');
      final r1ea = await db.addExerciseToRoutine(
        routineId: r1.syncId,
        exerciseId: exA.syncId,
      );
      final r1eb = await db.addExerciseToRoutine(
        routineId: r1.syncId,
        exerciseId: exB.syncId,
      );
      final r2ea = await db.addExerciseToRoutine(
        routineId: r2.syncId,
        exerciseId: exA.syncId,
      );
      final r2eaBefore = r2ea.orderIndex;

      // Sneak r2ea.syncId into r1's reorder — should be ignored by the guard.
      await db.reorderRoutineExercises(
        routineId: r1.syncId,
        orderedIds: [r1eb.syncId, r2ea.syncId, r1ea.syncId],
      );

      final r2Row = await (db.select(db.routineExercises)
            ..where((t) => t.syncId.equals(r2ea.syncId)))
          .getSingle();
      expect(r2Row.orderIndex, r2eaBefore);
      expect(r2Row.routineId, r2.syncId);
    });
  });

  group('exercise tombstones (version-LWW)', () {
    test('deleteExercise hides from the library but keeps the row + bumps version',
        () async {
      final ex = await db.createExercise('Curl');
      final before = await (db.select(db.exercises)
            ..where((t) => t.syncId.equals(ex.syncId)))
          .getSingle();
      expect(before.version, 1);
      expect(before.deletedAt, isNull);

      await db.deleteExercise(ex.syncId);

      // Row survives as a tombstone with a bumped version.
      final after = await (db.select(db.exercises)
            ..where((t) => t.syncId.equals(ex.syncId)))
          .getSingle();
      expect(after.deletedAt, isNotNull);
      expect(after.version, greaterThan(before.version));

      // Hidden from both library reads.
      expect(await db.watchExercises().first, isEmpty);
      expect(await db.loadExercisesWithMuscles(), isEmpty);
    });

    test('rename / setKind / setMuscles each bump the version', () async {
      final ex = await db.createExercise('Curl');
      final m = await (db.select(db.muscles)..limit(1)).getSingle();

      await db.renameExercise(ex.syncId, 'Bicep Curl');
      final v1 = (await (db.select(db.exercises)
                ..where((t) => t.syncId.equals(ex.syncId)))
              .getSingle())
          .version;
      expect(v1, greaterThan(1));

      await db.setExerciseKind(ex.syncId, exerciseKindTime);
      final v2 = (await (db.select(db.exercises)
                ..where((t) => t.syncId.equals(ex.syncId)))
              .getSingle())
          .version;
      expect(v2, greaterThan(v1));

      await db.setExerciseMuscles(ex.syncId, [m.syncId]);
      final v3 = (await (db.select(db.exercises)
                ..where((t) => t.syncId.equals(ex.syncId)))
              .getSingle())
          .version;
      expect(v3, greaterThan(v2));
    });

    test('a tombstoned exercise still resolves inside a routine', () async {
      final ex = await db.createExercise('Curl');
      final routine = await db.createRoutine('Arms');
      await db.addExerciseToRoutine(routineId: routine.syncId, exerciseId: ex.syncId);

      await db.deleteExercise(ex.syncId);

      // The library hides it, but the routine join must still render it.
      final full = await db.loadFullRoutine(routine.syncId);
      expect(full!.exercises.single.exercise.syncId, ex.syncId);
      expect(full.exercises.single.exercise.name, 'Curl');
    });
  });
}

