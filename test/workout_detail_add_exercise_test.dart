import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/history/workout_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The workout editor used to roll its own exercise list, which had no way to
/// create an exercise — so adding one you had not defined yet meant leaving the
/// workout, creating it in the Exercises tab, and coming back. It now uses the
/// shared picker, which offers search, muscle filters and creation.
void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

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

  testWidgets('the add-exercise picker can create and search', (tester) async {
    await db.createExercise('Bench Press');
    await db.createExercise('Barbell Row');
    final w = await db.createWorkout(
      startedAt: DateTime(2026, 3, 4, 18, 30),
      endedAt: DateTime(2026, 3, 4, 19, 45),
    );
    await pumpDetail(tester, w.syncId);

    await tester.tap(find.text('Add exercise'));
    await tester.pumpAndSettle();

    // The affordance the bespoke list was missing.
    expect(find.text('Create new exercise'), findsOneWidget);
    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('Barbell Row'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'row');
    await tester.pumpAndSettle();
    expect(find.text('Barbell Row'), findsOneWidget);
    expect(find.text('Bench Press'), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('picking an exercise adds it to the workout', (tester) async {
    await db.createExercise('Bench Press');
    final w = await db.createWorkout(
      startedAt: DateTime(2026, 3, 4, 18, 30),
      endedAt: DateTime(2026, 3, 4, 19, 45),
    );
    await pumpDetail(tester, w.syncId);

    await tester.tap(find.text('Add exercise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bench Press'));
    await tester.pumpAndSettle();

    final full = await db.loadFullWorkout(w.syncId);
    expect(full!.exercises.single.workoutExercise.exerciseName, 'Bench Press');

    await disposeTree(tester);
  });
}
