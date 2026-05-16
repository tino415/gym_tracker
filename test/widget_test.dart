import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gym_tracker/main.dart';

void main() {
  testWidgets('Tapping the FAB increments the set count', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: PhoneHome()),
      ),
    );

    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
  });
}
