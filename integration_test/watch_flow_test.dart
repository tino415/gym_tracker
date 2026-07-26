// End-to-end flow test for the Wear OS shell, run on a device/emulator via:
//   flutter test integration_test/watch_flow_test.dart -d <device>
//
// The watch has no routine-authoring UI ("create one on the phone"), so this
// seeds a routine directly into an in-memory Drift DB, then drives the real
// watch widget tree — pick page → run page → log the set → finish — the same
// way a user would, and asserts the completed workout landed in the DB.
//
// Two things are overridden to keep the run hermetic and deterministic:
//  * databaseProvider → an in-memory Drift DB (no real data touched).
//  * syncServiceProvider → a SyncService with *no* transports, so finishing a
//    workout doesn't fan a real message out over the Wear Data Layer. The
//    native WorkoutBridge (heart rate / foreground service / timers) already
//    no-ops itself under `flutter test` (FLUTTER_TEST env), so it needs no
//    override here.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/main.dart' show isWatchProvider;
import 'package:gym_tracker/sync/sync_service.dart';
import 'package:gym_tracker/sync/workout_bridge.dart' show WorkoutBridge;
import 'package:gym_tracker/watch/watch_app.dart';
import 'package:gym_tracker/watch/widgets/round_safe_area.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Pump real frames until [finder] matches, instead of pumpAndSettle: the
  // pick/run pages watch live Drift streams (and startWorkout runs a
  // transaction), so pumpAndSettle can spin without ever settling.
  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 150}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  // Let a PageView slide / fling settle before tapping — a target matched
  // mid-animation is horizontally offset, so a tap at its resting center
  // misses. pumpAndSettle can't be used (the live streams never settle), so
  // pump a fixed span comfortably past the 250 ms page animation.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('watch: start a seeded routine, log a set, finish',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // On-device integration runs don't set FLUTTER_TEST in the app process, so
    // the run page's WorkoutBridge would otherwise fire a real permission
    // dialog on Start and hang the test. Opt into the no-op path.
    WorkoutBridge.debugSkipPlatformCalls = true;
    addTearDown(() => WorkoutBridge.debugSkipPlatformCalls = false);

    // Seed one reps routine with a single planned set — a single set means
    // completing it makes the workout "genuinely complete" with no rest phase
    // or superset advance to drive through.
    final exercise = await db.createExercise('Bench Press');
    final routine = await db.createRoutine('Push Day');
    final re = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: exercise.syncId,
    );
    await db.addPlannedSet(
      routineExerciseId: re.syncId,
      targetReps: 10,
      targetWeightKg: 20,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firestoreDirectProvider.overrideWithValue(false),
          isWatchProvider.overrideWithValue(true),
          // No-transport sync so finishing doesn't hit the Wear Data Layer.
          syncServiceProvider.overrideWith((ref) {
            final svc = SyncService(
              ref.watch(databaseProvider),
              ref.watch(syncRepositoryProvider),
              isRoutineAuthority: false,
              transports: const [],
            );
            svc.start();
            ref.onDispose(svc.dispose);
            return svc;
          }),
        ],
        // Mirror _WearShell: WatchApp reads WatchShapeScope for bezel padding.
        child: const WatchShapeScope(isRound: false, child: WatchApp()),
      ),
    );

    // Pick page lists the seeded routine.
    await pumpUntil(tester, find.text('Push Day'));
    expect(find.text('1 exercise'), findsOneWidget);

    // Tap it → the run page opens on the exercise-list pane with a Start CTA.
    await tester.tap(find.text('Push Day'));
    await pumpUntil(tester, find.widgetWithText(FilledButton, 'Start'));

    // Start → creates the in-progress workout and swipes to the run pane.
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await pumpUntil(tester, find.widgetWithText(FilledButton, 'Done'));
    await settle(tester); // let the page finish sliding before tapping Done

    // A workout is now in progress in the DB.
    expect(await db.watchInProgressWorkout().first, isNotNull);

    // Log the set — the button flips to "Done ✓" once the completion persists.
    final doneButton = find.widgetWithText(FilledButton, 'Done');
    await tester.ensureVisible(doneButton);
    await tester.tap(doneButton);
    await pumpUntil(tester, find.widgetWithText(FilledButton, 'Done ✓'));

    // Swipe back to the exercise-list pane; every set logged ⇒ Finish enables.
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await settle(tester); // let the page settle back on the exercise list
    await pumpUntil(tester, find.widgetWithText(FilledButton, 'Finish'));

    // Finish → the done screen, and the workout is closed out in the DB.
    final finishButton = find.widgetWithText(FilledButton, 'Finish');
    await tester.ensureVisible(finishButton);
    await tester.tap(finishButton);
    await pumpUntil(tester, find.text('Workout complete'));

    expect(await db.watchInProgressWorkout().first, isNull);
    final recent = await db.watchRecentWorkouts().first;
    expect(recent, hasLength(1));
    expect(recent.single.endedAt, isNotNull);

    final completions = await db.completionsForWorkout(recent.single.syncId);
    expect(completions, hasLength(1));
    expect(completions.single.actualReps, 10);
    expect(completions.single.actualWeightKg, 20);
  });
}
