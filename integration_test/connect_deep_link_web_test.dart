// An assistant's sign-in lands on `/#/connect?request=…`. Signed out, the app
// shows the boot and sign-in screens, then the consent page, against the real
// web engine and Auth emulator. This harness keeps routes out of the address
// bar, so what the app reports there is checked by hand.
//
//   just e2e-web-connect     (needs the emulator suite running)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/main.dart';
import 'package:gym_tracker/phone/phone_app.dart';
import 'package:gym_tracker/sync/connect_gateway.dart';
import 'package:integration_test/integration_test.dart';

import 'support/connect_request.dart';

class _UnusedGateway implements ConnectGateway {
  @override
  Future<Uri> decide(String request, ConnectDecision decision) =>
      throw UnimplementedError();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxPumps = 300,
  }) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  testWidgets('web: a /connect link survives sign-in and asks for consent', (
    tester,
  ) async {
    final connectRoute = '/connect?request=${fakeConnectRequest('Claude')}';
    final email = 'connect-${DateTime.now().millisecondsSinceEpoch}@test.co';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isWatchProvider.overrideWithValue(false),
          // Stands in for main(), which this test does not run.
          launchRouteProvider.overrideWithValue(connectRoute),
          connectGatewayProvider.overrideWithValue(_UnusedGateway()),
        ],
        child: const GymTrackerRoot(isWatch: false),
      ),
    );

    await pumpUntil(tester, find.text('Create account'));
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), 'password');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Create account'));

    await pumpUntil(tester, find.text('Connect Claude to GymTracker?'));
  });
}
