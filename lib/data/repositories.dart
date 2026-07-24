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
  Stream<FullRoutine?> watchFullRoutine(int routineId);
  Future<FullRoutine?> loadFullRoutine(int routineId);

  // Routine mutations
  Future<Routine> createRoutine(String name);
  Future<void> renameRoutine(int id, String name);
  Future<void> deleteRoutine(int id);

  // Routine-exercise mutations
  Future<RoutineExercise> addExerciseToRoutine({
    required int routineId,
    required int exerciseId,
  });
  Future<void> removeRoutineExercise(int routineExerciseId);
  Future<void> reorderRoutineExercises({
    required int routineId,
    required List<int> orderedIds,
  });
  Future<void> setRestSeconds(int routineExerciseId, int seconds);
  Future<void> setSupersetGroup(int routineExerciseId, int? group);

  // Planned-set mutations
  Future<PlannedSet> addPlannedSet({
    required int routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> updatePlannedSet({
    required int id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> deletePlannedSet(int id);

  // Alternative mutations
  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required int routineExerciseId,
    required int exerciseId,
  });
  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required int alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> updateAlternativePlannedSet({
    required int id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> deleteAlternativePlannedSet(int id);
  Future<void> removeRoutineExerciseAlternative(int alternativeId);
}

/// Exercise & muscle reads and exercise mutations used by the phone UI.
abstract class ExerciseRepository {
  // Reads
  Stream<List<Exercise>> watchExercises();
  Stream<List<ExerciseWithMuscles>> watchExercisesWithMuscles();
  Stream<List<Muscle>> watchMuscles();
  Future<List<Muscle>> musclesForExercise(int exerciseId);

  // Mutations
  Future<Exercise> createExercise(String name, {String kind = exerciseKindReps});
  Future<void> renameExercise(int id, String name);
  Future<void> deleteExercise(int id);
  Future<void> setExerciseKind(int id, String kind);
  Future<void> setExerciseMuscles(int exerciseId, List<int> muscleIds);
}

/// Workout reads and history-editing mutations used by the phone UI.
abstract class WorkoutRepository {
  // Reads
  Stream<List<Workout>> watchRecentWorkouts();
  Stream<Workout?> watchInProgressWorkout();
  Stream<FullWorkout?> watchFullWorkout(int workoutId);
  Future<List<WorkoutImprovement>> findWorkoutImprovements(int workoutId);

  // History-editing mutations
  Future<void> applyWorkoutImprovements(int workoutId);
  Future<void> updateWorkoutTimes({
    required int workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  });
  Future<void> deleteWorkout(int workoutId);
  Future<WorkoutExercise> addWorkoutExercise({
    required int workoutId,
    required int exerciseId,
  });
  Future<void> removeWorkoutExercise(int workoutExerciseId);
  Future<WorkoutSet> addWorkoutSet({
    required int workoutExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  });
  Future<void> removeWorkoutSet(int workoutSetId);
  Future<SetCompletion> upsertSetCompletion({
    required int workoutId,
    required int workoutSetId,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    Value<int?> avgHeartRate = const Value.absent(),
    Value<int?> maxHeartRate = const Value.absent(),
  });
  Future<void> updateCompletion({
    required int id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    DateTime? completedAt,
  });
  Future<void> deleteCompletion(int id);
}
