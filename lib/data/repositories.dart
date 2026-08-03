import 'package:drift/drift.dart' show Value;

import 'database.dart';

/// Repository seam over [AppDatabase]. These interfaces mirror the database
/// method surface used by the phone UI so that a non-Drift (e.g. Firestore)
/// implementation can later be swapped in behind the same providers.
///
/// Signatures are intentionally identical to the [AppDatabase] methods they
/// wrap — this is an additive, behavior-preserving seam.

/// Routine reads (summaries + full routine) and every routine /
/// routine-exercise / planned-set / alternative mutation used by the phone UI.
abstract class RoutineRepository {
  // Reads
  Stream<List<RoutineSummary>> watchRoutineSummaries();
  Stream<FullRoutine?> watchFullRoutine(String routineId);
  Future<FullRoutine?> loadFullRoutine(String routineId);

  // Routine mutations
  Future<Routine> createRoutine(String name);
  Future<void> renameRoutine(String id, String name);
  Future<void> deleteRoutine(String id);

  // Routine-exercise mutations
  Future<RoutineExercise> addExerciseToRoutine({
    required String routineId,
    required String exerciseId,
  });
  Future<void> removeRoutineExercise(String routineExerciseId);
  Future<void> reorderRoutineExercises({
    required String routineId,
    required List<String> orderedIds,
  });
  Future<void> setRestSeconds(String routineExerciseId, int seconds);
  Future<void> setSupersetGroup(String routineExerciseId, int? group);

  // Planned-set mutations
  Future<PlannedSet> addPlannedSet({
    required String routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> updatePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> deletePlannedSet(String id);

  // Alternative mutations
  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required String routineExerciseId,
    required String exerciseId,
  });
  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required String alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> updateAlternativePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> deleteAlternativePlannedSet(String id);
  Future<void> removeRoutineExerciseAlternative(String alternativeId);
}

/// Exercise & muscle reads and exercise mutations used by the phone UI.
abstract class ExerciseRepository {
  // Reads
  Stream<List<Exercise>> watchExercises();
  Stream<List<ExerciseWithMuscles>> watchExercisesWithMuscles();
  Stream<List<Muscle>> watchMuscles();
  Future<List<Muscle>> musclesForExercise(String exerciseId);

  // Mutations
  Future<Exercise> createExercise(String name, {String kind = exerciseKindReps});
  Future<void> renameExercise(String id, String name);
  Future<void> deleteExercise(String id);
  Future<void> setExerciseKind(String id, String kind);
  Future<void> setExerciseMuscles(String exerciseId, List<String> muscleIds);
}

/// Workout reads and history-editing mutations used by the phone UI.
abstract class WorkoutRepository {
  // Reads
  Stream<List<Workout>> watchRecentWorkouts();
  Stream<Workout?> watchInProgressWorkout();
  Stream<FullWorkout?> watchFullWorkout(String workoutId);
  Future<List<WorkoutImprovement>> findWorkoutImprovements(String workoutId);

  /// What was last logged for [exerciseId] at [setIndex], ignoring
  /// [excludeWorkoutId] (the live session) and any unfinished or tombstoned
  /// workout. Null when the exercise has no history at that set index. The run
  /// pages show it as a reference point next to the current set's target.
  Future<SetCompletion?> lastCompletionForExerciseAtSetIndex({
    required String exerciseId,
    required int setIndex,
    required String excludeWorkoutId,
  });

  // History-editing mutations
  /// Create a workout for manual backfill: optionally snapshot [routineId]'s
  /// exercises + target sets (no completions), with the given times. Null/
  /// unknown routine yields an empty workout the user fills in by hand.
  Future<Workout> createWorkout({
    String? routineId,
    required DateTime startedAt,
    DateTime? endedAt,
  });
  Future<void> applyWorkoutImprovements(String workoutId);
  Future<void> updateWorkoutTimes({
    required String workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  });
  Future<void> deleteWorkout(String workoutId);
  Future<WorkoutExercise> addWorkoutExercise({
    required String workoutId,
    required String exerciseId,
  });
  Future<void> removeWorkoutExercise(String workoutExerciseId);

  /// Reorder the workout's own exercise snapshot. [orderedIds] is every
  /// workout-exercise syncId in the wanted order.
  Future<void> reorderWorkoutExercises({
    required String workoutId,
    required List<String> orderedIds,
  });
  Future<WorkoutSet> addWorkoutSet({
    required String workoutExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> removeWorkoutSet(String workoutSetId);
  Future<SetCompletion> upsertSetCompletion({
    required String workoutId,
    required String workoutSetId,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    Value<int?> avgHeartRate = const Value.absent(),
    Value<int?> maxHeartRate = const Value.absent(),
  });
  Future<void> updateCompletion({
    required String id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    DateTime? completedAt,
  });
  Future<void> deleteCompletion(String id);
}
