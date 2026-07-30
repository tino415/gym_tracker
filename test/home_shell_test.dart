import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gym_tracker/phone/home_shell.dart';
import 'package:gym_tracker/sync/auth_service.dart';

void main() {
  /// The account button renders nothing unless the backend is compiled in, so
  /// force it on. `authStateProvider` stays inert: `initFirebaseApp` returns
  /// false without the backend, so it emits a signed-out null and never
  /// touches FirebaseAuth.
  Widget host(GoRouter router) => ProviderScope(
        overrides: [authBackendEnabledProvider.overrideWithValue(true)],
        child: MaterialApp.router(routerConfig: router),
      );

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

    await tester.pumpWidget(host(buildRouter()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    // No rail on narrow, so no shell-level account button — each page's app bar
    // carries its own instead.
    expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
  });

  testWidgets('wide viewport uses the side NavigationRail', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(buildRouter()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    // Account sits at the foot of the rail, below the last destination, and is
    // the shell's only copy — the section panes no longer carry their own.
    final account = find.byIcon(Icons.account_circle_outlined);
    expect(account, findsOneWidget);
    expect(
      find.ancestor(of: account, matching: find.byType(NavigationRail)),
      findsOneWidget,
    );
    expect(
      tester.getCenter(account).dy,
      greaterThan(tester.getCenter(find.text('Workouts')).dy),
    );
  });

  testWidgets('rail selection switches branches', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(buildRouter()));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);

    await tester.tap(find.text('Exercises'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });
}
