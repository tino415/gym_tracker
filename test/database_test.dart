import 'package:drift/drift.dart' show Value;
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
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 10,
        targetWeightKg: 60.0,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 8,
        targetWeightKg: 62.5,
      );

      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);

      expect(snap, isNotNull);
      expect(snap!.workout.routineId, routine.id);
      expect(snap.exercises, hasLength(1));
      expect(snap.exercises.single.workoutExercise.exerciseName, 'Bench Press');
      expect(snap.exercises.single.kind, exerciseKindReps);
      expect(snap.exercises.single.sets, hasLength(2));
      expect(snap.exercises.single.sets[0].workoutSet.targetReps, 10);
      expect(snap.exercises.single.sets[0].workoutSet.targetWeightKg, 60.0);
      expect(snap.exercises.single.sets[1].workoutSet.targetReps, 8);
    });

    test('captures superset_group and exercise kind', () async {
      final bench = await db.createExercise('Bench');
      final fly = await db.createExercise('Fly');
      final routine = await db.createRoutine('Push');
      final reBench = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: bench.id,
      );
      final reFly = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: fly.id,
      );
      await db.addPlannedSet(
        routineExerciseId: reBench.id,
        targetReps: 5,
        targetWeightKg: 80,
      );
      await db.addPlannedSet(
        routineExerciseId: reFly.id,
        targetReps: 12,
        targetWeightKg: 12,
      );
      await db.setSupersetGroup(reBench.id, 1);
      await db.setSupersetGroup(reFly.id, 1);

      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);

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
        routineId: routine.id,
        exerciseId: plank.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetSeconds: 45,
        targetWeightKg: 5.0,
      );

      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);
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
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 5,
        targetWeightKg: 100,
      );
      final workout = await db.startWorkout(routine.id);

      await db.deleteRoutine(routine.id);

      final snap = await db.loadFullWorkout(workout.id);
      expect(snap, isNotNull);
      expect(snap!.routine, isNull);
      expect(snap.workout.routineId, isNull);
      expect(snap.exercises, hasLength(1));
      expect(snap.exercises.single.workoutExercise.exerciseName, 'Squat');
      expect(snap.exercises.single.sets, hasLength(1));
    });

    test('deleting the underlying exercise nulls exercise_id but keeps name',
        () async {
      final ex = await db.createExercise('Curl');
      final routine = await db.createRoutine('Arms');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 12,
        targetWeightKg: 15,
      );
      final workout = await db.startWorkout(routine.id);

      // RESTRICT on routine_exercises.exercise_id prevents this while the
      // routine references it; drop the routine first.
      await db.deleteRoutine(routine.id);
      await db.deleteExercise(ex.id);

      final snap = await db.loadFullWorkout(workout.id);
      expect(snap, isNotNull);
      expect(snap!.exercises.single.workoutExercise.exerciseId, isNull);
      expect(snap.exercises.single.workoutExercise.exerciseName, 'Curl');
    });
  });

  group('completions', () {
    test('upsert for reps then update', () async {
      final ex = await db.createExercise('Deadlift');
      final routine = await db.createRoutine('Pull');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 5,
        targetWeightKg: 100,
      );
      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);
      final wsId = snap!.exercises.single.sets.single.workoutSet.id;

      await db.upsertSetCompletion(
        workoutId: workout.id,
        workoutSetId: wsId,
        actualReps: 5,
        actualWeightKg: 100.0,
      );
      await db.upsertSetCompletion(
        workoutId: workout.id,
        workoutSetId: wsId,
        actualReps: 4,
        actualWeightKg: 102.5,
      );

      final cs = await db.completionsForWorkout(workout.id);
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
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(routineExerciseId: re.id, targetSeconds: 60);
      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);
      final wsId = snap!.exercises.single.sets.single.workoutSet.id;

      await db.upsertSetCompletion(
        workoutId: workout.id,
        workoutSetId: wsId,
        actualSeconds: 75,
        actualWeightKg: 24.0,
      );

      final cs = await db.completionsForWorkout(workout.id);
      expect(cs.single.actualSeconds, 75);
      expect(cs.single.actualWeightKg, 24.0);
      expect(cs.single.actualReps, isNull);
    });

    test('deleteSetCompletionFor removes the row', () async {
      final ex = await db.createExercise('Row');
      final routine = await db.createRoutine('Pull');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 10,
        targetWeightKg: 40,
      );
      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);
      final wsId = snap!.exercises.single.sets.single.workoutSet.id;

      await db.upsertSetCompletion(
        workoutId: workout.id,
        workoutSetId: wsId,
        actualReps: 10,
        actualWeightKg: 40,
      );
      expect(await db.completionsForWorkout(workout.id), hasLength(1));

      await db.deleteSetCompletionFor(
        workoutId: workout.id,
        workoutSetId: wsId,
      );
      expect(await db.completionsForWorkout(workout.id), isEmpty);
    });
  });

  group('workout edit (history page)', () {
    test('addWorkoutExercise + addWorkoutSet + completion round-trip',
        () async {
      final ex = await db.createExercise('Pullup');
      final routine = await db.createRoutine('Back');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 6,
        targetWeightKg: 0,
      );
      final workout = await db.startWorkout(routine.id);

      // Add an exercise after the fact.
      final extra = await db.createExercise('Chinup');
      final we = await db.addWorkoutExercise(
        workoutId: workout.id,
        exerciseId: extra.id,
      );
      final ws = await db.addWorkoutSet(
        workoutExerciseId: we.id,
        targetReps: 8,
        targetWeightKg: 0,
      );
      await db.upsertSetCompletion(
        workoutId: workout.id,
        workoutSetId: ws.id,
        actualReps: 8,
        actualWeightKg: 0,
      );

      final snap = await db.loadFullWorkout(workout.id);
      expect(snap!.exercises, hasLength(2));
      expect(snap.exercises[1].workoutExercise.exerciseName, 'Chinup');
      expect(snap.exercises[1].sets.single.completion?.actualReps, 8);
    });

    test('updateWorkoutTimes persists started/ended', () async {
      final ex = await db.createExercise('Press');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 5,
        targetWeightKg: 50,
      );
      final workout = await db.startWorkout(routine.id);

      final newStart = DateTime(2026, 5, 1, 9, 0);
      final newEnd = DateTime(2026, 5, 1, 10, 15);
      await db.updateWorkoutTimes(
        workoutId: workout.id,
        startedAt: newStart,
        endedAt: newEnd,
      );

      final snap = await db.loadFullWorkout(workout.id);
      expect(snap!.workout.startedAt, newStart);
      expect(snap.workout.endedAt, newEnd);
    });
  });

  group('heart-rate persistence', () {
    test('upsertSetCompletion writes avg/max on insert', () async {
      final ex = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 5,
        targetWeightKg: 60,
      );
      final workout = await db.startWorkout(routine.id);
      final snap = await db.loadFullWorkout(workout.id);
      final ws = snap!.exercises.single.sets.single.workoutSet;

      await db.upsertSetCompletion(
        workoutId: workout.id,
        workoutSetId: ws.id,
        actualReps: 5,
        actualWeightKg: 60,
        avgHeartRate: const Value(125),
        maxHeartRate: const Value(148),
      );

      final completions = await db.completionsForWorkout(workout.id);
      expect(completions.single.avgHeartRate, 125);
      expect(completions.single.maxHeartRate, 148);
    });

    test(
      'upsertSetCompletion with absent HR preserves prior values on update',
      () async {
        final ex = await db.createExercise('Bench');
        final routine = await db.createRoutine('Push');
        final re = await db.addExerciseToRoutine(
          routineId: routine.id,
          exerciseId: ex.id,
        );
        await db.addPlannedSet(
          routineExerciseId: re.id,
          targetReps: 5,
          targetWeightKg: 60,
        );
        final workout = await db.startWorkout(routine.id);
        final snap = await db.loadFullWorkout(workout.id);
        final ws = snap!.exercises.single.sets.single.workoutSet;

        await db.upsertSetCompletion(
          workoutId: workout.id,
          workoutSetId: ws.id,
          actualReps: 5,
          actualWeightKg: 60,
          avgHeartRate: const Value(130),
          maxHeartRate: const Value(150),
        );
        // Re-toggle without providing HR — existing values must survive.
        await db.upsertSetCompletion(
          workoutId: workout.id,
          workoutSetId: ws.id,
          actualReps: 6,
          actualWeightKg: 60,
        );

        final completions = await db.completionsForWorkout(workout.id);
        expect(completions.single.actualReps, 6);
        expect(completions.single.avgHeartRate, 130);
        expect(completions.single.maxHeartRate, 150);
      },
    );

    test('finishWorkout writes avg/max', () async {
      final ex = await db.createExercise('Bench');
      final routine = await db.createRoutine('Push');
      final re = await db.addExerciseToRoutine(
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 5,
        targetWeightKg: 60,
      );
      final workout = await db.startWorkout(routine.id);

      await db.finishWorkout(
        workout.id,
        avgHeartRate: 132,
        maxHeartRate: 162,
      );

      final after = await db.loadFullWorkout(workout.id);
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
        routineId: routine.id,
        exerciseId: ex.id,
      );
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: 5,
        targetWeightKg: 40,
      );
      return db.startWorkout(routine.id);
    }

    test('emits null when no workouts have been started', () async {
      expect(await db.watchInProgressWorkout().first, isNull);
    });

    test('emits the started workout, then null after finish', () async {
      final stream = db.watchInProgressWorkout();
      final w = await seedWorkout(db, 'A');

      final first = await stream.first;
      expect(first?.id, w.id);

      await db.finishWorkout(w.id);
      final next = await stream.first;
      expect(next, isNull);
    });

    test('returns most recent when multiple in-progress workouts exist',
        () async {
      final older = await seedWorkout(db, 'older');
      // Force a distinct startedAt so ordering is deterministic.
      await db.updateWorkoutTimes(
        workoutId: older.id,
        startedAt: DateTime(2024, 1, 1),
        endedAt: null,
      );
      final newer = await seedWorkout(db, 'newer');

      final w = await db.watchInProgressWorkout().first;
      expect(w?.id, newer.id);
    });
  });
}
