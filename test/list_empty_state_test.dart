import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/exercises/exercises_list_page.dart';
import 'package:gym_tracker/phone/history/history_list_page.dart';
import 'package:gym_tracker/phone/routines/routines_list_page.dart';

/// The three top-level lists used to hand-roll their own empty state, so the
/// icon landed at a different height in each. They now share [ListEmptyState];
/// this pins the icons to the same vertical center given the same viewport.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// Render [child] in a fixed-size viewport and return the center of its
  /// empty-state [icon]. Both axes matter: Routines/Workouts render the block
  /// as a sliver (tight width) and Exercises as a plain box child (loose), and
  /// only the latter shrink-wrapped to the left before it claimed full width.
  Future<Offset> iconCenter(
    WidgetTester tester,
    Widget child,
    IconData icon,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 700, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(icon), findsOneWidget);
    final center = tester.getCenter(find.byIcon(icon));

    // Unmount and pump so drift's stream-close `Timer(Duration.zero)` fires
    // before the next pump, otherwise teardown trips on a pending timer.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    return center;
  }

  testWidgets('empty-state icons sit in the same spot in all three lists',
      (tester) async {
    final routines = await iconCenter(
      tester,
      RoutinesListView(onSelect: (_) {}),
      Icons.fitness_center,
    );
    final exercises = await iconCenter(
      tester,
      ExercisesListView(onSelect: (_) {}),
      Icons.list_alt,
    );
    final workouts = await iconCenter(
      tester,
      WorkoutsListView(onSelect: (_) {}),
      Icons.history,
    );

    expect(exercises, routines);
    expect(workouts, routines);
  });
}
