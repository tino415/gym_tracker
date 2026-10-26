import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'sync_codec.dart';
import 'sync_dto_mapping.dart';

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
        result.add(routineTombstoneToDto(r));
        continue;
      }
      final full = await _db.loadFullRoutine(r.syncId);
      if (full == null) continue;
      // Hydrate each routine exercise with its alternatives. routineExerciseToDto
      // can't see the canonical exercise rows for alternatives without an
      // extra DB roundtrip, so we patch the dtos here.
      final exDtos = <RoutineExerciseDto>[];
      for (final re in full.exercises) {
        final altRows = await (_db.select(_db.routineExerciseAlternatives)
              ..where((t) => t.routineExerciseId.equals(re.routineExercise.syncId))
              ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
            .get();
        final altDtos = <AlternativeRefDto>[];
        for (final a in altRows) {
          final ex = await (_db.select(
            _db.exercises,
          )..where((t) => t.syncId.equals(a.exerciseId))).getSingleOrNull();
          if (ex == null) continue;
          final altPs = await (_db.select(_db.alternativePlannedSets)
                ..where((t) => t.alternativeId.equals(a.syncId))
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
        final base = routineExerciseToDto(re);
        exDtos.add(
          RoutineExerciseDto(
            syncId: base.syncId,
            exerciseSyncId: base.exerciseSyncId,
            exerciseName: base.exerciseName,
            exerciseKind: base.exerciseKind,
            orderIndex: base.orderIndex,
            restSeconds: base.restSeconds,
            circuitGroup: base.circuitGroup,
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

  /// Export the whole exercise library (canonical exercises + muscle tags),
  /// tombstones included. A tombstone travels as a versioned deletion marker
  /// with empty muscle tags; a live exercise carries its muscle syncIds.
  Future<List<ExerciseDto>> exportAllExercises() async {
    final all = await _db.select(_db.exercises).get();
    final result = <ExerciseDto>[];
    for (final e in all) {
      if (e.deletedAt != null) {
        result.add(exerciseTombstoneToDto(e));
        continue;
      }
      final muscles = await _db.musclesForExercise(e.syncId);
      result.add(
        exerciseToDto(e, [for (final m in muscles) m.syncId]),
      );
    }
    return result;
  }

  /// Apply an inbound exercise bundle non-destructively with version-LWW.
  /// Each exercise is upserted by syncId; deletions ride as tombstones inside
  /// the list. Local exercises absent from the bundle are left untouched (a
  /// lost or partial bundle must never wipe the library).
  Future<void> applyExerciseBundle(ExerciseBundleMessage bundle) async {
    await _db.transaction(() async {
      for (final dto in bundle.exercises) {
        await _upsertOneExercise(dto);
      }
    });
  }

  Future<void> _upsertOneExercise(ExerciseDto dto) async {
    final existing = await (_db.select(
      _db.exercises,
    )..where((t) => t.syncId.equals(dto.syncId))).getSingleOrNull();
    // Strictly older loses (out-of-order delivery guard); equal versions
    // re-apply (idempotent), matching the routine path.
    if (existing != null && existing.version > dto.version) return;

    final deletedAt = dto.deletedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(dto.deletedAtMs!);

    if (existing == null) {
      // Guard the UNIQUE(name): if a *different* local exercise already holds
      // this name, leave it as-is rather than failing the whole bundle. The
      // incoming syncId then has no local row — a name-based identity merge
      // (reconciling syncIds) is out of scope, same pragmatic stance as
      // [_findOrCreateExerciseBySyncId].
      final byName = await (_db.select(
        _db.exercises,
      )..where((t) => t.name.equals(dto.name))).getSingleOrNull();
      if (byName != null) return;
      final id = dto.syncId;
      await _db.into(_db.exercises).insert(
            ExercisesCompanion.insert(
              syncId: dto.syncId,
              name: dto.name,
              createdAt: DateTime.fromMillisecondsSinceEpoch(dto.createdAtMs),
              kind: Value(dto.kind),
              version: Value(dto.version),
              deletedAt: Value(deletedAt),
            ),
          );
      if (deletedAt == null) {
        await _applyExerciseMuscles(id, dto.muscleSyncIds);
      }
      return;
    }

    // Update in place. `deletedAt` is set for a tombstone and cleared (revive)
    // for a live edit at version ≥ local. The name is UNIQUE, so a colliding
    // rename is retried without the name (keep the local one) rather than
    // sinking the bundle.
    final companion = ExercisesCompanion(
      name: Value(dto.name),
      kind: Value(dto.kind),
      version: Value(dto.version),
      deletedAt: Value(deletedAt),
    );
    try {
      await (_db.update(
        _db.exercises,
      )..where((t) => t.syncId.equals(existing.syncId))).write(companion);
    } catch (_) {
      await (_db.update(_db.exercises)..where((t) => t.syncId.equals(existing.syncId)))
          .write(
        ExercisesCompanion(
          kind: Value(dto.kind),
          version: Value(dto.version),
          deletedAt: Value(deletedAt),
        ),
      );
    }
    if (deletedAt == null) {
      await _applyExerciseMuscles(existing.syncId, dto.muscleSyncIds);
    }
  }

  /// Replace an exercise's muscle tags from deterministic muscle syncIds,
  /// writing the join directly so the exercise version is NOT bumped (the
  /// version is authoritative from the DTO; bumping here would echo a push).
  /// Unknown muscle syncIds are skipped.
  Future<void> _applyExerciseMuscles(
    String exerciseId,
    List<String> muscleSyncIds,
  ) async {
    await (_db.delete(
      _db.exerciseMuscles,
    )..where((t) => t.exerciseId.equals(exerciseId))).go();
    if (muscleSyncIds.isEmpty) return;
    final rows = await (_db.select(
      _db.muscles,
    )..where((t) => t.syncId.isIn(muscleSyncIds))).get();
    for (final m in rows) {
      await _db.into(_db.exerciseMuscles).insert(
            ExerciseMusclesCompanion.insert(
              exerciseId: exerciseId,
              muscleId: m.syncId,
            ),
          );
    }
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
        )..where((t) => t.syncId.equals(r.syncId))).go();
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

    final String routineId;
    if (existing == null) {
      routineId = dto.syncId;
      await _db
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
      routineId = existing.syncId;
      await (_db.update(
        _db.routines,
      )..where((t) => t.syncId.equals(existing.syncId))).write(
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
    final keptREIds = <String>{};

    for (final e in dto.exercises) {
      final exerciseId = await _findOrCreateExerciseBySyncId(
        syncId: e.exerciseSyncId,
        name: e.exerciseName,
        kind: e.exerciseKind,
      );
      final String reId;
      final existingForE = existingREBySync[e.syncId];
      if (existingForE == null) {
        reId = e.syncId;
        await _db
            .into(_db.routineExercises)
            .insert(
              RoutineExercisesCompanion.insert(
                syncId: e.syncId,
                routineId: routineId,
                exerciseId: exerciseId,
                orderIndex: e.orderIndex,
                restSeconds: Value(e.restSeconds),
                circuitGroup: Value(e.circuitGroup),
              ),
            );
      } else {
        reId = existingForE.syncId;
        await (_db.update(
          _db.routineExercises,
        )..where((t) => t.syncId.equals(reId))).write(
          RoutineExercisesCompanion(
            exerciseId: Value(exerciseId),
            orderIndex: Value(e.orderIndex),
            restSeconds: Value(e.restSeconds),
            circuitGroup: Value(e.circuitGroup),
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
      final keptPSIds = <String>{};

      for (final s in e.plannedSets) {
        final existingForS = existingPSBySync[s.syncId];
        if (existingForS == null) {
          final psId = s.syncId;
          await _db
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
          )..where((t) => t.syncId.equals(existingForS.syncId))).write(
            PlannedSetsCompanion(
              setIndex: Value(s.setIndex),
              targetReps: Value(s.targetReps),
              targetWeightKg: Value(s.targetWeightKg),
              targetSeconds: Value(s.targetSeconds),
            ),
          );
          keptPSIds.add(existingForS.syncId);
        }
      }

      for (final ps in existingPS) {
        if (keptPSIds.contains(ps.syncId)) continue;
        try {
          await (_db.delete(
            _db.plannedSets,
          )..where((t) => t.syncId.equals(ps.syncId))).go();
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
      final keptAltIds = <String>{};
      for (final a in e.alternatives) {
        final altExerciseId = await _findOrCreateExerciseBySyncId(
          syncId: a.exerciseSyncId,
          name: a.exerciseName,
          kind: a.exerciseKind,
        );
        final exA = existingAltsBySync[a.syncId];
        final String altRowId;
        if (exA == null) {
          altRowId = a.syncId;
          await _db
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
          altRowId = exA.syncId;
          await (_db.update(_db.routineExerciseAlternatives)
                ..where((t) => t.syncId.equals(altRowId)))
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
        final keptAltPsIds = <String>{};
        for (final s in a.plannedSets) {
          final existingForS = existingAltPsBySync[s.syncId];
          if (existingForS == null) {
            final psId = s.syncId;
            await _db
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
                  ..where((t) => t.syncId.equals(existingForS.syncId)))
                .write(
                  AlternativePlannedSetsCompanion(
                    setIndex: Value(s.setIndex),
                    targetReps: Value(s.targetReps),
                    targetWeightKg: Value(s.targetWeightKg),
                    targetSeconds: Value(s.targetSeconds),
                  ),
                );
            keptAltPsIds.add(existingForS.syncId);
          }
        }
        for (final p in existingAltPs) {
          if (keptAltPsIds.contains(p.syncId)) continue;
          await (_db.delete(_db.alternativePlannedSets)
                ..where((t) => t.syncId.equals(p.syncId)))
              .go();
        }
      }
      for (final a in existingAlts) {
        if (keptAltIds.contains(a.syncId)) continue;
        await (_db.delete(_db.routineExerciseAlternatives)
              ..where((t) => t.syncId.equals(a.syncId)))
            .go();
      }

      // Apply muscle tags to the canonical exercise (last-write-wins).
      if (e.muscleSyncIds.isNotEmpty) {
        final muscleRows = await (_db.select(_db.muscles)
              ..where((t) => t.syncId.isIn(e.muscleSyncIds)))
            .get();
        await _db.setExerciseMuscles(
          exerciseId,
          [for (final m in muscleRows) m.syncId],
        );
      }
    }

    for (final re in existingRE) {
      if (keptREIds.contains(re.syncId)) continue;
      try {
        await (_db.delete(
          _db.routineExercises,
        )..where((t) => t.syncId.equals(re.syncId))).go();
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
    )..where((t) => t.routineId.equals(existing.syncId))).go();
    await (_db.update(
      _db.routines,
    )..where((t) => t.syncId.equals(existing.syncId))).write(
      RoutinesCompanion(
        name: Value(dto.name),
        version: Value(dto.version),
        deletedAt: Value(deletedAt),
      ),
    );
  }

  Future<String> _findOrCreateExerciseBySyncId({
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
        )..where((t) => t.syncId.equals(existing.syncId))).write(
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
          )..where((t) => t.syncId.equals(existing.syncId))).write(
            ExercisesCompanion(name: Value(name)),
          );
        } catch (_) {
          // name taken locally — leave as is
        }
      }
      return existing.syncId;
    }
    final byName = await (_db.select(
      _db.exercises,
    )..where((t) => t.name.equals(name))).getSingleOrNull();
    if (byName != null) return byName.syncId;
    await _db
        .into(_db.exercises)
        .insert(
          ExercisesCompanion.insert(
            syncId: syncId,
            name: name,
            createdAt: DateTime.now(),
            kind: Value(kind),
          ),
        );
    return syncId;
  }

  /// Export one workout (its snapshot exercises/sets + every completion) for
  /// outbound sync.
  Future<WorkoutDto?> exportWorkout(String workoutId) async {
    final workout = await (_db.select(
      _db.workouts,
    )..where((t) => t.syncId.equals(workoutId))).getSingleOrNull();
    if (workout == null) return null;
    // A tombstone travels as a versioned deletion marker, not a snapshot — its
    // child rows are already gone, so this also skips five pointless queries.
    if (workout.deletedAt != null) {
      return WorkoutDto.tombstone(
        syncId: workout.syncId,
        version: workout.version,
        deletedAtMs: workout.deletedAt!.millisecondsSinceEpoch,
        startedAtMs: workout.startedAt.millisecondsSinceEpoch,
        routineName: workout.routineName,
      );
    }
    String? routineSyncId;
    if (workout.routineId != null) {
      // Tombstoned routine reads as gone, matching loadFullWorkout.
      final r = await (_db.select(_db.routines)
            ..where(
              (t) => t.syncId.equals(workout.routineId!) & t.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      routineSyncId = r?.syncId;
    }
    final wes = await (_db.select(_db.workoutExercises)
          ..where((t) => t.workoutId.equals(workoutId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    final exerciseDtos = <WorkoutExerciseDto>[];
    final workoutSetSyncByLocalId = <String, String>{};
    for (final we in wes) {
      String? exerciseSyncId;
      if (we.exerciseId != null) {
        final ex = await (_db.select(
          _db.exercises,
        )..where((t) => t.syncId.equals(we.exerciseId!))).getSingleOrNull();
        exerciseSyncId = ex?.syncId;
      }
      String? routineExerciseSyncId;
      if (we.routineExerciseId != null) {
        final re = await (_db.select(
          _db.routineExercises,
        )..where((t) => t.syncId.equals(we.routineExerciseId!))).getSingleOrNull();
        routineExerciseSyncId = re?.syncId;
      }
      final sets = await (_db.select(_db.workoutSets)
            ..where((t) => t.workoutExerciseId.equals(we.syncId))
            ..orderBy([(t) => OrderingTerm.asc(t.setIndex)]))
          .get();
      for (final s in sets) {
        workoutSetSyncByLocalId[s.syncId] = s.syncId;
      }
      exerciseDtos.add(
        WorkoutExerciseDto(
          syncId: we.syncId,
          exerciseSyncId: exerciseSyncId,
          exerciseName: we.exerciseName,
          kind: we.kind,
          orderIndex: we.orderIndex,
          restSeconds: we.restSeconds,
          circuitGroup: we.circuitGroup,
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
    final samples = await _db.heartRateSamplesFor(workoutId);
    return WorkoutDto(
      syncId: workout.syncId,
      routineSyncId: routineSyncId,
      routineName: workout.routineName,
      startedAtMs: workout.startedAt.millisecondsSinceEpoch,
      endedAtMs: workout.endedAt?.millisecondsSinceEpoch,
      exercises: exerciseDtos,
      completions: completionDtos,
      heartRateSamples: [
        for (final s in samples)
          HeartRateSampleDto(
            tMs: s.measuredAtMs,
            bpm: s.bpm,
            accuracy: s.accuracy,
          ),
      ],
      avgHeartRate: workout.avgHeartRate,
      maxHeartRate: workout.maxHeartRate,
      version: workout.version,
    );
  }

  /// Apply an inbound workout message with version-LWW, replacing the whole
  /// snapshot in one transaction. Returns true iff local rows actually changed
  /// — [SyncService] gates the relay on that, and a false keeps a no-op echo
  /// from waking the workout watcher.
  ///
  /// The applied version is taken **from the DTO and never incremented**: that
  /// is what makes an apply invisible to the push path and keeps the relay
  /// loop-safe now that the old append-only skip is gone.
  Future<bool> applyWorkoutCompleted(WorkoutCompletedMessage msg) async {
    final dto = msg.workout;
    return _db.transaction(() async {
      final existing = await (_db.select(
        _db.workouts,
      )..where((t) => t.syncId.equals(dto.syncId))).getSingleOrNull();

      // Only strictly older loses (out-of-order delivery guard). Equal versions
      // re-apply, the same repair channel routines rely on for "Sync now".
      if (existing != null && existing.version > dto.version) return false;

      // Never let a sync clobber a workout that is open on this device right
      // now — the watch is mid-run in front of the user.
      if (existing != null &&
          existing.endedAt == null &&
          existing.deletedAt == null) {
        return false;
      }

      // Nothing to do if we already hold exactly this content. Skipping the
      // writes is what stops an echo from producing a table update (and so a
      // push) on every hop.
      if (existing != null && existing.version == dto.version) {
        final local = await exportWorkout(dto.syncId);
        if (local != null && jsonEquals(local.toJson(), dto.toJson())) {
          return false;
        }
      }

      if (dto.deletedAtMs != null) {
        await _applyWorkoutTombstone(dto, existing);
        return true;
      }

      String? routineLocalId;
      if (dto.routineSyncId != null) {
        final routine = await (_db.select(_db.routines)
              ..where(
                (t) => t.syncId.equals(dto.routineSyncId!) & t.deletedAt.isNull(),
              ))
            .getSingleOrNull();
        routineLocalId = routine?.syncId;
      }

      final workoutId = dto.syncId;
      final startedAt = DateTime.fromMillisecondsSinceEpoch(dto.startedAtMs);
      final endedAt = dto.endedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(dto.endedAtMs!);

      if (existing == null) {
        await _db
            .into(_db.workouts)
            .insert(
              WorkoutsCompanion.insert(
                syncId: dto.syncId,
                routineId: Value(routineLocalId),
                routineName: Value(dto.routineName),
                startedAt: startedAt,
                endedAt: Value(endedAt),
                avgHeartRate: Value(dto.avgHeartRate),
                maxHeartRate: Value(dto.maxHeartRate),
                version: Value(dto.version),
              ),
            );
      } else {
        // Replace the snapshot wholesale. The workout row itself is updated
        // rather than deleted: the child tables FK it, and keeping it preserves
        // row identity for any open watchFullWorkout stream.
        await (_db.delete(
          _db.heartRateSamples,
        )..where((t) => t.workoutId.equals(workoutId))).go();
        await (_db.delete(
          _db.setCompletions,
        )..where((t) => t.workoutId.equals(workoutId))).go();
        // Cascades to workoutSets.
        await (_db.delete(
          _db.workoutExercises,
        )..where((t) => t.workoutId.equals(workoutId))).go();
        await (_db.update(
          _db.workouts,
        )..where((t) => t.syncId.equals(workoutId))).write(
          WorkoutsCompanion(
            routineId: Value(routineLocalId),
            routineName: Value(dto.routineName),
            startedAt: Value(startedAt),
            endedAt: Value(endedAt),
            avgHeartRate: Value(dto.avgHeartRate),
            maxHeartRate: Value(dto.maxHeartRate),
            version: Value(dto.version),
            // A live edit at version >= local revives a tombstone.
            deletedAt: const Value(null),
          ),
        );
      }

      final workoutSetIdBySync = <String, String>{};
      for (final e in dto.exercises) {
        String? exerciseLocalId;
        if (e.exerciseSyncId != null) {
          final ex = await (_db.select(
            _db.exercises,
          )..where((t) => t.syncId.equals(e.exerciseSyncId!))).getSingleOrNull();
          exerciseLocalId = ex?.syncId;
        }
        String? routineExerciseLocalId;
        if (e.routineExerciseSyncId != null) {
          final re = await (_db.select(_db.routineExercises)
                ..where((t) => t.syncId.equals(e.routineExerciseSyncId!)))
              .getSingleOrNull();
          routineExerciseLocalId = re?.syncId;
        }
        final weId = e.syncId;
        await _db
            .into(_db.workoutExercises)
            .insert(
              WorkoutExercisesCompanion.insert(
                syncId: e.syncId,
                workoutId: workoutId,
                exerciseId: Value(exerciseLocalId),
                exerciseName: e.exerciseName,
                orderIndex: e.orderIndex,
                restSeconds: Value(e.restSeconds),
                circuitGroup: Value(e.circuitGroup),
                kind: Value(e.kind),
                routineExerciseId: Value(routineExerciseLocalId),
              ),
            );
        for (final s in e.sets) {
          final wsId = s.syncId;
          await _db
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

      for (final s in dto.heartRateSamples) {
        await _db.into(_db.heartRateSamples).insert(
              HeartRateSamplesCompanion.insert(
                workoutId: workoutId,
                measuredAtMs: s.tMs,
                bpm: s.bpm,
                accuracy: Value(s.accuracy),
              ),
              // A repeated timestamp in the payload must not abort the whole
              // apply on the composite key.
              mode: InsertMode.insertOrReplace,
            );
      }
      return true;
    });
  }

  /// Apply a workout tombstone: the deletion wins at version >= local, so the
  /// snapshot goes and the row stays as a versioned marker. Mirrors
  /// [_applyTombstone] for routines.
  Future<void> _applyWorkoutTombstone(WorkoutDto dto, Workout? existing) async {
    final deletedAt = DateTime.fromMillisecondsSinceEpoch(dto.deletedAtMs!);
    if (existing == null) {
      // Never seen this workout: persist the marker anyway, so a straggling
      // create at the same or lower version can't resurrect it.
      await _db
          .into(_db.workouts)
          .insert(
            WorkoutsCompanion.insert(
              syncId: dto.syncId,
              routineName: Value(dto.routineName),
              startedAt: DateTime.fromMillisecondsSinceEpoch(dto.startedAtMs),
              version: Value(dto.version),
              deletedAt: Value(deletedAt),
            ),
          );
      return;
    }
    // As in AppDatabase.deleteWorkout: the Workouts row survives as the
    // tombstone, so no cascade fires and every child has to go explicitly.
    await (_db.delete(
      _db.heartRateSamples,
    )..where((t) => t.workoutId.equals(dto.syncId))).go();
    await (_db.delete(
      _db.setCompletions,
    )..where((t) => t.workoutId.equals(dto.syncId))).go();
    // Cascades to workoutSets.
    await (_db.delete(
      _db.workoutExercises,
    )..where((t) => t.workoutId.equals(dto.syncId))).go();
    await (_db.update(
      _db.workouts,
    )..where((t) => t.syncId.equals(dto.syncId))).write(
      WorkoutsCompanion(
        version: Value(dto.version),
        deletedAt: Value(deletedAt),
      ),
    );
  }

  /// Generate a stable syncId for new rows that need one on the local side.
  String newSyncId() => _uuid.v4();
}
