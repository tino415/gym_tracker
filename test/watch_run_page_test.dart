import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/watch/watch_run_page.dart';

/// Build a routine described as `[(name, kind, [(reps?, kg?, sec?)], group?)]`
/// and return the loaded FullRoutine. Quick fixture helper.
Future<FullRoutine> _seedRoutine(
  AppDatabase db, {
  required String name,
  required List<_ExerciseFixture> exercises,
  int? restSeconds,
}) async {
  final routine = await db.createRoutine(name);
  for (final fx in exercises) {
    final ex = await db.createExercise(fx.name, kind: fx.kind);
    final re = await db.addExerciseToRoutine(
      routineId: routine.id,
      exerciseId: ex.id,
    );
    if (restSeconds != null) await db.setRestSeconds(re.id, restSeconds);
    if (fx.group != null) await db.setSupersetGroup(re.id, fx.group);
    for (final s in fx.sets) {
      await db.addPlannedSet(
        routineExerciseId: re.id,
        targetReps: s.reps,
        targetWeightKg: s.weight,
        targetSeconds: s.seconds,
      );
    }
  }
  final full = await db.loadFullRoutine(routine.id);
  return full!;
}

class _ExerciseFixture {
  const _ExerciseFixture({
    required this.name,
    this.kind = exerciseKindReps,
    required this.sets,
    this.group,
  });
  final String name;
  final String kind;
  final List<_SetFixture> sets;
  final int? group;
}

class _SetFixture {
  const _SetFixture({this.reps, this.weight, this.seconds});
  final int? reps;
  final double? weight;
  final int? seconds;
}

Future<void> _pumpRun(
  WidgetTester tester, {
  required AppDatabase db,
  required FullRoutine routine,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: WatchRunPage(routine: routine)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Watch run page — basic flow', () {
    testWidgets('Start button creates the workout and reveals the set view',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Push',
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [_SetFixture(reps: 5, weight: 60)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);

      // Exercise list shows the routine name + "Start" button.
      expect(find.text('Push'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // PageView swept to page 1 → set view shows the exercise name and the
      // reps-mode "Done" button.
      expect(find.text('Bench'), findsWidgets);
      expect(find.text('Set 1/1'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
    });
  });

  group('Watch run page — done toggle', () {
    testWidgets('marking and unmarking a set with the Done button',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Arms',
        exercises: const [
          _ExerciseFixture(
            name: 'Curl',
            sets: [_SetFixture(reps: 10, weight: 20)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // Mark done.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      // Button flips to the completed variant.
      expect(find.text('Done ✓'), findsOneWidget);

      // Tap again to unmark.
      await tester.tap(find.text('Done ✓'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
    });
  });

  group('Watch run page — superset alternation', () {
    testWidgets('A.set0 → B.set0 has no rest; round end starts rest then A.set1',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Super',
        restSeconds: 2,
        exercises: const [
          _ExerciseFixture(
            name: 'A',
            group: 1,
            sets: [
              _SetFixture(reps: 5, weight: 50),
              _SetFixture(reps: 5, weight: 50),
            ],
          ),
          _ExerciseFixture(
            name: 'B',
            group: 1,
            sets: [
              _SetFixture(reps: 8, weight: 20),
              _SetFixture(reps: 8, weight: 20),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // Land on A set 1/2.
      expect(find.text('A'), findsWidgets);
      expect(find.text('Set 1/2'), findsOneWidget);

      // Mark A.set0 — should jump straight to B.set0 (no rest in superset).
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsWidgets);
      expect(find.text('Set 1/2'), findsOneWidget);
      expect(find.text('Rest'), findsNothing);

      // Mark B.set0 — round ends, rest screen.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);

      // Advance the 2 s rest.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      // Should now be at A.set1.
      expect(find.text('A'), findsWidgets);
      expect(find.text('Set 2/2'), findsOneWidget);
    });
  });

  group('Watch run page — time-based exercise', () {
    testWidgets('countdown decrements each second after Start tap',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Core',
        exercises: const [
          _ExerciseFixture(
            name: 'Plank',
            kind: exerciseKindTime,
            sets: [_SetFixture(seconds: 10)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);

      // Begin the workout — there is also a "Start" inside the time-set view
      // for the countdown, but only after we land there. Tap the
      // routine-list Start first.
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // Time set view shows the target.
      expect(find.text('10s'), findsOneWidget);

      // Tap the time-set view's Start (an OutlinedButton).
      await tester.tap(find.widgetWithText(OutlinedButton, 'Start'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('9s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('8s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('7s'), findsOneWidget);
    });

    testWidgets('countdown survives an unrelated snapshot stream emission',
        (tester) async {
      // Regression: previously the snapshot listener called
      // _loadCurrentSetTargets() on every emission, cancelling the active
      // timer. Any concurrent DB write would freeze the countdown.
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Core',
        exercises: const [
          _ExerciseFixture(
            name: 'Plank',
            kind: exerciseKindTime,
            sets: [_SetFixture(seconds: 10)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Start'));
      await tester.pump();

      // 2 s into the countdown.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('8s'), findsOneWidget);

      // Provoke a snapshot emission by writing to a watched table. Must run
      // under `tester.runAsync` — direct awaits on real-time IO don't
      // progress under the widget tester's fake clock.
      await tester.runAsync(() async {
        final ex = (await db.watchExercises().first).first;
        await db.renameExercise(ex.id, 'Plank renamed');
      });
      await tester.pump();

      // One more tick — must keep counting.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('7s'), findsOneWidget);
    });
  });

  group('Watch run page — skip-and-wrap', () {
    testWidgets('wraps to first unfinished after completing the last set',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Skip',
        restSeconds: 2,
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [_SetFixture(reps: 5, weight: 60)],
          ),
          _ExerciseFixture(
            name: 'Row',
            sets: [_SetFixture(reps: 8, weight: 40)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // Land on Bench set 1/1.
      expect(find.text('Bench'), findsWidgets);

      // Tap the chevron-right "Next set" arrow to skip Bench without
      // completing it.
      await tester.tap(find.byTooltip('Next set'));
      await tester.pumpAndSettle();
      expect(find.text('Row'), findsWidgets);

      // Mark Row done — this is the last position in the forward sequence,
      // so we expect a wrap back to Bench's still-incomplete set 1 after the
      // rest interval elapses.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      // Wrap landed on Bench set 1/1 with the "Done" (uncompleted) button.
      expect(find.text('Bench'), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
    });
  });
}
