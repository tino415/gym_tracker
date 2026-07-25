// End-to-end flow test, run on a device/emulator via:
//   flutter test integration_test/routine_flow_test.dart -d <device>
//
// Unlike a widget test it drives the real app (real GoRouter navigation, real
// Drift on the device) through the Flutter widget tree — so taps land reliably
// (no canvas-coordinate problem). The DB is an in-memory override so the run is
// deterministic and touches no real data.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/phone_app.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Pump real frames until [finder] matches, instead of pumpAndSettle: the
  // routines/history pages watch live Drift streams behind a RefreshIndicator,
  // so pumpAndSettle can spin without ever settling.
  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 100}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  testWidgets('create a routine through the phone UI', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firestoreDirectProvider.overrideWithValue(false),
        ],
        child: const PhoneApp(),
      ),
    );

    // Routines tab loads with its empty state.
    await pumpUntil(tester, find.text('No routines yet'));

    // + FAB → the new-routine editor.
    await tester.tap(find.byType(FloatingActionButton));
    await pumpUntil(tester, find.text('New routine'));

    // Name it, then save (the ✓ in the app bar).
    await tester.enterText(find.byType(TextField).first, 'Push Day');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));

    // Persisting flips the draft title from "New routine" to "Edit routine".
    await pumpUntil(tester, find.text('Edit routine'));

    // Back to the list — the routine now shows there…
    await tester.pageBack();
    await pumpUntil(tester, find.text('Push Day'));
    expect(find.text('Push Day'), findsOneWidget);

    // …and it really landed in the database.
    final routines = await db.watchRoutineSummaries().first;
    expect(routines.map((s) => s.routine.name), contains('Push Day'));
  });
}
