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

  /// Apply an inbound routine bundle to the local DB.
  ///
  /// The bundle is treated as an authoritative snapshot: any local routine
  /// whose sync_id is not present in the bundle is also removed. Workouts
  /// no longer depend on routines (their snapshot is self-contained), so the
  /// drop is a single delete — workouts.routine_id is SET NULL.
  Future<void> applyRoutineBundle(RoutineBundleMessage bundle) async {
    await _db.transaction(() async {
      final received = bundle.routines.map((r) => r.syncId).toSet();
      for (final dto in bundle.routines) {
        await _upsertOneRoutine(dto);
      }
      final localRoutines = await _db.select(_db.routines).get();
      for (final r in localRoutines) {
        if (received.contains(r.syncId)) continue;
        await (_db.delete(
          _db.routines,
        )..where((t) => t.id.equals(r.id))).go();
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

    // Upsert routine_exercises by sync_id.
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
        kind: e.exerciseKind,
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
                supersetGroup: Value(e.supersetGroup),
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
            supersetGroup: Value(e.supersetGroup),
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
                  targetReps: Value(s.targetReps),
                  targetWeightKg: Value(s.targetWeightKg),
                  targetSeconds: Value(s.targetSeconds),
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
              targetSeconds: Value(s.targetSeconds),
            ),
          );
          keptPSIds.add(existingForS.id);
        }
      }

      for (final ps in existingPS) {
        if (keptPSIds.contains(ps.id)) continue;
        try {
          await (_db.delete(
            _db.plannedSets,
          )..where((t) => t.id.equals(ps.id))).go();
        } catch (_) {
          // No longer needed (set_completions reference workout_sets, not
          // planned_sets) but kept defensively in case of orphan rows.
        }
      }
    }

    for (final re in existingRE) {
      if (keptREIds.contains(re.id)) continue;
      try {
        await (_db.delete(
          _db.routineExercises,
        )..where((t) => t.id.equals(re.id))).go();
      } catch (_) {
        // best-effort
      }
    }
  }

  Future<int> _findOrCreateExerciseBySyncId({
    required String syncId,
    required String name,
    required String kind,
  }) async {
    final existing = await (_db.select(
      _db.exercises,
    )..where((t) => t.syncId.equals(syncId))).getSingleOrNull();
    if (existing != null) {
      // Keep the canonical kind aligned with the incoming bundle.
      if (existing.kind != kind) {
        await (_db.update(
          _db.exercises,
        )..where((t) => t.id.equals(existing.id))).write(
          ExercisesCompanion(kind: Value(kind)),
        );
      }
      return existing.id;
    }
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
            kind: Value(kind),
          ),
        );
  }

  /// Export one workout (its snapshot exercises/sets + every completion) for
  /// outbound sync.
  Future<WorkoutDto?> exportWorkout(int workoutId) async {
    final workout = await (_db.select(
      _db.workouts,
    )..where((t) => t.id.equals(workoutId))).getSingleOrNull();
    if (workout == null) return null;
    String? routineSyncId;
    if (workout.routineId != null) {
      final r = await (_db.select(
        _db.routines,
      )..where((t) => t.id.equals(workout.routineId!))).getSingleOrNull();
      routineSyncId = r?.syncId;
    }
    final wes = await (_db.select(_db.workoutExercises)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    final exerciseDtos = <WorkoutExerciseDto>[];
    final workoutSetSyncByLocalId = <int, String>{};
    for (final we in wes) {
      String? exerciseSyncId;
      if (we.exerciseId != null) {
        final ex = await (_db.select(
          _db.exercises,
        )..where((t) => t.id.equals(we.exerciseId!))).getSingleOrNull();
        exerciseSyncId = ex?.syncId;
      }
      final sets = await (_db.select(_db.workoutSets)
            ..where((t) => t.workoutExerciseId.equals(we.id))
            ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
          .get();
      for (final s in sets) {
        workoutSetSyncByLocalId[s.id] = s.syncId;
      }
      exerciseDtos.add(
        WorkoutExerciseDto(
          syncId: we.syncId,
          exerciseSyncId: exerciseSyncId,
          exerciseName: we.exerciseName,
          kind: we.kind,
          orderIndex: we.orderIndex,
          restSeconds: we.restSeconds,
          supersetGroup: we.supersetGroup,
          sets: [
            for (final s in sets)
              WorkoutSetDto(
                syncId: s.syncId,
                setIndex: s.setIndex,
                targetReps: s.targetReps,
                targetWeightKg: s.targetWeightKg,
                targetSeconds: s.targetSeconds,
              ),
          ],
        ),
      );
    }
    final completions = await _db.completionsForWorkout(workoutId);
    final completionDtos = <SetCompletionDto>[];
    for (final c in completions) {
      final wsSync = workoutSetSyncByLocalId[c.workoutSetId];
      if (wsSync == null) continue;
      completionDtos.add(
        SetCompletionDto(
          syncId: c.syncId,
          workoutSetSyncId: wsSync,
          actualReps: c.actualReps,
          actualWeightKg: c.actualWeightKg,
          actualSeconds: c.actualSeconds,
          completedAtMs: c.completedAt.millisecondsSinceEpoch,
        ),
      );
    }
    return WorkoutDto(
      syncId: workout.syncId,
      routineSyncId: routineSyncId,
      startedAtMs: workout.startedAt.millisecondsSinceEpoch,
      endedAtMs: workout.endedAt?.millisecondsSinceEpoch,
      exercises: exerciseDtos,
      completions: completionDtos,
    );
  }

  /// Apply an inbound workout message. Workouts are self-contained — we
  /// insert their snapshot tables before binding completions. Append-only on
  /// syncId.
  Future<void> applyWorkoutCompleted(WorkoutCompletedMessage msg) async {
    final dto = msg.workout;
    await _db.transaction(() async {
      final existing = await (_db.select(
        _db.workouts,
      )..where((t) => t.syncId.equals(dto.syncId))).getSingleOrNull();
      if (existing != null) return; // already have it; skip

      int? routineLocalId;
      if (dto.routineSyncId != null) {
        final routine = await (_db.select(
          _db.routines,
        )..where((t) => t.syncId.equals(dto.routineSyncId!))).getSingleOrNull();
        routineLocalId = routine?.id;
      }

      final workoutId = await _db
          .into(_db.workouts)
          .insert(
            WorkoutsCompanion.insert(
              syncId: dto.syncId,
              routineId: Value(routineLocalId),
              startedAt: DateTime.fromMillisecondsSinceEpoch(dto.startedAtMs),
              endedAt: Value(
                dto.endedAtMs == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(dto.endedAtMs!),
              ),
            ),
          );

      final workoutSetIdBySync = <String, int>{};
      for (final e in dto.exercises) {
        int? exerciseLocalId;
        if (e.exerciseSyncId != null) {
          final ex = await (_db.select(
            _db.exercises,
          )..where((t) => t.syncId.equals(e.exerciseSyncId!))).getSingleOrNull();
          exerciseLocalId = ex?.id;
        }
        final weId = await _db
            .into(_db.workoutExercises)
            .insert(
              WorkoutExercisesCompanion.insert(
                syncId: e.syncId,
                workoutId: workoutId,
                exerciseId: Value(exerciseLocalId),
                exerciseName: e.exerciseName,
                orderIndex: e.orderIndex,
                restSeconds: Value(e.restSeconds),
                supersetGroup: Value(e.supersetGroup),
                kind: Value(e.kind),
              ),
            );
        for (final s in e.sets) {
          final wsId = await _db
              .into(_db.workoutSets)
              .insert(
                WorkoutSetsCompanion.insert(
                  syncId: s.syncId,
                  workoutExerciseId: weId,
                  setIndex: s.setIndex,
                  targetReps: Value(s.targetReps),
                  targetWeightKg: Value(s.targetWeightKg),
                  targetSeconds: Value(s.targetSeconds),
                ),
              );
          workoutSetIdBySync[s.syncId] = wsId;
        }
      }

      for (final c in dto.completions) {
        final wsId = workoutSetIdBySync[c.workoutSetSyncId];
        if (wsId == null) continue;
        await _db
            .into(_db.setCompletions)
            .insert(
              SetCompletionsCompanion.insert(
                syncId: c.syncId,
                workoutId: workoutId,
                workoutSetId: wsId,
                actualReps: Value(c.actualReps),
                actualWeightKg: Value(c.actualWeightKg),
                actualSeconds: Value(c.actualSeconds),
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
