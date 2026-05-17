import '../data/database.dart';

const routineBundleType = 'routine_bundle';
const workoutCompletedType = 'workout_completed';
const syncRequestType = 'sync_request';

class RoutineBundleMessage {
  const RoutineBundleMessage(this.routines);

  final List<RoutineTemplateDto> routines;

  Map<String, Object?> toPayload() => {
    'routines': routines.map((r) => r.toJson()).toList(),
  };

  static RoutineBundleMessage fromPayload(Map<String, Object?> json) {
    final raw = (json['routines'] as List?)?.cast<Object?>() ?? const [];
    final list = raw
        .map(
          (m) =>
              RoutineTemplateDto.fromJson((m as Map).cast<String, Object?>()),
        )
        .toList();
    return RoutineBundleMessage(list);
  }
}

class WorkoutCompletedMessage {
  const WorkoutCompletedMessage(this.workout);

  final WorkoutDto workout;

  Map<String, Object?> toPayload() => workout.toJson();

  static WorkoutCompletedMessage fromPayload(Map<String, Object?> json) {
    return WorkoutCompletedMessage(WorkoutDto.fromJson(json));
  }
}

class RoutineTemplateDto {
  RoutineTemplateDto({
    required this.syncId,
    required this.name,
    required this.version,
    required this.createdAtMs,
    required this.exercises,
  });

  final String syncId;
  final String name;
  final int version;
  final int createdAtMs;
  final List<RoutineExerciseDto> exercises;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'name': name,
    'version': version,
    'createdAtMs': createdAtMs,
    'exercises': exercises.map((e) => e.toJson()).toList(),
  };

  factory RoutineTemplateDto.fromJson(Map<String, Object?> json) {
    final raw = (json['exercises'] as List).cast<Object?>();
    return RoutineTemplateDto(
      syncId: json['syncId']! as String,
      name: json['name']! as String,
      version: (json['version']! as num).toInt(),
      createdAtMs: (json['createdAtMs']! as num).toInt(),
      exercises: raw
          .map(
            (m) =>
                RoutineExerciseDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
    );
  }

  static RoutineTemplateDto fromFullRoutine(FullRoutine full) {
    return RoutineTemplateDto(
      syncId: full.routine.syncId,
      name: full.routine.name,
      version: full.routine.version,
      createdAtMs: full.routine.createdAt.millisecondsSinceEpoch,
      exercises: [
        for (final re in full.exercises)
          RoutineExerciseDto.fromFullExercise(re),
      ],
    );
  }
}

class RoutineExerciseDto {
  RoutineExerciseDto({
    required this.syncId,
    required this.exerciseSyncId,
    required this.exerciseName,
    required this.orderIndex,
    required this.restSeconds,
    required this.plannedSets,
  });

  final String syncId;
  final String exerciseSyncId;
  final String exerciseName;
  final int orderIndex;
  final int restSeconds;
  final List<PlannedSetDto> plannedSets;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'exerciseSyncId': exerciseSyncId,
    'exerciseName': exerciseName,
    'orderIndex': orderIndex,
    'restSeconds': restSeconds,
    'plannedSets': plannedSets.map((s) => s.toJson()).toList(),
  };

  factory RoutineExerciseDto.fromJson(Map<String, Object?> json) {
    final raw = (json['plannedSets'] as List).cast<Object?>();
    return RoutineExerciseDto(
      syncId: json['syncId']! as String,
      exerciseSyncId: json['exerciseSyncId']! as String,
      exerciseName: json['exerciseName']! as String,
      orderIndex: (json['orderIndex']! as num).toInt(),
      restSeconds: (json['restSeconds']! as num).toInt(),
      plannedSets: raw
          .map(
            (m) => PlannedSetDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
    );
  }

  static RoutineExerciseDto fromFullExercise(FullRoutineExercise re) {
    return RoutineExerciseDto(
      syncId: re.routineExercise.syncId,
      exerciseSyncId: re.exercise.syncId,
      exerciseName: re.exercise.name,
      orderIndex: re.routineExercise.orderIndex,
      restSeconds: re.routineExercise.restSeconds,
      plannedSets: [
        for (final s in re.plannedSets) PlannedSetDto.fromPlannedSet(s),
      ],
    );
  }
}

class PlannedSetDto {
  PlannedSetDto({
    required this.syncId,
    required this.setIndex,
    required this.targetReps,
    required this.targetWeightKg,
  });

  final String syncId;
  final int setIndex;
  final int targetReps;
  final double targetWeightKg;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'setIndex': setIndex,
    'targetReps': targetReps,
    'targetWeightKg': targetWeightKg,
  };

  factory PlannedSetDto.fromJson(Map<String, Object?> json) {
    return PlannedSetDto(
      syncId: json['syncId']! as String,
      setIndex: (json['setIndex']! as num).toInt(),
      targetReps: (json['targetReps']! as num).toInt(),
      targetWeightKg: (json['targetWeightKg']! as num).toDouble(),
    );
  }

  static PlannedSetDto fromPlannedSet(PlannedSet ps) {
    return PlannedSetDto(
      syncId: ps.syncId,
      setIndex: ps.setIndex,
      targetReps: ps.targetReps,
      targetWeightKg: ps.targetWeightKg,
    );
  }
}

class WorkoutDto {
  WorkoutDto({
    required this.syncId,
    required this.routineSyncId,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.completions,
  });

  final String syncId;
  final String routineSyncId;
  final int startedAtMs;
  final int? endedAtMs;
  final List<SetCompletionDto> completions;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'routineSyncId': routineSyncId,
    'startedAtMs': startedAtMs,
    'endedAtMs': endedAtMs,
    'completions': completions.map((c) => c.toJson()).toList(),
  };

  factory WorkoutDto.fromJson(Map<String, Object?> json) {
    final raw = (json['completions'] as List).cast<Object?>();
    return WorkoutDto(
      syncId: json['syncId']! as String,
      routineSyncId: json['routineSyncId']! as String,
      startedAtMs: (json['startedAtMs']! as num).toInt(),
      endedAtMs: (json['endedAtMs'] as num?)?.toInt(),
      completions: raw
          .map(
            (m) =>
                SetCompletionDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
    );
  }
}

class SetCompletionDto {
  SetCompletionDto({
    required this.syncId,
    required this.plannedSetSyncId,
    required this.actualReps,
    required this.actualWeightKg,
    required this.completedAtMs,
  });

  final String syncId;
  final String plannedSetSyncId;
  final int actualReps;
  final double actualWeightKg;
  final int completedAtMs;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'plannedSetSyncId': plannedSetSyncId,
    'actualReps': actualReps,
    'actualWeightKg': actualWeightKg,
    'completedAtMs': completedAtMs,
  };

  factory SetCompletionDto.fromJson(Map<String, Object?> json) {
    return SetCompletionDto(
      syncId: json['syncId']! as String,
      plannedSetSyncId: json['plannedSetSyncId']! as String,
      actualReps: (json['actualReps']! as num).toInt(),
      actualWeightKg: (json['actualWeightKg']! as num).toDouble(),
      completedAtMs: (json['completedAtMs']! as num).toInt(),
    );
  }
}
