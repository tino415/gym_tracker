import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/selectable_on_web.dart';

/// Text selection is a web affordance: Flutter paints text to a canvas, so a
/// name on the web build cannot be highlighted or copied unless the tree opts
/// in. The phone and watch builds must stay opted *out* — [SelectionArea]
/// claims the long-press gesture on touch.
///
/// `flutter test` runs on the VM, so `kIsWeb` is false here and these cover the
/// device side of the gate. The web side needs a browser; see the consent-screen
/// verification task.
void main() {
  testWidgets('no SelectionArea off the web', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SelectableOnWeb(child: Text('Bench press')),
      ),
    );

    expect(find.byType(SelectionArea), findsNothing);
  });

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
