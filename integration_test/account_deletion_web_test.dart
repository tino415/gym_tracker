// Account deletion against the real Firebase Auth + Firestore emulators, in a
// headless browser:
//
//   just e2e-web-delete     (needs the emulator suite running)
//
// The unit tests cover the Firestore side thoroughly with a fake — every
// collection cleared, other accounts untouched, past the 500-doc batch limit.
// What they cannot reach is Firebase Auth itself: reauthentication and
// `user.delete()` only exist against a real Auth instance. That is this test's
// job, and the assertion that matters is the last one — signing back in with
// the same credentials has to fail, which is only true if the account is really
// gone rather than merely signed out.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/main.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 300}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  testWidgets('web: delete the account and its data', (tester) async {
    // A fresh address per run: the Auth emulator keeps users between runs, so a
    // fixed one would fail the second time with email-already-in-use.
    final email = 'delete-${DateTime.now().millisecondsSinceEpoch}@test.co';
    const password = 'password';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [isWatchProvider.overrideWithValue(false)],
        child: const GymTrackerRoot(isWatch: false),
      ),
    );

    await pumpUntil(tester, find.text('Create account'));
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Create account'));
    await pumpUntil(tester, find.text('No routines yet'));

    // No routine is created first, deliberately. Clearing Firestore is covered
    // by the unit tests against a fake, and building data through the UI here
    // would tie this test to whichever layout the browser window happens to
    // produce — the headless viewport is wide, so there is no FAB, only the
    // master-detail pane header.

    // Account page → the delete flow.
    await tester.tap(find.byTooltip('Account').first);
    await pumpUntil(tester, find.text('Delete account'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete account'));
    await pumpUntil(tester, find.text('Delete account?'));

    // Reauthentication is asked for up front, before anything is destroyed.
    await tester.enterText(find.byType(TextField).last, password);
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Delete account'));

    // The account is gone, so auth state drops to null and the gate returns.
    await pumpUntil(tester, find.text('Create account'), maxPumps: 600);

    // The real proof: those credentials no longer belong to anyone. A mere
    // sign-out would let this succeed.
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.text('No routines yet'),
      findsNothing,
      reason: 'signing in with a deleted account must not succeed',
    );
    expect(find.text('Create account'), findsWidgets);
  });
}
