import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/routines/routine_edit_page.dart';
import 'package:gym_tracker/phone/routines/routines_list_page.dart';

/// Master-detail behaviour of the routines home: a single pushed-route pane on
/// narrow viewports, a pinned list + inline editor split on wide ones.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seed(List<String> names) async {
    for (final n in names) {
      await db.createRoutine(n);
    }
  }

  // Minimal router mirroring the real Routines branch: the editor sub-routes are
  // nested under /routines so a narrow tile-tap pushes the editor full-screen
  // (covering the list), matching production.
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/routines',
        routes: [
          GoRoute(
            path: '/routines',
            builder: (_, _) => const RoutinesListPage(),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, _) => const RoutineEditPage(),
              ),
              GoRoute(
                path: ':id',
                builder: (_, s) =>
                    RoutineEditPage(routineId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      );

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Tearing down the ProviderScope disposes the drift-backed StreamProviders,
  // and drift schedules a zero-duration Timer to close its query streams. Unmount
  // and pump so it fires before the framework's end-of-test invariant check
  // (otherwise: "A Timer is still pending even after the widget tree was
  // disposed").
  Future<void> disposeTree(WidgetTester tester) async {
    // Unmount so the drift-backed StreamProviders dispose now (inside the body).
    await tester.pumpWidget(const SizedBox());
    // drift schedules a zero-duration StreamQueryStore close timer when a query
    // stream is cancelled. A stream that just emitted (e.g. the summaries list
    // right after a delete write) stages that cancel across an extra event-loop
    // turn, so pump several times — each elapse drains the microtask that
    // schedules the timer and then fires it — before the framework's end-of-test
    // "A Timer is still pending" invariant check.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('narrow: tapping a tile pushes the editor full-screen',
      (tester) async {
    await seed(['Alpha']);
    await pump(tester, const Size(400, 800));

    // Single pane: list AppBar present, no editor.
    expect(find.text('Routines'), findsOneWidget);
    expect(find.text('Edit routine'), findsNothing);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    // Editor pushed over the list (list AppBar now offstage).
    expect(find.text('Edit routine'), findsOneWidget);
    expect(find.text('Routines'), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('wide: list and placeholder show, no editor until selection',
      (tester) async {
    await seed(['Alpha', 'Beta']);
    await pump(tester, const Size(1200, 800));

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Select a routine, or + to create one.'), findsOneWidget);
    expect(find.text('Edit routine'), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('wide: selecting a tile shows the editor inline beside the list',
      (tester) async {
    await seed(['Alpha', 'Beta']);
    await pump(tester, const Size(1200, 800));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    // Editor pane AND the list coexist → inline, not a full-screen push.
    expect(find.text('Edit routine'), findsOneWidget);
    expect(find.text('Alpha'), findsWidgets); // tile still visible
    expect(find.text('Beta'), findsOneWidget);

    // Tapped tile is highlighted.
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Alpha'),
    );
    expect(tile.selected, isTrue);
    await disposeTree(tester);
  });

  testWidgets('wide: the + header button opens a draft editor inline',
      (tester) async {
    await seed(['Alpha']);
    await pump(tester, const Size(1200, 800));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('New routine'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget); // list still present
    await disposeTree(tester);
  });

  testWidgets('wide: deleting from the embedded editor returns to placeholder',
      (tester) async {
    await seed(['Alpha']);
    await pump(tester, const Size(1200, 800));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Edit routine'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete routine'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // Back to the placeholder, list still present, no shell pop.
    expect(find.text('Edit routine'), findsNothing);
    expect(find.text('Select a routine, or + to create one.'), findsOneWidget);
    await disposeTree(tester);
  });

  // Seed one routine ('Push Day') containing one exercise ('Bench') so there's
  // an exercise row to select for the set editor.
  Future<void> seedRoutineWithExercise() async {
    final routine = await db.createRoutine('Push Day');
    final ex = await db.createExercise('Bench', kind: exerciseKindReps);
    await db.addExerciseToRoutine(
      routineId: routine.syncId,
      exerciseId: ex.syncId,
    );
  }

  testWidgets(
      '2-pane: selecting an exercise swaps detail to the set editor, back returns',
      (tester) async {
    await seedRoutineWithExercise();
    await pump(tester, const Size(1000, 800)); // >=900, <1240 → 2-pane

    await tester.tap(find.text('Push Day'));
    await tester.pumpAndSettle();
    expect(find.text('Edit routine'), findsOneWidget); // routine editor shown

    // Select the exercise row → detail pane swaps to the set editor.
    await tester.tap(find.text('Bench'));
    await tester.pumpAndSettle();
    expect(find.text('Add set'), findsOneWidget); // set editor
    expect(find.text('Edit routine'), findsNothing); // routine editor swapped out
    expect(find.widgetWithText(ListTile, 'Push Day'),
        findsOneWidget); // list still present

    // Back affordance returns to the routine editor.
    await tester.tap(find.byTooltip('Back to routine'));
    await tester.pumpAndSettle();
    expect(find.text('Add set'), findsNothing);
    expect(find.text('Edit routine'), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('3-pane: selecting an exercise fills the third column',
      (tester) async {
    await seedRoutineWithExercise();
    await pump(tester, const Size(1300, 900)); // >=1240 → 3-pane

    await tester.tap(find.text('Push Day'));
    await tester.pumpAndSettle();
    // Routine editor visible, third column is the placeholder.
    expect(find.text('Edit routine'), findsOneWidget);
    expect(find.text('Select an exercise to edit its sets.'), findsOneWidget);
    expect(find.text('Add set'), findsNothing);

    await tester.tap(find.text('Bench'));
    await tester.pumpAndSettle();
    // Third column fills; routine editor STILL visible (all three panes).
    expect(find.text('Add set'), findsOneWidget);
    expect(find.text('Edit routine'), findsOneWidget);
    expect(find.text('Select an exercise to edit its sets.'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Push Day'),
        findsOneWidget); // list still present
    await disposeTree(tester);
  });
}
