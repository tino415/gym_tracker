import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gym_tracker/phone/home_shell.dart';

void main() {
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/a',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (c, s, shell) => HomeShell(navigationShell: shell),
            branches: [
              StatefulShellBranch(
                routes: [GoRoute(path: '/a', builder: (_, _) => const Text('A'))],
              ),
              StatefulShellBranch(
                routes: [GoRoute(path: '/b', builder: (_, _) => const Text('B'))],
              ),
              StatefulShellBranch(
                routes: [GoRoute(path: '/c', builder: (_, _) => const Text('C'))],
              ),
            ],
          ),
        ],
      );

  testWidgets('narrow viewport uses the bottom NavigationBar', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('wide viewport uses the side NavigationRail', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('rail selection switches branches', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp.router(routerConfig: buildRouter()));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);

    await tester.tap(find.text('Exercises'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });
}
