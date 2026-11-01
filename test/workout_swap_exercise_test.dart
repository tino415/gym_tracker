import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/history/workout_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Swapping which exercise a workout slot records — "the bench was taken, I did
/// dumbbell press instead". The sets already say what happened, so they ride
/// along untouched; only the exercise changes.
void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  /// A finished workout with one exercise carrying [sets] sets, the first of
  /// them completed.
  Future<(Workout, FullWorkoutExercise)> seedWorkout({
    String exerciseName = 'Bench Press',
    String kind = exerciseKindReps,
    int sets = 2,
  }) async {
    final ex = await db.createExercise(exerciseName, kind: kind);
    final w = await db.createWorkout(
      startedAt: DateTime(2026, 3, 4, 18),
      endedAt: DateTime(2026, 3, 4, 19),
    );
    final we = await db.addWorkoutExercise(
      workoutId: w.syncId,
      exerciseId: ex.syncId,
    );
    for (var i = 0; i < sets; i++) {
      await db.addWorkoutSet(
        workoutExerciseId: we.syncId,
        targetReps: 8,
        targetWeightKg: 60,
      );
    }
    final full = await db.loadFullWorkout(w.syncId);
    final fwe = full!.exercises.single;
    await db.upsertSetCompletion(
      workoutId: w.syncId,
      workoutSetId: fwe.sets.first.workoutSet.syncId,
      actualReps: 9,
      actualWeightKg: 62.5,
    );
    return (w, fwe);
  }

  group('changeWorkoutExercise', () {
    test('adopts the new exercise, keeping sets and completions', () async {
      final (w, fwe) = await seedWorkout();
      final replacement = await db.createExercise('Dumbbell Press');

      await db.changeWorkoutExercise(
        workoutExerciseId: fwe.workoutExercise.syncId,
        exerciseId: replacement.syncId,
      );

      final full = await db.loadFullWorkout(w.syncId);
      final after = full!.exercises.single;
      expect(after.workoutExercise.exerciseId, replacement.syncId);
      expect(after.workoutExercise.exerciseName, 'Dumbbell Press');
      // Untouched: the sets are the record of what was actually done.
      expect(after.sets, hasLength(2));
      expect(after.sets.first.workoutSet.targetReps, 8);
      expect(after.sets.first.completion?.actualReps, 9);
      expect(after.sets.first.completion?.actualWeightKg, 62.5);
    });

    test('moves the slot\'s history to the new exercise', () async {
      final (w, fwe) = await seedWorkout();
      final bench = fwe.workoutExercise.exerciseId!;
      final replacement = await db.createExercise('Dumbbell Press');

      await db.changeWorkoutExercise(
        workoutExerciseId: fwe.workoutExercise.syncId,
        exerciseId: replacement.syncId,
      );

      Future<SetCompletion?> lastOf(String exerciseId) =>
          db.lastCompletionForExerciseAtSetIndex(
            routineExerciseId: null,
            exerciseId: exerciseId,
            setIndex: 0,
            excludeWorkoutId: 'another workout',
          );
      expect((await lastOf(replacement.syncId))?.workoutId, w.syncId);
      expect(await lastOf(bench), null);
    });

    test('adopts the new exercise kind', () async {
      final (w, fwe) = await seedWorkout();
      final hold = await db.createExercise('Plank', kind: exerciseKindTime);

      await db.changeWorkoutExercise(
        workoutExerciseId: fwe.workoutExercise.syncId,
        exerciseId: hold.syncId,
      );

      final full = await db.loadFullWorkout(w.syncId);
      expect(full!.exercises.single.kind, exerciseKindTime);
    });

    test('bumps the workout version so the edit syncs', () async {
      final (w, fwe) = await seedWorkout();
      final replacement = await db.createExercise('Dumbbell Press');
      final before = (await db.watchRecentWorkouts().first)
          .firstWhere((x) => x.syncId == w.syncId)
          .version;

      await db.changeWorkoutExercise(
        workoutExerciseId: fwe.workoutExercise.syncId,
        exerciseId: replacement.syncId,
      );

      final after = (await db.watchRecentWorkouts().first)
          .firstWhere((x) => x.syncId == w.syncId)
          .version;
      expect(after, greaterThan(before));
    });

    test('an unknown exercise changes nothing', () async {
      final (w, fwe) = await seedWorkout();

      await db.changeWorkoutExercise(
        workoutExerciseId: fwe.workoutExercise.syncId,
        exerciseId: 'does-not-exist',
      );

      final full = await db.loadFullWorkout(w.syncId);
      expect(full!.exercises.single.workoutExercise.exerciseName, 'Bench Press');
    });
  });

  group('workout editor', () {
    Future<void> pumpDetail(WidgetTester tester, String workoutId) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(home: WorkoutDetailPage(workoutId: workoutId)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> disposeTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    testWidgets('swapping from the picker rewrites the exercise',
        (tester) async {
      final (w, _) = await seedWorkout();
      await db.createExercise('Dumbbell Press');
      await pumpDetail(tester, w.syncId);

      await tester.tap(find.byTooltip('Swap exercise'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dumbbell Press'));
      await tester.pumpAndSettle();

      expect(find.text('Dumbbell Press'), findsOneWidget);
      expect(find.text('Bench Press'), findsNothing);

      await disposeTree(tester);
    });

    testWidgets('a bodyweight set shows reps, not "0 kg"', (tester) async {
      // Reps with no weight is a legitimate set — pull-ups, leg raises. The
      // target used to render as nothing at all and the actual as "0 kg × n".
      final ex = await db.createExercise('Hanging Leg Raise');
      final w = await db.createWorkout(
        startedAt: DateTime(2026, 3, 4, 18),
        endedAt: DateTime(2026, 3, 4, 19),
      );
      final we = await db.addWorkoutExercise(
        workoutId: w.syncId,
        exerciseId: ex.syncId,
      );
      await db.addWorkoutSet(workoutExerciseId: we.syncId, targetReps: 12);
      final full = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: full!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 14,
      );

      await pumpDetail(tester, w.syncId);

      expect(find.text('14 reps'), findsOneWidget);
      expect(find.text('target 12 reps'), findsOneWidget);
      expect(find.textContaining('0 kg'), findsNothing);

      await disposeTree(tester);
    });

    testWidgets('a weighted set still shows weight × reps', (tester) async {
      final (w, _) = await seedWorkout();

      await pumpDetail(tester, w.syncId);

      // seedWorkout completes the first of two sets at 62.5 kg × 9; both carry
      // the same 60 × 8 target.
      expect(find.text('62.5 kg × 9'), findsOneWidget);
      expect(find.text('target 60 kg × 8'), findsNWidgets(2));

      await disposeTree(tester);
    });

    testWidgets('the picker offers only the same kind', (tester) async {
      final (w, _) = await seedWorkout();
      await db.createExercise('Dumbbell Press');
      await db.createExercise('Plank', kind: exerciseKindTime);
      await pumpDetail(tester, w.syncId);

      await tester.tap(find.byTooltip('Swap exercise'));
      await tester.pumpAndSettle();

      // Reps slot: a time-kind exercise would leave every target blank, since
      // the sets carry over unchanged.
      expect(find.text('Dumbbell Press'), findsOneWidget);
      expect(find.text('Plank'), findsNothing);
      // The picker opens over the editor, so the slot's own heading is still on
      // screen behind it — one occurrence means the picker did not also list
      // it, i.e. you cannot swap an exercise for itself.
      expect(find.text('Bench Press'), findsOneWidget);

      await disposeTree(tester);
    });
  });
}
