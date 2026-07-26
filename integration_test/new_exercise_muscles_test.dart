// Integration test for tagging muscles while creating an exercise inline
// (the "Create new exercise" dialog in the routine exercise picker):
//   flutter test integration_test/new_exercise_muscles_test.dart -d <device>
//
// Drives the real dialog against an in-memory Drift DB (muscles are seeded in
// beforeOpen, so the chip list is populated), picks a muscle, creates the
// exercise, and asserts the muscle was persisted onto it.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/routines/exercise_picker.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 100}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  // Pump until [finder] matches nothing — used to wait out the async create +
  // the dialog's pop/close animation (the trigger button stays mounted behind
  // the dialog, so waiting for *it* wouldn't prove the dialog is gone).
  Future<void> pumpUntilGone(WidgetTester tester, Finder finder,
      {int maxPumps = 100}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsNothing, reason: 'timed out waiting for $finder to go');
  }

  testWidgets('create an exercise with a muscle selected', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // beforeOpen seeds the standard muscle list; grab one to select + assert.
    final muscles = await db.watchMuscles().first;
    expect(muscles, isNotEmpty, reason: 'muscles should be seeded');
    final target = muscles.first;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firestoreDirectProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showCreateExerciseDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Open the dialog and wait for the (streamed) muscle chips to render.
    await tester.tap(find.text('open'));
    await pumpUntil(tester, find.text('New exercise'));
    await pumpUntil(tester, find.widgetWithText(FilterChip, target.name));

    // Name it, tag the muscle, create.
    await tester.enterText(find.byType(TextField).first, 'Overhead Press');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, target.name));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));

    // Dialog closes once the exercise (and its muscles) are written.
    await pumpUntilGone(tester, find.text('New exercise'));

    // The exercise persisted with the selected muscle bound to it.
    final exercises = await db.watchExercises().first;
    final created =
        exercises.where((e) => e.name == 'Overhead Press').toList();
    expect(created, hasLength(1));
    final boundMuscles = await db.musclesForExercise(created.single.syncId);
    expect(boundMuscles.map((m) => m.syncId), contains(target.syncId));
  });
}
