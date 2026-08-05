import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/phone/breakpoints.dart';
import 'package:gym_tracker/phone/settings/account_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The account screen is a column of form controls, not a list of rows, so it
/// gets its own narrow cap. Without one it inherits the app's outer width —
/// sized for the three-pane Routines view — and a theme picker and two switches
/// stretch across the whole browser window.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<double> contentWidth(WidgetTester tester, Size viewport) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountPage())),
    );
    await tester.pump();
    return tester.getSize(find.byType(ListView).first).width;
  }

  testWidgets('stays a readable column on a desktop viewport', (tester) async {
    final width = await contentWidth(tester, const Size(1600, 900));

    expect(width, lessThanOrEqualTo(settingsMaxWidth));
    // The failure this guards against is "spreads across the window", so pin it
    // against the viewport too — an absolute bound alone would still pass if
    // the cap were raised to something silly.
    expect(width, lessThan(1600 * 0.5));
  });

  testWidgets('uses the full width of a phone', (tester) async {
    // The cap is a maximum, not a fixed width: on a narrow screen the column
    // should still fill it rather than sit in wasted margins.
    final width = await contentWidth(tester, const Size(400, 900));

    expect(width, 400);
  });
}
