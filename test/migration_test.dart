import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';

import 'drift_schemas/schema.dart';
import 'drift_schemas/schema_v14.dart' as v14;
import 'drift_schemas/schema_v15.dart' as v15;
import 'drift_schemas/schema_v16.dart' as v16;
import 'drift_schemas/schema_v17.dart' as v17;

/// Schema migrations, against databases actually created at the old version.
///
/// The demo seed can't stand in for this: it writes through the *current* Drift
/// classes, so it can only ever produce rows already in the new shape. These
/// tests start from a real v14 database built by drift's schema tooling
/// (`drift_schemas/`, dumped with `drift_dev schema dump`).
///
/// Regenerate after every schema change:
///   dart run drift_dev schema dump lib/data/database.dart drift_schemas/
///   dart run drift_dev schema generate --data-classes --companions \
///       drift_schemas/ test/drift_schemas/
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('migrates a v14 database to the current schema', () async {
    // Catches drift between the migration steps and the table definitions —
    // `migrateAndValidate` compares the migrated database against the dumped
    // v16 schema, column by column.
    final connection = await verifier.startAt(14);
    final db = AppDatabase.forTesting(connection);
    await verifier.migrateAndValidate(db, 17);
    await db.close();
  });

  test('v16 → v17 leaves existing exercises with weight alone in the list',
      () async {
    final schema = await verifier.schemaAt(16);
    final oldDb = v16.DatabaseAtV16(schema.newConnection());
    await oldDb.into(oldDb.exercises).insert(
          v16.ExercisesCompanion.insert(
            syncId: 'e1',
            name: 'Bench Press',
            createdAt: 1,
          ),
        );
    await oldDb.into(oldDb.routines).insert(
          v16.RoutinesCompanion.insert(syncId: 'r1', name: 'Push', createdAt: 1),
        );
    await oldDb.into(oldDb.routineExercises).insert(
          v16.RoutineExercisesCompanion.insert(
            syncId: 're1',
            routineId: 'r1',
            exerciseId: 'e1',
            orderIndex: 0,
          ),
        );
    await oldDb.into(oldDb.plannedSets).insert(
          v16.PlannedSetsCompanion.insert(
            syncId: 'ps1',
            routineExerciseId: 're1',
            setIndex: 0,
          ),
        );
    await oldDb.close();

    final db = AppDatabase.forTesting(schema.newConnection());
    await verifier.migrateAndValidate(db, 17);
    await db.close();

    final checkDb = v17.DatabaseAtV17(schema.newConnection());
    final exercise = await checkDb.select(checkDb.exercises).getSingle();
    final plannedSet = await checkDb.select(checkDb.plannedSets).getSingle();
    await checkDb.close();
    expect(exercise.params, '[]');
    expect(plannedSet.targetParams, null);
  });

  test('v15 → v16 keeps existing samples, with no recorded accuracy', () async {
    // The column is added, never backfilled: readings captured before it
    // existed have no confidence label, and null is the honest value for that.
    final schema = await verifier.schemaAt(15);
    final oldDb = v15.DatabaseAtV15(schema.newConnection());
    await oldDb
        .into(oldDb.workouts)
        .insert(v15.WorkoutsCompanion.insert(
          syncId: 'w1',
          startedAt: DateTime(2026, 8, 12, 18),
        ));
    await oldDb.into(oldDb.heartRateSamples).insert(
          v15.HeartRateSamplesCompanion.insert(
            workoutId: 'w1',
            measuredAtMs: 1000,
            bpm: 142,
          ),
        );
    await oldDb.close();

    final db = AppDatabase.forTesting(schema.newConnection());
    await verifier.migrateAndValidate(db, 17);
    await db.close();

    final checkDb = v17.DatabaseAtV17(schema.newConnection());
    final rows = await checkDb.select(checkDb.heartRateSamples).get();
    await checkDb.close();
    expect(rows, hasLength(1));
    expect(rows.single.bpm, 142);
    // Plain `null`, not `isNull`: drift exports a matcher of that name too.
    expect(rows.single.accuracy, null);
  });

  group('v14 → v15 rest translation', () {
    /// Seeds a v14 database with [exercises] as `(syncId, group, rest)` under
    /// one routine, runs the real migration, and returns the v15 rows in order.
    Future<List<v17.RoutineExercisesData>> migrateRoutine(
      List<(String, int?, int)> exercises, {
      int startVersion = 1,
    }) async {
      final schema = await verifier.schemaAt(14);

      final oldDb = v14.DatabaseAtV14(schema.newConnection());
      await oldDb
          .into(oldDb.routines)
          .insert(v14.RoutinesCompanion.insert(
            syncId: 'r1',
            name: 'Arms',
            createdAt: DateTime(2026, 8, 1),
            version: Value(startVersion),
          ));
      for (var i = 0; i < exercises.length; i++) {
        final (syncId, group, rest) = exercises[i];
        await oldDb.into(oldDb.exercises).insert(v14.ExercisesCompanion.insert(
              syncId: 'ex-$syncId',
              name: 'Exercise $syncId',
              createdAt: DateTime(2026, 8, 1),
            ));
        await oldDb.into(oldDb.routineExercises).insert(
              v14.RoutineExercisesCompanion.insert(
                syncId: syncId,
                routineId: 'r1',
                exerciseId: 'ex-$syncId',
                orderIndex: i,
                restSeconds: Value(rest),
                supersetGroup: Value(group),
              ),
            );
      }
      await oldDb.close();

      final migrated = AppDatabase.forTesting(schema.newConnection());
      await verifier.migrateAndValidate(migrated, 17);
      await migrated.close();

      final checkDb = v17.DatabaseAtV17(schema.newConnection());
      final rows = await (checkDb.select(checkDb.routineExercises)
            ..orderBy([(t) => OrderingTerm(expression: t.orderIndex)]))
          .get();
      await checkDb.close();
      return rows;
    }

    test('the group rest moves from the first member to the last', () async {
      // v14 ran this as: A, then B, then one 90 s rest — the value read off A.
      // v15 has to reproduce that from per-exercise rests.
      final rows = await migrateRoutine([
        ('a', 1, 90),
        ('b', 1, 90),
      ]);
      expect(rows.map((r) => r.restSeconds), [0, 90]);
      expect(rows.map((r) => r.circuitGroup), [1, 1]);
    });

    test("the last member takes the first member's value, not its own",
        () async {
      // B's stale 60 was never used by v14 — only A's 120 ever ran.
      final rows = await migrateRoutine([('a', 1, 120), ('b', 1, 60)]);
      expect(rows.map((r) => r.restSeconds), [0, 120]);
    });

    test('standalone exercises keep their rest', () async {
      final rows = await migrateRoutine([('a', null, 90), ('b', null, 60)]);
      expect(rows.map((r) => r.restSeconds), [90, 60]);
      expect(rows.map((r) => r.circuitGroup), [null, null]);
    });

    test('a three-member circuit zeroes all but the last', () async {
      final rows = await migrateRoutine([
        ('a', 1, 75),
        ('b', 1, 90),
        ('c', 1, 90),
      ]);
      expect(rows.map((r) => r.restSeconds), [0, 0, 75]);
    });

    test('a translated routine is version-bumped so it wins version-LWW',
        () async {
      // The server and the watch still hold the old rest layout; without the
      // bump their copies would outrank the migrated one and undo it.
      final schema = await verifier.schemaAt(14);
      final oldDb = v14.DatabaseAtV14(schema.newConnection());
      await oldDb.into(oldDb.routines).insert(v14.RoutinesCompanion.insert(
            syncId: 'r1',
            name: 'Grouped',
            createdAt: DateTime(2026, 8, 1),
            version: const Value(4),
          ));
      await oldDb.into(oldDb.routines).insert(v14.RoutinesCompanion.insert(
            syncId: 'r2',
            name: 'Untouched',
            createdAt: DateTime(2026, 8, 1),
            version: const Value(4),
          ));
      await oldDb.into(oldDb.exercises).insert(v14.ExercisesCompanion.insert(
            syncId: 'ex-1',
            name: 'Curl',
            createdAt: DateTime(2026, 8, 1),
          ));
      for (final (syncId, routineId, group) in const [
        ('a', 'r1', 1),
        ('b', 'r1', 1),
        ('c', 'r2', null),
      ]) {
        await oldDb.into(oldDb.routineExercises).insert(
              v14.RoutineExercisesCompanion.insert(
                syncId: syncId,
                routineId: routineId,
                exerciseId: 'ex-1',
                orderIndex: 0,
                restSeconds: const Value(90),
                supersetGroup: Value(group),
              ),
            );
      }
      await oldDb.close();

      final migrated = AppDatabase.forTesting(schema.newConnection());
      await verifier.migrateAndValidate(migrated, 17);
      await migrated.close();

      final checkDb = v17.DatabaseAtV17(schema.newConnection());
      final byId = {
        for (final r in await checkDb.select(checkDb.routines).get())
          r.syncId: r.version,
      };
      await checkDb.close();
      expect(byId['r1'], 5, reason: 'translated routine must be bumped');
      expect(byId['r2'], 4, reason: 'an untouched routine must not be bumped');
    });

    test('workout snapshots are translated but not version-bumped', () async {
      // A resumed session reads its own snapshot, so the rests have to be
      // right; re-pushing every past workout for a frozen value would not.
      final schema = await verifier.schemaAt(14);
      final oldDb = v14.DatabaseAtV14(schema.newConnection());
      await oldDb.into(oldDb.workouts).insert(v14.WorkoutsCompanion.insert(
            syncId: 'w1',
            startedAt: DateTime(2026, 8, 1),
            version: const Value(7),
          ));
      for (final (syncId, order, rest) in const [
        ('we-a', 0, 90),
        ('we-b', 1, 90),
      ]) {
        await oldDb.into(oldDb.workoutExercises).insert(
              v14.WorkoutExercisesCompanion.insert(
                syncId: syncId,
                workoutId: 'w1',
                exerciseName: 'Curl',
                orderIndex: order,
                restSeconds: Value(rest),
                supersetGroup: const Value(1),
              ),
            );
      }
      await oldDb.close();

      final migrated = AppDatabase.forTesting(schema.newConnection());
      await verifier.migrateAndValidate(migrated, 17);
      await migrated.close();

      final checkDb = v17.DatabaseAtV17(schema.newConnection());
      final rows = await (checkDb.select(checkDb.workoutExercises)
            ..orderBy([(t) => OrderingTerm(expression: t.orderIndex)]))
          .get();
      final workout = await checkDb.select(checkDb.workouts).getSingle();
      await checkDb.close();

      expect(rows.map((r) => r.restSeconds), [0, 90]);
      expect(rows.map((r) => r.circuitGroup), [1, 1]);
      expect(workout.version, 7);
    });
  });
}
