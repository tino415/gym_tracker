import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/watch/watch_app.dart';
import 'package:gym_tracker/watch/watch_run_page.dart';
import 'package:gym_tracker/watch/widgets/round_safe_area.dart';

Future<FullRoutine> _bikeRoutine(AppDatabase db) async {
  final routine = await db.createRoutine('Cardio');
  final bike = await db.createExercise('Bike', kind: exerciseKindTime);
  await db.setExerciseParams(bike.syncId, const [
    CustomParam(id: 'level', name: 'Level'),
    WeightEntry(),
  ]);
  final slot = await db.addExerciseToRoutine(
    routineId: routine.syncId,
    exerciseId: bike.syncId,
  );
  await db.addPlannedSet(
    routineExerciseId: slot.syncId,
    targetSeconds: 600,
    targetParams: {'level': 8},
  );
  return (await db.loadFullRoutine(routine.syncId))!;
}

Future<void> _pumpStartedRun(WidgetTester tester, AppDatabase db) async {
  final routine = await _bikeRoutine(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        theme: watchTheme(),
        builder: (context, child) =>
            WatchShapeScope(isRound: false, child: child!),
        home: WatchRunPage(routine: routine),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Start'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the top list entry is on the face, the rest on the third page',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pumpStartedRun(tester, db);

    expect(find.text('8 Level'), findsOneWidget);
    expect(find.text('Weight'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Weight'), findsOneWidget);
    expect(find.text('Level'), findsNothing);
  });

  testWidgets('back from the third page returns to the face', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pumpStartedRun(tester, db);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('8 Level'), findsOneWidget);
    expect(find.text('Weight'), findsNothing);
  });

  testWidgets('the face has no more button before the workout starts',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final routine = await _bikeRoutine(db);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: watchTheme(),
          builder: (context, child) =>
              WatchShapeScope(isRound: false, child: child!),
          home: WatchRunPage(routine: routine),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });
}
