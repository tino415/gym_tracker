import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/watch/watch_app.dart';

/// The watch shipped light for a long time because `ColorScheme.fromSeed`
/// defaults to `Brightness.light` when no brightness is passed — a silent
/// default, invisible in review. These assertions are what makes a revert loud.
///
/// Pumped in ambient mode on purpose: the ambient face needs no providers, so
/// the theme can be read back without a database.
void main() {
  testWidgets('WatchApp renders on a dark scheme over true black', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: WatchApp(ambient: true)),
    );

    final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, Colors.black);
  });

  test('watchTheme carries the dark scheme through to legacy ThemeData fields', () {
    // disabledColor is not part of ColorScheme — the disabled rail chevron in
    // watch_run_page reads it, and it derives from the scheme's brightness.
    expect(watchTheme().disabledColor, Colors.white38);
  });
}
