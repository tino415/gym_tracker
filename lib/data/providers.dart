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

final workoutSummariesStreamProvider =
    StreamProvider<List<WorkoutSummary>>((ref) {
  return ref.watch(databaseProvider).watchWorkoutSummaries();
});

final fullWorkoutProvider =
    StreamProvider.family<FullWorkout?, int>((ref, workoutId) {
  return ref.watch(databaseProvider).watchFullWorkout(workoutId);
});

final recentSessionsStreamProvider = StreamProvider<List<Session>>((ref) {
  return ref.watch(databaseProvider).watchRecentSessions();
});
