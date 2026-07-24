import 'package:drift/drift.dart' show Value;

import 'database.dart';
import 'repositories.dart';

/// Drift-backed implementations of the repository interfaces. Each method is a
/// straight forward to the equivalent [AppDatabase] method — no logic here.

class DriftRoutineRepository implements RoutineRepository {
  DriftRoutineRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<RoutineSummary>> watchRoutineSummaries() =>
      _db.watchRoutineSummaries();

  @override
  Stream<FullRoutine?> watchFullRoutine(int routineId) =>
      _db.watchFullRoutine(routineId);

  @override
  Future<FullRoutine?> loadFullRoutine(int routineId) =>
      _db.loadFullRoutine(routineId);

  @override
  Future<Routine> createRoutine(String name) => _db.createRoutine(name);

  @override
  Future<void> renameRoutine(int id, String name) =>
      _db.renameRoutine(id, name);

  @override
  Future<void> deleteRoutine(int id) => _db.deleteRoutine(id);

  @override
  Future<RoutineExercise> addExerciseToRoutine({
    required int routineId,
    required int exerciseId,
  }) =>
      _db.addExerciseToRoutine(routineId: routineId, exerciseId: exerciseId);

  @override
  Future<void> removeRoutineExercise(int routineExerciseId) =>
      _db.removeRoutineExercise(routineExerciseId);

  @override
  Future<void> reorderRoutineExercises({
    required int routineId,
    required List<int> orderedIds,
  }) =>
      _db.reorderRoutineExercises(routineId: routineId, orderedIds: orderedIds);

  @override
  Future<void> setRestSeconds(int routineExerciseId, int seconds) =>
      _db.setRestSeconds(routineExerciseId, seconds);

  @override
  Future<void> setSupersetGroup(int routineExerciseId, int? group) =>
      _db.setSupersetGroup(routineExerciseId, group);

  @override
  Future<PlannedSet> addPlannedSet({
    required int routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) =>
      _db.addPlannedSet(
        routineExerciseId: routineExerciseId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
      );

  @override
  Future<void> updatePlannedSet({
    required int id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) =>
      _db.updatePlannedSet(
        id: id,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
      );

  @override
  Future<void> deletePlannedSet(int id) => _db.deletePlannedSet(id);

  @override
  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required int routineExerciseId,
    required int exerciseId,
  }) =>
      _db.addRoutineExerciseAlternative(
        routineExerciseId: routineExerciseId,
        exerciseId: exerciseId,
      );

  @override
  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required int alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) =>
      _db.addAlternativePlannedSet(
        alternativeId: alternativeId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
      );

  @override
  Future<void> updateAlternativePlannedSet({
    required int id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) =>
      _db.updateAlternativePlannedSet(
        id: id,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
      );

  @override
  Future<void> deleteAlternativePlannedSet(int id) =>
      _db.deleteAlternativePlannedSet(id);

  @override
  Future<void> removeRoutineExerciseAlternative(int alternativeId) =>
      _db.removeRoutineExerciseAlternative(alternativeId);
}

class DriftExerciseRepository implements ExerciseRepository {
  DriftExerciseRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Exercise>> watchExercises() => _db.watchExercises();

  @override
  Stream<List<ExerciseWithMuscles>> watchExercisesWithMuscles() =>
      _db.watchExercisesWithMuscles();

  @override
  Stream<List<Muscle>> watchMuscles() => _db.watchMuscles();

  @override
  Future<List<Muscle>> musclesForExercise(int exerciseId) =>
      _db.musclesForExercise(exerciseId);

  @override
  Future<Exercise> createExercise(
    String name, {
    String kind = exerciseKindReps,
  }) =>
      _db.createExercise(name, kind: kind);

  @override
  Future<void> renameExercise(int id, String name) =>
      _db.renameExercise(id, name);

  @override
  Future<void> deleteExercise(int id) => _db.deleteExercise(id);

  @override
  Future<void> setExerciseKind(int id, String kind) =>
      _db.setExerciseKind(id, kind);

  @override
  Future<void> setExerciseMuscles(int exerciseId, List<int> muscleIds) =>
      _db.setExerciseMuscles(exerciseId, muscleIds);
}

class DriftWorkoutRepository implements WorkoutRepository {
  DriftWorkoutRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Workout>> watchRecentWorkouts() => _db.watchRecentWorkouts();

  @override
  Stream<Workout?> watchInProgressWorkout() => _db.watchInProgressWorkout();

  @override
  Stream<FullWorkout?> watchFullWorkout(int workoutId) =>
      _db.watchFullWorkout(workoutId);

  @override
  Future<List<WorkoutImprovement>> findWorkoutImprovements(int workoutId) =>
      _db.findWorkoutImprovements(workoutId);

  @override
  Future<void> applyWorkoutImprovements(int workoutId) =>
      _db.applyWorkoutImprovements(workoutId);

  @override
  Future<void> updateWorkoutTimes({
    required int workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  }) =>
      _db.updateWorkoutTimes(
        workoutId: workoutId,
        startedAt: startedAt,
        endedAt: endedAt,
      );

  @override
  Future<void> deleteWorkout(int workoutId) => _db.deleteWorkout(workoutId);

  @override
  Future<WorkoutExercise> addWorkoutExercise({
    required int workoutId,
    required int exerciseId,
  }) =>
      _db.addWorkoutExercise(workoutId: workoutId, exerciseId: exerciseId);

  @override
  Future<void> removeWorkoutExercise(int workoutExerciseId) =>
      _db.removeWorkoutExercise(workoutExerciseId);

  @override
  Future<WorkoutSet> addWorkoutSet({
    required int workoutExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) =>
      _db.addWorkoutSet(
        workoutExerciseId: workoutExerciseId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
      );

  @override
  Future<void> removeWorkoutSet(int workoutSetId) =>
      _db.removeWorkoutSet(workoutSetId);

  @override
  Future<SetCompletion> upsertSetCompletion({
    required int workoutId,
    required int workoutSetId,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    Value<int?> avgHeartRate = const Value.absent(),
    Value<int?> maxHeartRate = const Value.absent(),
  }) =>
      _db.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: workoutSetId,
        actualReps: actualReps,
        actualWeightKg: actualWeightKg,
        actualSeconds: actualSeconds,
        avgHeartRate: avgHeartRate,
        maxHeartRate: maxHeartRate,
      );

  @override
  Future<void> updateCompletion({
    required int id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    DateTime? completedAt,
  }) =>
      _db.updateCompletion(
        id: id,
        actualReps: actualReps,
        actualWeightKg: actualWeightKg,
        actualSeconds: actualSeconds,
        completedAt: completedAt,
      );

  @override
  Future<void> deleteCompletion(int id) => _db.deleteCompletion(id);
}
