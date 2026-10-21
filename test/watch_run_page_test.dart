import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/watch/watch_app.dart';
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
      routineId: routine.syncId,
      exerciseId: ex.syncId,
    );
    final rest = fx.rest ?? restSeconds;
    if (rest != null) await db.setRestSeconds(re.syncId, rest);
    if (fx.group != null) await db.setCircuitGroup(re.syncId, fx.group);
    for (final s in fx.sets) {
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: s.reps,
        targetWeightKg: s.weight,
        targetSeconds: s.seconds,
      );
    }
  }
  final full = await db.loadFullRoutine(routine.syncId);
  return full!;
}

class _ExerciseFixture {
  const _ExerciseFixture({
    required this.name,
    this.kind = exerciseKindReps,
    required this.sets,
    this.group,
    this.rest,
  });
  final String name;
  final String kind;
  final List<_SetFixture> sets;
  final int? group;
  /// Rest after this exercise's set, overriding `_seedRoutine`'s shared value.
  /// Rest is per-exercise, so circuit members need to differ.
  final int? rest;
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
      child: MaterialApp(
        theme: watchTheme(),
        home: WatchRunPage(routine: routine),
      ),
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
      expect(find.text('1/1'), findsOneWidget);
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

  group('Watch run page — rest up-next', () {
    testWidgets('rest view shows the next set name and its target', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Legs',
        restSeconds: 5,
        exercises: const [
          _ExerciseFixture(
            name: 'Squat',
            sets: [
              _SetFixture(reps: 10, weight: 80),
              _SetFixture(reps: 10, weight: 80),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // Completing set 1/2 starts the rest before set 2/2.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);

      // The upcoming set's name and target are both visible during rest.
      expect(find.text('Up next: Squat'), findsOneWidget);
      expect(find.text('10 × 80 kg'), findsOneWidget);

      // The HR slot renders during rest too — placeholder without a sample.
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('Watch run page — edits during rest', () {
    Future<FullRoutine> seedSquats(AppDatabase db) => _seedRoutine(
          db,
          name: 'Legs',
          restSeconds: 60,
          exercises: const [
            _ExerciseFixture(
              name: 'Squat',
              sets: [
                _SetFixture(reps: 10, weight: 80),
                _SetFixture(reps: 10, weight: 80),
                _SetFixture(reps: 10, weight: 80),
              ],
            ),
          ],
        );

    Future<List<SetCompletion>> completionsOf(AppDatabase db) =>
        db.select(db.setCompletions).get();

    testWidgets('the upcoming set is editable while the rest keeps running',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpRun(tester, db: db, routine: await seedSquats(db));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('60s'), findsOneWidget);

      await tester.tap(find.text('Up next: Squat'));
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('Rest 60s'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('82.5'), findsOneWidget);
      expect(find.text('Rest 58s'), findsOneWidget);

      await tester.tap(find.text('Rest 58s'));
      await tester.pump();
      expect(find.text('58s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 58));
      await tester.pump();
      expect(find.text('Rest'), findsNothing);
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('82.5'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      final weights = [for (final c in await completionsOf(db)) c.actualWeightKg];
      expect(weights, unorderedEquals([80.0, 82.5]));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the rest pill leaves the reps steppers clear of Done',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(226, 226));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpRun(tester, db: db, routine: await seedSquats(db));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      await tester.tap(find.text('Up next: Squat'));
      await tester.pump();
      expect(find.text('Rest 60s'), findsOneWidget);

      final repsLabel = tester.getRect(find.text('reps'));
      final done = tester.getRect(find.widgetWithText(FilledButton, 'Done'));
      expect(repsLabel.bottom, lessThanOrEqualTo(done.top));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('correcting the finished set during rest saves it in place',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpRun(tester, db: db, routine: await seedSquats(db));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump(const Duration(seconds: 5));

      await tester.tap(find.text('Up next: Squat'));
      await tester.pump();
      await tester.tap(find.byTooltip('Previous set'));
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('Done ✓'), findsOneWidget);
      expect(find.text('Rest 55s'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('11'), findsOneWidget);
      expect(find.text('Done ✓'), findsOneWidget);
      expect(find.text('Rest 54s'), findsOneWidget);
      final reps = [for (final c in await completionsOf(db)) c.actualReps];
      expect(reps, [11]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('skipping a set during rest keeps the rest running',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpRun(tester, db: db, routine: await seedSquats(db));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(find.text('Up next: Squat'));
      await tester.pump();
      final skipSet = find.widgetWithText(OutlinedButton, 'Skip set');
      await tester.ensureVisible(skipSet);
      await tester.pump();
      await tester.tap(skipSet);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('3/3'), findsOneWidget);
      expect(find.text('Rest 56s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switching exercise from the list during rest keeps the rest',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(226, 226));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Legs',
        restSeconds: 60,
        exercises: const [
          _ExerciseFixture(
            name: 'Squat',
            sets: [
              _SetFixture(reps: 10, weight: 80),
              _SetFixture(reps: 10, weight: 80),
            ],
          ),
          _ExerciseFixture(
            name: 'Lunge',
            sets: [_SetFixture(reps: 12, weight: 20)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();

      await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Lunge'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Switch to this'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Lunge'), findsOneWidget);
      expect(find.text('1/1'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Rest \d+s$')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Watch run page — circuit alternation', () {
    testWidgets('zero rest on A: A.set0 → B.set0 straight through, then rest',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Super',
        exercises: const [
          // The classic superset: nothing between the members, one rest at the
          // end of the round, carried by the member that ends it.
          _ExerciseFixture(
            name: 'A',
            group: 1,
            rest: 0,
            sets: [
              _SetFixture(reps: 5, weight: 50),
              _SetFixture(reps: 5, weight: 50),
            ],
          ),
          _ExerciseFixture(
            name: 'B',
            group: 1,
            rest: 2,
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
      expect(find.text('1/2'), findsOneWidget);

      // Mark A.set0 — should jump straight to B.set0 (no rest in circuit).
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsWidgets);
      expect(find.text('1/2'), findsOneWidget);
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
      expect(find.text('2/2'), findsOneWidget);
    });

    testWidgets('a member with its own rest pauses before the next member',
        (tester) async {
      // The left/right case: a short pause between sides, the full rest after
      // the round. Each member carries the rest that follows its own set.
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Arms',
        exercises: const [
          _ExerciseFixture(
            name: 'L',
            group: 1,
            rest: 1,
            sets: [
              _SetFixture(reps: 8, weight: 12),
              _SetFixture(reps: 8, weight: 12),
            ],
          ),
          _ExerciseFixture(
            name: 'R',
            group: 1,
            rest: 3,
            sets: [
              _SetFixture(reps: 8, weight: 12),
              _SetFixture(reps: 8, weight: 12),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      expect(find.text('L'), findsWidgets);

      // Left side done: L's 1 s rest runs before the right side.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);
      expect(find.text('Up next: R'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('R'), findsWidgets);
      // Still round one — the pause did not advance the set index.
      expect(find.text('1/2'), findsOneWidget);

      // Right side done: the round rest, R's own longer value.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);
      expect(find.text('Up next: L'), findsOneWidget);
    });
  });

  group('Watch run page — time-based exercise', () {
    testWidgets('Start button sits above Done at watch size (no overlap)', (
      tester,
    ) async {
      // Render at the watch's logical size — the default 800x600 test surface
      // is too tall to surface the cramped-layout overlap.
      await tester.binding.setSurfaceSize(const Size(226, 226));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Core',
        exercises: const [
          _ExerciseFixture(
            name: 'Plank',
            kind: exerciseKindTime,
            sets: [_SetFixture(seconds: 30, weight: 10)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // The countdown, the Start/Pause control and Done are all present...
      expect(find.text('30s'), findsOneWidget);
      final startRect = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Start'),
      );
      final doneRect = tester.getRect(find.widgetWithText(FilledButton, 'Done'));
      // ...and the Start control is fully above the Done button.
      expect(startRect.bottom, lessThanOrEqualTo(doneRect.top));
    });

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
        await db.renameExercise(ex.syncId, 'Plank renamed');
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

    testWidgets('after skipping ahead, completion stays in the new exercise',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Skip stay',
        restSeconds: 2,
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [
              _SetFixture(reps: 5, weight: 60),
              _SetFixture(reps: 5, weight: 60),
            ],
          ),
          _ExerciseFixture(
            name: 'Row',
            sets: [
              _SetFixture(reps: 8, weight: 40),
              _SetFixture(reps: 8, weight: 40),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      // Skip past both Bench sets to Row set 1/2.
      await tester.tap(find.byTooltip('Next set'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next set'));
      await tester.pumpAndSettle();
      expect(find.text('Row'), findsWidgets);

      // Complete Row set 1 — must continue with Row set 2, not bounce back
      // to the skipped Bench.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);
      expect(find.text('Up next: Row'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Row'), findsWidgets);
      expect(find.text('2/2'), findsOneWidget);

      // Completing Row's last set returns to the skipped Bench set 1.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      expect(find.text('Rest'), findsOneWidget);
      expect(find.text('Up next: Bench'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Bench'), findsWidgets);
      expect(find.text('1/2'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
    });
  });

  group('Watch run page — end sooner (skip)', () {
    testWidgets('"Skip set" advances without completing the set',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Skip set',
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [
              _SetFixture(reps: 5, weight: 60),
              _SetFixture(reps: 5, weight: 60),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);

      // The tray button lives below the fold — scroll it in, then tap.
      final skipSet = find.widgetWithText(OutlinedButton, 'Skip set');
      await tester.ensureVisible(skipSet);
      await tester.pumpAndSettle();
      await tester.tap(skipSet);
      await tester.pumpAndSettle();

      // Moved to set 2/2, which is still uncompleted (no rest kicked in).
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('Rest'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
      // Nothing was written for the skipped set.
      final completions = await db.customSelect(
        'SELECT COUNT(*) AS c FROM set_completions',
      ).getSingle();
      expect(completions.data['c'], 0);
    });

    testWidgets('"Skip exercise" confirms, skips remaining sets, enables Finish',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Skip ex',
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [
              _SetFixture(reps: 5, weight: 60),
              _SetFixture(reps: 5, weight: 60),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      final skipEx = find.widgetWithText(OutlinedButton, 'Skip exercise');
      await tester.ensureVisible(skipEx);
      await tester.pumpAndSettle();
      await tester.tap(skipEx);
      await tester.pumpAndSettle();

      // Confirmation dialog appears; confirm with the ✓ round choice.
      expect(find.text('Skip exercise?'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(Icons.check),
      ));
      await tester.pumpAndSettle();

      // Both sets skipped → the workout is complete. Swipe back to the list;
      // Finish is now enabled (every set is done or skipped).
      await tester.drag(find.byType(PageView), const Offset(500, 0));
      await tester.pumpAndSettle();
      final finish = find.widgetWithText(FilledButton, 'Finish');
      await tester.ensureVisible(finish);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(finish).onPressed,
        isNotNull,
        reason: 'skipping every set should enable Finish',
      );
    });

    testWidgets('"Skip exercise" in a circuit keeps the other member',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Skip super',
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
      expect(find.text('A'), findsWidgets);

      // Skip exercise A — its sets drop out, but B (same group) keeps its turn.
      final skipEx = find.widgetWithText(OutlinedButton, 'Skip exercise');
      await tester.ensureVisible(skipEx);
      await tester.pumpAndSettle();
      await tester.tap(skipEx);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(Icons.check),
      ));
      await tester.pumpAndSettle();

      expect(find.text('B'), findsWidgets);
      expect(find.text('Rest'), findsNothing);
    });
  });
}
