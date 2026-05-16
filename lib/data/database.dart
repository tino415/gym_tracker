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

class Workouts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(1))();
}

class WorkoutExercises extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutId =>
      integer().references(Workouts, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.restrict)();
  IntColumn get orderIndex => integer()();
  IntColumn get restSeconds => integer().withDefault(const Constant(90))();
}

class PlannedSets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutExerciseId => integer()
      .references(WorkoutExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get setIndex => integer()();
  IntColumn get targetReps => integer()();
  RealColumn get targetWeightKg => real()();
}

class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get workoutId =>
      integer().references(Workouts, #id, onDelete: KeyAction.restrict)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
}

class SetCompletions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().unique()();
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get plannedSetId =>
      integer().references(PlannedSets, #id, onDelete: KeyAction.restrict)();
  IntColumn get actualReps => integer()();
  RealColumn get actualWeightKg => real()();
  DateTimeColumn get completedAt => dateTime()();
}

class FullWorkout {
  FullWorkout({required this.workout, required this.exercises});
  final Workout workout;
  final List<FullWorkoutExercise> exercises;
}

class FullWorkoutExercise {
  FullWorkoutExercise({
    required this.workoutExercise,
    required this.exercise,
    required this.plannedSets,
  });
  final WorkoutExercise workoutExercise;
  final Exercise exercise;
  final List<PlannedSet> plannedSets;
}

class WorkoutSummary {
  WorkoutSummary({required this.workout, required this.exerciseCount});
  final Workout workout;
  final int exerciseCount;
}

@DriftDatabase(
  tables: [
    Exercises,
    Workouts,
    WorkoutExercises,
    PlannedSets,
    Sessions,
    SetCompletions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() => driftDatabase(
        name: 'gym_tracker',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      );

  // -- Exercises --------------------------------------------------------

  Stream<List<Exercise>> watchExercises() {
    return (select(exercises)..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  Future<Exercise> createExercise(String name) async {
    final now = DateTime.now();
    final id = await into(exercises).insert(
      ExercisesCompanion.insert(
        syncId: _uuid.v4(),
        name: name,
        createdAt: now,
      ),
    );
    return (select(exercises)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameExercise(int id, String name) async {
    await (update(exercises)..where((t) => t.id.equals(id)))
        .write(ExercisesCompanion(name: Value(name)));
  }

  Future<void> deleteExercise(int id) async {
    await (delete(exercises)..where((t) => t.id.equals(id))).go();
  }

  // -- Workouts ---------------------------------------------------------

  Stream<List<WorkoutSummary>> watchWorkoutSummaries() {
    final countExpr = workoutExercises.id.count();
    final query = select(workouts).join([
      leftOuterJoin(
        workoutExercises,
        workoutExercises.workoutId.equalsExp(workouts.id),
      ),
    ])
      ..addColumns([countExpr])
      ..groupBy([workouts.id])
      ..orderBy([OrderingTerm.desc(workouts.createdAt)]);
    return query.watch().map((rows) {
      return rows
          .map(
            (row) => WorkoutSummary(
              workout: row.readTable(workouts),
              exerciseCount: row.read(countExpr) ?? 0,
            ),
          )
          .toList();
    });
  }

  Future<Workout> createWorkout(String name) async {
    final now = DateTime.now();
    final id = await into(workouts).insert(
      WorkoutsCompanion.insert(
        syncId: _uuid.v4(),
        name: name,
        createdAt: now,
      ),
    );
    return (select(workouts)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameWorkout(int id, String name) async {
    await (update(workouts)..where((t) => t.id.equals(id))).write(
      WorkoutsCompanion(name: Value(name), version: const Value.absent()),
    );
    await _bumpWorkoutVersion(id);
  }

  Future<void> deleteWorkout(int id) async {
    await (delete(workouts)..where((t) => t.id.equals(id))).go();
  }

  Future<FullWorkout?> loadFullWorkout(int workoutId) async {
    final w = await (select(workouts)
          ..where((t) => t.id.equals(workoutId)))
        .getSingleOrNull();
    if (w == null) return null;
    final wes = await (select(workoutExercises)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    final result = <FullWorkoutExercise>[];
    for (final we in wes) {
      final ex = await (select(exercises)
            ..where((t) => t.id.equals(we.exerciseId)))
          .getSingle();
      final sets = await (select(plannedSets)
            ..where((t) => t.workoutExerciseId.equals(we.id))
            ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
          .get();
      result.add(
        FullWorkoutExercise(
          workoutExercise: we,
          exercise: ex,
          plannedSets: sets,
        ),
      );
    }
    return FullWorkout(workout: w, exercises: result);
  }

  Stream<FullWorkout?> watchFullWorkout(int workoutId) async* {
    yield await loadFullWorkout(workoutId);
    final updates = tableUpdates(
      TableUpdateQuery.onAllTables([
        workouts,
        workoutExercises,
        plannedSets,
        exercises,
      ]),
    );
    await for (final _ in updates) {
      yield await loadFullWorkout(workoutId);
    }
  }

  Future<WorkoutExercise> addExerciseToWorkout({
    required int workoutId,
    required int exerciseId,
  }) async {
    return transaction(() async {
      final maxOrder = await _maxOrderIndex(workoutId);
      final id = await into(workoutExercises).insert(
        WorkoutExercisesCompanion.insert(
          syncId: _uuid.v4(),
          workoutId: workoutId,
          exerciseId: exerciseId,
          orderIndex: maxOrder + 1,
        ),
      );
      await _bumpWorkoutVersion(workoutId);
      return (select(workoutExercises)..where((t) => t.id.equals(id)))
          .getSingle();
    });
  }

  Future<void> removeWorkoutExercise(int workoutExerciseId) async {
    await transaction(() async {
      final we = await (select(workoutExercises)
            ..where((t) => t.id.equals(workoutExerciseId)))
          .getSingleOrNull();
      if (we == null) return;
      await (delete(workoutExercises)..where((t) => t.id.equals(workoutExerciseId)))
          .go();
      await _bumpWorkoutVersion(we.workoutId);
    });
  }

  Future<void> setRestSeconds(int workoutExerciseId, int seconds) async {
    await transaction(() async {
      final we = await (select(workoutExercises)
            ..where((t) => t.id.equals(workoutExerciseId)))
          .getSingleOrNull();
      if (we == null) return;
      await (update(workoutExercises)
            ..where((t) => t.id.equals(workoutExerciseId)))
          .write(WorkoutExercisesCompanion(restSeconds: Value(seconds)));
      await _bumpWorkoutVersion(we.workoutId);
    });
  }

  Future<PlannedSet> addPlannedSet({
    required int workoutExerciseId,
    required int targetReps,
    required double targetWeightKg,
  }) async {
    return transaction(() async {
      final we = await (select(workoutExercises)
            ..where((t) => t.id.equals(workoutExerciseId)))
          .getSingle();
      final maxIndex = await _maxSetIndex(workoutExerciseId);
      final id = await into(plannedSets).insert(
        PlannedSetsCompanion.insert(
          syncId: _uuid.v4(),
          workoutExerciseId: workoutExerciseId,
          setIndex: maxIndex + 1,
          targetReps: targetReps,
          targetWeightKg: targetWeightKg,
        ),
      );
      await _bumpWorkoutVersion(we.workoutId);
      return (select(plannedSets)..where((t) => t.id.equals(id))).getSingle();
    });
  }

  Future<void> updatePlannedSet({
    required int id,
    required int targetReps,
    required double targetWeightKg,
  }) async {
    await transaction(() async {
      final ps = await (select(plannedSets)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (ps == null) return;
      final we = await (select(workoutExercises)
            ..where((t) => t.id.equals(ps.workoutExerciseId)))
          .getSingle();
      await (update(plannedSets)..where((t) => t.id.equals(id))).write(
        PlannedSetsCompanion(
          targetReps: Value(targetReps),
          targetWeightKg: Value(targetWeightKg),
        ),
      );
      await _bumpWorkoutVersion(we.workoutId);
    });
  }

  Future<void> deletePlannedSet(int id) async {
    await transaction(() async {
      final ps = await (select(plannedSets)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (ps == null) return;
      final we = await (select(workoutExercises)
            ..where((t) => t.id.equals(ps.workoutExerciseId)))
          .getSingle();
      await (delete(plannedSets)..where((t) => t.id.equals(id))).go();
      await _bumpWorkoutVersion(we.workoutId);
    });
  }

  Future<int> _maxOrderIndex(int workoutId) async {
    final expr = workoutExercises.orderIndex.max();
    final query = selectOnly(workoutExercises)
      ..where(workoutExercises.workoutId.equals(workoutId))
      ..addColumns([expr]);
    final row = await query.getSingleOrNull();
    return row?.read(expr) ?? -1;
  }

  Future<int> _maxSetIndex(int workoutExerciseId) async {
    final expr = plannedSets.setIndex.max();
    final query = selectOnly(plannedSets)
      ..where(plannedSets.workoutExerciseId.equals(workoutExerciseId))
      ..addColumns([expr]);
    final row = await query.getSingleOrNull();
    return row?.read(expr) ?? -1;
  }

  Future<void> _bumpWorkoutVersion(int workoutId) async {
    await customUpdate(
      'UPDATE workouts SET version = version + 1 WHERE id = ?',
      variables: [Variable.withInt(workoutId)],
      updates: {workouts},
    );
  }

  // -- Sessions ---------------------------------------------------------

  Stream<List<Session>> watchRecentSessions() {
    return (select(sessions)
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
        .watch();
  }

  Future<Session> startSession(int workoutId) async {
    final id = await into(sessions).insert(
      SessionsCompanion.insert(
        syncId: _uuid.v4(),
        workoutId: workoutId,
        startedAt: DateTime.now(),
      ),
    );
    return (select(sessions)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> finishSession(int sessionId) async {
    await (update(sessions)..where((t) => t.id.equals(sessionId)))
        .write(SessionsCompanion(endedAt: Value(DateTime.now())));
  }

  Future<SetCompletion> recordSetCompletion({
    required int sessionId,
    required int plannedSetId,
    required int actualReps,
    required double actualWeightKg,
  }) async {
    final id = await into(setCompletions).insert(
      SetCompletionsCompanion.insert(
        syncId: _uuid.v4(),
        sessionId: sessionId,
        plannedSetId: plannedSetId,
        actualReps: actualReps,
        actualWeightKg: actualWeightKg,
        completedAt: DateTime.now(),
      ),
    );
    return (select(setCompletions)..where((t) => t.id.equals(id)))
        .getSingle();
  }

  Future<List<SetCompletion>> completionsForSession(int sessionId) {
    return (select(setCompletions)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm.asc(t.completedAt)]))
        .get();
  }
}
