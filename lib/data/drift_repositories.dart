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
  Stream<FullRoutine?> watchFullRoutine(String routineId) =>
      _db.watchFullRoutine(routineId);

  @override
  Future<FullRoutine?> loadFullRoutine(String routineId) =>
      _db.loadFullRoutine(routineId);

  @override
  Future<Routine> createRoutine(String name) => _db.createRoutine(name);

  @override
  Future<void> renameRoutine(String id, String name) =>
      _db.renameRoutine(id, name);

  @override
  Future<void> deleteRoutine(String id) => _db.deleteRoutine(id);

  @override
  Future<RoutineExercise> addExerciseToRoutine({
    required String routineId,
    required String exerciseId,
  }) =>
      _db.addExerciseToRoutine(routineId: routineId, exerciseId: exerciseId);

  @override
  Future<void> removeRoutineExercise(String routineExerciseId) =>
      _db.removeRoutineExercise(routineExerciseId);

  @override
  Future<void> reorderRoutineExercises({
    required String routineId,
    required List<String> orderedIds,
  }) =>
      _db.reorderRoutineExercises(routineId: routineId, orderedIds: orderedIds);

  @override
  Future<void> setRestSeconds(String routineExerciseId, int seconds) =>
      _db.setRestSeconds(routineExerciseId, seconds);

  @override
  Future<void> setCircuitGroup(String routineExerciseId, int? group) =>
      _db.setCircuitGroup(routineExerciseId, group);

  @override
  Future<PlannedSet> addPlannedSet({
    required String routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
    ParamValues? targetParams,
  }) =>
      _db.addPlannedSet(
        routineExerciseId: routineExerciseId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
        targetParams: targetParams,
      );

  @override
  Future<void> updatePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
    ParamValues? targetParams,
  }) =>
      _db.updatePlannedSet(
        id: id,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
        targetParams: targetParams,
      );

  @override
  Future<void> deletePlannedSet(String id) => _db.deletePlannedSet(id);

  @override
  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required String routineExerciseId,
    required String exerciseId,
  }) =>
      _db.addRoutineExerciseAlternative(
        routineExerciseId: routineExerciseId,
        exerciseId: exerciseId,
      );

  @override
  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required String alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
    ParamValues? targetParams,
  }) =>
      _db.addAlternativePlannedSet(
        alternativeId: alternativeId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
        targetParams: targetParams,
      );

  @override
  Future<void> updateAlternativePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
    ParamValues? targetParams,
  }) =>
      _db.updateAlternativePlannedSet(
        id: id,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
        targetParams: targetParams,
      );

  @override
  Future<void> deleteAlternativePlannedSet(String id) =>
      _db.deleteAlternativePlannedSet(id);

  @override
  Future<void> removeRoutineExerciseAlternative(String alternativeId) =>
      _db.removeRoutineExerciseAlternative(alternativeId);
}

class DriftExerciseRepository implements ExerciseRepository {
  DriftExerciseRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Exercise>> watchExercises() => _db.watchExercises();

  @override
  Future<bool> hasAnyExercise() => _db.hasAnyExercise();

  @override
  Stream<List<ExerciseWithMuscles>> watchExercisesWithMuscles() =>
      _db.watchExercisesWithMuscles();

  @override
  Stream<List<Muscle>> watchMuscles() => _db.watchMuscles();

  @override
  Future<List<Muscle>> musclesForExercise(String exerciseId) =>
      _db.musclesForExercise(exerciseId);

  @override
  Future<Exercise> createExercise(
    String name, {
    String kind = exerciseKindReps,
  }) =>
      _db.createExercise(name, kind: kind);

  @override
  Future<int> writeCatalogExercises(List<CatalogExercise> entries) =>
      _db.writeCatalogExercises(entries);

  @override
  Future<void> renameExercise(String id, String name) =>
      _db.renameExercise(id, name);

  @override
  Future<void> deleteExercise(String id) => _db.deleteExercise(id);

  @override
  Future<void> setExerciseKind(String id, String kind) =>
      _db.setExerciseKind(id, kind);

  @override
  Future<void> setExerciseParams(String id, List<ParamEntry> order) =>
      _db.setExerciseParams(id, order);

  @override
  Future<void> setExerciseMuscles(String exerciseId, List<String> muscleIds) =>
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
  Stream<FullWorkout?> watchFullWorkout(String workoutId) =>
      _db.watchFullWorkout(workoutId);

  @override
  Future<List<WorkoutImprovement>> findWorkoutImprovements(String workoutId) =>
      _db.findWorkoutImprovements(workoutId);

  @override
  Future<SetCompletion?> lastCompletionForExerciseAtSetIndex({
    required String exerciseId,
    required int setIndex,
    required String excludeWorkoutId,
  }) => _db.lastCompletionForExerciseAtSetIndex(
    exerciseId: exerciseId,
    setIndex: setIndex,
    excludeWorkoutId: excludeWorkoutId,
  );

  @override
  Future<Workout> createWorkout({
    String? routineId,
    required DateTime startedAt,
    DateTime? endedAt,
  }) =>
      _db.createWorkout(
        routineId: routineId,
        startedAt: startedAt,
        endedAt: endedAt,
      );

  @override
  Future<void> applyWorkoutImprovements(String workoutId) =>
      _db.applyWorkoutImprovements(workoutId);

  @override
  Future<void> updateWorkoutTimes({
    required String workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  }) =>
      _db.updateWorkoutTimes(
        workoutId: workoutId,
        startedAt: startedAt,
        endedAt: endedAt,
      );

  @override
  Future<void> deleteWorkout(String workoutId) => _db.deleteWorkout(workoutId);

  @override
  Future<WorkoutExercise> addWorkoutExercise({
    required String workoutId,
    required String exerciseId,
  }) =>
      _db.addWorkoutExercise(workoutId: workoutId, exerciseId: exerciseId);

  @override
  Future<void> removeWorkoutExercise(String workoutExerciseId) =>
      _db.removeWorkoutExercise(workoutExerciseId);

  @override
  Future<void> changeWorkoutExercise({
    required String workoutExerciseId,
    required String exerciseId,
  }) => _db.changeWorkoutExercise(
    workoutExerciseId: workoutExerciseId,
    exerciseId: exerciseId,
  );

  @override
  Future<void> reorderWorkoutExercises({
    required String workoutId,
    required List<String> orderedIds,
  }) => _db.reorderWorkoutExercises(
    workoutId: workoutId,
    orderedIds: orderedIds,
  );

  @override
  Future<WorkoutSet> addWorkoutSet({
    required String workoutExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
    ParamValues? targetParams,
  }) =>
      _db.addWorkoutSet(
        workoutExerciseId: workoutExerciseId,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        targetSeconds: targetSeconds,
        targetParams: targetParams,
      );

  @override
  Future<void> removeWorkoutSet(String workoutSetId) =>
      _db.removeWorkoutSet(workoutSetId);

  @override
  Future<SetCompletion> upsertSetCompletion({
    required String workoutId,
    required String workoutSetId,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    ParamValues? actualParams,
    Value<int?> avgHeartRate = const Value.absent(),
    Value<int?> maxHeartRate = const Value.absent(),
  }) =>
      _db.upsertSetCompletion(
        workoutId: workoutId,
        workoutSetId: workoutSetId,
        actualReps: actualReps,
        actualWeightKg: actualWeightKg,
        actualSeconds: actualSeconds,
        actualParams: actualParams,
        avgHeartRate: avgHeartRate,
        maxHeartRate: maxHeartRate,
      );

  @override
  Future<void> updateCompletion({
    required String id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    ParamValues? actualParams,
    DateTime? completedAt,
  }) =>
      _db.updateCompletion(
        id: id,
        actualReps: actualReps,
        actualWeightKg: actualWeightKg,
        actualSeconds: actualSeconds,
        actualParams: actualParams,
        completedAt: completedAt,
      );

  @override
  Future<void> deleteCompletion(String id) => _db.deleteCompletion(id);
}
