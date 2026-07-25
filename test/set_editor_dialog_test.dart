import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart'
    show exerciseKindReps, exerciseKindTime;
import 'package:gym_tracker/phone/routines/set_editor_dialog.dart';

void main() {
  Future<void> open(WidgetTester tester, Widget dialog) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('add mode: Save & add persists a set and stays open',
      (tester) async {
    final added = <SetValues>[];
    final updated = <String>[];
    await open(
      tester,
      SetEditorDialog(
        kind: exerciseKindReps,
        onAdd: (v) async => added.add(v),
        onUpdate: (id, v) async => updated.add(id),
      ),
    );
    expect(find.text('New set'), findsOneWidget);

    // Defaults are weight 20 / reps 10.
    await tester.tap(find.text('Save & add'));
    await tester.pumpAndSettle();
    expect(added, hasLength(1));
    expect(added.single.reps, 10);
    expect(added.single.weightKg, 20);
    expect(updated, isEmpty);
    // Still open, with a running count.
    expect(find.text('New set · 1 added'), findsOneWidget);

    await tester.tap(find.text('Save & add'));
    await tester.pumpAndSettle();
    expect(added, hasLength(2));

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(SetEditorDialog), findsNothing);
  });

  testWidgets('edit mode: Save updates once and closes', (tester) async {
    final added = <SetValues>[];
    final updated = <String>[];
    await open(
      tester,
      SetEditorDialog(
        kind: exerciseKindReps,
        existingId: 'ps1',
        initialReps: 5,
        initialWeightKg: 100,
        onAdd: (v) async => added.add(v),
        onUpdate: (id, v) async => updated.add(id),
      ),
    );
    expect(find.text('Edit set'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(updated, ['ps1']);
    expect(added, isEmpty);
    expect(find.byType(SetEditorDialog), findsNothing);
  });

  testWidgets('Enter (submit action) saves the set', (tester) async {
    final added = <SetValues>[];
    await open(
      tester,
      SetEditorDialog(
        kind: exerciseKindReps,
        onAdd: (v) async => added.add(v),
        onUpdate: (_, _) async {},
      ),
    );
    // Type a weight and press Enter (the field's submit action).
    await tester.enterText(find.byType(TextField).first, '35');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(added, hasLength(1));
    expect(added.single.weightKg, 35);
  });

  testWidgets('time-kind shows a Seconds field', (tester) async {
    await open(
      tester,
      SetEditorDialog(
        kind: exerciseKindTime,
        onAdd: (_) async {},
        onUpdate: (_, _) async {},
      ),
    );
    expect(find.text('Seconds'), findsOneWidget);
    expect(find.text('Reps'), findsNothing);
  });
}
