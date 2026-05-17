import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'sync_codec.dart';

const _uuid = Uuid();

class SyncRepository {
  SyncRepository(this._db);

  final AppDatabase _db;

  Future<List<RoutineTemplateDto>> exportAllRoutines() async {
    final all = await _db.select(_db.routines).get();
    final result = <RoutineTemplateDto>[];
    for (final r in all) {
      final full = await _db.loadFullRoutine(r.id);
      if (full != null) {
        result.add(RoutineTemplateDto.fromFullRoutine(full));
      }
    }
    return result;
  }

  /// Apply an inbound routine bundle to the local DB. Routines already present
  /// at a >= version are skipped; older or missing ones are upserted (whole
  /// template replaced, since templates are small).
  ///
  /// The bundle is treated as an authoritative snapshot: any local routine
  /// whose sync_id is not present in the bundle is also removed, along with
  /// its workout history. This lets a delete on the phone (the routine
  /// authority) propagate to the watch.
  Future<void> applyRoutineBundle(RoutineBundleMessage bundle) async {
    await _db.transaction(() async {
      final received = bundle.routines.map((r) => r.syncId).toSet();
      for (final dto in bundle.routines) {
        await _upsertOneRoutine(dto);
      }
      final localRoutines = await _db.select(_db.routines).get();
      for (final r in localRoutines) {
        if (received.contains(r.syncId)) continue;
        // Drop its workouts first — workouts.routine_id is RESTRICT, so a
        // direct routine delete would fail. Cascade from workouts cleans
        // out set_completions automatically.
        await (_db.delete(
          _db.workouts,
        )..where((t) => t.routineId.equals(r.id))).go();
        await (_db.delete(_db.routines)..where((t) => t.id.equals(r.id))).go();
      }
    });
  }

  Future<void> _upsertOneRoutine(RoutineTemplateDto dto) async {
    final existing = await (_db.select(
      _db.routines,
    )..where((t) => t.syncId.equals(dto.syncId))).getSingleOrNull();
    if (existing != null && existing.version >= dto.version) return;

    final int routineId;
    if (existing == null) {
      routineId = await _db
          .into(_db.routines)
          .insert(
            RoutinesCompanion.insert(
              syncId: dto.syncId,
              name: dto.name,
              createdAt: DateTime.fromMillisecondsSinceEpoch(dto.createdAtMs),
              version: Value(dto.version),
            ),
          );
    } else {
      // Update in place. Delete-and-reinsert would cascade through
      // planned_sets into set_completions, which use RESTRICT to preserve
      // workout history — that cascade fails as soon as any historical
      // workout references a planned_set on this routine.
      routineId = existing.id;
      await (_db.update(
        _db.routines,
      )..where((t) => t.id.equals(existing.id))).write(
        RoutinesCompanion(
          name: Value(dto.name),
          createdAt: Value(
            DateTime.fromMillisecondsSinceEpoch(dto.createdAtMs),
          ),
          version: Value(dto.version),
        ),
      );
    }

    // Upsert routine_exercises by sync_id, indexed for fast lookup.
    final existingRE = existing == null
        ? <RoutineExercise>[]
        : await (_db.select(
            _db.routineExercises,
          )..where((t) => t.routineId.equals(routineId))).get();
    final existingREBySync = {for (final re in existingRE) re.syncId: re};
    final keptREIds = <int>{};

    for (final e in dto.exercises) {
      final exerciseId = await _findOrCreateExerciseBySyncId(
        syncId: e.exerciseSyncId,
        name: e.exerciseName,
      );
      final int reId;
      final existingForE = existingREBySync[e.syncId];
      if (existingForE == null) {
        reId = await _db
            .into(_db.routineExercises)
            .insert(
              RoutineExercisesCompanion.insert(
                syncId: e.syncId,
                routineId: routineId,
                exerciseId: exerciseId,
                orderIndex: e.orderIndex,
                restSeconds: Value(e.restSeconds),
              ),
            );
      } else {
        reId = existingForE.id;
        await (_db.update(
          _db.routineExercises,
        )..where((t) => t.id.equals(reId))).write(
          RoutineExercisesCompanion(
            exerciseId: Value(exerciseId),
            orderIndex: Value(e.orderIndex),
            restSeconds: Value(e.restSeconds),
          ),
        );
      }
      keptREIds.add(reId);

      // Upsert planned_sets within this routine_exercise.
      final existingPS = existingForE == null
          ? <PlannedSet>[]
          : await (_db.select(
              _db.plannedSets,
            )..where((t) => t.routineExerciseId.equals(reId))).get();
      final existingPSBySync = {for (final ps in existingPS) ps.syncId: ps};
      final keptPSIds = <int>{};

      for (final s in e.plannedSets) {
        final existingForS = existingPSBySync[s.syncId];
        if (existingForS == null) {
          final psId = await _db
              .into(_db.plannedSets)
              .insert(
                PlannedSetsCompanion.insert(
                  syncId: s.syncId,
                  routineExerciseId: reId,
                  setIndex: s.setIndex,
                  targetReps: s.targetReps,
                  targetWeightKg: s.targetWeightKg,
                ),
              );
          keptPSIds.add(psId);
        } else {
          await (_db.update(
            _db.plannedSets,
          )..where((t) => t.id.equals(existingForS.id))).write(
            PlannedSetsCompanion(
              setIndex: Value(s.setIndex),
              targetReps: Value(s.targetReps),
              targetWeightKg: Value(s.targetWeightKg),
            ),
          );
          keptPSIds.add(existingForS.id);
        }
      }

      // Best-effort prune of planned_sets that the routine no longer has.
      // RESTRICT on set_completions.planned_set_id will refuse the delete
      // when historical workouts reference the set — that is intentional;
      // the stale set stays around so the history page can still resolve
      // the exercise name.
      for (final ps in existingPS) {
        if (keptPSIds.contains(ps.id)) continue;
        try {
          await (_db.delete(
            _db.plannedSets,
          )..where((t) => t.id.equals(ps.id))).go();
        } catch (_) {
          // Referenced by a historical completion — leave it in place.
        }
      }
    }

    // Best-effort prune of routine_exercises that the routine no longer has.
    for (final re in existingRE) {
      if (keptREIds.contains(re.id)) continue;
      try {
        await (_db.delete(
          _db.routineExercises,
        )..where((t) => t.id.equals(re.id))).go();
      } catch (_) {
        // Has planned_sets still referenced by history — leave it in place.
      }
    }
  }

  Future<int> _findOrCreateExerciseBySyncId({
    required String syncId,
    required String name,
  }) async {
    final existing = await (_db.select(
      _db.exercises,
    )..where((t) => t.syncId.equals(syncId))).getSingleOrNull();
    if (existing != null) return existing.id;
    // Same name may already exist locally with a different syncId — reuse the
    // local row but keep the syncId stable on our side. Otherwise create new.
    final byName = await (_db.select(
      _db.exercises,
    )..where((t) => t.name.equals(name))).getSingleOrNull();
    if (byName != null) return byName.id;
    return _db
        .into(_db.exercises)
        .insert(
          ExercisesCompanion.insert(
            syncId: syncId,
            name: name,
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Export one workout (with its completions) to a DTO for outbound sync.
  Future<WorkoutDto?> exportWorkout(int workoutId) async {
    final workout = await (_db.select(
      _db.workouts,
    )..where((t) => t.id.equals(workoutId))).getSingleOrNull();
    if (workout == null) return null;
    final routine = await (_db.select(
      _db.routines,
    )..where((t) => t.id.equals(workout.routineId))).getSingle();
    final completions = await _db.completionsForWorkout(workoutId);
    final dtos = <SetCompletionDto>[];
    for (final c in completions) {
      final ps = await (_db.select(
        _db.plannedSets,
      )..where((t) => t.id.equals(c.plannedSetId))).getSingleOrNull();
      if (ps == null) continue;
      dtos.add(
        SetCompletionDto(
          syncId: c.syncId,
          plannedSetSyncId: ps.syncId,
          actualReps: c.actualReps,
          actualWeightKg: c.actualWeightKg,
          completedAtMs: c.completedAt.millisecondsSinceEpoch,
        ),
      );
    }
    return WorkoutDto(
      syncId: workout.syncId,
      routineSyncId: routine.syncId,
      startedAtMs: workout.startedAt.millisecondsSinceEpoch,
      endedAtMs: workout.endedAt?.millisecondsSinceEpoch,
      completions: dtos,
    );
  }

  /// Apply an inbound workout message. Append-only on syncId — if a workout
  /// with the same syncId already exists, it is skipped. Completions whose
  /// plannedSet can't be resolved are dropped (the corresponding routine was
  /// not synced yet on this device).
  Future<void> applyWorkoutCompleted(WorkoutCompletedMessage msg) async {
    final dto = msg.workout;
    await _db.transaction(() async {
      final existing = await (_db.select(
        _db.workouts,
      )..where((t) => t.syncId.equals(dto.syncId))).getSingleOrNull();
      if (existing != null) return;
      final routine = await (_db.select(
        _db.routines,
      )..where((t) => t.syncId.equals(dto.routineSyncId))).getSingleOrNull();
      if (routine == null) return; // can't link without a template
      final workoutId = await _db
          .into(_db.workouts)
          .insert(
            WorkoutsCompanion.insert(
              syncId: dto.syncId,
              routineId: routine.id,
              startedAt: DateTime.fromMillisecondsSinceEpoch(dto.startedAtMs),
              endedAt: Value(
                dto.endedAtMs == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(dto.endedAtMs!),
              ),
            ),
          );
      for (final c in dto.completions) {
        final ps = await (_db.select(
          _db.plannedSets,
        )..where((t) => t.syncId.equals(c.plannedSetSyncId))).getSingleOrNull();
        if (ps == null) continue;
        await _db
            .into(_db.setCompletions)
            .insert(
              SetCompletionsCompanion.insert(
                syncId: c.syncId,
                workoutId: workoutId,
                plannedSetId: ps.id,
                actualReps: c.actualReps,
                actualWeightKg: c.actualWeightKg,
                completedAt: DateTime.fromMillisecondsSinceEpoch(
                  c.completedAtMs,
                ),
              ),
            );
      }
    });
  }

  /// Generate a stable syncId for new rows that need one on the local side.
  String newSyncId() => _uuid.v4();
}
