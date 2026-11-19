import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/watch/watch_app.dart';
import 'package:gym_tracker/watch/watch_run_page.dart';
import 'package:gym_tracker/watch/watch_workout_done_page.dart';
import 'package:gym_tracker/watch/widgets/round_safe_area.dart';

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
  bool round = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        theme: watchTheme(),
        builder: (context, child) =>
            WatchShapeScope(isRound: round, child: child!),
        home: WatchRunPage(routine: routine),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> editValue(
  WidgetTester tester,
  Finder opener, {
  IconData tap = Icons.add,
  int times = 1,
}) async {
  await tester.tap(opener);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byIcon(tap));
    await tester.pump();
  }
  await tester.tap(find.widgetWithText(FilledButton, 'OK'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
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

      await editValue(tester, find.widgetWithText(ActionChip, '80 kg'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('82.5 kg'), findsOneWidget);
      expect(find.text('Rest 57s'), findsOneWidget);

      await tester.tap(find.text('Rest 57s'));
      await tester.pump();
      expect(find.text('57s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 58));
      await tester.pump();
      expect(find.text('Rest'), findsNothing);
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('82.5 kg'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      final weights = [for (final c in await completionsOf(db)) c.actualWeightKg];
      expect(weights, unorderedEquals([80.0, 82.5]));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the previous and next arrows sit level on the face',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(226, 226));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpRun(tester, db: db, routine: await seedSquats(db));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      final left = tester.getCenter(find.byIcon(Icons.chevron_left));
      final right = tester.getCenter(find.byIcon(Icons.chevron_right));
      expect(right.dy, left.dy);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the rest pill leaves the reps controls clear of Done',
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

      final weightChip = tester.getRect(find.byType(ActionChip));
      final done = tester.getRect(find.widgetWithText(FilledButton, 'Done'));
      expect(weightChip.bottom, lessThanOrEqualTo(done.top));
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

      await editValue(tester, find.text('10'));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('11'), findsOneWidget);
      expect(find.text('Done ✓'), findsOneWidget);
      expect(find.text('Rest 53s'), findsOneWidget);
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
    for (final side in [226.0, 192.0]) {
      group('set faces at ${side.toInt()}dp, round', () {
        Future<void> openFace(
          WidgetTester tester,
          _ExerciseFixture exercise,
        ) async {
          await tester.binding.setSurfaceSize(Size(side, side));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final routine = await _seedRoutine(
            db,
            name: 'Core',
            exercises: [exercise],
          );
          await _pumpRun(tester, db: db, routine: routine, round: true);
          await tester.tap(find.widgetWithText(FilledButton, 'Start'));
          await tester.pumpAndSettle();
        }

        void expectInsideFace(WidgetTester tester, Finder finder) {
          final rect = tester.getRect(finder);
          final centre = Offset(side / 2, side / 2);
          final bite = rect.shortestSide / 2 * (1 - 0.7071);
          final rounded = rect.deflate(bite);
          for (final corner in [
            rounded.topLeft,
            rounded.topRight,
            rounded.bottomLeft,
            rounded.bottomRight,
          ]) {
            expect((corner - centre).distance, lessThanOrEqualTo(side / 2));
          }
        }

        testWidgets('timed face: big targets, Start beside Done', (
          tester,
        ) async {
          await openFace(
            tester,
            const _ExerciseFixture(
              name: 'Plank',
              kind: exerciseKindTime,
              sets: [_SetFixture(seconds: 30, weight: 10)],
            ),
          );

          final start = find.widgetWithText(FilledButton, 'Start').last;
          final done = find.widgetWithText(FilledButton, 'Done');
          final startRect = tester.getRect(start);
          final doneRect = tester.getRect(done);
          expect(startRect.height, greaterThanOrEqualTo(44));
          expect(doneRect.height, greaterThanOrEqualTo(44));
          expect(startRect.right, lessThanOrEqualTo(doneRect.left));
          expect(startRect.width, greaterThanOrEqualTo(48));
          expect(tester.getSize(find.text('30s')).height, greaterThan(0));
          expect(tester.getSize(find.byType(ActionChip)).height,
              greaterThanOrEqualTo(32));
          expect(tester.getRect(find.text('30s')).bottom,
              lessThanOrEqualTo(tester.getRect(find.byType(ActionChip)).top));
          expect(tester.getRect(find.byType(ActionChip)).bottom,
              lessThanOrEqualTo(startRect.top));
          expectInsideFace(tester, start);
          expectInsideFace(tester, done);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });

        testWidgets('reps face: big targets, Done 44dp', (tester) async {
          await openFace(
            tester,
            const _ExerciseFixture(
              name: 'Bench',
              sets: [_SetFixture(reps: 8, weight: 60)],
            ),
          );

          final done = find.widgetWithText(FilledButton, 'Done');
          final chip = find.byType(ActionChip);
          expect(tester.getSize(done).height, greaterThanOrEqualTo(44));
          expect(tester.getSize(chip).height, greaterThanOrEqualTo(32));
          expect(tester.getRect(find.text('8')).bottom,
              lessThanOrEqualTo(tester.getRect(chip).top));
          expect(tester.getRect(chip).bottom,
              lessThanOrEqualTo(tester.getRect(done).top));
          expectInsideFace(tester, done);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });

        testWidgets('editor: 64dp buttons, OK inside the bezel', (
          tester,
        ) async {
          await openFace(
            tester,
            const _ExerciseFixture(
              name: 'Bench',
              sets: [_SetFixture(reps: 8, weight: 60)],
            ),
          );
          await tester.tap(find.byType(ActionChip));
          await tester.pumpAndSettle();

          for (final icon in [Icons.remove, Icons.add]) {
            final button = find.ancestor(
              of: find.byIcon(icon),
              matching: find.byType(InkWell),
            );
            expect(tester.getSize(button).shortestSide, 64);
            expectInsideFace(tester, button);
          }
          expectInsideFace(tester, find.widgetWithText(FilledButton, 'OK'));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      });
    }

    testWidgets('OK applies the edit, back discards it', (tester) async {
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

      await tester.tap(find.byType(ActionChip));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, '10 kg'), findsOneWidget);

      await editValue(tester, find.widgetWithText(ActionChip, '10 kg'));
      expect(find.widgetWithText(ActionChip, '12.5 kg'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
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

      // Tap the time-set view's Start.
      await tester.tap(find.widgetWithText(FilledButton, 'Start').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('9s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));

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
      await tester.tap(find.widgetWithText(FilledButton, 'Start').last);
      await tester.pump();

      // 2 s into the countdown.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

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

    testWidgets('the seconds editor moves the target, running or not',
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
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      await editValue(tester, find.text('10s'));
      expect(find.text('15s'), findsOneWidget);
      expect(find.text('/15'), findsNothing);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Start').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('13s'), findsOneWidget);
      expect(find.text('/15'), findsOneWidget);

      await editValue(tester, find.text('13s'), tap: Icons.remove);
      expect(find.text('/10'), findsOneWidget);

      await editValue(
        tester,
        find.textContaining(RegExp(r'^\d+s$')),
        tap: Icons.remove,
        times: 3,
      );
      expect(find.text('/5'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Watch run page — hold survives navigation', () {
    Future<FullRoutine> seedCore(AppDatabase db) => _seedRoutine(
          db,
          name: 'Core',
          exercises: const [
            _ExerciseFixture(
              name: 'Plank',
              kind: exerciseKindTime,
              sets: [_SetFixture(seconds: 30), _SetFixture(seconds: 30)],
            ),
            _ExerciseFixture(
              name: 'Lunge',
              sets: [_SetFixture(reps: 12, weight: 20)],
            ),
          ],
        );

    Future<void> startHold(WidgetTester tester, AppDatabase db) async {
      await tester.binding.setSurfaceSize(const Size(226, 226));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpRun(tester, db: db, routine: await seedCore(db));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start').last);
    }

    // Takes three seconds of the fake clock.
    Future<void> switchFromList(WidgetTester tester, String exercise) async {
      await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(exercise));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Switch to this'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('switching to the holding exercise keeps the hold running',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await startHold(tester, db);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('28s'), findsOneWidget);

      await switchFromList(tester, 'Plank');

      expect(find.text('25s'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Pause'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('another exercise shows the running hold and leads back to it',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await startHold(tester, db);
      await tester.pump(const Duration(seconds: 2));

      await switchFromList(tester, 'Lunge');
      expect(find.text('1/1'), findsOneWidget);
      expect(find.text('Timer 25s'), findsOneWidget);

      await tester.tap(find.text('Timer 25s'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Plank'), findsOneWidget);
      expect(find.text('24s'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      final completions = await db.select(db.setCompletions).get();
      expect(completions.single.actualSeconds, 6);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a target raised mid-hold still counts after leaving the set',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await startHold(tester, db);
      await tester.pump(const Duration(seconds: 2));

      await editValue(tester, find.text('28s'));
      await tester.pump();
      expect(find.text('/35'), findsOneWidget);

      await switchFromList(tester, 'Lunge');
      expect(find.textContaining('Timer '), findsOneWidget);

      await tester.tap(find.textContaining('Timer '));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('/35'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();
      final completions = await db.select(db.setCompletions).get();
      expect(completions.single.actualSeconds, greaterThanOrEqualTo(6));
      await tester.pumpWidget(const SizedBox());
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
      // Every set is done or skipped, so Finish needs no confirmation.
      await _openListAndTapFinish(tester);
      expect(find.text('Finish workout?'), findsNothing);
      expect(find.byType(WatchWorkoutDonePage), findsOneWidget);
    });

    testWidgets('Finish with sets left confirms, then saves the workout',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Half',
        restSeconds: 0,
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [
              _SetFixture(reps: 5, weight: 60),
              _SetFixture(reps: 5, weight: 60),
              _SetFixture(reps: 5, weight: 60),
            ],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      await _openListAndTapFinish(tester);

      expect(find.text('Finish workout?'), findsOneWidget);
      expect(find.textContaining('2 sets'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(Icons.check),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(WatchWorkoutDonePage), findsOneWidget);
      final workout = (await tester.runAsync(
        () => db.select(db.workouts).getSingle(),
      ))!;
      expect(workout.endedAt, isNotNull);
    });

    testWidgets('cancelling the Finish confirmation keeps the workout open',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Cancel',
        restSeconds: 0,
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

      await _openListAndTapFinish(tester);
      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(Icons.close),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(WatchWorkoutDonePage), findsNothing);
      final workout = (await tester.runAsync(
        () => db.select(db.workouts).getSingle(),
      ))!;
      expect(workout.endedAt, isNull);
    });

    testWidgets('Finish with every set done saves without a dialog',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final routine = await _seedRoutine(
        db,
        name: 'Full',
        restSeconds: 0,
        exercises: const [
          _ExerciseFixture(
            name: 'Bench',
            sets: [_SetFixture(reps: 5, weight: 60)],
          ),
        ],
      );
      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      await _openListAndTapFinish(tester);

      expect(find.text('Finish workout?'), findsNothing);
      expect(find.byType(WatchWorkoutDonePage), findsOneWidget);
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

  group('Watch run page — swap exercise', () {
    testWidgets('"Last" after a swap is the substitute\'s history', (
      tester,
    ) async {
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
      final dumbbell = await db.createExercise('Dumbbell press');
      await db.addRoutineExerciseAlternative(
        routineExerciseId: routine.exercises.single.routineExercise.syncId,
        exerciseId: dumbbell.syncId,
      );
      await _finishPastWorkout(db, routine, reps: 5, weight: 60);
      await _finishPastWorkout(
        db,
        routine,
        swapTo: dumbbell.syncId,
        reps: 8,
        weight: 30,
      );

      await _pumpRun(tester, db: db, routine: routine);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      expect(find.text('Last: 5 × 60 kg'), findsOneWidget);

      await tester.ensureVisible(find.text('Swap exercise'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Swap exercise'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dumbbell press'));
      await tester.pumpAndSettle();

      expect(find.text('Dumbbell press'), findsWidgets);
      expect(find.text('Last: 8 × 30 kg'), findsOneWidget);
    });
  });
}

Future<void> _openListAndTapFinish(WidgetTester tester) async {
  await tester.drag(find.byType(PageView), const Offset(500, 0));
  await tester.pumpAndSettle();
  final finish = find.widgetWithText(FilledButton, 'Finish');
  await tester.ensureVisible(finish);
  await tester.pumpAndSettle();
  await tester.tap(finish);
  await tester.pumpAndSettle();
}

Future<void> _finishPastWorkout(
  AppDatabase db,
  FullRoutine routine, {
  String? swapTo,
  required int reps,
  required double weight,
}) async {
  final workout = await db.startWorkout(routine.routine.syncId);
  final slot = (await db.loadFullWorkout(workout.syncId))!.exercises.single;
  if (swapTo != null) {
    await db.swapWorkoutExercise(
      workoutExerciseId: slot.workoutExercise.syncId,
      newExerciseId: swapTo,
    );
  }
  await db.upsertSetCompletion(
    workoutId: workout.syncId,
    workoutSetId: slot.sets.single.workoutSet.syncId,
    actualReps: reps,
    actualWeightKg: weight,
  );
  await db.finishWorkout(workout.syncId);
}
