import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/muscle_seeds.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/routines/exercise_picker.dart';

/// Widget tests for the routine exercise picker's search + muscle filtering.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// Seed exercises tagged with distinct muscles. Muscles are seeded
  /// deterministically by the DB (`_seedMuscles`), so we tag by their known
  /// [muscleSyncId]s.
  Future<void> seed() async {
    final bench = await db.createExercise('Bench Press');
    await db.setExerciseMuscles(bench.syncId, [muscleSyncId('Chest')]);
    final row = await db.createExercise('Barbell Row');
    await db.setExerciseMuscles(row.syncId, [muscleSyncId('Back')]);
    final curl = await db.createExercise('Bicep Curl');
    await db.setExerciseMuscles(curl.syncId, [muscleSyncId('Biceps')]);
  }

  /// Pump a host with a single button that opens the picker, then tap it and let
  /// the picker's pre-show DB read resolve.
  Future<void> pumpAndOpen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: ElevatedButton(
                  onPressed: () => showExercisePicker(context, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    // The picker awaits a DB read before showing the sheet; let it resolve.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  /// Unmount the tree and pump so drift's stream-close `Timer(Duration.zero)`
  /// (scheduled by `StreamQueryStore.markAsClosed` on cancel) fires before
  /// teardown, otherwise the test fails with "A Timer is still pending".
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  testWidgets('lists all exercises initially', (tester) async {
    await seed();
    await pumpAndOpen(tester);

    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('Barbell Row'), findsOneWidget);
    expect(find.text('Bicep Curl'), findsOneWidget);
    expect(find.text('Create new exercise'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('search narrows the list to name matches', (tester) async {
    await seed();
    await pumpAndOpen(tester);

    await tester.enterText(find.byType(TextField), 'row');
    await tester.pumpAndSettle();

    expect(find.text('Barbell Row'), findsOneWidget);
    expect(find.text('Bench Press'), findsNothing);
    expect(find.text('Bicep Curl'), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('tapping a muscle chip narrows to that muscle', (tester) async {
    await seed();
    await pumpAndOpen(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'Back'));
    await tester.pumpAndSettle();

    expect(find.text('Barbell Row'), findsOneWidget);
    expect(find.text('Bench Press'), findsNothing);
    expect(find.text('Bicep Curl'), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('a non-matching query shows "No exercises match."',
      (tester) async {
    await seed();
    await pumpAndOpen(tester);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();

    expect(find.text('No exercises match.'), findsOneWidget);
    expect(find.text('Bench Press'), findsNothing);

    await disposeTree(tester);
  });
}
