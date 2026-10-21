// Full web e2e: the Firestore-direct build, driven in a real headless browser
// against the Firebase emulator. Boots the real app root, signs up a fresh
// account through the sign-in gate, then creates a routine (which round-trips
// to the Firestore emulator) and verifies it in the list.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/web_flow_test.dart -d web-server \
//     --browser-name=chrome --headless --driver-port=4444 \
//     --dart-define=SYNC_BACKEND=firestore --dart-define=FIREBASE_USE_EMULATOR=true
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/main.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Pump real frames until [finder] matches — Firebase init, auth, and the
  // Firestore round-trips are all async, and the live-stream pages never let
  // pumpAndSettle settle.
  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 300}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  testWidgets('web: sign up then create a routine (Firestore-direct)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [isWatchProvider.overrideWithValue(false)],
        child: const GymTrackerRoot(isWatch: false),
      ),
    );

    // Boot → Firebase inits against the emulator → the sign-in gate.
    await pumpUntil(tester, find.text('Create account'));

    await tester.enterText(find.byType(TextField).at(0), 'webflow@test.co');
    await tester.enterText(find.byType(TextField).at(1), 'password');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Create account'));

    // Auth succeeds → the app swaps in; a fresh account has no routines.
    await pumpUntil(tester, find.text('No routines yet'));

    // The driver's browser is desktop-sized, so this is the master-detail
    // view: the editor opens in a pane beside the list, not as a route.
    await tester.tap(find.byTooltip('New routine'));
    await pumpUntil(tester, find.text('New routine'));
    await tester.enterText(find.byType(TextField).first, 'Push Day');
    await tester.pump();
    // Saving writes to the Firestore emulator; the list reads it back.
    await tester.tap(find.byTooltip('Save'));
    await pumpUntil(tester, find.text('Edit routine'));

    final listed = find.widgetWithText(ListTile, 'Push Day');
    await pumpUntil(tester, listed);
    expect(listed, findsOneWidget);
  });
}
