// Minimal web e2e: proves `flutter drive` + headless Chrome drives the widget
// tree in a real browser. Renders the sign-in screen (the web entry point) with
// no Firebase needed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/phone/sign_in_screen.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('web harness renders the sign-in screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SignInScreen())),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Gym Tracker'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    // Web enables the Google affordance (googleSignInSupported => kIsWeb).
    expect(find.text('Continue with Google'), findsOneWidget);
  });
}
