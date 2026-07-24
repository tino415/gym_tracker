import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'drift_repositories.dart';
import 'repositories.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final routineRepositoryProvider = Provider<RoutineRepository>(
  (ref) => DriftRoutineRepository(ref.watch(databaseProvider)),
);

final exerciseRepositoryProvider = Provider<ExerciseRepository>(
  (ref) => DriftExerciseRepository(ref.watch(databaseProvider)),
);

final workoutRepositoryProvider = Provider<WorkoutRepository>(
  (ref) => DriftWorkoutRepository(ref.watch(databaseProvider)),
);

final exercisesStreamProvider = StreamProvider<List<Exercise>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchExercises();
});

final musclesStreamProvider = StreamProvider<List<Muscle>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchMuscles();
});

final exercisesWithMusclesStreamProvider =
    StreamProvider<List<ExerciseWithMuscles>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchExercisesWithMuscles();
});

final routineSummariesStreamProvider = StreamProvider<List<RoutineSummary>>((
  ref,
) {
  return ref.watch(routineRepositoryProvider).watchRoutineSummaries();
});

final fullRoutineProvider = StreamProvider.family<FullRoutine?, String>((
  ref,
  routineId,
) {
  return ref.watch(routineRepositoryProvider).watchFullRoutine(routineId);
});

final recentWorkoutsStreamProvider = StreamProvider<List<Workout>>((ref) {
  return ref.watch(workoutRepositoryProvider).watchRecentWorkouts();
});

final inProgressWorkoutStreamProvider = StreamProvider<Workout?>((ref) {
  return ref.watch(workoutRepositoryProvider).watchInProgressWorkout();
});

final fullWorkoutProvider = StreamProvider.family<FullWorkout?, String>((
  ref,
  workoutId,
) {
  return ref.watch(workoutRepositoryProvider).watchFullWorkout(workoutId);
});
