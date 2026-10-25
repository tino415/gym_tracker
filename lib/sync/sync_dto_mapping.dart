import '../data/database.dart';
import 'sync_dtos.dart';

RoutineTemplateDto routineTombstoneToDto(Routine routine) {
  return RoutineTemplateDto(
    syncId: routine.syncId,
    name: routine.name,
    version: routine.version,
    createdAtMs: routine.createdAt.millisecondsSinceEpoch,
    deletedAtMs: routine.deletedAt?.millisecondsSinceEpoch,
    exercises: const [],
  );
}

RoutineExerciseDto routineExerciseToDto(FullRoutineExercise re) {
  return RoutineExerciseDto(
    syncId: re.routineExercise.syncId,
    exerciseSyncId: re.exercise.syncId,
    exerciseName: re.exercise.name,
    exerciseKind: re.exercise.kind,
    orderIndex: re.routineExercise.orderIndex,
    restSeconds: re.routineExercise.restSeconds,
    circuitGroup: re.routineExercise.circuitGroup,
    plannedSets: [for (final s in re.plannedSets) plannedSetToDto(s)],
    alternatives: const [], // populated by repository (needs syncIds)
    muscleSyncIds: [for (final m in re.muscles) m.syncId],
  );
}

PlannedSetDto plannedSetToDto(PlannedSet ps) {
  return PlannedSetDto(
    syncId: ps.syncId,
    setIndex: ps.setIndex,
    targetReps: ps.targetReps,
    targetWeightKg: ps.targetWeightKg,
    targetSeconds: ps.targetSeconds,
  );
}

ExerciseDto exerciseToDto(Exercise e, List<String> muscleSyncIds) {
  return ExerciseDto(
    syncId: e.syncId,
    name: e.name,
    kind: e.kind,
    version: e.version,
    createdAtMs: e.createdAt.millisecondsSinceEpoch,
    muscleSyncIds: muscleSyncIds,
  );
}

ExerciseDto exerciseTombstoneToDto(Exercise e) {
  return ExerciseDto(
    syncId: e.syncId,
    name: e.name,
    kind: e.kind,
    version: e.version,
    createdAtMs: e.createdAt.millisecondsSinceEpoch,
    deletedAtMs: e.deletedAt?.millisecondsSinceEpoch,
  );
}
