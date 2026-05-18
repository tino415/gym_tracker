import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

part 'database.g.dart';

const _uuid = Uuid();

// Exercise kinds. Reps-based exercises track reps + weight per set; time-based
// exercises track a duration per set.
const exerciseKindReps = 'reps';
const exerciseKindTime = 'time';

class Exercises extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  TextColumn get name => text().unique()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get kind =>
      text().withDefault(const Constant(exerciseKindReps))();
}

class Routines extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(1))();
}

class RoutineExercises extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get routineId =>
      integer().references(Routines, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.restrict)();
  IntColumn get orderIndex => integer()();
  IntColumn get restSeconds => integer().withDefault(const Constant(90))();
  // Exercises sharing a non-null group on the same routine form a superset
  // (alternating sets at run time). Null = standalone.
  IntColumn get supersetGroup => integer().nullable()();
}

class PlannedSets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get routineExerciseId =>
      integer().references(RoutineExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get setIndex => integer()();
  // For reps-kind exercises:
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  // For time-kind exercises:
  IntColumn get targetSeconds => integer().nullable()();
}

/// Alternative exercises for a routine slot. The user can swap to any of these
/// mid-workout (e.g., dumbbell bench if the barbell is occupied). Lives on the
/// routine — workouts read these on demand via [WorkoutExercises.routineExerciseId].
class RoutineExerciseAlternatives extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get routineExerciseId =>
      integer().references(RoutineExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.restrict)();
  IntColumn get orderIndex => integer()();
}

/// Per-alternative planned sets. Mirrors [PlannedSets] but FK'd to an
/// alternative row. Empty list means the alternative shares the primary's
/// targets at swap time — feature is opt-in per alternative.
class AlternativePlannedSets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get alternativeId => integer().references(
    RoutineExerciseAlternatives,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get setIndex => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetSeconds => integer().nullable()();
}

/// Muscle group registry. Seeded with a standard set; users may add more.
class Muscles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  TextColumn get name => text().unique()();
}

/// Many-to-many: which muscles an exercise targets.
class ExerciseMuscles extends Table {
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get muscleId =>
      integer().references(Muscles, #id, onDelete: KeyAction.cascade)();
  @override
  Set<Column> get primaryKey => {exerciseId, muscleId};
}

class Workouts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  // Nullable + SET NULL: the workout owns a snapshot of its routine, so
  // deleting the routine just severs the link, the workout stays.
  IntColumn get routineId => integer()
      .nullable()
      .references(Routines, #id, onDelete: KeyAction.setNull)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  // Workout-level heart-rate aggregates computed on Finish from the per-set
  // completion aggregates. Null until a workout finishes (or if no HR samples
  // were captured).
  IntColumn get avgHeartRate => integer().nullable()();
  IntColumn get maxHeartRate => integer().nullable()();
}

/// Snapshot of a routine exercise taken when a workout starts. Owned by the
/// workout — survives routine edits and routine deletion.
class WorkoutExercises extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutId =>
      integer().references(Workouts, #id, onDelete: KeyAction.cascade)();
  // Link back to the canonical Exercise for analytics. SET NULL on delete so
  // history survives the source exercise being removed.
  IntColumn get exerciseId => integer().nullable().references(
    Exercises,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get exerciseName => text()();
  IntColumn get orderIndex => integer()();
  IntColumn get restSeconds => integer().withDefault(const Constant(90))();
  IntColumn get supersetGroup => integer().nullable()();
  TextColumn get kind =>
      text().withDefault(const Constant(exerciseKindReps))();
  // Back-pointer to the routine slot this workout exercise was created from.
  // SET NULL on delete so a routine edit that removes the slot mid-workout
  // gracefully disables mid-workout swap without breaking the workout itself.
  IntColumn get routineExerciseId => integer().nullable().references(
    RoutineExercises,
    #id,
    onDelete: KeyAction.setNull,
  )();
}

/// Snapshot of a planned set taken when a workout starts.
class WorkoutSets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutExerciseId => integer()
      .references(WorkoutExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get setIndex => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetSeconds => integer().nullable()();
}

class SetCompletions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutId =>
      integer().references(Workouts, #id, onDelete: KeyAction.cascade)();
  // Bound to the workout's own snapshot, not back to the routine's planned_set.
  IntColumn get workoutSetId =>
      integer().references(WorkoutSets, #id, onDelete: KeyAction.cascade)();
  IntColumn get actualReps => integer().nullable()();
  RealColumn get actualWeightKg => real().nullable()();
  IntColumn get actualSeconds => integer().nullable()();
  DateTimeColumn get completedAt => dateTime()();
  // Per-set heart-rate aggregates over the time the set was active. Nullable
  // because earlier rows / sets recorded without HR permission won't have them.
  IntColumn get avgHeartRate => integer().nullable()();
  IntColumn get maxHeartRate => integer().nullable()();
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 7;

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
      if (from < 2) {
        // v1 → v2: vocabulary rename (workouts→routines, sessions→workouts).
        await customStatement('ALTER TABLE sessions RENAME TO _workouts_new');
        await customStatement('ALTER TABLE workouts RENAME TO routines');
        await customStatement(
          'ALTER TABLE workout_exercises RENAME TO routine_exercises',
        );
        await customStatement(
          'ALTER TABLE routine_exercises RENAME COLUMN workout_id TO routine_id',
        );
        await customStatement(
          'ALTER TABLE planned_sets RENAME COLUMN workout_exercise_id TO routine_exercise_id',
        );
        await customStatement('ALTER TABLE _workouts_new RENAME TO workouts');
        await customStatement(
          'ALTER TABLE workouts RENAME COLUMN workout_id TO routine_id',
        );
        await customStatement(
          'ALTER TABLE set_completions RENAME COLUMN session_id TO workout_id',
        );
      }
      if (from < 3) {
        // v2 → v3: introduce workout snapshot, exercise kinds, supersets,
        // time-based targets, and make workouts independent of routines.
        await _migrateToV3(m);
      }
      if (from < 4) {
        // v3 → v4: repair FK references on the snapshot tables. The original
        // v3 migration created workout_exercises/workout_sets before it
        // recreated `workouts`, so SQLite re-pointed their workout_id FK at
        // the now-dropped `_workouts_v2` rename-target. Recreate the
        // snapshot tables (preserving rows) so their FKs reference the
        // current `workouts`. v2→v3 has been reordered above so a fresh
        // upgrade no longer hits this; the step still runs as a no-op
        // safety net for clean v3s.
        await _migrateToV4(m);
      }
      if (from < 5) {
        // v4 → v5: HR aggregate columns on workouts + set_completions.
        await m.addColumn(workouts, workouts.avgHeartRate);
        await m.addColumn(workouts, workouts.maxHeartRate);
        await m.addColumn(setCompletions, setCompletions.avgHeartRate);
        await m.addColumn(setCompletions, setCompletions.maxHeartRate);
      }
      if (from < 6) {
        // v5 → v6: alternative exercises per routine slot + muscle registry.
        await m.createTable(routineExerciseAlternatives);
        await m.createTable(muscles);
        await m.createTable(exerciseMuscles);
        await m.addColumn(
          workoutExercises,
          workoutExercises.routineExerciseId,
        );
      }
      if (from < 7) {
        // v6 → v7: per-alternative planned sets.
        await m.createTable(alternativePlannedSets);
      }
    },
  );

  // Standard muscle list. Seeded idempotently on every open so a fresh DB and
  // an upgraded one both end up with the same row ids (deterministic syncIds
  // mean phone and watch agree without sync round-trips).
  static const _muscleSeeds = [
    'Chest',
    'Back',
    'Shoulders',
    'Biceps',
    'Triceps',
    'Forearms',
    'Abs',
    'Quads',
    'Hamstrings',
    'Glutes',
    'Calves',
  ];

  Future<void> _seedMuscles() async {
    for (final name in _muscleSeeds) {
      await customStatement(
        'INSERT OR IGNORE INTO muscles (sync_id, name) VALUES (?, ?)',
        ['muscle:${name.toLowerCase()}', name],
      );
    }
  }

  Future<void> _migrateToV3(Migrator m) async {
    // Foreign keys must be off for the recreate-table dance below. They get
    // turned back on by beforeOpen on the next connection.
    await customStatement('PRAGMA foreign_keys = OFF');

    // 1. Additive column adds.
    await m.addColumn(exercises, exercises.kind);
    await m.addColumn(routineExercises, routineExercises.supersetGroup);
    await m.addColumn(plannedSets, plannedSets.targetSeconds);

    // 2. Recreate planned_sets so target_reps / target_weight_kg become
    //    nullable.
    await customStatement(
      'ALTER TABLE planned_sets RENAME TO _planned_sets_v2',
    );
    await m.createTable(plannedSets);
    await customStatement('''
      INSERT INTO planned_sets
        (id, sync_id, routine_exercise_id, set_index, target_reps, target_weight_kg, target_seconds)
      SELECT id, sync_id, routine_exercise_id, set_index, target_reps, target_weight_kg, target_seconds
      FROM _planned_sets_v2
    ''');
    await customStatement('DROP TABLE _planned_sets_v2');

    // 3. Recreate workouts (nullable routine_id + SET NULL) BEFORE creating
    //    the snapshot tables. Otherwise the snapshot tables' FK references
    //    would track the rename target and end up dangling after the drop.
    await customStatement('ALTER TABLE workouts RENAME TO _workouts_v2');
    await m.createTable(workouts);
    await customStatement('''
      INSERT INTO workouts (id, sync_id, routine_id, started_at, ended_at)
      SELECT id, sync_id, routine_id, started_at, ended_at FROM _workouts_v2
    ''');
    await customStatement('DROP TABLE _workouts_v2');

    // 4. Create the snapshot tables, now bound to the freshly-recreated
    //    workouts.
    await m.createTable(workoutExercises);
    await m.createTable(workoutSets);

    // 5. Snapshot every existing workout's routine into the new tables.
    final workoutToPlannedSetToWorkoutSet = <int, Map<int, int>>{};
    final existingWorkouts = await select(workouts).get();
    for (final w in existingWorkouts) {
      final routineId = w.routineId;
      if (routineId == null) continue;
      final res = await (select(routineExercises)
            ..where((t) => t.routineId.equals(routineId))
            ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
          .get();
      final psMap = <int, int>{};
      for (final re in res) {
        final ex = await (select(
          exercises,
        )..where((t) => t.id.equals(re.exerciseId))).getSingle();
        final weId = await into(workoutExercises).insert(
          WorkoutExercisesCompanion.insert(
            syncId: _uuid.v4(),
            workoutId: w.id,
            exerciseId: Value(ex.id),
            exerciseName: ex.name,
            orderIndex: re.orderIndex,
            restSeconds: Value(re.restSeconds),
            supersetGroup: Value(re.supersetGroup),
            kind: Value(ex.kind),
          ),
        );
        final ps = await (select(plannedSets)
              ..where((t) => t.routineExerciseId.equals(re.id))
              ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
            .get();
        for (final p in ps) {
          final wsId = await into(workoutSets).insert(
            WorkoutSetsCompanion.insert(
              syncId: _uuid.v4(),
              workoutExerciseId: weId,
              setIndex: p.setIndex,
              targetReps: Value(p.targetReps),
              targetWeightKg: Value(p.targetWeightKg),
              targetSeconds: Value(p.targetSeconds),
            ),
          );
          psMap[p.id] = wsId;
        }
      }
      workoutToPlannedSetToWorkoutSet[w.id] = psMap;
    }

    // 6. Recreate set_completions: planned_set_id → workout_set_id, nullable
    //    actuals, plus actual_seconds.
    await customStatement(
      'ALTER TABLE set_completions RENAME TO _set_completions_v2',
    );
    await m.createTable(setCompletions);
    final oldCompletions = await customSelect(
      'SELECT id, sync_id, workout_id, planned_set_id, actual_reps, actual_weight_kg, completed_at FROM _set_completions_v2',
    ).get();
    for (final row in oldCompletions) {
      final workoutId = row.read<int>('workout_id');
      final oldPlannedSetId = row.read<int>('planned_set_id');
      final wsId =
          workoutToPlannedSetToWorkoutSet[workoutId]?[oldPlannedSetId];
      if (wsId == null) continue; // orphan — drop
      await into(setCompletions).insert(
        SetCompletionsCompanion.insert(
          syncId: row.read<String>('sync_id'),
          workoutId: workoutId,
          workoutSetId: wsId,
          actualReps: Value(row.read<int>('actual_reps')),
          actualWeightKg: Value(row.read<double>('actual_weight_kg')),
          actualSeconds: const Value(null),
          completedAt: row.read<DateTime>('completed_at'),
        ),
      );
    }
    await customStatement('DROP TABLE _set_completions_v2');

    await customStatement('PRAGMA foreign_keys = ON');
  }

  Future<void> _migrateToV4(Migrator m) async {
    // Recreate the snapshot tables (and set_completions, which FKs into
    // workout_sets) so that any stale FK references left over from the bad
    // v3 path are rebuilt against the current `workouts`. Done unconditionally
    // — for correct v3 DBs it is just data round-tripped through fresh
    // tables.
    await customStatement('PRAGMA foreign_keys = OFF');
    await customStatement(
      'ALTER TABLE set_completions RENAME TO _set_completions_v3',
    );
    await customStatement(
      'ALTER TABLE workout_sets RENAME TO _workout_sets_v3',
    );
    await customStatement(
      'ALTER TABLE workout_exercises RENAME TO _workout_exercises_v3',
    );
    await m.createTable(workoutExercises);
    await m.createTable(workoutSets);
    await m.createTable(setCompletions);
    await customStatement('''
      INSERT INTO workout_exercises
        (id, sync_id, workout_id, exercise_id, exercise_name, order_index, rest_seconds, superset_group, kind)
      SELECT id, sync_id, workout_id, exercise_id, exercise_name, order_index, rest_seconds, superset_group, kind
      FROM _workout_exercises_v3
    ''');
    await customStatement('''
      INSERT INTO workout_sets
        (id, sync_id, workout_exercise_id, set_index, target_reps, target_weight_kg, target_seconds)
      SELECT id, sync_id, workout_exercise_id, set_index, target_reps, target_weight_kg, target_seconds
      FROM _workout_sets_v3
    ''');
    await customStatement('''
      INSERT INTO set_completions
        (id, sync_id, workout_id, workout_set_id, actual_reps, actual_weight_kg, actual_seconds, completed_at)
      SELECT id, sync_id, workout_id, workout_set_id, actual_reps, actual_weight_kg, actual_seconds, completed_at
      FROM _set_completions_v3
    ''');
    await customStatement('DROP TABLE _set_completions_v3');
    await customStatement('DROP TABLE _workout_sets_v3');
    await customStatement('DROP TABLE _workout_exercises_v3');
    await customStatement('PRAGMA foreign_keys = ON');
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
    return (select(
      exercises,
    )..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();
  }

  /// One-shot fetch of every exercise with its muscle tags, in name order.
  /// Used by the exercise registry list — the call is cheap (small N) and
  /// avoids one query per row on rebuild.
  Future<List<ExerciseWithMuscles>> loadExercisesWithMuscles() async {
    final exs = await (select(
      exercises,
    )..orderBy([(t) => OrderingTerm.asc(t.name)])).get();
    if (exs.isEmpty) return const [];
    final rows = await (select(exerciseMuscles).join([
          innerJoin(muscles, muscles.id.equalsExp(exerciseMuscles.muscleId)),
        ])
          ..orderBy([OrderingTerm.asc(muscles.name)]))
        .get();
    final byExercise = <int, List<Muscle>>{};
    for (final row in rows) {
      final em = row.readTable(exerciseMuscles);
      final m = row.readTable(muscles);
      byExercise.putIfAbsent(em.exerciseId, () => []).add(m);
    }
    return [
      for (final e in exs)
        ExerciseWithMuscles(exercise: e, muscles: byExercise[e.id] ?? const []),
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
    final now = DateTime.now();
    final id = await into(exercises).insert(
      ExercisesCompanion.insert(
        syncId: _uuid.v4(),
        name: name,
        createdAt: now,
        kind: Value(kind),
      ),
    );
    return (select(exercises)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameExercise(int id, String name) async {
    await (update(
      exercises,
    )..where((t) => t.id.equals(id))).write(ExercisesCompanion(name: Value(name)));
  }

  Future<void> setExerciseKind(int id, String kind) async {
    await (update(
      exercises,
    )..where((t) => t.id.equals(id))).write(ExercisesCompanion(kind: Value(kind)));
  }

  Future<void> deleteExercise(int id) async {
    await (delete(exercises)..where((t) => t.id.equals(id))).go();
  }

  // -- Routines ---------------------------------------------------------

  Stream<List<RoutineSummary>> watchRoutineSummaries() {
    final countExpr = routineExercises.id.count();
    final query =
        select(routines).join([
            leftOuterJoin(
              routineExercises,
              routineExercises.routineId.equalsExp(routines.id),
            ),
          ])
          ..addColumns([countExpr])
          ..groupBy([routines.id])
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
    final id = await into(routines).insert(
      RoutinesCompanion.insert(syncId: _uuid.v4(), name: name, createdAt: now),
    );
    return (select(routines)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameRoutine(int id, String name) async {
    await (update(routines)..where((t) => t.id.equals(id))).write(
      RoutinesCompanion(name: Value(name), version: const Value.absent()),
    );
    await _bumpRoutineVersion(id);
  }

  Future<void> deleteRoutine(int id) async {
    // Workouts.routine_id is SET NULL on delete now — past workouts keep
    // their own snapshot and just lose their backref. Cascade through
    // routine_exercises → planned_sets cleans up template data.
    await (delete(routines)..where((t) => t.id.equals(id))).go();
  }

  Future<FullRoutine?> loadFullRoutine(int routineId) async {
    final r = await (select(
      routines,
    )..where((t) => t.id.equals(routineId))).getSingleOrNull();
    if (r == null) return null;
    final res =
        await (select(routineExercises)
              ..where((t) => t.routineId.equals(routineId))
              ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
            .get();
    final result = <FullRoutineExercise>[];
    for (final re in res) {
      final ex = await (select(
        exercises,
      )..where((t) => t.id.equals(re.exerciseId))).getSingle();
      final sets =
          await (select(plannedSets)
                ..where((t) => t.routineExerciseId.equals(re.id))
                ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
              .get();
      final alts = await _loadAlternatives(re.id);
      final mus = await _loadMusclesFor(ex.id);
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
    int routineExerciseId,
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
    )..where((t) => t.id.isIn(ids))).get();
    final byId = {for (final e in exs) e.id: e};
    final result = <RoutineAlternative>[];
    for (final a in alts) {
      final ex = byId[a.exerciseId];
      if (ex == null) continue;
      final ps = await (select(alternativePlannedSets)
            ..where((t) => t.alternativeId.equals(a.id))
            ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
          .get();
      result.add(RoutineAlternative(join: a, exercise: ex, plannedSets: ps));
    }
    return result;
  }

  Future<List<Muscle>> _loadMusclesFor(int exerciseId) async {
    final rows =
        await (select(exerciseMuscles).join([
              innerJoin(muscles, muscles.id.equalsExp(exerciseMuscles.muscleId)),
            ])
              ..where(exerciseMuscles.exerciseId.equals(exerciseId))
              ..orderBy([OrderingTerm.asc(muscles.name)]))
            .get();
    return rows.map((r) => r.readTable(muscles)).toList();
  }

  Stream<FullRoutine?> watchFullRoutine(int routineId) async* {
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
    required int routineId,
    required int exerciseId,
  }) async {
    return transaction(() async {
      final maxOrder = await _maxOrderIndex(routineId);
      final id = await into(routineExercises).insert(
        RoutineExercisesCompanion.insert(
          syncId: _uuid.v4(),
          routineId: routineId,
          exerciseId: exerciseId,
          orderIndex: maxOrder + 1,
        ),
      );
      await _bumpRoutineVersion(routineId);
      return (select(
        routineExercises,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> removeRoutineExercise(int routineExerciseId) async {
    await transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(routineExerciseId))).getSingleOrNull();
      if (re == null) return;
      await (delete(
        routineExercises,
      )..where((t) => t.id.equals(routineExerciseId))).go();
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> setRestSeconds(int routineExerciseId, int seconds) async {
    await transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(routineExerciseId))).getSingleOrNull();
      if (re == null) return;
      await (update(routineExercises)
            ..where((t) => t.id.equals(routineExerciseId)))
          .write(RoutineExercisesCompanion(restSeconds: Value(seconds)));
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> setSupersetGroup(int routineExerciseId, int? group) async {
    await transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(routineExerciseId))).getSingleOrNull();
      if (re == null) return;
      await (update(routineExercises)
            ..where((t) => t.id.equals(routineExerciseId)))
          .write(RoutineExercisesCompanion(supersetGroup: Value(group)));
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<PlannedSet> addPlannedSet({
    required int routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    return transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(routineExerciseId))).getSingle();
      final maxIndex = await _maxSetIndex(routineExerciseId);
      final id = await into(plannedSets).insert(
        PlannedSetsCompanion.insert(
          syncId: _uuid.v4(),
          routineExerciseId: routineExerciseId,
          setIndex: maxIndex + 1,
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      await _bumpRoutineVersion(re.routineId);
      return (select(plannedSets)..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> updatePlannedSet({
    required int id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    await transaction(() async {
      final ps = await (select(
        plannedSets,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(ps.routineExerciseId))).getSingle();
      await (update(plannedSets)..where((t) => t.id.equals(id))).write(
        PlannedSetsCompanion(
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> deletePlannedSet(int id) async {
    await transaction(() async {
      final ps = await (select(
        plannedSets,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(ps.routineExerciseId))).getSingle();
      await (delete(plannedSets)..where((t) => t.id.equals(id))).go();
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<int> _maxOrderIndex(int routineId) async {
    final expr = routineExercises.orderIndex.max();
    final query = selectOnly(routineExercises)
      ..where(routineExercises.routineId.equals(routineId))
      ..addColumns([expr]);
    final row = await query.getSingleOrNull();
    return row?.read(expr) ?? -1;
  }

  Future<int> _maxSetIndex(int routineExerciseId) async {
    final expr = plannedSets.setIndex.max();
    final query = selectOnly(plannedSets)
      ..where(plannedSets.routineExerciseId.equals(routineExerciseId))
      ..addColumns([expr]);
    final row = await query.getSingleOrNull();
    return row?.read(expr) ?? -1;
  }

  Future<void> _bumpRoutineVersion(int routineId) async {
    await customUpdate(
      'UPDATE routines SET version = version + 1 WHERE id = ?',
      variables: [Variable.withInt(routineId)],
      updates: {routines},
    );
  }

  // -- Routine exercise alternatives ------------------------------------

  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required int routineExerciseId,
    required int exerciseId,
  }) async {
    return transaction(() async {
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(routineExerciseId))).getSingle();
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
      final id = await into(routineExerciseAlternatives).insert(
        RoutineExerciseAlternativesCompanion.insert(
          syncId: _uuid.v4(),
          routineExerciseId: routineExerciseId,
          exerciseId: exerciseId,
          orderIndex: next,
        ),
      );
      await _bumpRoutineVersion(re.routineId);
      return (select(
        routineExerciseAlternatives,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required int alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    return transaction(() async {
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.id.equals(alternativeId))).getSingle();
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(alt.routineExerciseId))).getSingle();
      final maxExpr = alternativePlannedSets.setIndex.max();
      final row = await (selectOnly(alternativePlannedSets)
            ..where(alternativePlannedSets.alternativeId.equals(alternativeId))
            ..addColumns([maxExpr]))
          .getSingleOrNull();
      final next = (row?.read(maxExpr) ?? -1) + 1;
      final id = await into(alternativePlannedSets).insert(
        AlternativePlannedSetsCompanion.insert(
          syncId: _uuid.v4(),
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
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> updateAlternativePlannedSet({
    required int id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    await transaction(() async {
      final ps = await (select(
        alternativePlannedSets,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.id.equals(ps.alternativeId))).getSingle();
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(alt.routineExerciseId))).getSingle();
      await (update(alternativePlannedSets)..where((t) => t.id.equals(id)))
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

  Future<void> deleteAlternativePlannedSet(int id) async {
    await transaction(() async {
      final ps = await (select(
        alternativePlannedSets,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (ps == null) return;
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.id.equals(ps.alternativeId))).getSingle();
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(alt.routineExerciseId))).getSingle();
      await (delete(alternativePlannedSets)..where((t) => t.id.equals(id)))
          .go();
      await _bumpRoutineVersion(re.routineId);
    });
  }

  Future<void> removeRoutineExerciseAlternative(int alternativeId) async {
    await transaction(() async {
      final alt = await (select(
        routineExerciseAlternatives,
      )..where((t) => t.id.equals(alternativeId))).getSingleOrNull();
      if (alt == null) return;
      final re = await (select(
        routineExercises,
      )..where((t) => t.id.equals(alt.routineExerciseId))).getSingleOrNull();
      await (delete(routineExerciseAlternatives)
            ..where((t) => t.id.equals(alternativeId)))
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

  Future<List<Muscle>> musclesForExercise(int exerciseId) =>
      _loadMusclesFor(exerciseId);

  /// Replace the muscle set for an exercise with [muscleIds].
  Future<void> setExerciseMuscles(int exerciseId, List<int> muscleIds) async {
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
    });
  }

  // -- Workouts (runs) --------------------------------------------------

  Stream<List<Workout>> watchRecentWorkouts() {
    return (select(
      workouts,
    )..orderBy([(t) => OrderingTerm.desc(t.startedAt)])).watch();
  }

  /// Most recent workout with no `endedAt`. Used by the watch picker to offer
  /// a Resume entry when the user pops out of a running workout.
  Stream<Workout?> watchInProgressWorkout() {
    return ((select(workouts)..where((t) => t.endedAt.isNull()))
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Start a workout and snapshot its routine into workout-owned tables.
  /// Returns the new workout row; the snapshot is reachable via
  /// [loadFullWorkout] / [watchFullWorkout].
  Future<Workout> startWorkout(int routineId) async {
    return transaction(() async {
      final full = await loadFullRoutine(routineId);
      if (full == null) {
        throw StateError('Routine $routineId not found');
      }
      final workoutId = await into(workouts).insert(
        WorkoutsCompanion.insert(
          syncId: _uuid.v4(),
          routineId: Value(routineId),
          startedAt: DateTime.now(),
        ),
      );
      for (final re in full.exercises) {
        final weId = await into(workoutExercises).insert(
          WorkoutExercisesCompanion.insert(
            syncId: _uuid.v4(),
            workoutId: workoutId,
            exerciseId: Value(re.exercise.id),
            exerciseName: re.exercise.name,
            orderIndex: re.routineExercise.orderIndex,
            restSeconds: Value(re.routineExercise.restSeconds),
            supersetGroup: Value(re.routineExercise.supersetGroup),
            kind: Value(re.exercise.kind),
            routineExerciseId: Value(re.routineExercise.id),
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
      return (select(
        workouts,
      )..where((t) => t.id.equals(workoutId))).getSingle();
    });
  }

  Future<void> finishWorkout(
    int workoutId, {
    int? avgHeartRate,
    int? maxHeartRate,
  }) async {
    await (update(workouts)..where((t) => t.id.equals(workoutId))).write(
      WorkoutsCompanion(
        endedAt: Value(DateTime.now()),
        avgHeartRate: Value(avgHeartRate),
        maxHeartRate: Value(maxHeartRate),
      ),
    );
  }

  Future<void> updateWorkoutTimes({
    required int workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  }) async {
    await (update(workouts)..where((t) => t.id.equals(workoutId))).write(
      WorkoutsCompanion(
        startedAt: Value(startedAt),
        endedAt: Value(endedAt),
      ),
    );
  }

  Future<void> deleteWorkout(int workoutId) async {
    await (delete(workouts)..where((t) => t.id.equals(workoutId))).go();
  }

  /// Full snapshot of a workout: its (optional) routine, every workout
  /// exercise + its sets, and any completions resolved per set.
  Future<FullWorkout?> loadFullWorkout(int workoutId) async {
    final w = await (select(
      workouts,
    )..where((t) => t.id.equals(workoutId))).getSingleOrNull();
    if (w == null) return null;
    final routine = w.routineId == null
        ? null
        : await (select(
            routines,
          )..where((t) => t.id.equals(w.routineId!))).getSingleOrNull();
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
                ..where((t) => t.workoutExerciseId.equals(we.id))
                ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
              .get();
      result.add(
        FullWorkoutExercise(
          workoutExercise: we,
          sets: sets
              .map(
                (s) => FullWorkoutSet(
                  workoutSet: s,
                  completion: completionByWorkoutSet[s.id],
                ),
              )
              .toList(),
        ),
      );
    }
    return FullWorkout(workout: w, routine: routine, exercises: result);
  }

  Stream<FullWorkout?> watchFullWorkout(int workoutId) async* {
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

  Future<List<SetCompletion>> completionsForWorkout(int workoutId) {
    return (select(setCompletions)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.completedAt)]))
        .get();
  }

  /// Watch all completions for a workout, indexed by workoutSetId for fast
  /// lookup from the watch run page.
  Stream<Map<int, SetCompletion>> watchCompletionsByWorkoutSet(int workoutId) {
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
    required int workoutId,
    required int workoutSetId,
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
        )..where((t) => t.id.equals(existing.id))).write(
          SetCompletionsCompanion(
            actualReps: Value(actualReps),
            actualWeightKg: Value(actualWeightKg),
            actualSeconds: Value(actualSeconds),
            avgHeartRate: avgHeartRate,
            maxHeartRate: maxHeartRate,
            completedAt: Value(DateTime.now()),
          ),
        );
        return (select(
          setCompletions,
        )..where((t) => t.id.equals(existing.id))).getSingle();
      }
      final id = await into(setCompletions).insert(
        SetCompletionsCompanion.insert(
          syncId: _uuid.v4(),
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
      return (select(
        setCompletions,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  /// Update a completion by id (workout-edit flow on phone).
  Future<void> updateCompletion({
    required int id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    DateTime? completedAt,
  }) async {
    await (update(setCompletions)..where((t) => t.id.equals(id))).write(
      SetCompletionsCompanion(
        actualReps: Value(actualReps),
        actualWeightKg: Value(actualWeightKg),
        actualSeconds: Value(actualSeconds),
        completedAt: completedAt == null
            ? const Value.absent()
            : Value(completedAt),
      ),
    );
  }

  /// Remove the completion (if any) for (workoutId, workoutSetId).
  Future<void> deleteSetCompletionFor({
    required int workoutId,
    required int workoutSetId,
  }) async {
    await (delete(setCompletions)..where(
          (t) =>
              t.workoutId.equals(workoutId) &
              t.workoutSetId.equals(workoutSetId),
        ))
        .go();
  }

  Future<void> deleteCompletion(int id) async {
    await (delete(setCompletions)..where((t) => t.id.equals(id))).go();
  }

  // -- Workout snapshot editing (phone history page) -------------------

  Future<WorkoutExercise> addWorkoutExercise({
    required int workoutId,
    required int exerciseId,
  }) async {
    return transaction(() async {
      final ex = await (select(
        exercises,
      )..where((t) => t.id.equals(exerciseId))).getSingle();
      final maxOrderExpr = workoutExercises.orderIndex.max();
      final row = await (selectOnly(workoutExercises)
            ..where(workoutExercises.workoutId.equals(workoutId))
            ..addColumns([maxOrderExpr]))
          .getSingleOrNull();
      final next = (row?.read(maxOrderExpr) ?? -1) + 1;
      final id = await into(workoutExercises).insert(
        WorkoutExercisesCompanion.insert(
          syncId: _uuid.v4(),
          workoutId: workoutId,
          exerciseId: Value(ex.id),
          exerciseName: ex.name,
          orderIndex: next,
          kind: Value(ex.kind),
        ),
      );
      return (select(
        workoutExercises,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> removeWorkoutExercise(int workoutExerciseId) async {
    await (delete(
      workoutExercises,
    )..where((t) => t.id.equals(workoutExerciseId))).go();
  }

  Future<WorkoutSet> addWorkoutSet({
    required int workoutExerciseId,
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
      final id = await into(workoutSets).insert(
        WorkoutSetsCompanion.insert(
          syncId: _uuid.v4(),
          workoutExerciseId: workoutExerciseId,
          setIndex: next,
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
          targetSeconds: Value(targetSeconds),
        ),
      );
      return (select(
        workoutSets,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> removeWorkoutSet(int workoutSetId) async {
    await (delete(workoutSets)..where((t) => t.id.equals(workoutSetId))).go();
  }

  /// Mid-workout swap: change which canonical exercise this snapshot row
  /// represents. If the chosen alternative carries its own planned sets, the
  /// workout's uncompleted sets are retargeted to those values (completed sets
  /// keep their targets + completions intact). With no alternative planned
  /// sets, targets are left as-is — falling back to "share with primary"
  /// behaviour.
  Future<void> swapWorkoutExercise({
    required int workoutExerciseId,
    required int newExerciseId,
  }) async {
    await transaction(() async {
      final ex = await (select(
        exercises,
      )..where((t) => t.id.equals(newExerciseId))).getSingle();
      final we = await (select(workoutExercises)
            ..where((t) => t.id.equals(workoutExerciseId)))
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
                ..where((t) => t.alternativeId.equals(altRow.id))
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
          if (completedSetIds.contains(existing.id)) continue;
          await (update(workoutSets)..where((t) => t.id.equals(existing.id)))
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
            ..where((t) => t.id.equals(workoutExerciseId)))
          .write(
            WorkoutExercisesCompanion(
              exerciseId: Value(ex.id),
              exerciseName: Value(ex.name),
              kind: Value(ex.kind),
            ),
          );
    });
  }

  /// Variants available for [workoutExerciseId]: the routine slot's primary
  /// exercise plus all its alternatives, minus the currently-selected one.
  /// Returns empty if the workout exercise has no `routineExerciseId` back
  /// pointer (e.g., pre-v6 workouts) or if the slot was removed from the
  /// routine since the workout started.
  Future<List<Exercise>> loadAlternativesForWorkoutExercise(
    int workoutExerciseId,
  ) async {
    final we = await (select(
      workoutExercises,
    )..where((t) => t.id.equals(workoutExerciseId))).getSingleOrNull();
    if (we == null) return const [];
    final reId = we.routineExerciseId;
    if (reId == null) return const [];
    final re = await (select(
      routineExercises,
    )..where((t) => t.id.equals(reId))).getSingleOrNull();
    if (re == null) return const [];
    final variantIds = <int>{re.exerciseId};
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
    )..where((t) => t.id.isIn(variantIds))).get();
    // Stable order: primary first if still present, then alternatives in
    // their stored orderIndex.
    final byId = {for (final e in exs) e.id: e};
    final ordered = <Exercise>[];
    if (current != re.exerciseId && byId.containsKey(re.exerciseId)) {
      ordered.add(byId[re.exerciseId]!);
    }
    for (final a in alts) {
      final ex = byId[a.exerciseId];
      if (ex != null && ex.id != current) ordered.add(ex);
    }
    return ordered;
  }
}
