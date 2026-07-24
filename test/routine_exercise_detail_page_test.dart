import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/routines/routine_exercise_detail_page.dart';

/// Widget tests probing the intermittent "crash while editing a routine".
///
/// Hypothesis: the add-set / add-alternative handlers await a dialog/picker and
/// then touch `ref` with no `mounted` guard, while the page reactively
/// unmounts/pops itself when its watched data goes null (a concurrent sync
/// bundle-apply or delete). If the widget unmounts during the await, the
/// post-await `ref.read` runs on a defunct ref.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(int routineId, int reId)> seed({String kind = exerciseKindReps}) async {
    final routine = await db.createRoutine('R');
    final ex = await db.createExercise('Bench', kind: kind);
    final re = await db.addExerciseToRoutine(
      routineId: routine.id,
      exerciseId: ex.id,
    );
    return (routine.id, re.id);
  }

  Future<void> pumpDetail(WidgetTester tester, int routineId, int reId) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: RoutineExerciseDetailPage(
            routineId: routineId,
            routineExerciseId: reId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('happy paths (should not crash)', () {
    testWidgets('add set persists and does not throw', (tester) async {
      final (routineId, reId) = await seed();
      await pumpDetail(tester, routineId, reId);

      await tester.tap(find.text('Add set').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final full = await db.loadFullRoutine(routineId);
      expect(full!.exercises.single.plannedSets, hasLength(1));
    });

    testWidgets('add alternative persists and does not throw', (tester) async {
      final (routineId, reId) = await seed();
      await db.createExercise('Squat', kind: exerciseKindReps);
      await pumpDetail(tester, routineId, reId);

      await tester.tap(find.text('Add')); // alternatives "Add"
      // The picker awaits a DB read before showing the sheet; let real async
      // resolve, then pump the sheet in.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      // Sheet should be open with the create tile + the pickable exercise.
      expect(find.text('Create new exercise'), findsOneWidget);
      await tester.tap(find.text('Squat')); // pick from the bottom sheet
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final full = await db.loadFullRoutine(routineId);
      expect(full!.exercises.single.alternatives, hasLength(1));
    });
  });

  group('use-after-dispose mechanism', () {
    testWidgets(
      'a ref captured by a handler throws if used after the widget unmounts',
      (tester) async {
        // This is exactly what _addAlternative / _editSetDialog do: capture the
        // WidgetRef in a callback, await, then ref.read(databaseProvider). If
        // the page unmounted during the await, this is the throw.
        late WidgetRef captured;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) {
                  captured = ref;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );

        // Unmount the Consumer (stand-in for the reactive pop/replace on line
        // 42-48 when the watched routine data goes null mid-dialog).
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));

        expect(() => captured.read(databaseProvider), throwsA(anything));
      },
    );
  });
}
