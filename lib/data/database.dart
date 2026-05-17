import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

part 'database.g.dart';

const _uuid = Uuid();

class Exercises extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  TextColumn get name => text().unique()();
  DateTimeColumn get createdAt => dateTime()();
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
}

class PlannedSets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get routineExerciseId => integer().references(
    RoutineExercises,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get setIndex => integer()();
  IntColumn get targetReps => integer()();
  RealColumn get targetWeightKg => real()();
}

class Workouts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get routineId =>
      integer().references(Routines, #id, onDelete: KeyAction.restrict)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
}

class SetCompletions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutId =>
      integer().references(Workouts, #id, onDelete: KeyAction.cascade)();
  IntColumn get plannedSetId =>
      integer().references(PlannedSets, #id, onDelete: KeyAction.restrict)();
  IntColumn get actualReps => integer()();
  RealColumn get actualWeightKg => real()();
  DateTimeColumn get completedAt => dateTime()();
}

class FullRoutine {
  FullRoutine({required this.routine, required this.exercises});
  final Routine routine;
  final List<FullRoutineExercise> exercises;
}

class FullRoutineExercise {
  FullRoutineExercise({
    required this.routineExercise,
    required this.exercise,
    required this.plannedSets,
  });
  final RoutineExercise routineExercise;
  final Exercise exercise;
  final List<PlannedSet> plannedSets;
}

class RoutineSummary {
  RoutineSummary({required this.routine, required this.exerciseCount});
  final Routine routine;
  final int exerciseCount;
}

@DriftDatabase(
  tables: [
    Exercises,
    Routines,
    RoutineExercises,
    PlannedSets,
    Workouts,
    SetCompletions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      // Drift / sqlite3 do not enable foreign keys by default. Without
      // this, ON DELETE CASCADE on routine_exercises / planned_sets /
      // set_completions silently fails to fire, leaving orphan rows that
      // then collide with later inserts (e.g. when re-applying a routine
      // bundle during sync).
      await customStatement('PRAGMA foreign_keys = ON');
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // v1 schema had: workouts (template), workout_exercises, sessions,
        // set_completions(session_id). Rename in-place using SQLite
        // ALTER TABLE … RENAME (supported since 3.25). Order matters
        // because the new `workouts` name collides with the old one.
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
    },
  );

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

  Future<Exercise> createExercise(String name) async {
    final now = DateTime.now();
    final id = await into(exercises).insert(
      ExercisesCompanion.insert(syncId: _uuid.v4(), name: name, createdAt: now),
    );
    return (select(exercises)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameExercise(int id, String name) async {
    await (update(exercises)..where((t) => t.id.equals(id))).write(
      ExercisesCompanion(name: Value(name)),
    );
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
    await transaction(() async {
      // Delete all workouts referencing this routine first — that cascades
      // through set_completions, which would otherwise be blocked by the
      // RESTRICT on set_completions.planned_set_id when we then cascade-
      // delete the routine's planned_sets.
      await (delete(workouts)..where((t) => t.routineId.equals(id))).go();
      await (delete(routines)..where((t) => t.id.equals(id))).go();
    });
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
      result.add(
        FullRoutineExercise(
          routineExercise: re,
          exercise: ex,
          plannedSets: sets,
        ),
      );
    }
    return FullRoutine(routine: r, exercises: result);
  }

  Stream<FullRoutine?> watchFullRoutine(int routineId) async* {
    yield await loadFullRoutine(routineId);
    final updates = tableUpdates(
      TableUpdateQuery.onAllTables([
        routines,
        routineExercises,
        plannedSets,
        exercises,
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

  Future<PlannedSet> addPlannedSet({
    required int routineExerciseId,
    required int targetReps,
    required double targetWeightKg,
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
          targetReps: targetReps,
          targetWeightKg: targetWeightKg,
        ),
      );
      await _bumpRoutineVersion(re.routineId);
      return (select(plannedSets)..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> updatePlannedSet({
    required int id,
    required int targetReps,
    required double targetWeightKg,
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

  // -- Workouts (runs) --------------------------------------------------

  Stream<List<Workout>> watchRecentWorkouts() {
    return (select(
      workouts,
    )..orderBy([(t) => OrderingTerm.desc(t.startedAt)])).watch();
  }

  Future<Workout> startWorkout(int routineId) async {
    final id = await into(workouts).insert(
      WorkoutsCompanion.insert(
        syncId: _uuid.v4(),
        routineId: routineId,
        startedAt: DateTime.now(),
      ),
    );
    return (select(workouts)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> finishWorkout(int workoutId) async {
    await (update(workouts)..where((t) => t.id.equals(workoutId))).write(
      WorkoutsCompanion(endedAt: Value(DateTime.now())),
    );
  }

  Future<List<SetCompletion>> completionsForWorkout(int workoutId) {
    return (select(setCompletions)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.completedAt)]))
        .get();
  }

  /// Watch all completions for a workout, indexed by plannedSetId for fast
  /// lookup from the watch run page.
  Stream<Map<int, SetCompletion>> watchCompletionsByPlannedSet(int workoutId) {
    return (select(setCompletions)..where((t) => t.workoutId.equals(workoutId)))
        .watch()
        .map((rows) => {for (final c in rows) c.plannedSetId: c});
  }

  /// Insert or update a completion for (workoutId, plannedSetId). Used by the
  /// watch run page to allow re-marking a set after navigating back to it.
  Future<SetCompletion> upsertSetCompletion({
    required int workoutId,
    required int plannedSetId,
    required int actualReps,
    required double actualWeightKg,
  }) async {
    return transaction(() async {
      final existing =
          await (select(setCompletions)..where(
                (t) =>
                    t.workoutId.equals(workoutId) &
                    t.plannedSetId.equals(plannedSetId),
              ))
              .getSingleOrNull();
      if (existing != null) {
        await (update(
          setCompletions,
        )..where((t) => t.id.equals(existing.id))).write(
          SetCompletionsCompanion(
            actualReps: Value(actualReps),
            actualWeightKg: Value(actualWeightKg),
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
          plannedSetId: plannedSetId,
          actualReps: actualReps,
          actualWeightKg: actualWeightKg,
          completedAt: DateTime.now(),
        ),
      );
      return (select(
        setCompletions,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  /// Remove the completion (if any) for (workoutId, plannedSetId). Used by
  /// the watch run page to unmark a set.
  Future<void> deleteSetCompletionFor({
    required int workoutId,
    required int plannedSetId,
  }) async {
    await (delete(setCompletions)..where(
          (t) =>
              t.workoutId.equals(workoutId) &
              t.plannedSetId.equals(plannedSetId),
        ))
        .go();
  }
}
