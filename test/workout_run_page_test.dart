import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/run/workout_run_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live workout running on the phone. The page mirrors the watch run page's
/// lifecycle but is built on the repository seam.
void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  /// A routine of `name -> list of (reps, kg)` sets, optionally in a circuit
  /// group, with a known rest so the rest phase is observable.
  Future<Routine> seedRoutine({
    required String name,
    required List<({String exercise, List<(int, double)> sets, int? group})>
        exercises,
    int restSeconds = 90,
    // Per-exercise rest, positional; falls back to [restSeconds]. Rest is a
    // per-exercise value now, so a circuit needs to set its members apart.
    List<int>? restPerExercise,
  }) async {
    final routine = await db.createRoutine(name);
    for (var i = 0; i < exercises.length; i++) {
      final fx = exercises[i];
      final ex = await db.createExercise(fx.exercise);
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.setRestSeconds(re.syncId, restPerExercise?[i] ?? restSeconds);
      if (fx.group != null) await db.setCircuitGroup(re.syncId, fx.group);
      for (final s in fx.sets) {
        await db.addPlannedSet(
          routineExerciseId: re.syncId,
          targetReps: s.$1,
          targetWeightKg: s.$2,
        );
      }
    }
    return routine;
  }

  /// Pumps a few frames without `pumpAndSettle` — the rest phase runs a
  /// periodic ticker, so settling would time out.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpRun(
    WidgetTester tester, {
    String? routineId,
    String? resumeWorkoutId,
  }) async {
    final router = GoRouter(
      initialLocation: routineId != null
          ? '/run/$routineId'
          : '/run/resume/$resumeWorkoutId',
      routes: [
        GoRoute(
          path: '/run/resume/:workoutId',
          builder: (context, state) => WorkoutRunPage(
            resumeWorkoutId: state.pathParameters['workoutId']!,
          ),
        ),
        GoRoute(
          path: '/run/:routineId',
          builder: (context, state) => WorkoutRunPage(
            routineId: state.pathParameters['routineId']!,
          ),
        ),
        GoRoute(
          path: '/history/:id',
          builder: (context, state) =>
              Text('HISTORY:${state.pathParameters['id']}'),
        ),
        GoRoute(path: '/routines', builder: (_, _) => const Text('ROUTINES')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await settle(tester);
  }

  /// Unmount so the run page's periodic ticker is cancelled; otherwise the test
  /// ends with a pending timer.
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  /// Reads of drift *streams* must run under [WidgetTester.runAsync] — direct
  /// awaits on real-time IO don't progress under the widget tester's fake
  /// clock, and `.first` would hang forever. Plain futures like
  /// `loadFullWorkout` are fine awaited directly.
  Future<Workout> onlyWorkout(WidgetTester tester) async {
    final list = await tester.runAsync(() => db.watchRecentWorkouts().first);
    expect(list, hasLength(1));
    return list!.single;
  }

  /// The current-exercise heading. `find.text` alone is ambiguous — the same
  /// name also appears in the overview strip along the bottom.
  String currentExercise(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('runExerciseName'))).data!;

  Future<List<SetCompletion>> completionsOf(String workoutId) async {
    final full = await db.loadFullWorkout(workoutId);
    return [
      for (final e in full!.exercises)
        for (final s in e.sets)
          if (s.completion != null) s.completion!,
    ];
  }

  testWidgets('starting a routine snapshots it and seeds the first set',
      (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0), (8, 60.0)], group: null),
      ],
    );
    await pumpRun(tester, routineId: r.syncId);

    // The workout is created from the routine, with the snapshot copied over.
    final w = await onlyWorkout(tester);
    expect(w.routineId, r.syncId);
    expect(w.endedAt, isNull);
    final full = await db.loadFullWorkout(w.syncId);
    expect(full!.exercises.single.sets, hasLength(2));

    expect(find.text('Push'), findsOneWidget);
    expect(currentExercise(tester), 'Bench');
    expect(find.text('Set 1 of 2'), findsOneWidget);
    // Inputs seed from the target, not from zero.
    expect(find.text('8'), findsOneWidget);
    expect(find.text('60 kg'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('completing a set records actuals and starts a rest',
      (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0), (8, 60.0)], group: null),
      ],
    );
    await pumpRun(tester, routineId: r.syncId);

    // Nudge the reps up so the recorded value is distinguishable from the
    // target — the run page logs what was performed, not what was planned.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add).first);
    await settle(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);

    final w = await onlyWorkout(tester);
    final completions = await completionsOf(w.syncId);
    expect(completions, hasLength(1));
    expect(completions.single.actualReps, 9);
    expect(completions.single.actualWeightKg, 60.0);

    // A new set of the same exercise rests first.
    expect(find.text('Rest'), findsOneWidget);
    expect(find.text('Skip rest'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('a zero rest on a circuit member advances straight to the next',
      (tester) async {
    // The classic superset: no pause between the two members, one rest at the
    // end of the round. Expressed now as rest 0 on the first member.
    final r = await seedRoutine(
      name: 'Upper',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0), (8, 60.0)], group: 1),
        (exercise: 'Row', sets: [(8, 50.0), (8, 50.0)], group: 1),
      ],
      restPerExercise: [0, 90],
    );
    await pumpRun(tester, routineId: r.syncId);
    expect(currentExercise(tester), 'Bench');

    // Same round, next member: straight there, no rest.
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Rest'), findsNothing);
    expect(currentExercise(tester), 'Row');
    // Still round one — the alternation moved sideways, not on to the next set.
    expect(find.text('Set 1 of 2 • circuit'), findsOneWidget);

    // End of the round: Row's own rest runs before round two.
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Rest'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('a circuit member with a rest pauses before the next member',
      (tester) async {
    // What a left/right pair needs: a short pause between the sides, the full
    // rest after the round. Before rest became per-exercise this was
    // unexpressible — the value was read off the first member and applied only
    // between rounds.
    final r = await seedRoutine(
      name: 'Arms',
      exercises: [
        (exercise: 'Curl L', sets: [(8, 12.0), (8, 12.0)], group: 1),
        (exercise: 'Curl R', sets: [(8, 12.0), (8, 12.0)], group: 1),
      ],
      restPerExercise: [30, 90],
    );
    await pumpRun(tester, routineId: r.syncId);
    expect(currentExercise(tester), 'Curl L');

    // Left side done: rest before the right side, still inside round one.
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Rest'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);

    await tester.tap(find.text('Skip rest'));
    await settle(tester);
    expect(currentExercise(tester), 'Curl R');
    expect(find.text('Set 1 of 2 • circuit'), findsOneWidget);

    // Right side done: the round rest, which is the right side's own value.
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Rest'), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('a snapshot emission during rest does not reset the timer',
      (tester) async {
    // Regression guard for the _initialLoadDone gate: only the first emission
    // may seed position and reload targets. Without it a concurrent write —
    // a sync push, a rename — would cancel an active rest.
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0), (8, 60.0)], group: null),
      ],
      restSeconds: 120,
    );
    await pumpRun(tester, routineId: r.syncId);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Rest'), findsOneWidget);
    final restBefore = find.text('2:00');
    expect(restBefore, findsOneWidget);

    // Something else writes to the workout — exactly what a sync apply does.
    final w = await onlyWorkout(tester);
    await db.updateWorkoutTimes(
      workoutId: w.syncId,
      startedAt: w.startedAt.subtract(const Duration(minutes: 5)),
      endedAt: null,
    );
    await settle(tester);

    // Still resting, still the same countdown, not bounced back to set 1.
    expect(find.text('Rest'), findsOneWidget);
    expect(find.text('2:00'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('a running hold keeps counting while other sets are open',
      (tester) async {
    final routine = await db.createRoutine('Core');
    final plank = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: (await db.createExercise('Plank', kind: exerciseKindTime))
          .syncId,
    );
    await db.addPlannedSet(routineExerciseId: plank.syncId, targetSeconds: 45);
    await db.addPlannedSet(routineExerciseId: plank.syncId, targetSeconds: 45);
    final raise = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: (await db.createExercise('Leg Raise')).syncId,
    );
    await db.addPlannedSet(routineExerciseId: raise.syncId, targetReps: 10);
    await pumpRun(tester, routineId: routine.syncId);

    await tester.tap(find.text('Start timer'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('0:42'), findsOneWidget);

    await tester.tap(find.text('1').first);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:41'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);

    await tester.tap(find.text('1').last);
    await tester.pump(const Duration(seconds: 2));
    expect(currentExercise(tester), 'Leg Raise');
    expect(find.text('Plank timer 0:39'), findsOneWidget);

    await tester.tap(find.text('Plank timer 0:39'));
    await tester.pump(const Duration(seconds: 1));
    expect(currentExercise(tester), 'Plank');
    expect(find.text('0:38'), findsOneWidget);

    await tester.ensureVisible(find.text('Done'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await settle(tester);
    final w = await onlyWorkout(tester);
    expect((await completionsOf(w.syncId)).single.actualSeconds, 7);

    await disposeTree(tester);
  });

  testWidgets('a time set adjusts its target seconds, running or not',
      (tester) async {
    final routine = await db.createRoutine('Core');
    final plank = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: (await db.createExercise('Plank', kind: exerciseKindTime))
          .syncId,
    );
    await db.addPlannedSet(routineExerciseId: plank.syncId, targetSeconds: 45);
    final raise = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: (await db.createExercise('Leg Raise')).syncId,
    );
    await db.addPlannedSet(routineExerciseId: raise.syncId, targetReps: 10);
    await pumpRun(tester, routineId: routine.syncId);

    await tester.tap(find.byTooltip('Increase Time'));
    await tester.pump();
    expect(find.text('0:50'), findsNWidgets(2));

    await tester.tap(find.text('Start timer'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('0:47'), findsOneWidget);

    await tester.tap(find.byTooltip('Increase Time'));
    await tester.pump();
    expect(find.text('0:52'), findsOneWidget);
    expect(find.text('0:55'), findsOneWidget);

    await tester.tap(find.text('1').last);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Plank timer 0:50'), findsOneWidget);

    await tester.tap(find.text('Plank timer 0:50'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:55'), findsOneWidget);
    expect(find.text('0:49'), findsOneWidget);

    await tester.ensureVisible(find.text('Done'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await settle(tester);
    final w = await onlyWorkout(tester);
    expect((await completionsOf(w.syncId)).single.actualSeconds, 6);

    await disposeTree(tester);
  });

  testWidgets('a time target cannot drop below one step', (tester) async {
    final routine = await db.createRoutine('Core');
    final plank = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: (await db.createExercise('Plank', kind: exerciseKindTime))
          .syncId,
    );
    await db.addPlannedSet(routineExerciseId: plank.syncId, targetSeconds: 10);
    await pumpRun(tester, routineId: routine.syncId);

    await tester.tap(find.byTooltip('Decrease Time'));
    await tester.pump();
    expect(find.text('0:05'), findsNWidgets(2));
    final decrease = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Decrease Time'),
        matching: find.byType(IconButton),
      ),
    );
    expect(decrease.onPressed, isNull);

    await disposeTree(tester);
  });

  testWidgets('resume picks up at the first incomplete set', (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0), (8, 60.0), (8, 60.0)], group: null),
      ],
    );
    final w = await db.startWorkout(r.syncId);
    final full = await db.loadFullWorkout(w.syncId);
    // First set already logged in an earlier part of the session.
    await db.upsertSetCompletion(
      workoutId: w.syncId,
      workoutSetId: full!.exercises.single.sets.first.workoutSet.syncId,
      actualReps: 8,
      actualWeightKg: 60,
    );

    await pumpRun(tester, resumeWorkoutId: w.syncId);

    expect(find.text('Set 2 of 3'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('last time actuals are shown for a repeated set', (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0)], group: null),
      ],
    );
    // A finished session where the first set was done at a different weight.
    final past = await db.startWorkout(r.syncId);
    final pastFull = await db.loadFullWorkout(past.syncId);
    await db.upsertSetCompletion(
      workoutId: past.syncId,
      workoutSetId: pastFull!.exercises.single.sets.first.workoutSet.syncId,
      actualReps: 7,
      actualWeightKg: 55,
    );
    await db.updateWorkoutTimes(
      workoutId: past.syncId,
      startedAt: DateTime(2026, 7, 1, 18),
      endedAt: DateTime(2026, 7, 1, 19),
    );

    await pumpRun(tester, routineId: r.syncId);

    expect(find.text('Last time  7 × 55 kg'), findsOneWidget);
    // The target still drives the inputs; last time is a reference only.
    expect(find.text('Target  8 × 60 kg'), findsOneWidget);
    expect(find.text('60 kg'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('last time of an exercise listed twice is the entry being run', (
    tester,
  ) async {
    final bench = await db.createExercise('Bench');
    final routine = await db.createRoutine('Heavy and light');
    for (final reps in [5, 12]) {
      final slot = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: bench.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: slot.syncId,
        targetReps: reps,
        targetWeightKg: 60,
      );
    }
    final past = await db.startWorkout(routine.syncId);
    final entries = (await db.loadFullWorkout(past.syncId))!.exercises;
    for (final (entry, reps) in [(entries[1], 11), (entries[0], 4)]) {
      await db.upsertSetCompletion(
        workoutId: past.syncId,
        workoutSetId: entry.sets.single.workoutSet.syncId,
        actualReps: reps,
        actualWeightKg: 60,
      );
    }
    await db.updateWorkoutTimes(
      workoutId: past.syncId,
      startedAt: DateTime(2026, 7, 1, 18),
      endedAt: DateTime(2026, 7, 1, 19),
    );

    await pumpRun(tester, routineId: routine.syncId);

    expect(find.text('Last time  4 × 60 kg'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('finish stamps endedAt and lands on the workout in history',
      (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0)], group: null),
      ],
    );
    await pumpRun(tester, routineId: r.syncId);
    await tester.tap(find.text('Done'));
    await settle(tester);

    await tester.tap(find.text('Finish'));
    await settle(tester);

    final w = await onlyWorkout(tester);
    expect(w.endedAt, isNotNull);
    expect(find.text('HISTORY:${w.syncId}'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('finishing with unlogged sets asks first', (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0), (8, 60.0)], group: null),
      ],
    );
    await pumpRun(tester, routineId: r.syncId);

    await tester.tap(find.text('Finish'));
    await settle(tester);
    expect(find.text('Finish workout?'), findsOneWidget);
    expect(find.text('2 sets are still unlogged.'), findsOneWidget);

    // Backing out leaves the session running.
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect((await onlyWorkout(tester)).endedAt, isNull);

    await disposeTree(tester);
  });

  testWidgets('discard tombstones the workout', (tester) async {
    final r = await seedRoutine(
      name: 'Push',
      exercises: [
        (exercise: 'Bench', sets: [(8, 60.0)], group: null),
      ],
    );
    await pumpRun(tester, routineId: r.syncId);

    await tester.tap(find.byIcon(Icons.more_vert));
    await settle(tester);
    await tester.tap(find.text('Discard workout'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settle(tester);

    // A tombstone is hidden from every read, including the resume check.
    expect(await tester.runAsync(() => db.watchRecentWorkouts().first), isEmpty);
    expect(
      await tester.runAsync(() => db.watchInProgressWorkout().first),
      isNull,
    );
    expect(find.text('ROUTINES'), findsOneWidget);

    await disposeTree(tester);
  });
}
