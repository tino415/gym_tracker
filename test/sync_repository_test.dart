import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/sync_codec.dart';
import 'package:gym_tracker/sync/sync_repository.dart';

RoutineBundleMessage _bundle({
  required int version,
  String routineName = 'Push day',
  String exerciseName = 'Bench Press',
  double targetWeightKg = 50,
}) {
  return RoutineBundleMessage([
    RoutineTemplateDto(
      syncId: 'routine-1',
      name: routineName,
      version: version,
      createdAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      exercises: [
        RoutineExerciseDto(
          syncId: 're-1',
          exerciseSyncId: 'ex-1',
          exerciseName: exerciseName,
          exerciseKind: exerciseKindReps,
          orderIndex: 0,
          restSeconds: 60,
          supersetGroup: null,
          plannedSets: [
            PlannedSetDto(
              syncId: 'ps-1',
              setIndex: 0,
              targetReps: 10,
              targetWeightKg: targetWeightKg,
              targetSeconds: null,
            ),
          ],
        ),
      ],
    ),
  ]);
}

void main() {
  late AppDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  group('applyRoutineBundle versioning', () {
    test('same-version bundle still applies changed targets', () async {
      await repo.applyRoutineBundle(_bundle(version: 1, targetWeightKg: 50));
      // The phone re-pushes at the same version (e.g. manual "Sync now"
      // after an earlier push was lost mid-edit). The watch must converge.
      await repo.applyRoutineBundle(_bundle(version: 1, targetWeightKg: 62.5));

      final sets = await db.select(db.plannedSets).get();
      expect(sets, hasLength(1));
      expect(sets.single.targetWeightKg, 62.5);
    });

    test('same-version bundle applies an exercise rename', () async {
      await repo.applyRoutineBundle(
        _bundle(version: 1, exerciseName: 'Bench Press'),
      );
      // renameExercise on the phone doesn't bump routine versions — the
      // rename arrives at the same version and must still land.
      await repo.applyRoutineBundle(
        _bundle(version: 1, exerciseName: 'Incline Bench'),
      );

      final exercises = await db.select(db.exercises).get();
      expect(exercises, hasLength(1));
      expect(exercises.single.name, 'Incline Bench');
    });

    test('strictly older bundle is ignored', () async {
      await repo.applyRoutineBundle(
        _bundle(version: 3, routineName: 'Push day v3'),
      );
      await repo.applyRoutineBundle(
        _bundle(version: 2, routineName: 'Push day v2'),
      );

      final routine = await db.select(db.routines).getSingle();
      expect(routine.name, 'Push day v3');
      expect(routine.version, 3);
    });

    test('re-applying an identical bundle stays idempotent', () async {
      await repo.applyRoutineBundle(_bundle(version: 1));
      await repo.applyRoutineBundle(_bundle(version: 1));

      expect(await db.select(db.routines).get(), hasLength(1));
      expect(await db.select(db.routineExercises).get(), hasLength(1));
      expect(await db.select(db.plannedSets).get(), hasLength(1));
      expect(await db.select(db.exercises).get(), hasLength(1));
    });

    test('rename to a name already taken locally is skipped, not fatal',
        () async {
      // A different local exercise already owns the target name; the UNIQUE
      // constraint would fire. The apply must survive and keep the old name.
      await db.into(db.exercises).insert(
            ExercisesCompanion.insert(
              syncId: 'ex-other',
              name: 'Incline Bench',
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          );
      await repo.applyRoutineBundle(
        _bundle(version: 1, exerciseName: 'Bench Press'),
      );
      await repo.applyRoutineBundle(
        _bundle(version: 1, exerciseName: 'Incline Bench'),
      );

      final synced = await (db.select(db.exercises)
            ..where((t) => t.syncId.equals('ex-1')))
          .getSingle();
      expect(synced.name, 'Bench Press');
    });
  });

  group('tombstone LWW', () {
    RoutineBundleMessage tombstone({required int version, int deletedAtMs = 0}) {
      return RoutineBundleMessage([
        RoutineTemplateDto(
          syncId: 'routine-1',
          name: 'Push day',
          version: version,
          createdAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
          deletedAtMs: deletedAtMs == 0
              ? DateTime.utc(2026, 2, 1).millisecondsSinceEpoch
              : deletedAtMs,
          exercises: const [],
        ),
      ]);
    }

    test('a tombstone soft-deletes the routine and drops its children',
        () async {
      await repo.applyRoutineBundleUpsert(_bundle(version: 1));
      await repo.applyRoutineBundleUpsert(tombstone(version: 2));

      final routine = await db.select(db.routines).getSingle();
      expect(routine.deletedAt, isNotNull);
      expect(routine.version, 2);
      // Children gone; the routine reads as absent.
      expect(await db.select(db.routineExercises).get(), isEmpty);
      expect(await db.select(db.plannedSets).get(), isEmpty);
      expect(await db.loadFullRoutine(routine.syncId), isNull);
    });

    test('a tombstone older than a local edit is ignored (edit wins)',
        () async {
      await repo.applyRoutineBundleUpsert(_bundle(version: 3));
      await repo.applyRoutineBundleUpsert(tombstone(version: 2));

      final routine = await db.select(db.routines).getSingle();
      expect(routine.deletedAt, isNull, reason: 'newer edit outranks delete');
      expect(await db.select(db.routineExercises).get(), hasLength(1));
    });

    test('a newer non-tombstone edit revives a tombstoned routine', () async {
      await repo.applyRoutineBundleUpsert(_bundle(version: 1));
      await repo.applyRoutineBundleUpsert(tombstone(version: 2));
      await repo.applyRoutineBundleUpsert(_bundle(version: 3, routineName: 'v3'));

      final routine = await db.select(db.routines).getSingle();
      expect(routine.deletedAt, isNull);
      expect(routine.name, 'v3');
      expect(await db.loadFullRoutine(routine.syncId), isNotNull);
    });

    test('a tombstone for an unseen routine suppresses a stale re-creation',
        () async {
      // Delete arrives before we ever saw the routine (out-of-order delivery).
      await repo.applyRoutineBundleUpsert(tombstone(version: 2));
      // A stale, strictly-older upsert must not resurrect it.
      await repo.applyRoutineBundleUpsert(_bundle(version: 1));

      final routine = await db.select(db.routines).getSingle();
      expect(routine.deletedAt, isNotNull);
      expect(await db.select(db.routineExercises).get(), isEmpty);
    });

    test('exportAllRoutines emits a tombstone for a soft-deleted routine',
        () async {
      final r = await db.createRoutine('Legs');
      await db.deleteRoutine(r.syncId);

      final exported = await repo.exportAllRoutines();
      expect(exported, hasLength(1));
      expect(exported.single.syncId, r.syncId);
      expect(exported.single.deletedAtMs, isNotNull);
      expect(exported.single.exercises, isEmpty);
    });
  });

  group('exercise library sync (version-LWW)', () {
    ExerciseDto exDto({
      required int version,
      String syncId = 'ex-lib-1',
      String name = 'Overhead Press',
      String kind = exerciseKindReps,
      List<String> muscles = const [],
      int? deletedAtMs,
    }) {
      return ExerciseDto(
        syncId: syncId,
        name: name,
        kind: kind,
        version: version,
        createdAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        muscleSyncIds: muscles,
        deletedAtMs: deletedAtMs,
      );
    }

    test('exportAllExercises carries live exercises with muscle tags', () async {
      final ex = await db.createExercise('Row');
      final m = await (db.select(db.muscles)..limit(1)).getSingle();
      await db.setExerciseMuscles(ex.syncId, [m.syncId]);

      final exported = await repo.exportAllExercises();
      final dto = exported.firstWhere((e) => e.syncId == ex.syncId);
      expect(dto.name, 'Row');
      expect(dto.deletedAtMs, isNull);
      expect(dto.muscleSyncIds, contains(m.syncId));
    });

    test('exportAllExercises emits a tombstone for a soft-deleted exercise',
        () async {
      final ex = await db.createExercise('Row');
      await db.deleteExercise(ex.syncId);
      final exported = await repo.exportAllExercises();
      final dto = exported.firstWhere((e) => e.syncId == ex.syncId);
      expect(dto.deletedAtMs, isNotNull);
      expect(dto.muscleSyncIds, isEmpty);
    });

    test('applyExerciseBundle inserts a new exercise with its muscle tags',
        () async {
      final m = await (db.select(db.muscles)..limit(1)).getSingle();
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([
          exDto(version: 1, muscles: [m.syncId]),
        ]),
      );

      final lib = await db.loadExercisesWithMuscles();
      final entry = lib.firstWhere((e) => e.exercise.syncId == 'ex-lib-1');
      expect(entry.exercise.name, 'Overhead Press');
      expect(entry.muscles.map((x) => x.syncId), contains(m.syncId));
    });

    test('a strictly older bundle is ignored; equal/newer applies', () async {
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 3, name: 'V3')]),
      );
      // Older loses.
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 2, name: 'V2')]),
      );
      var row = await (db.select(db.exercises)
            ..where((t) => t.syncId.equals('ex-lib-1')))
          .getSingle();
      expect(row.name, 'V3');
      // Newer wins.
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 4, name: 'V4')]),
      );
      row = await (db.select(db.exercises)
            ..where((t) => t.syncId.equals('ex-lib-1')))
          .getSingle();
      expect(row.name, 'V4');
    });

    test('a tombstone deletes locally; a strictly-newer edit revives it',
        () async {
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 1)]),
      );
      // Delete at v2.
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 2, deletedAtMs: 111)]),
      );
      expect(
        (await db.watchExercises().first).where((e) => e.syncId == 'ex-lib-1'),
        isEmpty,
      );
      // Revive with a newer live edit.
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 3, name: 'Revived')]),
      );
      final row = await (db.select(db.exercises)
            ..where((t) => t.syncId.equals('ex-lib-1')))
          .getSingle();
      expect(row.deletedAt, isNull);
      expect(row.name, 'Revived');
    });

    test('a same-name collision from a different syncId is skipped, not fatal',
        () async {
      await db.createExercise('Squat'); // local, its own syncId
      // Incoming exercise with a DIFFERENT syncId but the same (UNIQUE) name.
      await repo.applyExerciseBundle(
        ExerciseBundleMessage([exDto(version: 1, syncId: 'other', name: 'Squat')]),
      );
      // No crash, no duplicate; the incoming syncId got no row.
      final rows = await (db.select(db.exercises)
            ..where((t) => t.name.equals('Squat')))
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.syncId, isNot('other'));
    });
  });
}
