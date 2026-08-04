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
