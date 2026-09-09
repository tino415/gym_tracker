import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

import 'circuit_rest_v15.dart';
import 'muscle_seeds.dart';

part 'database.g.dart';

const _uuid = Uuid();

// Exercise kinds. Reps-based exercises track reps + weight per set; time-based
// exercises track a duration per set.
const exerciseKindReps = 'reps';
const exerciseKindTime = 'time';

/// One starter-catalogue row as the write path needs it: identity, display and
/// tags, with nothing derived at write time so two installs seeding the same
/// entry produce the same document.
///
/// Lives here rather than beside the repository seam because [AppDatabase]
/// takes it too, and the seam already imports this file.
class CatalogExercise {
  const CatalogExercise({
    required this.syncId,
    required this.name,
    required this.kind,
    required this.muscleSyncIds,
    required this.createdAt,
  });

  final String syncId;
  final String name;
  final String kind;
  final List<String> muscleSyncIds;
  final DateTime createdAt;
}

// Every table is keyed by its `syncId` (a uuid string) — the same identity
// used across the Wear bridge and Firestore. There is no separate autoincrement
// int id: Drift rows, server docs, and the UI all address by this one string,
// so a server-backed store needs no id synthesis. Foreign keys reference the
// parent's `syncId`.

class Exercises extends Table {
  TextColumn get syncId => text()();
  TextColumn get name => text().unique()();
  DateTimeColumn get createdAt => dateTime()();
  // Literal rather than [exerciseKindReps]: `drift_dev schema dump` copies this
  // expression verbatim into the schema JSON, and the code it generates from
  // that imports only drift — a named constant there fails to compile in the
  // migration tests. The default is frozen into the schema anyway.
  TextColumn get kind => text().withDefault(const Constant('reps'))();
  IntColumn get version => integer().withDefault(const Constant(1))();
  // Non-null marks a versioned tombstone: the exercise was deleted at this
  // instant, but the row survives (with a bumped [version]) so the deletion
  // participates in version-LWW sync. Library reads (watchExercises,
  // loadExercisesWithMuscles, the exercise picker) skip tombstoned rows;
  // routine/workout joins deliberately do NOT, so a routine that still
  // references a deleted exercise keeps rendering its name.
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

class Routines extends Table {
  TextColumn get syncId => text()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  // Non-null marks a versioned tombstone: the routine was deleted at this
  // instant, but the row survives (with a bumped [version]) so the deletion
  // participates in version-LWW sync instead of travelling out-of-band. Reads
  // skip tombstoned rows; a later higher-or-equal-version non-tombstone edit
  // clears it (a legitimate revive). See lib/sync/sync_repository.dart.
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

class RoutineExercises extends Table {
  TextColumn get syncId => text()();
  TextColumn get routineId =>
      text().references(Routines, #syncId, onDelete: KeyAction.cascade)();
  TextColumn get exerciseId =>
      text().references(Exercises, #syncId, onDelete: KeyAction.restrict)();
  IntColumn get orderIndex => integer()();
  // Rest taken *after* this exercise's set. For a circuit member that is the
  // transition to the next member; for the last member of a round it is the
  // round rest. 0 = advance immediately.
  IntColumn get restSeconds => integer().withDefault(const Constant(90))();
  // Exercises sharing a non-null group on the same routine form a circuit:
  // their sets alternate at run time (set 1 of every member, then set 2, …).
  // Null = standalone. Two members with 0 rest on the first is the classic
  // superset; more members with real rests is circuit training.
  IntColumn get circuitGroup => integer().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

class PlannedSets extends Table {
  TextColumn get syncId => text()();
  TextColumn get routineExerciseId => text().references(
    RoutineExercises,
    #syncId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get setIndex => integer()();
  // For reps-kind exercises:
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  // For time-kind exercises:
  IntColumn get targetSeconds => integer().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Alternative exercises for a routine slot. The user can swap to any of these
/// mid-workout (e.g., dumbbell bench if the barbell is occupied). Lives on the
/// routine — workouts read these on demand via [WorkoutExercises.routineExerciseId].
class RoutineExerciseAlternatives extends Table {
  TextColumn get syncId => text()();
  TextColumn get routineExerciseId => text().references(
    RoutineExercises,
    #syncId,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get exerciseId =>
      text().references(Exercises, #syncId, onDelete: KeyAction.restrict)();
  IntColumn get orderIndex => integer()();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Per-alternative planned sets. Mirrors [PlannedSets] but FK'd to an
/// alternative row. Empty list means the alternative shares the primary's
/// targets at swap time — feature is opt-in per alternative.
class AlternativePlannedSets extends Table {
  TextColumn get syncId => text()();
  TextColumn get alternativeId => text().references(
    RoutineExerciseAlternatives,
    #syncId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get setIndex => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetSeconds => integer().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Muscle group registry. Seeded with a standard set; users may add more.
class Muscles extends Table {
  TextColumn get syncId => text()();
  TextColumn get name => text().unique()();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Many-to-many: which muscles an exercise targets.
class ExerciseMuscles extends Table {
  TextColumn get exerciseId =>
      text().references(Exercises, #syncId, onDelete: KeyAction.cascade)();
  TextColumn get muscleId =>
      text().references(Muscles, #syncId, onDelete: KeyAction.cascade)();
  @override
  Set<Column> get primaryKey => {exerciseId, muscleId};
}

class Workouts extends Table {
  TextColumn get syncId => text()();
  // Nullable + SET NULL: the workout owns a snapshot of its routine, so
  // deleting the routine just severs the link, the workout stays.
  TextColumn get routineId => text()
      .nullable()
      .references(Routines, #syncId, onDelete: KeyAction.setNull)();
  // The routine's name at start, copied into the snapshot so history renders it
  // even after the routine is deleted (routineId is severed on delete). Null
  // for workouts started before this column existed.
  TextColumn get routineName => text().nullable()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  // Workout-level heart-rate aggregates computed on Finish from the per-set
  // completion aggregates. Null until a workout finishes (or if no HR samples
  // were captured).
  IntColumn get avgHeartRate => integer().nullable()();
  IntColumn get maxHeartRate => integer().nullable()();
  // Monotonic edit counter, bumped by every mutation of the workout or its
  // snapshot. Sync arbitrates by it (last-writer-wins per syncId), same as
  // [Routines] / [Exercises] — a workout is owned by the device that ran it, so
  // whole-workout granularity is enough.
  IntColumn get version => integer().withDefault(const Constant(1))();
  // Non-null marks a versioned tombstone: the child rows are gone but the row
  // stays so the deletion can travel and outrank a stale re-creation.
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Snapshot of a routine exercise taken when a workout starts. Owned by the
/// workout — survives routine edits and routine deletion.
class WorkoutExercises extends Table {
  TextColumn get syncId => text()();
  TextColumn get workoutId =>
      text().references(Workouts, #syncId, onDelete: KeyAction.cascade)();
  // Link back to the canonical Exercise for analytics. SET NULL on delete so
  // history survives the source exercise being removed.
  TextColumn get exerciseId => text().nullable().references(
    Exercises,
    #syncId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get exerciseName => text()();
  IntColumn get orderIndex => integer()();
  IntColumn get restSeconds => integer().withDefault(const Constant(90))();
  IntColumn get circuitGroup => integer().nullable()();
  // Literal, for the schema-dump reason on `Exercises.kind`.
  TextColumn get kind => text().withDefault(const Constant('reps'))();
  // Back-pointer to the routine slot this workout exercise was created from.
  // SET NULL on delete so a routine edit that removes the slot mid-workout
  // gracefully disables mid-workout swap without breaking the workout itself.
  TextColumn get routineExerciseId => text().nullable().references(
    RoutineExercises,
    #syncId,
    onDelete: KeyAction.setNull,
  )();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Snapshot of a planned set taken when a workout starts.
class WorkoutSets extends Table {
  TextColumn get syncId => text()();
  TextColumn get workoutExerciseId => text()
      .references(WorkoutExercises, #syncId, onDelete: KeyAction.cascade)();
  IntColumn get setIndex => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetSeconds => integer().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

class SetCompletions extends Table {
  TextColumn get syncId => text()();
  TextColumn get workoutId =>
      text().references(Workouts, #syncId, onDelete: KeyAction.cascade)();
  // Bound to the workout's own snapshot, not back to the routine's planned_set.
  TextColumn get workoutSetId =>
      text().references(WorkoutSets, #syncId, onDelete: KeyAction.cascade)();
  IntColumn get actualReps => integer().nullable()();
  RealColumn get actualWeightKg => real().nullable()();
  IntColumn get actualSeconds => integer().nullable()();
  DateTimeColumn get completedAt => dateTime()();
  // Per-set heart-rate aggregates over the time the set was active. Nullable
  // because earlier rows / sets recorded without HR permission won't have them.
  IntColumn get avgHeartRate => integer().nullable()();
  IntColumn get maxHeartRate => integer().nullable()();
  @override
  Set<Column> get primaryKey => {syncId};
}

/// Heart rate over a workout, as a timestamped series rather than the avg/max
/// aggregates on [Workouts] and [SetCompletions]. Health Connect's
/// `HeartRateRecord` wants samples; averages cannot honestly be turned back
/// into them. The aggregates stay: the history UI reads those, and recomputing
/// them from the series on every render would be wasteful.
///
/// Two deliberate departures from every other table here:
///
/// * **No `syncId`.** Samples are replaced wholesale with the workout snapshot
///   and never edited one at a time, so a stable id buys nothing — and at ~720
///   rows per workout, 36-character uuids would dominate the sync payload.
///   `{workoutId, measuredAtMs}` is the natural identity.
/// * **`measuredAtMs` is an integer, not a `DateTime`.** Drift stores
///   `DateTime` as unix *seconds*. Sync suppresses echoes by comparing an
///   exported workout's JSON against the incoming DTO, so a timestamp that lost
///   its sub-second part on the way through the database would never compare
///   equal, and every workout carrying heart rate would re-push on every sync,
///   forever.
/// Row class named explicitly: the default would be `HeartRateSample`, which
/// already means the live sensor reading from `WorkoutBridge`. Two types with
/// one name across the run page is a needless ambiguity.
@DataClassName('HeartRateReading')
class HeartRateSamples extends Table {
  TextColumn get workoutId =>
      text().references(Workouts, #syncId, onDelete: KeyAction.cascade)();
  IntColumn get measuredAtMs => integer()();
  IntColumn get bpm => integer()();

  /// What the sensor thought of this reading (`kHrAccuracy*` in
  /// `lib/watch/heart_rate_thinning.dart`), or null on rows recorded before the
  /// column existed — and on any device that reports no confidence at all.
  ///
  /// Recorded, not enforced: nothing filters on it yet. It exists because a
  /// motion-artifact plateau is smooth and physiologically plausible, so no
  /// statistic over bpm alone can tell it from real effort, and gating *capture*
  /// on confidence is the one thing already known to fail (it deletes the work
  /// intervals — see `WorkoutService.hasContact`).
  IntColumn get accuracy => integer().nullable()();
  @override
  Set<Column> get primaryKey => {workoutId, measuredAtMs};
}

class FullRoutine {
  FullRoutine({required this.routine, required this.exercises});
  final Routine routine;
  final List<FullRoutineExercise> exercises;
}

/// Exercise + its muscle tags, for list/registry rendering.
class ExerciseWithMuscles {
  ExerciseWithMuscles({required this.exercise, required this.muscles});
  final Exercise exercise;
  final List<Muscle> muscles;
}

class FullRoutineExercise {
  FullRoutineExercise({
    required this.routineExercise,
    required this.exercise,
    required this.plannedSets,
    this.alternatives = const [],
    this.muscles = const [],
  });
  final RoutineExercise routineExercise;
  final Exercise exercise;
  final List<PlannedSet> plannedSets;
  // Alternative exercises for this slot, ordered by `orderIndex`. Each carries
  // its own (optional) planned sets — empty list = share the primary's.
  final List<RoutineAlternative> alternatives;
  // Muscles targeted by [exercise]. Same shape on every variant slot.
  final List<Muscle> muscles;
  String get kind => exercise.kind;
}

/// One alternative on a routine slot: the join row, the canonical exercise,
/// and its (optional) own planned sets.
class RoutineAlternative {
  RoutineAlternative({
    required this.join,
    required this.exercise,
    required this.plannedSets,
  });
  final RoutineExerciseAlternative join;
  final Exercise exercise;
  final List<AlternativePlannedSet> plannedSets;
}

class RoutineSummary {
  RoutineSummary({required this.routine, required this.exerciseCount});
  final Routine routine;
  final int exerciseCount;
}

class FullWorkout {
  FullWorkout({
    required this.workout,
    required this.routine,
    required this.exercises,
  });
  final Workout workout;
  final Routine? routine;
  final List<FullWorkoutExercise> exercises;
}

class FullWorkoutExercise {
  FullWorkoutExercise({required this.workoutExercise, required this.sets});
  final WorkoutExercise workoutExercise;
  final List<FullWorkoutSet> sets;
  String get kind => workoutExercise.kind;
}

class FullWorkoutSet {
  FullWorkoutSet({required this.workoutSet, required this.completion});
  final WorkoutSet workoutSet;
  final SetCompletion? completion;
}

/// One outstanding improvement found in a finished workout: the user's actuals
/// strictly beat the routine's current target for this set. The phone surfaces
/// these in a banner on the workout-detail page so the user can promote them
/// to the routine with one tap.
class WorkoutImprovement {
  WorkoutImprovement({
    required this.exerciseName,
    required this.kind,
    required this.setIndex,
    required this.targetPlannedSetId,
    required this.targetIsAlternative,
    required this.oldReps,
    required this.oldWeightKg,
    required this.oldSeconds,
    required this.newReps,
    required this.newWeightKg,
    required this.newSeconds,
  });
  final String exerciseName;
  final String kind;
  final int setIndex;
  // Either a PlannedSets.syncId or an AlternativePlannedSets.syncId — `targetIsAlternative` discriminates.
  final String targetPlannedSetId;
  final bool targetIsAlternative;
  final int? oldReps;
  final double? oldWeightKg;
  final int? oldSeconds;
  final int? newReps;
  final double? newWeightKg;
  final int? newSeconds;
}

/// Small key/value store for sync bookkeeping that isn't domain data — e.g. the
/// account that owns this install's local store (see `sync_ownership.dart`).
/// Lives in Drift rather than a separate plugin so it works on every platform
/// the app already persists on (native, web IndexedDB/OPFS) and in tests.
class SyncMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    Exercises,
    Routines,
    RoutineExercises,
    PlannedSets,
    RoutineExerciseAlternatives,
    AlternativePlannedSets,
    Muscles,
    ExerciseMuscles,
    Workouts,
    WorkoutExercises,
    WorkoutSets,
    SetCompletions,
    HeartRateSamples,
    SyncMeta,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 16;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      // Drift / sqlite3 do not enable foreign keys by default. Without this,
      // ON DELETE CASCADE / SET NULL silently no-op, leaving orphan rows.
      await customStatement('PRAGMA foreign_keys = ON');
      await _seedMuscles();
    },
    onUpgrade: (m, from, to) async {
      // Pre-uuid (int-id) schemas have no in-place path to v11, so upgrading
      // from before v11 is a destructive reset: drop every table and recreate
      // the current schema. FKs are re-enabled and muscles re-seeded by
      // beforeOpen on the next open.
      if (from < 11) {
        await customStatement('PRAGMA foreign_keys = OFF');
        final tables = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%'",
        ).get();
        for (final row in tables) {
          await customStatement(
            'DROP TABLE IF EXISTS "${row.read<String>('name')}"',
          );
        }
        await m.createAll();
        return;
      }
      // v11+ carries real data — migrate incrementally, never wipe.
      if (from < 12) {
        await m.addColumn(workouts, workouts.routineName);
      }
      // v12 → v13: version-LWW for workouts, so edits (and deletions, as
      // tombstones) propagate instead of losing to the old append-only skip.
      // Both columns carry their defaults into existing rows — `version`
      // through the SQL DEFAULT 1 drift emits, `deletedAt` as NULL (= live) —
      // so no backfill pass is needed.
      if (from < 13) {
        await m.addColumn(workouts, workouts.version);
        await m.addColumn(workouts, workouts.deletedAt);
      }
      // v13 → v14: heart rate as a timestamped series, for Health Connect.
      // Purely additive — a new table, nothing renamed or recreated, so none of
      // the FK re-pointing hazards that make the recreate-table steps above
      // order-sensitive apply here. Existing workouts simply have no samples.
      if (from < 14) {
        await m.createTable(heartRateSamples);
      }
      // v14 → v15: "superset" became "circuit", and rest stopped being a single
      // per-group interval. Rest now follows *every* set, taken from the
      // exercise just completed — see `RoutineExercises.restSeconds`.
      //
      // Renaming the column is `ALTER TABLE … RENAME COLUMN`, which — unlike
      // the RENAME TABLE steps above — re-points nothing and needs no FK dance.
      if (from < 15) {
        await m.renameColumn(
          routineExercises,
          'superset_group',
          routineExercises.circuitGroup,
        );
        await m.renameColumn(
          workoutExercises,
          'superset_group',
          workoutExercises.circuitGroup,
        );
        await _translateGroupRestV15();
      }
      // v15 → v16: heart-rate samples carry the sensor's own confidence.
      // Additive and nullable, so existing rows read back as "unknown" — which
      // is what they are, the label having been discarded at capture until now.
      if (from < 16) {
        await m.addColumn(heartRateSamples, heartRateSamples.accuracy);
      }
    },
  );

  /// v14 → v15 data step. The rule itself lives in `circuit_rest_v15.dart`,
  /// pure and unit-tested; this only reads the rows and writes the result back.
  ///
  /// Affected routines get a `version` bump so the translated values win the
  /// version-LWW arbitration against server and watch copies still holding the
  /// old layout. Workout snapshots are translated too (a resumed session reads
  /// its own snapshot) but not bumped: their rest values are never replayed
  /// into history, so re-pushing every past workout would be noise.
  Future<void> _translateGroupRestV15() async {
    const specs = [
      (table: 'routine_exercises', parent: 'routine_id'),
      (table: 'workout_exercises', parent: 'workout_id'),
    ];
    for (final spec in specs) {
      final raw = await customSelect(
        'SELECT sync_id, ${spec.parent} AS parent, circuit_group, rest_seconds '
        'FROM ${spec.table} ORDER BY ${spec.parent}, order_index',
      ).get();
      final plan = translateCircuitRestV15([
        for (final row in raw)
          (
            syncId: row.read<String>('sync_id'),
            parent: row.read<String>('parent'),
            group: row.read<int?>('circuit_group'),
            restSeconds: row.read<int>('rest_seconds'),
          ),
      ]);
      for (final entry in plan.restBySyncId.entries) {
        await customStatement(
          'UPDATE ${spec.table} SET rest_seconds = ? WHERE sync_id = ?',
          [entry.value, entry.key],
        );
      }
      if (spec.table == 'routine_exercises' && plan.parents.isNotEmpty) {
        final placeholders = List.filled(plan.parents.length, '?').join(', ');
        await customStatement(
          'UPDATE routines SET version = version + 1 '
          'WHERE sync_id IN ($placeholders)',
          plan.parents.toList(),
        );
      }
    }
  }

  // Standard muscle list (shared constant in muscle_seeds.dart). Seeded
  // idempotently on every open so a fresh DB and an upgraded one both end up
  // with the same row ids (deterministic syncIds mean phone, watch, and web
  // agree without sync round-trips).
  Future<void> _seedMuscles() async {
    for (final name in muscleSeeds) {
      await customStatement(
        'INSERT OR IGNORE INTO muscles (sync_id, name) VALUES (?, ?)',
        [muscleSyncId(name), name],
      );
    }
  }

  // -- Sync metadata (key/value) ----------------------------------------

  /// Read a sync-metadata value by key, or null if unset.
  Future<String?> getSyncMeta(String key) async {
    final row = await (select(
      syncMeta,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// Upsert a sync-metadata value.
  Future<void> setSyncMeta(String key, String value) async {
    await into(syncMeta).insertOnConflictUpdate(
      SyncMetaCompanion.insert(key: key, value: value),
    );
  }

  /// Drop a sync-metadata key.
  Future<void> clearSyncMeta(String key) async {
    await (delete(syncMeta)..where((t) => t.key.equals(key))).go();
  }

  /// Erase every local row — routines, workouts, exercises, sync bookkeeping.
  /// Used when deleting an account and the user opts to clear this device too.
  ///
  /// Tables go in reverse declaration order so children are removed before the
  /// parents they reference. The `ON DELETE CASCADE` rules would mostly handle
  /// it, but not every FK cascades and the pragma is on (see `beforeOpen`), so
  /// a parent-first pass could trip a constraint.
  Future<void> clearAllLocalData() async {
    await transaction(() async {
      for (final table in allTables.toList().reversed) {
        await delete(table).go();
      }
    });
  }

  static QueryExecutor _openConnection() => driftDatabase(
    name: 'gym_tracker',
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );

  // -- Exercises --------------------------------------------------------

  Stream<List<Exercise>> watchExercises() {
    return (select(exercises)
          ..where((t) => t.deletedAt.isNull()) // hide tombstones
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Whether any exercise row exists, tombstones **included** — see
  /// `ExerciseRepository.hasAnyExercise` for why deleted rows count.
  Future<bool> hasAnyExercise() async {
    final row = await (select(exercises)..limit(1)).getSingleOrNull();
    return row != null;
  }

  /// One-shot fetch of every exercise with its muscle tags, in name order.
  /// Used by the exercise registry list — the call is cheap (small N) and
  /// avoids one query per row on rebuild.
  Future<List<ExerciseWithMuscles>> loadExercisesWithMuscles() async {
    final exs = await (select(exercises)
          ..where((t) => t.deletedAt.isNull()) // hide tombstones
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
    if (exs.isEmpty) return const [];
    final rows = await (select(exerciseMuscles).join([
          innerJoin(muscles, muscles.syncId.equalsExp(exerciseMuscles.muscleId)),
        ])
          ..orderBy([OrderingTerm.asc(muscles.name)]))
        .get();
    final byExercise = <String, List<Muscle>>{};
    for (final row in rows) {
      final em = row.readTable(exerciseMuscles);
      final m = row.readTable(muscles);
      byExercise.putIfAbsent(em.exerciseId, () => []).add(m);
    }
    return [
      for (final e in exs)
        ExerciseWithMuscles(exercise: e, muscles: byExercise[e.syncId] ?? const []),
    ];
  }

  /// Stream variant of [loadExercisesWithMuscles] for reactive UIs.
  Stream<List<ExerciseWithMuscles>> watchExercisesWithMuscles() async* {
    yield await loadExercisesWithMuscles();
    final updates = tableUpdates(
      TableUpdateQuery.onAllTables([exercises, muscles, exerciseMuscles]),
    );
    await for (final _ in updates) {
      yield await loadExercisesWithMuscles();
    }
  }

  Future<Exercise> createExercise(
    String name, {
    String kind = exerciseKindReps,
  }) async {
    // `name` is UNIQUE, but soft delete leaves the tombstoned row (and its
    // name) in place, so a plain insert of a previously-deleted name would
    // throw a UNIQUE violation even though library reads hide the tombstone.
    // Reconcile by name: revive a tombstone (LWW — clear deletedAt, apply the
    // requested kind, bump version) and treat an already-live match as an
    // idempotent create, returning it rather than erroring.
    final existing =
        await (select(exercises)..where((t) => t.name.equals(name)))
            .getSingleOrNull();
    if (existing != null) {
      if (existing.deletedAt == null) return existing;
      await (update(exercises)..where((t) => t.syncId.equals(existing.syncId)))
          .write(ExercisesCompanion(
            deletedAt: const Value(null),
            kind: Value(kind),
          ));
      await _bumpExerciseVersion(existing.syncId);
      return (select(
        exercises,
      )..where((t) => t.syncId.equals(existing.syncId))).getSingle();
    }
    final id = _uuid.v4();
    await into(exercises).insert(
      ExercisesCompanion.insert(
        syncId: id,
        name: name,
        createdAt: DateTime.now(),
        kind: Value(kind),
      ),
    );
    return (select(exercises)..where((t) => t.syncId.equals(id))).getSingle();
  }

  Future<void> renameExercise(String id, String name) async {
    await (update(
      exercises,
    )..where((t) => t.syncId.equals(id))).write(ExercisesCompanion(name: Value(name)));
    await _bumpExerciseVersion(id);
  }

  Future<void> setExerciseKind(String id, String kind) async {
    await (update(
      exercises,
    )..where((t) => t.syncId.equals(id))).write(ExercisesCompanion(kind: Value(kind)));
    await _bumpExerciseVersion(id);
  }

  /// Soft-delete: leave a versioned tombstone (`deletedAt` set + bumped
  /// version) so the deletion travels through version-LWW sync. The row
  /// survives, so routines/workouts still referencing this exercise (by FK id)
  /// keep resolving it; only the library reads hide it.
  Future<void> deleteExercise(String id) async {
    await transaction(() async {
      await (update(exercises)..where((t) => t.syncId.equals(id))).write(
        ExercisesCompanion(deletedAt: Value(DateTime.now())),
      );
      await _bumpExerciseVersion(id);
    });
  }

  /// Insert the catalogue under the ids it chose, with its muscle tags, in one
  /// transaction. Returns how many rows were written.
  ///
  /// Distinct from [createExercise] in three ways that all matter to the seed:
  ///
  /// The id is given, not minted, so two installs seeding the same catalogue
  /// entry agree on it and the second one upserts instead of creating a
  /// duplicate document.
  ///
  /// The row rests at version 1. Tags are written inside the same transaction
  /// rather than through [setExerciseMuscles], which ends in a version bump and
  /// would leave every seeded row at 2. A fresh seed has to lose to an account
  /// that has been edited, and it can only do that from the bottom.
  ///
  /// A name collision skips that entry rather than reconciling. [createExercise]
  /// deliberately revives a tombstone or returns the live row of that name,
  /// which is right for a user typing a name and wrong for a seed: it would
  /// take a row under an id the catalogue does not own. The collision is
  /// reachable because the seed's emptiness check happens once and the writes
  /// that follow are interleaved with inbound sync.
  ///
  /// See [CatalogExercise] and the repository seam for why this is plural.
  Future<int> writeCatalogExercises(List<CatalogExercise> entries) async {
    return transaction(() async {
      var written = 0;
      for (final e in entries) {
        final existing =
            await (select(exercises)..where((t) => t.syncId.equals(e.syncId)))
                .getSingleOrNull();
        if (existing != null) continue;

        final byName = await (select(
          exercises,
        )..where((t) => t.name.equals(e.name))).getSingleOrNull();
        if (byName != null) continue;

        await into(exercises).insert(
          ExercisesCompanion.insert(
            syncId: e.syncId,
            name: e.name,
            createdAt: e.createdAt,
            kind: Value(e.kind),
          ),
        );
        for (final muscleId in e.muscleSyncIds) {
          await into(exerciseMuscles).insert(
            ExerciseMusclesCompanion.insert(
              exerciseId: e.syncId,
              muscleId: muscleId,
            ),
          );
        }
        written++;
      }
      return written;
    });
  }

  Future<void> _bumpExerciseVersion(String id) async {
    await customUpdate(
      'UPDATE exercises SET version = version + 1 WHERE sync_id = ?',
      variables: [Variable.withString(id)],
      updates: {exercises},
    );
  }

  // -- Routines ---------------------------------------------------------

  Stream<List<RoutineSummary>> watchRoutineSummaries() {
    final countExpr = routineExercises.syncId.count();
    final query =
        select(routines).join([
            leftOuterJoin(
              routineExercises,
              routineExercises.routineId.equalsExp(routines.syncId),
            ),
          ])
          ..where(routines.deletedAt.isNull()) // hide tombstones
          ..addColumns([countExpr])
          ..groupBy([routines.syncId])
          ..orderBy([OrderingTerm.desc(routines.createdAt)]);
    return query.watch().map((rows) {
      return rows
          .map(
            (row) => RoutineSummary(
              routine: row.readTable(routines),
              exerciseCount: row.read(countExpr) ?? 0,
            ),
          )
          .toList();
    });
  }

  Future<Routine> createRoutine(String name) async {
    final now = DateTime.now();
    final id = _uuid.v4();
    await into(routines).insert(
      RoutinesCompanion.insert(syncId: id, name: name, createdAt: now),
    );
    return (select(routines)..where((t) => t.syncId.equals(id))).getSingle();
  }

  Future<void> renameRoutine(String id, String name) async {
    await (update(routines)..where((t) => t.syncId.equals(id))).write(
      RoutinesCompanion(name: Value(name), version: const Value.absent()),
    );
    await _bumpRoutineVersion(id);
  }

  /// Soft-delete: leave a versioned tombstone (`deletedAt` set + bumped
  /// version) so the deletion travels through version-LWW sync like any other
  /// edit, instead of out-of-band. The template's child rows are dropped
  /// (routine_exercises → planned_sets / alternatives) so a tombstone stays
  /// lightweight; reads skip tombstoned routines, so it reads as deleted.
  /// Past workouts keep their own snapshot (they read it, not the routine), so
  /// the surviving backref is harmless.
  Future<void> deleteRoutine(String id) async {
    await transaction(() async {
      await (delete(routineExercises)..where((t) => t.routineId.equals(id)))
          .go();
      // Sever workout backrefs, matching the old ON DELETE SET NULL: past
      // workouts keep their self-contained snapshot and just lose the link, so
      // history never resolves back to a tombstoned routine.
      await (update(workouts)..where((t) => t.routineId.equals(id))).write(
        const WorkoutsCompanion(routineId: Value(null)),
      );
      await (update(routines)..where((t) => t.syncId.equals(id))).write(
        RoutinesCompanion(deletedAt: Value(DateTime.now())),
      );
      await _bumpRoutineVersion(id);
    });
  }

  Future<FullRoutine?> loadFullRoutine(String routineId) async {
    final r = await (select(
      routines,
    )..where((t) => t.syncId.equals(routineId))).getSingleOrNull();
    // Tombstoned routines read as absent (callers already treat null as gone).
    if (r == null || r.deletedAt != null) return null;
    final res =
        await (select(routineExercises)
              ..where((t) => t.routineId.equals(routineId))
              ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
            .get();
    final result = <FullRoutineExercise>[];
    for (final re in res) {
      final ex = await (select(
        exercises,
      )..where((t) => t.syncId.equals(re.exerciseId))).getSingle();
      final sets =
          await (select(plannedSets)
                ..where((t) => t.routineExerciseId.equals(re.syncId))
                ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
              .get();
      final alts = await _loadAlternatives(re.syncId);
      final mus = await _loadMusclesFor(ex.syncId);
      result.add(
        FullRoutineExercise(
          routineExercise: re,
          exercise: ex,
          plannedSets: sets,
          alternatives: alts,
          muscles: mus,
        ),
      );
    }
    return FullRoutine(routine: r, exercises: result);
  }

  Future<List<RoutineAlternative>> _loadAlternatives(
    String routineExerciseId,
  ) async {
    final alts =
        await (select(routineExerciseAlternatives)
              ..where((t) => t.routineExerciseId.equals(routineExerciseId))
              ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
            .get();
    if (alts.isEmpty) return const [];
    final ids = alts.map((a) => a.exerciseId).toList();
    final exs = await (select(
      exercises,
    )..where((t) => t.syncId.isIn(ids))).get();
    final byId = {for (final e in exs) e.syncId: e};
    final result = <RoutineAlternative>[];
    for (final a in alts) {
      final ex = byId[a.exerciseId];
      if (ex == null) continue;
      final ps = await (select(alternativePlannedSets)
            ..where((t) => t.alternativeId.equals(a.syncId))
            ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
          .get();
      result.add(RoutineAlternative(join: a, exercise: ex, plannedSets: ps));
    }
    return result;
  }

  Future<List<Muscle>> _loadMusclesFor(String exerciseId) async {
    final rows =
        await (select(exerciseMuscles).join([
              innerJoin(muscles, muscles.syncId.equalsExp(exerciseMuscles.muscleId)),
            ])
              ..where(exerciseMuscles.exerciseId.equals(exerciseId))
              ..orderBy([OrderingTerm.asc(muscles.name)]))
            .get();
    return rows.map((r) => r.readTable(muscles)).toList();
  }

  Stream<FullRoutine?> watchFullRoutine(String routineId) async* {
    yield await loadFullRoutine(routineId);
    final updates = tableUpdates(
      TableUpdateQuery.onAllTables([
        routines,
        routineExercises,
        plannedSets,
        exercises,
        routineExerciseAlternatives,
        alternativePlannedSets,
        muscles,
        exerciseMuscles,
      ]),
    );
    await for (final _ in updates) {
      yield await loadFullRoutine(routineId);
    }
  }

  Future<RoutineExercise> addExerciseToRoutine({
    required String routineId,
    required String exerciseId,
  }) async {
    return transaction(() async {
      final maxOrder = await _maxOrderIndex(routineId);
      final id = _uuid.v4();
      await into(routineExercises).insert(
        RoutineExercisesCompanion.insert(
          syncId: id,
          routineId: routineId,
          exerciseId: exerciseId,
          orderIndex: maxOrder + 1,
        ),
      );
      await _bumpRoutineVersion(routineId);
      return (select(
        routineExercises,
      )..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  Future<void> removeRoutineExercise(String routineExerciseId) async {
    await transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(routineExerciseId))).getSingleOrNull();
      if (re == null) return;
      await (delete(
        routineExercises,
      )..where((t) => t.syncId.equals(routineExerciseId))).go();
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> reorderRoutineExercises({
    required String routineId,
    required List<String> orderedIds,
  }) async {
    await transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (update(routineExercises)..where(
              (t) => t.syncId.equals(orderedIds[i]) & t.routineId.equals(routineId),
            ))
            .write(RoutineExercisesCompanion(orderIndex: Value(i)));
      }
      await _bumpRoutineVersion(routineId);
    });
  }

  /// Reorder a workout's own snapshot rows. Mirrors [reorderRoutineExercises];
  /// edits the workout, never the routine it was taken from.
  Future<void> reorderWorkoutExercises({
    required String workoutId,
    required List<String> orderedIds,
  }) async {
    await transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (update(workoutExercises)..where(
              (t) =>
                  t.syncId.equals(orderedIds[i]) & t.workoutId.equals(workoutId),
            ))
            .write(WorkoutExercisesCompanion(orderIndex: Value(i)));
      }
      await _bumpWorkoutVersion(workoutId);
    });
  }

  Future<void> setRestSeconds(String routineExerciseId, int seconds) async {
    await transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(routineExerciseId))).getSingleOrNull();
      if (re == null) return;
      await (update(routineExercises)
            ..where((t) => t.syncId.equals(routineExerciseId)))
          .write(RoutineExercisesCompanion(restSeconds: Value(seconds)));
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> setCircuitGroup(String routineExerciseId, int? group) async {
    await transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(routineExerciseId))).getSingleOrNull();
      if (re == null) return;
      await (update(routineExercises)
            ..where((t) => t.syncId.equals(routineExerciseId)))
          .write(RoutineExercisesCompanion(circuitGroup: Value(group)));
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<PlannedSet> addPlannedSet({
    required String routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    return transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(routineExerciseId))).getSingle();
      final maxIndex = await _maxSetIndex(routineExerciseId);
      final id = _uuid.v4();
      await into(plannedSets).insert(
        PlannedSetsCompanion.insert(
          syncId: id,
          routineExerciseId: routineExerciseId,
          setIndex: maxIndex + 1,
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      await _bumpRoutineVersion(re.routineId);
      return (select(plannedSets)..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  Future<void> updatePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    await transaction(() async {
      final ps = await (select(
        plannedSets,
      )..where((t) => t.syncId.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(ps.routineExerciseId))).getSingle();
      await (update(plannedSets)..where((t) => t.syncId.equals(id))).write(
        PlannedSetsCompanion(
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> deletePlannedSet(String id) async {
    await transaction(() async {
      final ps = await (select(
        plannedSets,
      )..where((t) => t.syncId.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(ps.routineExerciseId))).getSingle();
      await (delete(plannedSets)..where((t) => t.syncId.equals(id))).go();
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<int> _maxOrderIndex(String routineId) async {
    final expr = routineExercises.orderIndex.max();
    final query = selectOnly(routineExercises)
      ..where(routineExercises.routineId.equals(routineId))
      ..addColumns([expr]);
    final row = await query.getSingleOrNull();
    return row?.read(expr) ?? -1;
  }

  Future<int> _maxSetIndex(String routineExerciseId) async {
    final expr = plannedSets.setIndex.max();
    final query = selectOnly(plannedSets)
      ..where(plannedSets.routineExerciseId.equals(routineExerciseId))
      ..addColumns([expr]);
    final row = await query.getSingleOrNull();
    return row?.read(expr) ?? -1;
  }

  Future<void> _bumpRoutineVersion(String routineId) async {
    await customUpdate(
      'UPDATE routines SET version = version + 1 WHERE sync_id = ?',
      variables: [Variable.withString(routineId)],
      updates: {routines},
    );
  }

  // -- Routine exercise alternatives ------------------------------------

  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required String routineExerciseId,
    required String exerciseId,
  }) async {
    return transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(routineExerciseId))).getSingle();
      final maxExpr = routineExerciseAlternatives.orderIndex.max();
      final row =
          await (selectOnly(routineExerciseAlternatives)
                ..where(
                  routineExerciseAlternatives.routineExerciseId.equals(
                    routineExerciseId,
                  ),
                )
                ..addColumns([maxExpr]))
              .getSingleOrNull();
      final next = (row?.read(maxExpr) ?? -1) + 1;
      final id = _uuid.v4();
      await into(routineExerciseAlternatives).insert(
        RoutineExerciseAlternativesCompanion.insert(
          syncId: id,
          routineExerciseId: routineExerciseId,
          exerciseId: exerciseId,
          orderIndex: next,
        ),
      );
      await _bumpRoutineVersion(re.routineId);
      return (select(
        routineExerciseAlternatives,
      )..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required String alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    return transaction(() async {
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.syncId.equals(alternativeId))).getSingle();
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(alt.routineExerciseId))).getSingle();
      final maxExpr = alternativePlannedSets.setIndex.max();
      final row = await (selectOnly(alternativePlannedSets)
            ..where(alternativePlannedSets.alternativeId.equals(alternativeId))
            ..addColumns([maxExpr]))
          .getSingleOrNull();
      final next = (row?.read(maxExpr) ?? -1) + 1;
      final id = _uuid.v4();
      await into(alternativePlannedSets).insert(
        AlternativePlannedSetsCompanion.insert(
          syncId: id,
          alternativeId: alternativeId,
          setIndex: next,
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      await _bumpRoutineVersion(re.routineId);
      return (select(
        alternativePlannedSets,
      )..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  Future<void> updateAlternativePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    await transaction(() async {
      final ps = await (select(
        alternativePlannedSets,
      )..where((t) => t.syncId.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.syncId.equals(ps.alternativeId))).getSingle();
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(alt.routineExerciseId))).getSingle();
      await (update(alternativePlannedSets)..where((t) => t.syncId.equals(id)))
          .write(
            AlternativePlannedSetsCompanion(
              targetReps: Value(targetReps),
              targetWeightKg: Value(targetWeightKg),
              targetSeconds: Value(targetSeconds),
            ),
          );
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> deleteAlternativePlannedSet(String id) async {
    await transaction(() async {
      final ps = await (select(
        alternativePlannedSets,
      )..where((t) => t.syncId.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.syncId.equals(ps.alternativeId))).getSingle();
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(alt.routineExerciseId))).getSingle();
      await (delete(alternativePlannedSets)..where((t) => t.syncId.equals(id)))
          .go();
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> removeRoutineExerciseAlternative(String alternativeId) async {
    await transaction(() async {
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.syncId.equals(alternativeId))).getSingleOrNull();
      if (alt == null) return;
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(alt.routineExerciseId))).getSingleOrNull();
      await (delete(routineExerciseAlternatives)
            ..where((t) => t.syncId.equals(alternativeId)))
          .go();
      if (re != null) {
        await _bumpRoutineVersion(re.routineId);
      }
    });
  }

  // -- Muscles ----------------------------------------------------------

  Stream<List<Muscle>> watchMuscles() {
    return (select(
      muscles,
    )..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();
  }

  Future<List<Muscle>> musclesForExercise(String exerciseId) =>
      _loadMusclesFor(exerciseId);

  /// Replace the muscle set for an exercise with [muscleIds].
  Future<void> setExerciseMuscles(String exerciseId, List<String> muscleIds) async {
    await transaction(() async {
      await (delete(
        exerciseMuscles,
      )..where((t) => t.exerciseId.equals(exerciseId))).go();
      for (final mId in muscleIds) {
        await into(exerciseMuscles).insert(
          ExerciseMusclesCompanion.insert(
            exerciseId: exerciseId,
            muscleId: mId,
          ),
        );
      }
      await _bumpExerciseVersion(exerciseId);
    });
  }

  // -- Workouts (runs) --------------------------------------------------

  Stream<List<Workout>> watchRecentWorkouts() {
    return ((select(workouts)..where((t) => t.deletedAt.isNull()))
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
        .watch();
  }

  /// Most recent workout with no `endedAt`. Used by the watch picker to offer
  /// a Resume entry when the user pops out of a running workout.
  ///
  /// The tombstone filter is load-bearing: a soft-deleted workout keeps its null
  /// `endedAt`, so without it an abandoned-and-deleted workout would offer
  /// "Resume" forever.
  Stream<Workout?> watchInProgressWorkout() {
    return ((select(workouts)
          ..where((t) => t.endedAt.isNull() & t.deletedAt.isNull()))
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Start a workout and snapshot its routine into workout-owned tables.
  /// Returns the new workout row; the snapshot is reachable via
  /// [loadFullWorkout] / [watchFullWorkout].
  Future<Workout> startWorkout(String routineId) async {
    return transaction(() async {
      final full = await loadFullRoutine(routineId);
      if (full == null) {
        throw StateError('Routine $routineId not found');
      }
      final workoutId = _uuid.v4();
      await into(workouts).insert(
        WorkoutsCompanion.insert(
          syncId: workoutId,
          routineId: Value(routineId),
          routineName: Value(full.routine.name),
          startedAt: DateTime.now(),
        ),
      );
      await _snapshotRoutineExercises(workoutId, full);
      return (select(
        workouts,
      )..where((t) => t.syncId.equals(workoutId))).getSingle();
    });
  }

  /// Create a workout for manual backfill: optionally snapshot [routineId]'s
  /// exercises + target sets (no completions), with caller-chosen times. A null
  /// or unknown routine yields an empty workout the user fills in by hand.
  Future<Workout> createWorkout({
    String? routineId,
    required DateTime startedAt,
    DateTime? endedAt,
  }) async {
    return transaction(() async {
      final full = routineId == null ? null : await loadFullRoutine(routineId);
      final workoutId = _uuid.v4();
      await into(workouts).insert(
        WorkoutsCompanion.insert(
          syncId: workoutId,
          routineId: Value(full == null ? null : routineId),
          routineName: Value(full?.routine.name),
          startedAt: startedAt,
          endedAt: Value(endedAt),
        ),
      );
      if (full != null) await _snapshotRoutineExercises(workoutId, full);
      return (select(
        workouts,
      )..where((t) => t.syncId.equals(workoutId))).getSingle();
    });
  }

  /// Copy a routine's exercises + planned sets into a workout's snapshot tables
  /// (targets only; completions are logged later). Runs in the caller's
  /// transaction.
  Future<void> _snapshotRoutineExercises(
    String workoutId,
    FullRoutine full,
  ) async {
    for (final re in full.exercises) {
      final weId = _uuid.v4();
      await into(workoutExercises).insert(
        WorkoutExercisesCompanion.insert(
          syncId: weId,
          workoutId: workoutId,
          exerciseId: Value(re.exercise.syncId),
          exerciseName: re.exercise.name,
          orderIndex: re.routineExercise.orderIndex,
          restSeconds: Value(re.routineExercise.restSeconds),
          circuitGroup: Value(re.routineExercise.circuitGroup),
          kind: Value(re.exercise.kind),
          routineExerciseId: Value(re.routineExercise.syncId),
        ),
      );
      for (final ps in re.plannedSets) {
        await into(workoutSets).insert(
          WorkoutSetsCompanion.insert(
            syncId: _uuid.v4(),
            workoutExerciseId: weId,
            setIndex: ps.setIndex,
            targetReps: Value(ps.targetReps),
            targetWeightKg: Value(ps.targetWeightKg),
            targetSeconds: Value(ps.targetSeconds),
          ),
        );
      }
    }
  }

  /// Bump a workout's edit counter. Raw SQL so the increment is atomic, with an
  /// explicit `updates:` so drift's stream tracker fires — that notification is
  /// what wakes [SyncService]'s workout watcher, so every mutation below must
  /// call this or its edit will never leave the device.
  ///
  /// Never call this from [SyncRepository]: applying an inbound workout assigns
  /// the sender's version verbatim, and a bump there would make every apply look
  /// like a local edit and push straight back.
  Future<void> _bumpWorkoutVersion(String workoutId) async {
    await customUpdate(
      'UPDATE workouts SET version = version + 1 WHERE sync_id = ?',
      variables: [Variable.withString(workoutId)],
      updates: {workouts},
    );
  }

  /// Owning workout of a snapshot child, for the mutators that only receive a
  /// child id. Must be resolved *before* a delete removes the row.
  Future<String?> _workoutIdOfWorkoutExercise(String workoutExerciseId) async {
    final we = await (select(
      workoutExercises,
    )..where((t) => t.syncId.equals(workoutExerciseId))).getSingleOrNull();
    return we?.workoutId;
  }

  Future<String?> _workoutIdOfWorkoutSet(String workoutSetId) async {
    final ws = await (select(
      workoutSets,
    )..where((t) => t.syncId.equals(workoutSetId))).getSingleOrNull();
    if (ws == null) return null;
    return _workoutIdOfWorkoutExercise(ws.workoutExerciseId);
  }

  Future<String?> _workoutIdOfCompletion(String completionId) async {
    final c = await (select(
      setCompletions,
    )..where((t) => t.syncId.equals(completionId))).getSingleOrNull();
    return c?.workoutId;
  }

  /// Record one heart-rate reading against a workout.
  ///
  /// Upsert, so a repeated timestamp overwrites rather than throwing on the
  /// composite key — sensors do occasionally repeat one.
  ///
  /// **Deliberately does not bump the workout version**, unlike every other
  /// mutating workout method here. Samples arrive continuously through a live
  /// run, and a live workout is excluded from the sync push predicate anyway
  /// (`endedAt IS NOT NULL OR deletedAt IS NOT NULL`); bumping per sample would
  /// be hundreds of pointless writes. The single bump in [finishWorkout] is
  /// what carries the whole series out to peers. Don't "fix" this.
  Future<void> addHeartRateSample({
    required String workoutId,
    required int measuredAtMs,
    required int bpm,
    int? accuracy,
  }) async {
    await into(heartRateSamples).insertOnConflictUpdate(
      HeartRateSamplesCompanion.insert(
        workoutId: workoutId,
        measuredAtMs: measuredAtMs,
        bpm: bpm,
        accuracy: Value(accuracy),
      ),
    );
  }

  /// A workout's heart-rate series, oldest first.
  Future<List<HeartRateReading>> heartRateSamplesFor(String workoutId) {
    return (select(heartRateSamples)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.measuredAtMs)]))
        .get();
  }

  Future<void> finishWorkout(
    String workoutId, {
    int? avgHeartRate,
    int? maxHeartRate,
  }) async {
    await transaction(() async {
      await (update(workouts)..where((t) => t.syncId.equals(workoutId))).write(
        WorkoutsCompanion(
          endedAt: Value(DateTime.now()),
          avgHeartRate: Value(avgHeartRate),
          maxHeartRate: Value(maxHeartRate),
        ),
      );
      await _bumpWorkoutVersion(workoutId);
    });
  }

  Future<void> updateWorkoutTimes({
    required String workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  }) async {
    await transaction(() async {
      await (update(workouts)..where((t) => t.syncId.equals(workoutId))).write(
        WorkoutsCompanion(
          startedAt: Value(startedAt),
          endedAt: Value(endedAt),
        ),
      );
      await _bumpWorkoutVersion(workoutId);
    });
  }

  /// Soft delete: drop the snapshot but keep a versioned tombstone, so the
  /// deletion travels over sync and outranks a peer's stale copy. Mirrors
  /// [deleteRoutine]. Reads skip tombstoned rows.
  Future<void> deleteWorkout(String workoutId) async {
    await transaction(() async {
      // Explicit, not by cascade: this is a *soft* delete, so the Workouts row
      // survives as a tombstone and the FK never fires.
      await (delete(
        heartRateSamples,
      )..where((t) => t.workoutId.equals(workoutId))).go();
      await (delete(
        setCompletions,
      )..where((t) => t.workoutId.equals(workoutId))).go();
      // Cascades to workoutSets.
      await (delete(
        workoutExercises,
      )..where((t) => t.workoutId.equals(workoutId))).go();
      await (update(workouts)..where((t) => t.syncId.equals(workoutId))).write(
        WorkoutsCompanion(deletedAt: Value(DateTime.now())),
      );
      await _bumpWorkoutVersion(workoutId);
    });
  }

  /// Full snapshot of a workout: its (optional) routine, every workout
  /// exercise + its sets, and any completions resolved per set.
  Future<FullWorkout?> loadFullWorkout(String workoutId) async {
    final w = await (select(
      workouts,
    )..where((t) => t.syncId.equals(workoutId))).getSingleOrNull();
    if (w == null || w.deletedAt != null) return null;
    // A routine tombstoned via sync (backref not severed locally) reads as
    // gone here too, matching a locally-deleted routine's null backref.
    final routine = w.routineId == null
        ? null
        : await (select(routines)
                ..where((t) => t.syncId.equals(w.routineId!) & t.deletedAt.isNull()))
              .getSingleOrNull();
    final wes =
        await (select(workoutExercises)
              ..where((t) => t.workoutId.equals(workoutId))
              ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
            .get();
    final allCompletions = await (select(
      setCompletions,
    )..where((t) => t.workoutId.equals(workoutId))).get();
    final completionByWorkoutSet = {
      for (final c in allCompletions) c.workoutSetId: c,
    };
    final result = <FullWorkoutExercise>[];
    for (final we in wes) {
      final sets =
          await (select(workoutSets)
                ..where((t) => t.workoutExerciseId.equals(we.syncId))
                ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
              .get();
      result.add(
        FullWorkoutExercise(
          workoutExercise: we,
          sets: sets
              .map(
                (s) => FullWorkoutSet(
                  workoutSet: s,
                  completion: completionByWorkoutSet[s.syncId],
                ),
              )
              .toList(),
        ),
      );
    }
    return FullWorkout(workout: w, routine: routine, exercises: result);
  }

  Stream<FullWorkout?> watchFullWorkout(String workoutId) async* {
    yield await loadFullWorkout(workoutId);
    final updates = tableUpdates(
      TableUpdateQuery.onAllTables([
        workouts,
        workoutExercises,
        workoutSets,
        setCompletions,
        routines,
      ]),
    );
    await for (final _ in updates) {
      yield await loadFullWorkout(workoutId);
    }
  }

  Future<List<SetCompletion>> completionsForWorkout(String workoutId) {
    return (select(setCompletions)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.completedAt)]))
        .get();
  }

  /// Most recent completion of [exerciseId] at [setIndex], from any *finished*
  /// workout other than [excludeWorkoutId]. Used by the watch run page to show
  /// "Last: 8 × 80 kg" alongside the current set's targets.
  Future<SetCompletion?> lastCompletionForExerciseAtSetIndex({
    required String exerciseId,
    required int setIndex,
    required String excludeWorkoutId,
  }) async {
    final query =
        select(setCompletions).join([
            innerJoin(
              workoutSets,
              workoutSets.syncId.equalsExp(setCompletions.workoutSetId),
            ),
            innerJoin(
              workoutExercises,
              workoutExercises.syncId.equalsExp(workoutSets.workoutExerciseId),
            ),
            innerJoin(
              workouts,
              workouts.syncId.equalsExp(setCompletions.workoutId),
            ),
          ])
          ..where(workoutExercises.exerciseId.equals(exerciseId))
          ..where(workoutSets.setIndex.equals(setIndex))
          ..where(workouts.syncId.equals(excludeWorkoutId).not())
          ..where(workouts.endedAt.isNotNull())
          ..where(workouts.deletedAt.isNull())
          ..orderBy([OrderingTerm(expression: workouts.startedAt, mode: OrderingMode.desc)])
          ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.readTable(setCompletions);
  }

  /// Sets in [workoutId] whose actuals strictly beat the routine's current
  /// target. Empty when the routine is gone, the workout is purely ad-hoc, or
  /// nothing exceeded — the phone uses that to hide the banner entirely.
  Future<List<WorkoutImprovement>> findWorkoutImprovements(String workoutId) async {
    final w = await (select(
      workouts,
    )..where((t) => t.syncId.equals(workoutId))).getSingleOrNull();
    if (w == null || w.deletedAt != null || w.routineId == null) return const [];
    final wes = await (select(workoutExercises)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    final allCompletions = await (select(
      setCompletions,
    )..where((t) => t.workoutId.equals(workoutId))).get();
    final completionByWorkoutSet = {
      for (final c in allCompletions) c.workoutSetId: c,
    };
    final out = <WorkoutImprovement>[];
    for (final we in wes) {
      final reId = we.routineExerciseId;
      if (reId == null) continue;
      final re = await (select(
        routineExercises,
      )..where((t) => t.syncId.equals(reId))).getSingleOrNull();
      if (re == null) continue;
      List<PlannedSet> primaryPs = const [];
      List<AlternativePlannedSet> altPs = const [];
      bool useAlt = false;
      if (we.exerciseId == re.exerciseId) {
        primaryPs = await (select(plannedSets)
              ..where((t) => t.routineExerciseId.equals(re.syncId))
              ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
            .get();
      } else if (we.exerciseId != null) {
        final altRow = await (select(routineExerciseAlternatives)..where(
              (t) =>
                  t.routineExerciseId.equals(re.syncId) &
                  t.exerciseId.equals(we.exerciseId!),
            ))
            .getSingleOrNull();
        if (altRow == null) continue;
        altPs = await (select(alternativePlannedSets)
              ..where((t) => t.alternativeId.equals(altRow.syncId))
              ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
            .get();
        if (altPs.isEmpty) continue;
        useAlt = true;
      } else {
        continue;
      }
      final wSets = await (select(workoutSets)
            ..where((t) => t.workoutExerciseId.equals(we.syncId))
            ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
          .get();
      for (final ws in wSets) {
        final c = completionByWorkoutSet[ws.syncId];
        if (c == null) continue;
        int? tReps;
        double? tWeight;
        int? tSeconds;
        String targetPsId;
        if (useAlt) {
          final ps = altPs
              .where((p) => p.setIndex == ws.setIndex)
              .firstOrNull;
          if (ps == null) continue;
          tReps = ps.targetReps;
          tWeight = ps.targetWeightKg;
          tSeconds = ps.targetSeconds;
          targetPsId = ps.syncId;
        } else {
          final ps = primaryPs
              .where((p) => p.setIndex == ws.setIndex)
              .firstOrNull;
          if (ps == null) continue;
          tReps = ps.targetReps;
          tWeight = ps.targetWeightKg;
          tSeconds = ps.targetSeconds;
          targetPsId = ps.syncId;
        }
        final improved = _isImprovement(
          kind: we.kind,
          targetReps: tReps,
          targetWeightKg: tWeight,
          targetSeconds: tSeconds,
          actualReps: c.actualReps,
          actualWeightKg: c.actualWeightKg,
          actualSeconds: c.actualSeconds,
        );
        if (!improved) continue;
        out.add(
          WorkoutImprovement(
            exerciseName: we.exerciseName,
            kind: we.kind,
            setIndex: ws.setIndex,
            targetPlannedSetId: targetPsId,
            targetIsAlternative: useAlt,
            oldReps: tReps,
            oldWeightKg: tWeight,
            oldSeconds: tSeconds,
            newReps: c.actualReps,
            newWeightKg: c.actualWeightKg,
            newSeconds: c.actualSeconds,
          ),
        );
      }
    }
    return out;
  }

  bool _isImprovement({
    required String kind,
    required int? targetReps,
    required double? targetWeightKg,
    required int? targetSeconds,
    required int? actualReps,
    required double? actualWeightKg,
    required int? actualSeconds,
  }) {
    if (kind == exerciseKindTime) {
      if (targetSeconds == null || actualSeconds == null) return false;
      return actualSeconds > targetSeconds;
    }
    if (targetReps == null ||
        targetWeightKg == null ||
        actualReps == null ||
        actualWeightKg == null) {
      return false;
    }
    if (actualReps < targetReps || actualWeightKg < targetWeightKg) return false;
    return actualReps > targetReps || actualWeightKg > targetWeightKg;
  }

  /// Promote every outstanding improvement in [workoutId] to its routine
  /// planned set. Idempotent — once applied, the same call returns an empty
  /// improvement list and is a no-op.
  Future<void> applyWorkoutImprovements(String workoutId) async {
    final improvements = await findWorkoutImprovements(workoutId);
    if (improvements.isEmpty) return;
    await transaction(() async {
      for (final imp in improvements) {
        if (imp.targetIsAlternative) {
          await updateAlternativePlannedSet(
            id: imp.targetPlannedSetId,
            targetReps: imp.newReps,
            targetWeightKg: imp.newWeightKg,
            targetSeconds: imp.newSeconds,
          );
        } else {
          await updatePlannedSet(
            id: imp.targetPlannedSetId,
            targetReps: imp.newReps,
            targetWeightKg: imp.newWeightKg,
            targetSeconds: imp.newSeconds,
          );
        }
      }
    });
  }

  /// Watch all completions for a workout, indexed by workoutSetId for fast
  /// lookup from the watch run page.
  Stream<Map<String, SetCompletion>> watchCompletionsByWorkoutSet(String workoutId) {
    return (select(setCompletions)..where((t) => t.workoutId.equals(workoutId)))
        .watch()
        .map((rows) => {for (final c in rows) c.workoutSetId: c});
  }

  /// Insert or update a completion for (workoutId, workoutSetId). Used by the
  /// watch run page to allow re-marking a set after navigating back to it.
  ///
  /// HR aggregates use `Value.absent()` semantics — passing absent leaves the
  /// existing value untouched on an update. That way re-marking a set with no
  /// new HR samples buffered doesn't clobber a previously-captured value.
  Future<SetCompletion> upsertSetCompletion({
    required String workoutId,
    required String workoutSetId,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    Value<int?> avgHeartRate = const Value.absent(),
    Value<int?> maxHeartRate = const Value.absent(),
  }) async {
    return transaction(() async {
      final existing = await (select(setCompletions)..where(
            (t) =>
                t.workoutId.equals(workoutId) &
                t.workoutSetId.equals(workoutSetId),
          ))
          .getSingleOrNull();
      if (existing != null) {
        await (update(
          setCompletions,
        )..where((t) => t.syncId.equals(existing.syncId))).write(
          SetCompletionsCompanion(
            actualReps: Value(actualReps),
            actualWeightKg: Value(actualWeightKg),
            actualSeconds: Value(actualSeconds),
            avgHeartRate: avgHeartRate,
            maxHeartRate: maxHeartRate,
            completedAt: Value(DateTime.now()),
          ),
        );
        await _bumpWorkoutVersion(workoutId);
        return (select(
          setCompletions,
        )..where((t) => t.syncId.equals(existing.syncId))).getSingle();
      }
      final id = _uuid.v4();
      await into(setCompletions).insert(
        SetCompletionsCompanion.insert(
          syncId: id,
          workoutId: workoutId,
          workoutSetId: workoutSetId,
          actualReps: Value(actualReps),
          actualWeightKg: Value(actualWeightKg),
          actualSeconds: Value(actualSeconds),
          avgHeartRate: avgHeartRate,
          maxHeartRate: maxHeartRate,
          completedAt: DateTime.now(),
        ),
      );
      await _bumpWorkoutVersion(workoutId);
      return (select(
        setCompletions,
      )..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  /// Update a completion by id (workout-edit flow on phone).
  Future<void> updateCompletion({
    required String id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    DateTime? completedAt,
  }) async {
    await transaction(() async {
      final workoutId = await _workoutIdOfCompletion(id);
      await (update(setCompletions)..where((t) => t.syncId.equals(id))).write(
        SetCompletionsCompanion(
          actualReps: Value(actualReps),
          actualWeightKg: Value(actualWeightKg),
          actualSeconds: Value(actualSeconds),
          completedAt: completedAt == null
              ? const Value.absent()
              : Value(completedAt),
        ),
      );
      if (workoutId != null) await _bumpWorkoutVersion(workoutId);
    });
  }

  /// Remove the completion (if any) for (workoutId, workoutSetId).
  Future<void> deleteSetCompletionFor({
    required String workoutId,
    required String workoutSetId,
  }) async {
    await transaction(() async {
      await (delete(setCompletions)..where(
            (t) =>
                t.workoutId.equals(workoutId) &
                t.workoutSetId.equals(workoutSetId),
          ))
          .go();
      await _bumpWorkoutVersion(workoutId);
    });
  }

  Future<void> deleteCompletion(String id) async {
    await transaction(() async {
      // Resolve the owner before the delete removes the row.
      final workoutId = await _workoutIdOfCompletion(id);
      await (delete(setCompletions)..where((t) => t.syncId.equals(id))).go();
      if (workoutId != null) await _bumpWorkoutVersion(workoutId);
    });
  }

  // -- Workout snapshot editing (phone history page) -------------------

  Future<WorkoutExercise> addWorkoutExercise({
    required String workoutId,
    required String exerciseId,
  }) async {
    return transaction(() async {
      final ex = await (select(
        exercises,
      )..where((t) => t.syncId.equals(exerciseId))).getSingle();
      final maxOrderExpr = workoutExercises.orderIndex.max();
      final row = await (selectOnly(workoutExercises)
            ..where(workoutExercises.workoutId.equals(workoutId))
            ..addColumns([maxOrderExpr]))
          .getSingleOrNull();
      final next = (row?.read(maxOrderExpr) ?? -1) + 1;
      final id = _uuid.v4();
      await into(workoutExercises).insert(
        WorkoutExercisesCompanion.insert(
          syncId: id,
          workoutId: workoutId,
          exerciseId: Value(ex.syncId),
          exerciseName: ex.name,
          orderIndex: next,
          kind: Value(ex.kind),
        ),
      );
      await _bumpWorkoutVersion(workoutId);
      return (select(
        workoutExercises,
      )..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  Future<void> removeWorkoutExercise(String workoutExerciseId) async {
    await transaction(() async {
      // Resolve the owner before the delete removes the row.
      final workoutId = await _workoutIdOfWorkoutExercise(workoutExerciseId);
      await (delete(
        workoutExercises,
      )..where((t) => t.syncId.equals(workoutExerciseId))).go();
      if (workoutId != null) await _bumpWorkoutVersion(workoutId);
    });
  }

  /// Change which exercise a workout slot records, adopting the new name and
  /// kind and touching nothing else — the sets, their targets and their
  /// completions all stay exactly as they are.
  ///
  /// Distinct from [swapWorkoutExercise], which is the watch's mid-run swap and
  /// *retargets* unfinished sets to a registered alternative's planned values.
  /// This one is the editor's "actually, that was dumbbell press": the sets
  /// already record what happened, so rewriting their targets would be wrong.
  ///
  /// `routineExerciseId` is left alone. It is safe: [findWorkoutImprovements]
  /// skips any slot whose exercise is neither the routine's primary nor one of
  /// its registered alternatives, so a substitute can't have its actuals
  /// promoted onto the original exercise's targets.
  Future<void> changeWorkoutExercise({
    required String workoutExerciseId,
    required String exerciseId,
  }) async {
    await transaction(() async {
      final ex = await (select(
        exercises,
      )..where((t) => t.syncId.equals(exerciseId))).getSingleOrNull();
      if (ex == null) return;
      final workoutId = await _workoutIdOfWorkoutExercise(workoutExerciseId);
      await (update(workoutExercises)
            ..where((t) => t.syncId.equals(workoutExerciseId)))
          .write(
        WorkoutExercisesCompanion(
          exerciseId: Value(ex.syncId),
          exerciseName: Value(ex.name),
          kind: Value(ex.kind),
        ),
      );
      if (workoutId != null) await _bumpWorkoutVersion(workoutId);
    });
  }

  Future<WorkoutSet> addWorkoutSet({
    required String workoutExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    return transaction(() async {
      final maxIndexExpr = workoutSets.setIndex.max();
      final row =
          await (selectOnly(workoutSets)
                ..where(workoutSets.workoutExerciseId.equals(workoutExerciseId))
                ..addColumns([maxIndexExpr]))
              .getSingleOrNull();
      final next = (row?.read(maxIndexExpr) ?? -1) + 1;
      final id = _uuid.v4();
      await into(workoutSets).insert(
        WorkoutSetsCompanion.insert(
          syncId: id,
          workoutExerciseId: workoutExerciseId,
          setIndex: next,
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      final workoutId = await _workoutIdOfWorkoutExercise(workoutExerciseId);
      if (workoutId != null) await _bumpWorkoutVersion(workoutId);
      return (select(
        workoutSets,
      )..where((t) => t.syncId.equals(id))).getSingle();
    });
  }

  Future<void> removeWorkoutSet(String workoutSetId) async {
    await transaction(() async {
      // Resolve the owner before the delete removes the row (two hops up).
      final workoutId = await _workoutIdOfWorkoutSet(workoutSetId);
      await (delete(
        workoutSets,
      )..where((t) => t.syncId.equals(workoutSetId))).go();
      if (workoutId != null) await _bumpWorkoutVersion(workoutId);
    });
  }

  /// Mid-workout swap: change which canonical exercise this snapshot row
  /// represents. If the chosen alternative carries its own planned sets, the
  /// workout's uncompleted sets are retargeted to those values (completed sets
  /// keep their targets + completions intact). With no alternative planned
  /// sets, targets are left as-is — falling back to "share with primary"
  /// behaviour.
  Future<void> swapWorkoutExercise({
    required String workoutExerciseId,
    required String newExerciseId,
  }) async {
    await transaction(() async {
      final ex = await (select(
        exercises,
      )..where((t) => t.syncId.equals(newExerciseId))).getSingle();
      final we = await (select(workoutExercises)
            ..where((t) => t.syncId.equals(workoutExerciseId)))
          .getSingle();

      // Look up the alternative row (and its planned sets) for this slot, if
      // any: the alternative's exerciseId matches the new selection, and the
      // workout exercise has a back-pointer to a routine slot.
      List<AlternativePlannedSet> altPs = const [];
      final reId = we.routineExerciseId;
      if (reId != null) {
        final alts = await (select(routineExerciseAlternatives)
              ..where((t) => t.routineExerciseId.equals(reId)))
            .get();
        final altRow =
            alts.where((a) => a.exerciseId == newExerciseId).firstOrNull;
        if (altRow != null) {
          altPs = await (select(alternativePlannedSets)
                ..where((t) => t.alternativeId.equals(altRow.syncId))
                ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
              .get();
        }
      }

      if (altPs.isNotEmpty) {
        // Retarget unfinished sets in place. Walk existing WorkoutSets in
        // setIndex order; for each one without a completion, overwrite its
        // targets from the matching alt set. Append extras for any alt sets
        // beyond the current count.
        final existingSets = await (select(workoutSets)
              ..where((t) => t.workoutExerciseId.equals(workoutExerciseId))
              ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
            .get();
        final completions = await (select(setCompletions)
              ..where((t) => t.workoutId.equals(we.workoutId)))
            .get();
        final completedSetIds = {
          for (final c in completions) c.workoutSetId,
        };
        final byIndex = {for (final s in existingSets) s.setIndex: s};
        for (final aps in altPs) {
          final existing = byIndex[aps.setIndex];
          if (existing == null) {
            await into(workoutSets).insert(
              WorkoutSetsCompanion.insert(
                syncId: _uuid.v4(),
                workoutExerciseId: workoutExerciseId,
                setIndex: aps.setIndex,
                targetReps: Value(aps.targetReps),
                targetWeightKg: Value(aps.targetWeightKg),
                targetSeconds: Value(aps.targetSeconds),
              ),
            );
            continue;
          }
          if (completedSetIds.contains(existing.syncId)) continue;
          await (update(workoutSets)..where((t) => t.syncId.equals(existing.syncId)))
              .write(
                WorkoutSetsCompanion(
                  targetReps: Value(aps.targetReps),
                  targetWeightKg: Value(aps.targetWeightKg),
                  targetSeconds: Value(aps.targetSeconds),
                ),
              );
        }
      }

      await (update(workoutExercises)
            ..where((t) => t.syncId.equals(workoutExerciseId)))
          .write(
            WorkoutExercisesCompanion(
              exerciseId: Value(ex.syncId),
              exerciseName: Value(ex.name),
              kind: Value(ex.kind),
            ),
          );
      await _bumpWorkoutVersion(we.workoutId);
    });
  }

  /// Variants available for [workoutExerciseId]: the routine slot's primary
  /// exercise plus all its alternatives, minus the currently-selected one.
  /// Returns empty if the workout exercise has no `routineExerciseId` back
  /// pointer (e.g., pre-v6 workouts) or if the slot was removed from the
  /// routine since the workout started.
  Future<List<Exercise>> loadAlternativesForWorkoutExercise(
    String workoutExerciseId,
  ) async {
    final we = await (select(
      workoutExercises,
    )..where((t) => t.syncId.equals(workoutExerciseId))).getSingleOrNull();
    if (we == null) return const [];
    final reId = we.routineExerciseId;
    if (reId == null) return const [];
    final re = await (select(
      routineExercises,
    )..where((t) => t.syncId.equals(reId))).getSingleOrNull();
    if (re == null) return const [];
    final variantIds = <String>{re.exerciseId};
    final alts = await (select(routineExerciseAlternatives)
          ..where((t) => t.routineExerciseId.equals(reId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    variantIds.addAll(alts.map((a) => a.exerciseId));
    final current = we.exerciseId;
    if (current != null) variantIds.remove(current);
    if (variantIds.isEmpty) return const [];
    final exs = await (select(
      exercises,
    )..where((t) => t.syncId.isIn(variantIds))).get();
    // Stable order: primary first if still present, then alternatives in
    // their stored orderIndex.
    final byId = {for (final e in exs) e.syncId: e};
    final ordered = <Exercise>[];
    if (current != re.exerciseId && byId.containsKey(re.exerciseId)) {
      ordered.add(byId[re.exerciseId]!);
    }
    for (final a in alts) {
      final ex = byId[a.exerciseId];
      if (ex != null && ex.syncId != current) ordered.add(ex);
    }
    return ordered;
  }
}
