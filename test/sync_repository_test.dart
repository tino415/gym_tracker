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
}
