import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final exercisesStreamProvider = StreamProvider<List<Exercise>>((ref) {
  return ref.watch(databaseProvider).watchExercises();
});

final routineSummariesStreamProvider = StreamProvider<List<RoutineSummary>>((
  ref,
) {
  return ref.watch(databaseProvider).watchRoutineSummaries();
});

final fullRoutineProvider = StreamProvider.family<FullRoutine?, int>((
  ref,
  routineId,
) {
  return ref.watch(databaseProvider).watchFullRoutine(routineId);
});

final recentWorkoutsStreamProvider = StreamProvider<List<Workout>>((ref) {
  return ref.watch(databaseProvider).watchRecentWorkouts();
});

final fullWorkoutProvider = StreamProvider.family<FullWorkout?, int>((
  ref,
  workoutId,
) {
  return ref.watch(databaseProvider).watchFullWorkout(workoutId);
});
