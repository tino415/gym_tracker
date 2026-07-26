import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'breakpoints.dart';
import 'exercises/exercise_edit_page.dart';
import 'exercises/exercises_list_page.dart';
import 'history/history_list_page.dart';
import 'history/workout_detail_page.dart';
import 'home_shell.dart';
import 'routines/routine_edit_page.dart';
import 'routines/routine_exercise_detail_page.dart';
import 'routines/routines_list_page.dart';
import 'settings/account_page.dart';
import 'settings/theme_controller.dart';

final _rootKey = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/routines',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          HomeShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/routines',
              builder: (context, state) => const RoutinesListPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  parentNavigatorKey: _rootKey,
                  builder: (context, state) => const RoutineEditPage(),
                ),
                GoRoute(
                  path: ':id',
                  parentNavigatorKey: _rootKey,
                  builder: (context, state) => RoutineEditPage(
                    routineId: state.pathParameters['id']!,
                  ),
                  routes: [
                    GoRoute(
                      path: 'exercises/:reId',
                      parentNavigatorKey: _rootKey,
                      builder: (context, state) => RoutineExerciseDetailPage(
                        routineId: state.pathParameters['id']!,
                        routineExerciseId:
                            state.pathParameters['reId']!,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/exercises',
              builder: (context, state) => const ExercisesListPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  parentNavigatorKey: _rootKey,
                  builder: (context, state) => const ExerciseEditPage(),
                ),
                GoRoute(
                  path: ':id',
                  parentNavigatorKey: _rootKey,
                  builder: (context, state) => ExerciseEditPage(
                    exerciseId: state.pathParameters['id']!,
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/history',
              builder: (context, state) => const HistoryListPage(),
              routes: [
                GoRoute(
                  path: ':id',
                  parentNavigatorKey: _rootKey,
                  builder: (context, state) => WorkoutDetailPage(
                    workoutId: state.pathParameters['id']!,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/account',
      parentNavigatorKey: _rootKey,
      builder: (context, state) => const AccountPage(),
    ),
  ],
);

class PhoneApp extends ConsumerWidget {
  const PhoneApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Gym Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: _router,
      // Cap every route to a centered max-width column so the app reads as a
      // focused editor on wide desktop/web windows instead of stretching edge
      // to edge; a no-op on phones (viewport < maxWidth). The margins take a
      // subtle surface tint so the column reads as an app window. The cap is
      // [routinesWideMaxWidth] to give the Routines 3-pane view room; within it
      // the 2-pane sections (Exercises / Workouts) fill the width, list pane
      // flush to the rail.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: routinesWideMaxWidth),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
