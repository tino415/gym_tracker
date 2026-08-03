// The phone run flow end to end, on a device/emulator:
//   just e2e-run phone      (or: flutter test integration_test/run_flow_test.dart -d <device>)
//
// Covers what was previously only checked by hand: opening a routine, starting
// a workout from it, logging sets, the superset alternation rule (a mate in the
// same round follows immediately, anything else rests first), finishing, and
// the workout landing in the database. The DB is an in-memory override, so the
// run is deterministic and touches no real data.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/phone_app.dart';
import 'package:gym_tracker/sync/workout_bridge.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // On-device runs don't set FLUTTER_TEST, so without this the run page would
  // start the real foreground workout service. Nothing here needs it, and a
  // stray notification outliving the test is just noise.
  setUpAll(() => WorkoutBridge.debugSkipPlatformCalls = true);

  // Pump real frames until [finder] matches rather than pumpAndSettle: the run
  // page holds a periodic ticker during rest and the list pages watch live
  // Drift streams, so settling can spin forever.
  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 100}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  String currentExercise(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('runExerciseName'))).data!;

  /// Pumps until the run page's *heading* reads [name].
  ///
  /// Not `pumpUntil(find.text(name))`: every exercise name is also in the
  /// overview strip along the bottom, so that matches from the moment the
  /// workout starts and would wave the test through mid-rest — when the
  /// heading isn't built at all and reading it throws.
  Future<void> pumpUntilExercise(WidgetTester tester, String name,
      {int maxPumps = 100}) async {
    final heading = find.byKey(const Key('runExerciseName'));
    for (var i = 0; i < maxPumps; i++) {
      if (heading.evaluate().isNotEmpty &&
          tester.widget<Text>(heading).data == name) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for the run page to show "$name"');
  }

  /// Bench (2 sets), then a superset pair of Fly + Pushdown (1 set each).
  Future<void> seed(AppDatabase db) async {
    final routine = await db.createRoutine('E2E Push');
    Future<void> slot(String name, {required int sets, int? group}) async {
      final ex = await db.createExercise(name);
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.setRestSeconds(re.syncId, 90);
      if (group != null) await db.setSupersetGroup(re.syncId, group);
      for (var i = 0; i < sets; i++) {
        await db.addPlannedSet(
          routineExerciseId: re.syncId,
          targetReps: 8,
          targetWeightKg: 40,
        );
      }
    }

    await slot('Bench Press', sets: 2);
    await slot('Cable Fly', sets: 1, group: 1);
    await slot('Triceps Pushdown', sets: 1, group: 1);
  }

  testWidgets('run a workout from a routine, supersets and all',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firestoreDirectProvider.overrideWithValue(false),
        ],
        child: const PhoneApp(),
      ),
    );

    // Routines list → open the routine → start from the editor.
    await pumpUntil(tester, find.text('E2E Push'));
    await tester.tap(find.text('E2E Push'));
    await pumpUntil(tester, find.text('Start workout'));
    await tester.tap(find.text('Start workout'));
    await pumpUntilExercise(tester, 'Bench Press');
    expect(find.text('Set 1 of 2'), findsOneWidget);

    // Set 1 → another set of the same exercise, so it rests first.
    await tester.tap(find.text('Done'));
    await pumpUntil(tester, find.text('Skip rest'));
    await tester.tap(find.text('Skip rest'));
    await pumpUntil(tester, find.text('Set 2 of 2'));
    expect(currentExercise(tester), 'Bench Press');

    // Set 2 → a new exercise, so it rests again.
    await tester.tap(find.text('Done'));
    await pumpUntil(tester, find.text('Skip rest'));
    await tester.tap(find.text('Skip rest'));
    await pumpUntilExercise(tester, 'Cable Fly');

    // The superset rule: the mate in the same round follows immediately, with
    // no rest in between.
    await tester.tap(find.text('Done'));
    await pumpUntilExercise(tester, 'Triceps Pushdown');
    expect(find.text('Skip rest'), findsNothing);

    // Last set: everything is logged, so Finish asks nothing.
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Finish'));
    await tester.pump(const Duration(milliseconds: 300));

    final workouts = await db.watchRecentWorkouts().first;
    expect(workouts, hasLength(1));
    final w = workouts.single;
    expect(w.routineName, 'E2E Push');
    expect(w.endedAt, isNotNull, reason: 'Finish must stamp endedAt');

    final full = await db.loadFullWorkout(w.syncId);
    final logged = [
      for (final e in full!.exercises)
        for (final s in e.sets)
          if (s.completion != null) s.completion!,
    ];
    expect(logged, hasLength(4), reason: 'every set of the routine was logged');
    expect(logged.every((c) => c.actualReps == 8), isTrue);
  });
}
