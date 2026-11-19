import '../data/exercise_kind.dart';
import '../data/exercise_params.dart';

const routineBundleType = 'routine_bundle';
const workoutCompletedType = 'workout_completed';
const syncRequestType = 'sync_request';

/// Non-destructive routine upsert. Unlike [routineBundleType] — which is an
/// authoritative full snapshot that deletes local routines not present — this
/// carries one or more routines to merge, leaving others untouched. Used by
/// the Firestore transport, where each device owns a shared document set and
/// deletions arrive separately as [routineDeletedType].
const routineUpsertType = 'routine_upsert';

/// Explicit deletion of routines by sync id (payload: {'syncIds': [...]}).
const routineDeletedType = 'routine_deleted';

/// Exercise-library sync (payload: {'exercises': [...]}). Applied
/// non-destructively with version-LWW; deletions ride as tombstones inside the
/// list (an [ExerciseDto] with a non-null `deletedAtMs`), so no destructive
/// "delete absent" variant is needed.
const exerciseBundleType = 'exercise_bundle';

/// Reads the circuit group, falling back to the pre-v15 `supersetGroup` key.
///
/// Compatibility shim, not a permanent alias: Firestore documents written
/// before the rename keep the old key until something bumps their version and
/// rewrites them, and past workout docs never will (their version is frozen).
/// Without this a synced history entry would come back ungrouped. Safe to drop
/// once no old documents remain.
///
/// Keys on *presence*, not on null: the web edits a document in place, so an
/// ungrouped exercise can carry `circuitGroup: null` next to a stale
/// `supersetGroup: 1`, and `??` would revive the group it just removed.
int? _readCircuitGroup(Map<String, Object?> json) {
  final raw = json.containsKey('circuitGroup')
      ? json['circuitGroup']
      : json['supersetGroup'];
  return (raw as num?)?.toInt();
}

/// Structural equality for JSON-shaped values (the DTO payloads are maps of
/// primitives, lists, and nested maps — no Firestore Timestamps, since all
/// times are stored as epoch-millisecond ints). Dart's `Map ==` is identity, so
/// echo suppression and no-op detection both need this.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

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

class RoutineDeletedMessage {
  const RoutineDeletedMessage(this.syncIds);

  final List<String> syncIds;

  Map<String, Object?> toPayload() => {'syncIds': syncIds};

  static RoutineDeletedMessage fromPayload(Map<String, Object?> json) {
    final raw = (json['syncIds'] as List?)?.cast<Object?>() ?? const [];
    // Skip non-string ids rather than throwing, so one malformed entry doesn't
    // sink the whole deletion batch (the caller swallows exceptions).
    return RoutineDeletedMessage(raw.whereType<String>().toList());
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
    this.deletedAtMs,
  });

  final String syncId;
  final String name;
  final int version;
  final int createdAtMs;
  final List<RoutineExerciseDto> exercises;
  // Non-null marks a versioned tombstone (the routine was deleted at this
  // instant). Carried in the ordinary bundle so deletions arbitrate by
  // [version] like edits; a tombstone's [exercises] is empty.
  final int? deletedAtMs;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'name': name,
    'version': version,
    'createdAtMs': createdAtMs,
    'exercises': exercises.map((e) => e.toJson()).toList(),
    'deletedAtMs': deletedAtMs,
  };

  factory RoutineTemplateDto.fromJson(Map<String, Object?> json) {
    final raw = (json['exercises'] as List).cast<Object?>();
    return RoutineTemplateDto(
      syncId: json['syncId']! as String,
      name: json['name']! as String,
      version: (json['version']! as num).toInt(),
      createdAtMs: (json['createdAtMs']! as num).toInt(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
      exercises: raw
          .map(
            (m) =>
                RoutineExerciseDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
    );
  }
}

class RoutineExerciseDto {
  RoutineExerciseDto({
    required this.syncId,
    required this.exerciseSyncId,
    required this.exerciseName,
    required this.exerciseKind,
    required this.orderIndex,
    required this.restSeconds,
    required this.circuitGroup,
    required this.plannedSets,
    this.alternatives = const [],
    this.muscleSyncIds = const [],
    this.exerciseParams = defaultParamOrder,
  });

  final String syncId;
  final String exerciseSyncId;
  final String exerciseName;
  final String exerciseKind;
  final List<ParamEntry> exerciseParams;
  final int orderIndex;
  final int restSeconds;
  final int? circuitGroup;
  final List<PlannedSetDto> plannedSets;
  final List<AlternativeRefDto> alternatives;
  // Sync ids of muscles tagged on the canonical exercise. Receiver applies
  // these to the local Exercise after resolving syncId → local row.
  final List<String> muscleSyncIds;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'exerciseSyncId': exerciseSyncId,
    'exerciseName': exerciseName,
    'exerciseKind': exerciseKind,
    'exerciseParams': paramOrderToJson(exerciseParams),
    'orderIndex': orderIndex,
    'restSeconds': restSeconds,
    'circuitGroup': circuitGroup,
    'plannedSets': plannedSets.map((s) => s.toJson()).toList(),
    'alternatives': alternatives.map((a) => a.toJson()).toList(),
    'muscleSyncIds': muscleSyncIds,
  };

  factory RoutineExerciseDto.fromJson(Map<String, Object?> json) {
    final raw = (json['plannedSets'] as List).cast<Object?>();
    final rawAlts = (json['alternatives'] as List?)?.cast<Object?>() ?? const [];
    final rawMuscles = (json['muscleSyncIds'] as List?)?.cast<Object?>() ?? const [];
    return RoutineExerciseDto(
      syncId: json['syncId']! as String,
      exerciseSyncId: json['exerciseSyncId']! as String,
      exerciseName: json['exerciseName']! as String,
      exerciseKind:
          (json['exerciseKind'] as String?) ?? exerciseKindReps,
      exerciseParams: paramOrderFromJson(json['exerciseParams']),
      orderIndex: (json['orderIndex']! as num).toInt(),
      restSeconds: (json['restSeconds']! as num).toInt(),
      circuitGroup: _readCircuitGroup(json),
      plannedSets: raw
          .map(
            (m) => PlannedSetDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
      alternatives: rawAlts
          .map(
            (m) => AlternativeRefDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
      muscleSyncIds: rawMuscles.map((s) => s as String).toList(),
    );
  }
}

/// Reference to one alternative exercise of a routine slot.
class AlternativeRefDto {
  AlternativeRefDto({
    required this.syncId,
    required this.exerciseSyncId,
    required this.exerciseName,
    required this.exerciseKind,
    required this.orderIndex,
    this.plannedSets = const [],
    this.exerciseParams = defaultParamOrder,
  });

  final String syncId;
  final String exerciseSyncId;
  final String exerciseName;
  final String exerciseKind;
  final List<ParamEntry> exerciseParams;
  final int orderIndex;
  // Per-alternative planned sets. Empty list = alternative inherits the
  // primary's targets at swap time.
  final List<PlannedSetDto> plannedSets;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'exerciseSyncId': exerciseSyncId,
    'exerciseName': exerciseName,
    'exerciseKind': exerciseKind,
    'exerciseParams': paramOrderToJson(exerciseParams),
    'orderIndex': orderIndex,
    'plannedSets': plannedSets.map((s) => s.toJson()).toList(),
  };

  factory AlternativeRefDto.fromJson(Map<String, Object?> json) {
    final raw = (json['plannedSets'] as List?)?.cast<Object?>() ?? const [];
    return AlternativeRefDto(
      syncId: json['syncId']! as String,
      exerciseSyncId: json['exerciseSyncId']! as String,
      exerciseName: json['exerciseName']! as String,
      exerciseKind: (json['exerciseKind'] as String?) ?? exerciseKindReps,
      exerciseParams: paramOrderFromJson(json['exerciseParams']),
      orderIndex: (json['orderIndex']! as num).toInt(),
      plannedSets: raw
          .map(
            (m) => PlannedSetDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
    );
  }
}

class PlannedSetDto {
  PlannedSetDto({
    required this.syncId,
    required this.setIndex,
    required this.targetReps,
    required this.targetWeightKg,
    required this.targetSeconds,
    this.targetParams,
  });

  final String syncId;
  final int setIndex;
  final int? targetReps;
  final double? targetWeightKg;
  final int? targetSeconds;
  final ParamValues? targetParams;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'setIndex': setIndex,
    'targetReps': targetReps,
    'targetWeightKg': targetWeightKg,
    'targetSeconds': targetSeconds,
    'targetParams': targetParams,
  };

  factory PlannedSetDto.fromJson(Map<String, Object?> json) {
    return PlannedSetDto(
      syncId: json['syncId']! as String,
      setIndex: (json['setIndex']! as num).toInt(),
      targetReps: (json['targetReps'] as num?)?.toInt(),
      targetWeightKg: (json['targetWeightKg'] as num?)?.toDouble(),
      targetSeconds: (json['targetSeconds'] as num?)?.toInt(),
      targetParams: paramValuesFromJson(json['targetParams']),
    );
  }
}

/// One exercise-library entry (the canonical exercise, not a routine slot).
/// Carries its muscle tags as deterministic muscle syncIds. A non-null
/// [deletedAtMs] marks a versioned tombstone (empty muscle tags).
class ExerciseDto {
  ExerciseDto({
    required this.syncId,
    required this.name,
    required this.kind,
    required this.version,
    required this.createdAtMs,
    this.muscleSyncIds = const [],
    this.deletedAtMs,
    this.params = defaultParamOrder,
  });

  final String syncId;
  final String name;
  final String kind;
  final List<ParamEntry> params;
  final int version;
  final int createdAtMs;
  final List<String> muscleSyncIds;
  final int? deletedAtMs;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'name': name,
    'kind': kind,
    'params': paramOrderToJson(params),
    'version': version,
    'createdAtMs': createdAtMs,
    'muscleSyncIds': muscleSyncIds,
    'deletedAtMs': deletedAtMs,
  };

  factory ExerciseDto.fromJson(Map<String, Object?> json) {
    final rawMuscles =
        (json['muscleSyncIds'] as List?)?.cast<Object?>() ?? const [];
    return ExerciseDto(
      syncId: json['syncId']! as String,
      name: json['name']! as String,
      kind: (json['kind'] as String?) ?? exerciseKindReps,
      params: paramOrderFromJson(json['params']),
      version: (json['version']! as num).toInt(),
      createdAtMs: (json['createdAtMs']! as num).toInt(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
      muscleSyncIds: rawMuscles.map((s) => s as String).toList(),
    );
  }
}

class ExerciseBundleMessage {
  const ExerciseBundleMessage(this.exercises);

  final List<ExerciseDto> exercises;

  Map<String, Object?> toPayload() => {
    'exercises': exercises.map((e) => e.toJson()).toList(),
  };

  static ExerciseBundleMessage fromPayload(Map<String, Object?> json) {
    final raw = (json['exercises'] as List?)?.cast<Object?>() ?? const [];
    final list = raw
        .map((m) => ExerciseDto.fromJson((m as Map).cast<String, Object?>()))
        .toList();
    return ExerciseBundleMessage(list);
  }
}

class WorkoutDto {
  WorkoutDto({
    required this.syncId,
    required this.routineSyncId,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.exercises,
    required this.completions,
    this.heartRateSamples = const [],
    this.version = 1,
    this.deletedAtMs,
    this.routineName,
    this.avgHeartRate,
    this.maxHeartRate,
  });

  /// A deletion travelling as a versioned marker: no snapshot, just the id,
  /// the version that deleted it, and when. [startedAtMs] rides along because a
  /// receiver that has never seen this workout still has to insert a row, and
  /// `Workouts.startedAt` is non-null.
  factory WorkoutDto.tombstone({
    required String syncId,
    required int version,
    required int deletedAtMs,
    required int startedAtMs,
    String? routineName,
  }) => WorkoutDto(
    syncId: syncId,
    routineSyncId: null,
    routineName: routineName,
    startedAtMs: startedAtMs,
    endedAtMs: null,
    exercises: const [],
    completions: const [],
    version: version,
    deletedAtMs: deletedAtMs,
  );

  final String syncId;
  /// Routine sync id at the time the workout started. May reference a routine
  /// that no longer exists on the receiver — workouts are self-contained.
  final String? routineSyncId;

  /// The routine's name at start, carried in the snapshot so history renders it
  /// without the (possibly-deleted) routine. Null for pre-column workouts.
  final String? routineName;
  final int startedAtMs;
  final int? endedAtMs;
  final List<WorkoutExerciseDto> exercises;
  final List<SetCompletionDto> completions;

  /// Heart rate over the session, oldest first. Empty for workouts recorded
  /// without a sensor — phone runs and backfills — and for peers that predate
  /// the field, which is why it defaults rather than being required.
  final List<HeartRateSampleDto> heartRateSamples;
  final int? avgHeartRate;
  final int? maxHeartRate;

  /// Monotonic edit counter for LWW arbitration. Defaults to 1 so a message
  /// from a pre-versioning peer (or a legacy server doc) still parses.
  final int version;

  /// Non-null marks a versioned tombstone; [exercises] / [completions] are empty.
  final int? deletedAtMs;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'routineSyncId': routineSyncId,
    'routineName': routineName,
    'startedAtMs': startedAtMs,
    'endedAtMs': endedAtMs,
    'exercises': exercises.map((e) => e.toJson()).toList(),
    'completions': completions.map((c) => c.toJson()).toList(),
    'heartRateSamples': heartRateSamples.map((s) => s.toJson()).toList(),
    'avgHeartRate': avgHeartRate,
    'maxHeartRate': maxHeartRate,
    'version': version,
    // Always emitted, as explicit null when live, so the Firestore transport's
    // content compare sees the same key set on both sides.
    'deletedAtMs': deletedAtMs,
  };

  factory WorkoutDto.fromJson(Map<String, Object?> json) {
    final rawExercises = (json['exercises'] as List?)?.cast<Object?>() ??
        const [];
    final rawCompletions =
        (json['completions'] as List?)?.cast<Object?>() ?? const [];
    final rawSamples =
        (json['heartRateSamples'] as List?)?.cast<Object?>() ?? const [];
    return WorkoutDto(
      syncId: json['syncId']! as String,
      routineSyncId: json['routineSyncId'] as String?,
      routineName: json['routineName'] as String?,
      startedAtMs: (json['startedAtMs']! as num).toInt(),
      endedAtMs: (json['endedAtMs'] as num?)?.toInt(),
      exercises: rawExercises
          .map(
            (m) =>
                WorkoutExerciseDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
      completions: rawCompletions
          .map(
            (m) =>
                SetCompletionDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
      heartRateSamples: rawSamples
          .map(
            (m) => HeartRateSampleDto.fromJson(
              (m as Map).cast<String, Object?>(),
            ),
          )
          .toList(),
      avgHeartRate: (json['avgHeartRate'] as num?)?.toInt(),
      maxHeartRate: (json['maxHeartRate'] as num?)?.toInt(),
      // Tolerant, unlike RoutineTemplateDto: workouts predate versioning, so
      // docs and peers without the field must read as version 1, not throw.
      version: (json['version'] as num?)?.toInt() ?? 1,
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// One heart-rate reading in a workout's series.
///
/// Keys are terse on purpose. A workout carries hundreds of these, so at this
/// size the field names are a real fraction of the payload — and the payload
/// travels inside a single Firestore document, which caps at 1 MiB.
///
/// [tMs] is epoch milliseconds, matching the integer column it comes from:
/// drift stores `DateTime` as unix seconds, and losing the sub-second part
/// would break the export/apply content comparison that suppresses sync echoes.
class HeartRateSampleDto {
  HeartRateSampleDto({required this.tMs, required this.bpm, this.accuracy});

  final int tMs;
  final int bpm;

  /// Sensor confidence (`kHrAccuracy*`), omitted from the JSON when null so a
  /// series recorded before the field existed costs nothing to carry — and so a
  /// peer on an older build still round-trips a document byte-identically.
  final int? accuracy;

  Map<String, Object?> toJson() => {
        't': tMs,
        'bpm': bpm,
        if (accuracy != null) 'a': accuracy,
      };

  factory HeartRateSampleDto.fromJson(Map<String, Object?> json) =>
      HeartRateSampleDto(
        tMs: (json['t']! as num).toInt(),
        bpm: (json['bpm']! as num).toInt(),
        accuracy: (json['a'] as num?)?.toInt(),
      );
}

class WorkoutExerciseDto {
  WorkoutExerciseDto({
    required this.syncId,
    required this.exerciseSyncId,
    required this.exerciseName,
    required this.kind,
    required this.orderIndex,
    required this.restSeconds,
    required this.circuitGroup,
    required this.sets,
    this.routineExerciseSyncId,
    this.params = defaultParamOrder,
  });

  final String syncId;
  final String? exerciseSyncId;
  final String exerciseName;
  final String kind;
  final List<ParamEntry> params;
  final int orderIndex;
  final int restSeconds;
  final int? circuitGroup;
  final List<WorkoutSetDto> sets;
  // Sync id of the routine slot the workout exercise was created from. The
  // receiver resolves this to a local routine_exercise row to enable
  // mid-workout swap; nullable since pre-v6 / orphaned snapshots have none.
  final String? routineExerciseSyncId;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'exerciseSyncId': exerciseSyncId,
    'exerciseName': exerciseName,
    'kind': kind,
    'params': paramOrderToJson(params),
    'orderIndex': orderIndex,
    'restSeconds': restSeconds,
    'circuitGroup': circuitGroup,
    'sets': sets.map((s) => s.toJson()).toList(),
    'routineExerciseSyncId': routineExerciseSyncId,
  };

  factory WorkoutExerciseDto.fromJson(Map<String, Object?> json) {
    final raw = (json['sets'] as List?)?.cast<Object?>() ?? const [];
    return WorkoutExerciseDto(
      syncId: json['syncId']! as String,
      exerciseSyncId: json['exerciseSyncId'] as String?,
      exerciseName: json['exerciseName']! as String,
      kind: (json['kind'] as String?) ?? exerciseKindReps,
      params: paramOrderFromJson(json['params']),
      orderIndex: (json['orderIndex']! as num).toInt(),
      restSeconds: (json['restSeconds']! as num).toInt(),
      circuitGroup: _readCircuitGroup(json),
      sets: raw
          .map(
            (m) => WorkoutSetDto.fromJson((m as Map).cast<String, Object?>()),
          )
          .toList(),
      routineExerciseSyncId: json['routineExerciseSyncId'] as String?,
    );
  }
}

class WorkoutSetDto {
  WorkoutSetDto({
    required this.syncId,
    required this.setIndex,
    required this.targetReps,
    required this.targetWeightKg,
    required this.targetSeconds,
    this.targetParams,
  });

  final String syncId;
  final int setIndex;
  final int? targetReps;
  final double? targetWeightKg;
  final int? targetSeconds;
  final ParamValues? targetParams;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'setIndex': setIndex,
    'targetReps': targetReps,
    'targetWeightKg': targetWeightKg,
    'targetSeconds': targetSeconds,
    'targetParams': targetParams,
  };

  factory WorkoutSetDto.fromJson(Map<String, Object?> json) {
    return WorkoutSetDto(
      syncId: json['syncId']! as String,
      setIndex: (json['setIndex']! as num).toInt(),
      targetReps: (json['targetReps'] as num?)?.toInt(),
      targetWeightKg: (json['targetWeightKg'] as num?)?.toDouble(),
      targetSeconds: (json['targetSeconds'] as num?)?.toInt(),
      targetParams: paramValuesFromJson(json['targetParams']),
    );
  }
}

class SetCompletionDto {
  SetCompletionDto({
    required this.syncId,
    required this.workoutSetSyncId,
    required this.actualReps,
    required this.actualWeightKg,
    required this.actualSeconds,
    required this.completedAtMs,
    this.actualParams,
    this.avgHeartRate,
    this.maxHeartRate,
  });

  final String syncId;
  final String workoutSetSyncId;
  final int? actualReps;
  final double? actualWeightKg;
  final int? actualSeconds;
  final ParamValues? actualParams;
  final int completedAtMs;
  final int? avgHeartRate;
  final int? maxHeartRate;

  Map<String, Object?> toJson() => {
    'syncId': syncId,
    'workoutSetSyncId': workoutSetSyncId,
    'actualReps': actualReps,
    'actualWeightKg': actualWeightKg,
    'actualSeconds': actualSeconds,
    'actualParams': actualParams,
    'completedAtMs': completedAtMs,
    'avgHeartRate': avgHeartRate,
    'maxHeartRate': maxHeartRate,
  };

  factory SetCompletionDto.fromJson(Map<String, Object?> json) {
    return SetCompletionDto(
      syncId: json['syncId']! as String,
      workoutSetSyncId: json['workoutSetSyncId']! as String,
      actualReps: (json['actualReps'] as num?)?.toInt(),
      actualWeightKg: (json['actualWeightKg'] as num?)?.toDouble(),
      actualSeconds: (json['actualSeconds'] as num?)?.toInt(),
      actualParams: paramValuesFromJson(json['actualParams']),
      completedAtMs: (json['completedAtMs']! as num).toInt(),
      avgHeartRate: (json['avgHeartRate'] as num?)?.toInt(),
      maxHeartRate: (json['maxHeartRate'] as num?)?.toInt(),
    );
  }
}
