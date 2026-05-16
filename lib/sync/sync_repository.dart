import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'sync_codec.dart';

const _uuid = Uuid();

class SyncRepository {
  SyncRepository(this._db);

  final AppDatabase _db;

  Future<List<WorkoutTemplateDto>> exportAllWorkouts() async {
    final workouts = await _db.select(_db.workouts).get();
    final result = <WorkoutTemplateDto>[];
    for (final w in workouts) {
      final full = await _db.loadFullWorkout(w.id);
      if (full != null) {
        result.add(WorkoutTemplateDto.fromFullWorkout(full));
      }
    }
    return result;
  }

  /// Apply an inbound workout bundle to the local DB. Workouts already present
  /// at a >= version are skipped; older or missing ones are upserted (whole
  /// template replaced, since templates are small).
  Future<void> applyWorkoutBundle(WorkoutBundleMessage bundle) async {
    await _db.transaction(() async {
      for (final dto in bundle.workouts) {
        await _upsertOneWorkout(dto);
      }
    });
  }

  Future<void> _upsertOneWorkout(WorkoutTemplateDto dto) async {
    final existing = await (_db.select(_db.workouts)
          ..where((t) => t.syncId.equals(dto.syncId)))
        .getSingleOrNull();
    if (existing != null && existing.version >= dto.version) return;

    if (existing != null) {
      // Replace existing — cascade deletes wipe child workout_exercises and
      // planned_sets, then we re-insert.
      await (_db.delete(_db.workouts)..where((t) => t.id.equals(existing.id)))
          .go();
    }

    final workoutId = await _db.into(_db.workouts).insert(
          WorkoutsCompanion.insert(
            syncId: dto.syncId,
            name: dto.name,
            createdAt: DateTime.fromMillisecondsSinceEpoch(dto.createdAtMs),
            version: Value(dto.version),
          ),
        );

    for (final e in dto.exercises) {
      final exerciseId = await _findOrCreateExerciseBySyncId(
        syncId: e.exerciseSyncId,
        name: e.exerciseName,
      );
      final weId = await _db.into(_db.workoutExercises).insert(
            WorkoutExercisesCompanion.insert(
              syncId: e.syncId,
              workoutId: workoutId,
              exerciseId: exerciseId,
              orderIndex: e.orderIndex,
              restSeconds: Value(e.restSeconds),
            ),
          );
      for (final s in e.plannedSets) {
        await _db.into(_db.plannedSets).insert(
              PlannedSetsCompanion.insert(
                syncId: s.syncId,
                workoutExerciseId: weId,
                setIndex: s.setIndex,
                targetReps: s.targetReps,
                targetWeightKg: s.targetWeightKg,
              ),
            );
      }
    }
  }

  Future<int> _findOrCreateExerciseBySyncId({
    required String syncId,
    required String name,
  }) async {
    final existing = await (_db.select(_db.exercises)
          ..where((t) => t.syncId.equals(syncId)))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    // Same name may already exist locally with a different syncId — reuse the
    // local row but keep the syncId stable on our side. Otherwise create new.
    final byName = await (_db.select(_db.exercises)
          ..where((t) => t.name.equals(name)))
        .getSingleOrNull();
    if (byName != null) return byName.id;
    return _db.into(_db.exercises).insert(
          ExercisesCompanion.insert(
            syncId: syncId,
            name: name,
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Export one session (with its completions) to a DTO for outbound sync.
  Future<SessionDto?> exportSession(int sessionId) async {
    final session = await (_db.select(_db.sessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (session == null) return null;
    final workout = await (_db.select(_db.workouts)
          ..where((t) => t.id.equals(session.workoutId)))
        .getSingle();
    final completions = await _db.completionsForSession(sessionId);
    final dtos = <SetCompletionDto>[];
    for (final c in completions) {
      final ps = await (_db.select(_db.plannedSets)
            ..where((t) => t.id.equals(c.plannedSetId)))
          .getSingleOrNull();
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
    return SessionDto(
      syncId: session.syncId,
      workoutSyncId: workout.syncId,
      startedAtMs: session.startedAt.millisecondsSinceEpoch,
      endedAtMs: session.endedAt?.millisecondsSinceEpoch,
      completions: dtos,
    );
  }

  /// Apply an inbound session message. Append-only on syncId — if a session
  /// with the same syncId already exists, it is skipped. Completions whose
  /// plannedSet can't be resolved are dropped (the corresponding workout was
  /// not synced yet on this device).
  Future<void> applySessionCompleted(SessionCompletedMessage msg) async {
    final dto = msg.session;
    await _db.transaction(() async {
      final existing = await (_db.select(_db.sessions)
            ..where((t) => t.syncId.equals(dto.syncId)))
          .getSingleOrNull();
      if (existing != null) return;
      final workout = await (_db.select(_db.workouts)
            ..where((t) => t.syncId.equals(dto.workoutSyncId)))
          .getSingleOrNull();
      if (workout == null) return; // can't link without a template
      final sessionId = await _db.into(_db.sessions).insert(
            SessionsCompanion.insert(
              syncId: dto.syncId,
              workoutId: workout.id,
              startedAt: DateTime.fromMillisecondsSinceEpoch(dto.startedAtMs),
              endedAt: Value(
                dto.endedAtMs == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(dto.endedAtMs!),
              ),
            ),
          );
      for (final c in dto.completions) {
        final ps = await (_db.select(_db.plannedSets)
              ..where((t) => t.syncId.equals(c.plannedSetSyncId)))
            .getSingleOrNull();
        if (ps == null) continue;
        await _db.into(_db.setCompletions).insert(
              SetCompletionsCompanion.insert(
                syncId: c.syncId,
                sessionId: sessionId,
                plannedSetId: ps.id,
                actualReps: c.actualReps,
                actualWeightKg: c.actualWeightKg,
                completedAt:
                    DateTime.fromMillisecondsSinceEpoch(c.completedAtMs),
              ),
            );
      }
    });
  }

  /// Generate a stable syncId for new rows that need one on the local side.
  String newSyncId() => _uuid.v4();
}
