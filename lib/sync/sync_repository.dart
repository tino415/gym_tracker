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
      // A tombstone travels as a versioned deletion marker, not a full routine.
      if (r.deletedAt != null) {
        result.add(RoutineTemplateDto.tombstone(r));
        continue;
      }
      final full = await _db.loadFullRoutine(r.id);
      if (full == null) continue;
      // Hydrate each routine exercise with its alternatives. fromFullRoutine
      // can't see the canonical exercise rows for alternatives without an
      // extra DB roundtrip, so we patch the dtos here.
      final exDtos = <RoutineExerciseDto>[];
      for (final re in full.exercises) {
        final altRows = await (_db.select(_db.routineExerciseAlternatives)
              ..where((t) => t.routineExerciseId.equals(re.routineExercise.id))
              ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
            .get();
        final altDtos = <AlternativeRefDto>[];
        for (final a in altRows) {
          final ex = await (_db.select(
            _db.exercises,
          )..where((t) => t.id.equals(a.exerciseId))).getSingleOrNull();
          if (ex == null) continue;
          final altPs = await (_db.select(_db.alternativePlannedSets)
                ..where((t) => t.alternativeId.equals(a.id))
                ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
              .get();
          altDtos.add(
            AlternativeRefDto(
              syncId: a.syncId,
              exerciseSyncId: ex.syncId,
              exerciseName: ex.name,
              exerciseKind: ex.kind,
              orderIndex: a.orderIndex,
              plannedSets: [
                for (final p in altPs)
                  PlannedSetDto(
                    syncId: p.syncId,
                    setIndex: p.setIndex,
                    targetReps: p.targetReps,
                    targetWeightKg: p.targetWeightKg,
                    targetSeconds: p.targetSeconds,
                  ),
              ],
            ),
          );
        }
        final base = RoutineExerciseDto.fromFullExercise(re);
        exDtos.add(
          RoutineExerciseDto(
            syncId: base.syncId,
            exerciseSyncId: base.exerciseSyncId,
            exerciseName: base.exerciseName,
            exerciseKind: base.exerciseKind,
            orderIndex: base.orderIndex,
            restSeconds: base.restSeconds,
            supersetGroup: base.supersetGroup,
            plannedSets: base.plannedSets,
            alternatives: altDtos,
            muscleSyncIds: base.muscleSyncIds,
          ),
        );
      }
      result.add(
        RoutineTemplateDto(
          syncId: full.routine.syncId,
          name: full.routine.name,
          version: full.routine.version,
          createdAtMs: full.routine.createdAt.millisecondsSinceEpoch,
          exercises: exDtos,
        ),
      );
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

  /// Apply routines as a non-destructive merge: each is upserted, but local
  /// routines absent from the message are left untouched (unlike
  /// [applyRoutineBundle]). Deletions are carried separately by
  /// [deleteRoutinesBySyncId]. Used by the Firestore transport, where a lost
  /// or empty snapshot must never wipe local routines.
  Future<void> applyRoutineBundleUpsert(RoutineBundleMessage bundle) async {
    await _db.transaction(() async {
      for (final dto in bundle.routines) {
        await _upsertOneRoutine(dto);
      }
    });
  }

  /// Delete local routines by sync id. Workouts survive (routine_id is SET
  /// NULL). No-op for ids not present locally.
  Future<void> deleteRoutinesBySyncId(List<String> syncIds) async {
    if (syncIds.isEmpty) return;
    await (_db.delete(
      _db.routines,
    )..where((t) => t.syncId.isIn(syncIds))).go();
  }

  Future<void> _upsertOneRoutine(RoutineTemplateDto dto) async {
    final existing = await (_db.select(
      _db.routines,
    )..where((t) => t.syncId.equals(dto.syncId))).getSingleOrNull();
    // Only strictly older bundles are dropped (out-of-order delivery guard).
    // Equal versions re-apply: exercise-level edits on the phone (rename,
    // kind) don't bump any routine version, and a lost push would otherwise
    // leave the watch permanently stale with no way for the manual "Sync
    // now" to repair it. The upsert below is idempotent, so this is safe.
    if (existing != null && existing.version > dto.version) return;

    // Tombstone: a deletion at version ≥ local wins. Persist the marker (so a
    // later stale lower-version edit can't resurrect) and drop the template's
    // child rows. Applies at equal version by arrival order, same as edits.
    if (dto.deletedAtMs != null) {
      await _applyTombstone(dto, existing);
      return;
    }

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
          // A non-tombstone edit at version ≥ local revives a tombstoned
          // routine (legitimate re-author); clear the marker.
          deletedAt: const Value(null),
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

      // Upsert alternatives within this routine exercise.
      final existingAlts = await (_db.select(_db.routineExerciseAlternatives)
            ..where((t) => t.routineExerciseId.equals(reId)))
          .get();
      final existingAltsBySync = {
        for (final a in existingAlts) a.syncId: a,
      };
      final keptAltIds = <int>{};
      for (final a in e.alternatives) {
        final altExerciseId = await _findOrCreateExerciseBySyncId(
          syncId: a.exerciseSyncId,
          name: a.exerciseName,
          kind: a.exerciseKind,
        );
        final exA = existingAltsBySync[a.syncId];
        final int altRowId;
        if (exA == null) {
          altRowId = await _db
              .into(_db.routineExerciseAlternatives)
              .insert(
                RoutineExerciseAlternativesCompanion.insert(
                  syncId: a.syncId,
                  routineExerciseId: reId,
                  exerciseId: altExerciseId,
                  orderIndex: a.orderIndex,
                ),
              );
        } else {
          altRowId = exA.id;
          await (_db.update(_db.routineExerciseAlternatives)
                ..where((t) => t.id.equals(altRowId)))
              .write(
                RoutineExerciseAlternativesCompanion(
                  exerciseId: Value(altExerciseId),
                  orderIndex: Value(a.orderIndex),
                ),
              );
        }
        keptAltIds.add(altRowId);

        // Upsert this alt's planned sets by syncId. Match the primary's
        // pattern: drop any not present in the bundle.
        final existingAltPs =
            await (_db.select(_db.alternativePlannedSets)
                  ..where((t) => t.alternativeId.equals(altRowId)))
                .get();
        final existingAltPsBySync = {
          for (final p in existingAltPs) p.syncId: p,
        };
        final keptAltPsIds = <int>{};
        for (final s in a.plannedSets) {
          final existingForS = existingAltPsBySync[s.syncId];
          if (existingForS == null) {
            final psId = await _db
                .into(_db.alternativePlannedSets)
                .insert(
                  AlternativePlannedSetsCompanion.insert(
                    syncId: s.syncId,
                    alternativeId: altRowId,
                    setIndex: s.setIndex,
                    targetReps: Value(s.targetReps),
                    targetWeightKg: Value(s.targetWeightKg),
                    targetSeconds: Value(s.targetSeconds),
                  ),
                );
            keptAltPsIds.add(psId);
          } else {
            await (_db.update(_db.alternativePlannedSets)
                  ..where((t) => t.id.equals(existingForS.id)))
                .write(
                  AlternativePlannedSetsCompanion(
                    setIndex: Value(s.setIndex),
                    targetReps: Value(s.targetReps),
                    targetWeightKg: Value(s.targetWeightKg),
                    targetSeconds: Value(s.targetSeconds),
                  ),
                );
            keptAltPsIds.add(existingForS.id);
          }
        }
        for (final p in existingAltPs) {
          if (keptAltPsIds.contains(p.id)) continue;
          await (_db.delete(_db.alternativePlannedSets)
                ..where((t) => t.id.equals(p.id)))
              .go();
        }
      }
      for (final a in existingAlts) {
        if (keptAltIds.contains(a.id)) continue;
        await (_db.delete(_db.routineExerciseAlternatives)
              ..where((t) => t.id.equals(a.id)))
            .go();
      }

      // Apply muscle tags to the canonical exercise (last-write-wins).
      if (e.muscleSyncIds.isNotEmpty) {
        final muscleRows = await (_db.select(_db.muscles)
              ..where((t) => t.syncId.isIn(e.muscleSyncIds)))
            .get();
        await _db.setExerciseMuscles(
          exerciseId,
          [for (final m in muscleRows) m.id],
        );
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

  /// Apply an inbound tombstone: mark the routine deleted at [dto]'s version
  /// and drop its template rows. Inserts a fresh tombstone row when we've never
  /// seen the routine (so a delete that arrives before the routine ever did
  /// still suppresses a later stale re-creation). Idempotent.
  Future<void> _applyTombstone(RoutineTemplateDto dto, Routine? existing) async {
    final deletedAt = DateTime.fromMillisecondsSinceEpoch(dto.deletedAtMs!);
    if (existing == null) {
      await _db
          .into(_db.routines)
          .insert(
            RoutinesCompanion.insert(
              syncId: dto.syncId,
              name: dto.name,
              createdAt: DateTime.fromMillisecondsSinceEpoch(dto.createdAtMs),
              version: Value(dto.version),
              deletedAt: Value(deletedAt),
            ),
          );
      return;
    }
    // Dropping routine_exercises cascades to planned_sets / alternatives.
    await (_db.delete(
      _db.routineExercises,
    )..where((t) => t.routineId.equals(existing.id))).go();
    await (_db.update(
      _db.routines,
    )..where((t) => t.id.equals(existing.id))).write(
      RoutinesCompanion(
        name: Value(dto.name),
        version: Value(dto.version),
        deletedAt: Value(deletedAt),
      ),
    );
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
      // Same for the name — the authority may have renamed the exercise. A
      // different local exercise can already hold the target name (UNIQUE);
      // keep the old name in that case rather than failing the whole bundle.
      if (existing.name != name) {
        try {
          await (_db.update(
            _db.exercises,
          )..where((t) => t.id.equals(existing.id))).write(
            ExercisesCompanion(name: Value(name)),
          );
        } catch (_) {
          // name taken locally — leave as is
        }
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
      String? routineExerciseSyncId;
      if (we.routineExerciseId != null) {
        final re = await (_db.select(
          _db.routineExercises,
        )..where((t) => t.id.equals(we.routineExerciseId!))).getSingleOrNull();
        routineExerciseSyncId = re?.syncId;
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
          routineExerciseSyncId: routineExerciseSyncId,
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
          avgHeartRate: c.avgHeartRate,
          maxHeartRate: c.maxHeartRate,
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
      avgHeartRate: workout.avgHeartRate,
      maxHeartRate: workout.maxHeartRate,
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
              avgHeartRate: Value(dto.avgHeartRate),
              maxHeartRate: Value(dto.maxHeartRate),
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
        int? routineExerciseLocalId;
        if (e.routineExerciseSyncId != null) {
          final re = await (_db.select(_db.routineExercises)
                ..where((t) => t.syncId.equals(e.routineExerciseSyncId!)))
              .getSingleOrNull();
          routineExerciseLocalId = re?.id;
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
                routineExerciseId: Value(routineExerciseLocalId),
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
                avgHeartRate: Value(c.avgHeartRate),
                maxHeartRate: Value(c.maxHeartRate),
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
