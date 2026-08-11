import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/selectable_on_web.dart';

/// Text selection is a web affordance: Flutter paints text to a canvas, so a
/// name on the web build cannot be highlighted or copied unless the tree opts
/// in. The phone and watch builds must stay opted *out* — [SelectionArea]
/// claims the long-press gesture on touch.
///
/// Both directions of the gate are asserted, and which one runs depends on where
/// the suite runs: `just test` (VM) covers the device side, `just test-web`
/// (Chrome) covers the web side. Neither alone proves the widget does anything —
/// the whole point of it is that the two platforms differ.
void main() {
  testWidgets('no SelectionArea off the web', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SelectableOnWeb(child: Text('Bench press')),
      ),
    );

    expect(find.byType(SelectionArea), findsNothing);
  }, skip: kIsWeb);

  testWidgets('a SelectionArea on the web', (tester) async {
    // The half that could not be tested before `just test-web` existed: on the
    // VM this branch never executes, so "it compiles" was the only evidence
    // that the web build gained selection at all.
    await tester.pumpWidget(
      const MaterialApp(
        home: SelectableOnWeb(child: Text('Bench press')),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
  }, skip: !kIsWeb);

  testWidgets('the child renders either way', (tester) async {
    // The wrapper is transparent: gating it must never cost a widget its place
    // in the tree, since it wraps every route in the app.
    await tester.pumpWidget(
      const MaterialApp(
        home: SelectableOnWeb(child: Text('Bench press')),
      ),
    );

    expect(find.text('Bench press'), findsOneWidget);
  });
}
