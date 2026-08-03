import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/routines/routine_edit_page.dart';
import 'package:gym_tracker/phone/routines/routines_list_page.dart';

/// How you start a workout from a routine: a swipe on the list row, or the
/// button inside the routine editor.
///
/// These cover what the affordances *do*. Where they live is a design call that
/// is free to change, so nothing here asserts the absence of a start button on
/// the row — the reasoning for keeping it off there is on `_SwipeToStart`.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// A routine with [exerciseCount] exercises, each carrying one planned set.
  Future<Routine> seedRoutine(String name, {int exerciseCount = 1}) async {
    final routine = await db.createRoutine(name);
    for (var i = 0; i < exerciseCount; i++) {
      final ex = await db.createExercise('$name-ex$i');
      final re = await db.addExerciseToRoutine(
        routineId: routine.syncId,
        exerciseId: ex.syncId,
      );
      await db.addPlannedSet(
        routineExerciseId: re.syncId,
        targetReps: 8,
        targetWeightKg: 60,
      );
    }
    return routine;
  }

  GoRouter buildRouter(String initial) => GoRouter(
        initialLocation: initial,
        routes: [
          GoRoute(
            path: '/routines',
            builder: (_, _) => const RoutinesListPage(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (_, s) =>
                    RoutineEditPage(routineId: s.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/run/:routineId',
            builder: (_, s) => Text('RUNNING:${s.pathParameters['routineId']}'),
          ),
        ],
      );

  Future<void> pump(WidgetTester tester, String initial) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: buildRouter(initial)),
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

  group('routines list', () {
    testWidgets('tapping a row opens the routine', (tester) async {
      await seedRoutine('Push');
      await pump(tester, '/routines');

      await tester.tap(find.text('Push'));
      await tester.pumpAndSettle();
      expect(find.text('Edit routine'), findsOneWidget);

      await disposeTree(tester);
    });

    testWidgets('swiping a row left starts a workout', (tester) async {
      final r = await seedRoutine('Push');
      await pump(tester, '/routines');

      await tester.drag(find.text('Push'), const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(find.text('RUNNING:${r.syncId}'), findsOneWidget);

      await disposeTree(tester);
    });

    testWidgets('the swiped row stays in the list', (tester) async {
      await seedRoutine('Push');
      await pump(tester, '/routines');

      await tester.drag(find.text('Push'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      // Back out of the workout: the routine must still be there. A plain
      // Dismissible would have removed it.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      expect(find.text('Push'), findsOneWidget);

      await disposeTree(tester);
    });

    testWidgets('an empty routine cannot be swiped to start', (tester) async {
      await db.createRoutine('Empty');
      await pump(tester, '/routines');

      await tester.drag(find.text('Empty'), const Offset(-500, 0));
      await tester.pumpAndSettle();

      // Nothing to run, so no swipe affordance is wired up at all.
      expect(find.textContaining('RUNNING:'), findsNothing);
      expect(find.text('Empty'), findsOneWidget);

      await disposeTree(tester);
    });
  });

  group('routine editor', () {
    testWidgets('offers Start workout, and the Add exercise FAB stays',
        (tester) async {
      final r = await seedRoutine('Push');
      await pump(tester, '/routines/${r.syncId}');

      expect(find.widgetWithText(FloatingActionButton, 'Add exercise'),
          findsOneWidget);

      // Tapped by label, not by type: `FilledButton.icon` builds a private
      // subclass and `find.byType` matches the exact runtime type.
      await tester.tap(find.text('Start workout'));
      await tester.pumpAndSettle();
      expect(find.text('RUNNING:${r.syncId}'), findsOneWidget);

      await disposeTree(tester);
    });

    testWidgets('no Start workout for an empty routine', (tester) async {
      final r = await db.createRoutine('Empty');
      await pump(tester, '/routines/${r.syncId}');

      expect(find.text('Start workout'), findsNothing);
      expect(find.text('No exercises in this routine yet.'), findsOneWidget);

      await disposeTree(tester);
    });
  });
}
