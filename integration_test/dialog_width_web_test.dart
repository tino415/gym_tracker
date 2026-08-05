// Measures the "New exercise" dialog in a real browser at desktop width:
//
//   just _web-drive integration_test/dialog_width_web_test.dart
//
// This dialog only takes its AlertDialog form above the master-detail
// breakpoint, which no phone or Android emulator reaches — even in landscape,
// which is why an on-device check kept showing the bottom sheet instead. The
// headless browser is wide, so it is the only place the wide branch actually
// renders.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/main.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int maxPumps = 400}) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets, reason: 'timed out waiting for $finder');
  }

  /// Width of the visible surface of the dialog whose title is [title].
  ///
  /// Scoped by title, not `find.byType(Dialog).first`: the create dialog opens
  /// *over* the picker, so both are in the tree and `.first` silently measures
  /// the one underneath. Measuring the AlertDialog itself is no good either —
  /// its render box spans the whole route and always reports the viewport.
  double dialogWidth(WidgetTester tester, String title) {
    final dialog =
        find.ancestor(of: find.text(title), matching: find.byType(Dialog)).first;
    return tester
        .getSize(
          find.descendant(of: dialog, matching: find.byType(Material)).first,
        )
        .width;
  }

  testWidgets('the New exercise dialog stays narrow on a desktop viewport',
      (tester) async {
    final email = 'dlg-${DateTime.now().millisecondsSinceEpoch}@test.co';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [isWatchProvider.overrideWithValue(false)],
        child: const GymTrackerRoot(isWatch: false),
      ),
    );

    await pumpUntil(tester, find.text('Create account'));
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), 'password');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Create account'));
    await pumpUntil(tester, find.text('No routines yet'));

    final viewport = tester.view.physicalSize.width / tester.view.devicePixelRatio;

    // A routine to open the picker from. The wide layout has no FAB — the
    // list pane header carries the + instead.
    await tester.tap(find.byTooltip('New routine'));
    await pumpUntil(tester, find.text('New routine'));
    await tester.enterText(find.byType(TextField).first, 'Dialog Probe');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await pumpUntil(tester, find.byTooltip('Add exercise'));

    await tester.tap(find.byTooltip('Add exercise'));
    await pumpUntil(tester, find.text('Create new exercise'));
    final pickerWidth = dialogWidth(tester, "Add exercise");

    await tester.tap(find.text('Create new exercise'));
    await pumpUntil(tester, find.text('New exercise'));
    final createWidth = dialogWidth(tester, "New exercise");

    // With SizedBox(width: double.maxFinite) this measured 1420 against a 1600
    // viewport — the whole window. It is 468 now (420 of content plus the
    // dialog's padding). Asserting against the viewport as well as an absolute
    // bound, so the test still means something at a different window size.
    expect(
      createWidth,
      lessThan(520),
      reason: 'the New exercise dialog must not stretch across the window',
    );
    expect(createWidth, lessThan(viewport * 0.5));
    // The two open one from the other, so a big jump between them reads as a
    // glitch even when neither is full-width.
    expect((createWidth - pickerWidth).abs(), lessThan(120));
  });
}
