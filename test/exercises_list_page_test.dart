import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/exercises/exercises_list_page.dart';

/// Widget tests for the Exercises tab's name search.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seed() async {
    await db.createExercise('Bench Press');
    await db.createExercise('Barbell Row');
    await db.createExercise('Bicep Curl');
  }

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ExercisesListView(onSelect: (_) {}),
          ),
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

  testWidgets('filters the list by name, case-insensitively', (tester) async {
    await seed();
    await pumpList(tester);

    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('Barbell Row'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'curl');
    await tester.pumpAndSettle();

    expect(find.text('Bicep Curl'), findsOneWidget);
    expect(find.text('Bench Press'), findsNothing);
    expect(find.text('Barbell Row'), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('clear button restores the full list', (tester) async {
    await seed();
    await pumpList(tester);

    await tester.enterText(find.byType(TextField), 'curl');
    await tester.pumpAndSettle();
    expect(find.text('Bench Press'), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('Barbell Row'), findsOneWidget);
    expect(find.text('Bicep Curl'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('no-match query shows the empty-match state', (tester) async {
    await seed();
    await pumpList(tester);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No exercises match'), findsOneWidget);
    // The search field survives so the query can be edited or cleared.
    expect(find.byType(TextField), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('no search field before any exercise exists', (tester) async {
    await pumpList(tester);

    expect(find.text('No exercises yet'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await disposeTree(tester);
  });
}
