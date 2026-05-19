import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'exercises/exercise_edit_page.dart';
import 'exercises/exercises_list_page.dart';
import 'history/history_list_page.dart';
import 'history/workout_detail_page.dart';
import 'home_shell.dart';
import 'routines/routine_edit_page.dart';
import 'routines/routine_exercise_detail_page.dart';
import 'routines/routines_list_page.dart';

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
                    routineId: int.parse(state.pathParameters['id']!),
                  ),
                  routes: [
                    GoRoute(
                      path: 'exercises/:reId',
                      parentNavigatorKey: _rootKey,
                      builder: (context, state) => RoutineExerciseDetailPage(
                        routineId: int.parse(state.pathParameters['id']!),
                        routineExerciseId:
                            int.parse(state.pathParameters['reId']!),
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
                    exerciseId: int.parse(state.pathParameters['id']!),
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
                    workoutId: int.parse(state.pathParameters['id']!),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

class PhoneApp extends StatelessWidget {
  const PhoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Gym Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}
