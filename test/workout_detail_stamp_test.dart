import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/history/workout_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The workout editor's started/ended timestamps are two independent tap
/// targets. The regression these guard: the editor used to run the date picker
/// first and only then the time picker, so changing just the time meant
/// dismissing a date dialog you never wanted.
void main() {
  late AppDatabase db;

  setUp(() {
    // The improvements banner reads a dismissal flag on mount.
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  /// A finished workout, so both stamps render as editable chips.
  Future<Workout> seedWorkout() => db.createWorkout(
        startedAt: DateTime(2026, 3, 4, 18, 30),
        endedAt: DateTime(2026, 3, 4, 19, 45),
      );

  Future<void> pumpDetail(WidgetTester tester, String workoutId) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          // Applied via `builder` so the Navigator — and therefore the pushed
          // time picker — inherits it. Without this the picker is 12-hour and
          // rejects an entered hour of 20, so OK silently does nothing.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
          home: WorkoutDetailPage(workoutId: workoutId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Unmount and pump so drift's stream-close `Timer(Duration.zero)` fires
  /// before teardown, otherwise the test fails with "A Timer is still pending".
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  testWidgets('shows date and time as separate chips', (tester) async {
    final w = await seedWorkout();
    await pumpDetail(tester, w.syncId);

    expect(find.text('2026-03-04'), findsNWidgets(2)); // started + ended
    expect(find.text('18:30'), findsOneWidget);
    expect(find.text('19:45'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('the time chip opens the time picker, not the date picker', (
    tester,
  ) async {
    final w = await seedWorkout();
    await pumpDetail(tester, w.syncId);

    await tester.tap(find.text('18:30'));
    await tester.pumpAndSettle();

    // Material's time picker offers an input-mode toggle; the date picker
    // instead shows a calendar with a Cancel/OK pair and no such affordance.
    expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    expect(find.byType(CalendarDatePicker), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await disposeTree(tester);
  });

  testWidgets('the date chip opens the date picker', (tester) async {
    final w = await seedWorkout();
    await pumpDetail(tester, w.syncId);

    await tester.tap(find.text('2026-03-04').first);
    await tester.pumpAndSettle();

    expect(find.byType(CalendarDatePicker), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await disposeTree(tester);
  });

  testWidgets('picking a time keeps the date it was paired with', (
    tester,
  ) async {
    final w = await seedWorkout();
    await pumpDetail(tester, w.syncId);

    await tester.tap(find.text('19:45'));
    await tester.pumpAndSettle();

    // Switch to input mode and type, rather than dragging the clock dial.
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '20');
    await tester.enterText(fields.at(1), '15');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final row = await db.loadFullWorkout(w.syncId);
    expect(row!.workout.endedAt, DateTime(2026, 3, 4, 20, 15));
    // The date half is untouched — that is the whole point of splitting them.
    expect(row.workout.startedAt, DateTime(2026, 3, 4, 18, 30));

    await disposeTree(tester);
  });
}
