import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/watch/watch_app.dart';
import 'package:gym_tracker/watch/watch_exercise_preview_page.dart';

/// The watch routine preview must surface the slot's alternative exercises —
/// they are configured on the phone but were previously only visible during a
/// workout (the swap picker), not while reviewing a routine.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<FullRoutineExercise> seedSlot({required bool withAlternative}) async {
    final routine = await db.createRoutine('R');
    final bench = await db.createExercise('Bench', kind: exerciseKindReps);
    final re = await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: bench.syncId,
    );
    await db.addPlannedSet(
      routineExerciseId: re.syncId,
      targetReps: 8,
      targetWeightKg: 40,
    );
    if (withAlternative) {
      final alt = await db.createExercise(
        'Dumbbell Press',
        kind: exerciseKindReps,
      );
      await db.addRoutineExerciseAlternative(
        routineExerciseId: re.syncId,
        exerciseId: alt.syncId,
      );
    }
    final full = await db.loadFullRoutine(routine.syncId);
    return full!.exercises.single;
  }

  Future<void> pumpPreview(WidgetTester tester, FullRoutineExercise re) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: watchTheme(),
        home: WatchExercisePreviewPage.fromRoutine(re),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('routine preview lists the slot alternatives', (tester) async {
    final re = await seedSlot(withAlternative: true);
    await pumpPreview(tester, re);

    expect(find.text('Alternatives'), findsOneWidget);
    expect(find.text('Dumbbell Press'), findsOneWidget);
  });

  testWidgets('no Alternatives section when the slot has none', (tester) async {
    final re = await seedSlot(withAlternative: false);
    await pumpPreview(tester, re);

    expect(find.text('Alternatives'), findsNothing);
  });
}
