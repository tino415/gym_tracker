import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart' show exerciseKindReps, exerciseKindTime;
import 'package:gym_tracker/sync/sync_codec.dart';

void main() {
  group('RoutineBundleMessage', () {
    test('round-trips through payload unchanged', () {
      final bundle = RoutineBundleMessage([
        RoutineTemplateDto(
          syncId: 'r-1',
          name: 'Push Day',
          version: 3,
          createdAtMs: 1700000000000,
          exercises: [
            RoutineExerciseDto(
              syncId: 're-1',
              exerciseSyncId: 'ex-1',
              exerciseName: 'Bench Press',
              exerciseKind: 'reps',
              orderIndex: 0,
              restSeconds: 90,
              circuitGroup: null,
              plannedSets: [
                PlannedSetDto(
                  syncId: 'ps-1',
                  setIndex: 0,
                  targetReps: 10,
                  targetWeightKg: 60.0,
                  targetSeconds: null,
                ),
                PlannedSetDto(
                  syncId: 'ps-2',
                  setIndex: 1,
                  targetReps: 8,
                  targetWeightKg: 62.5,
                  targetSeconds: null,
                ),
              ],
            ),
            RoutineExerciseDto(
              syncId: 're-2',
              exerciseSyncId: 'ex-2',
              exerciseName: 'Plank',
              exerciseKind: 'time',
              orderIndex: 1,
              restSeconds: 120,
              circuitGroup: 1,
              plannedSets: [
                PlannedSetDto(
                  syncId: 'ps-3',
                  setIndex: 0,
                  targetReps: null,
                  targetWeightKg: null,
                  targetSeconds: 30,
                ),
              ],
            ),
          ],
        ),
      ]);

      final decoded = RoutineBundleMessage.fromPayload(bundle.toPayload());

      expect(decoded.routines, hasLength(1));
      final r = decoded.routines.single;
      expect(r.syncId, 'r-1');
      expect(r.exercises, hasLength(2));

      final e1 = r.exercises[0];
      expect(e1.exerciseKind, 'reps');
      expect(e1.circuitGroup, isNull);
      expect(e1.plannedSets[0].targetReps, 10);
      expect(e1.plannedSets[0].targetSeconds, isNull);

      final e2 = r.exercises[1];
      expect(e2.exerciseKind, 'time');
      expect(e2.circuitGroup, 1);
      expect(e2.plannedSets.single.targetSeconds, 30);
      expect(e2.plannedSets.single.targetReps, isNull);
    });

    test('empty bundle round-trips', () {
      final bundle = RoutineBundleMessage(const []);
      final decoded = RoutineBundleMessage.fromPayload(bundle.toPayload());
      expect(decoded.routines, isEmpty);
    });
  });

  group('WorkoutCompletedMessage', () {
    test('round-trips snapshot + completions', () {
      final msg = WorkoutCompletedMessage(
        WorkoutDto(
          syncId: 'w-1',
          routineSyncId: 'r-1',
          routineName: 'Push Day',
          startedAtMs: 1700001000000,
          endedAtMs: 1700004000000,
          exercises: [
            WorkoutExerciseDto(
              syncId: 'we-1',
              exerciseSyncId: 'ex-1',
              exerciseName: 'Bench Press',
              kind: 'reps',
              orderIndex: 0,
              restSeconds: 90,
              circuitGroup: null,
              sets: [
                WorkoutSetDto(
                  syncId: 'ws-1',
                  setIndex: 0,
                  targetReps: 10,
                  targetWeightKg: 60.0,
                  targetSeconds: null,
                ),
              ],
            ),
            WorkoutExerciseDto(
              syncId: 'we-2',
              exerciseSyncId: null,
              exerciseName: 'Plank',
              kind: 'time',
              orderIndex: 1,
              restSeconds: 60,
              circuitGroup: 1,
              sets: [
                WorkoutSetDto(
                  syncId: 'ws-2',
                  setIndex: 0,
                  targetReps: null,
                  targetWeightKg: null,
                  targetSeconds: 30,
                ),
              ],
            ),
          ],
          completions: [
            SetCompletionDto(
              syncId: 'c-1',
              workoutSetSyncId: 'ws-1',
              actualReps: 10,
              actualWeightKg: 60.0,
              actualSeconds: null,
              completedAtMs: 1700001060000,
            ),
            SetCompletionDto(
              syncId: 'c-2',
              workoutSetSyncId: 'ws-2',
              actualReps: null,
              actualWeightKg: null,
              actualSeconds: 40,
              completedAtMs: 1700001180000,
            ),
          ],
        ),
      );

      final decoded = WorkoutCompletedMessage.fromPayload(msg.toPayload());

      expect(decoded.workout.syncId, 'w-1');
      expect(decoded.workout.routineSyncId, 'r-1');
      expect(decoded.workout.routineName, 'Push Day');
      expect(decoded.workout.exercises, hasLength(2));
      expect(decoded.workout.exercises[1].kind, 'time');
      expect(decoded.workout.exercises[1].circuitGroup, 1);
      expect(decoded.workout.exercises[1].sets.single.targetSeconds, 30);

      expect(decoded.workout.completions, hasLength(2));
      expect(decoded.workout.completions[0].workoutSetSyncId, 'ws-1');
      expect(decoded.workout.completions[0].actualReps, 10);
      expect(decoded.workout.completions[1].actualSeconds, 40);
      expect(decoded.workout.completions[1].actualReps, isNull);
    });

    test('preserves null endedAtMs and missing routine link', () {
      final msg = WorkoutCompletedMessage(
        WorkoutDto(
          syncId: 'w-2',
          routineSyncId: null,
          startedAtMs: 1700001000000,
          endedAtMs: null,
          exercises: const [],
          completions: const [],
        ),
      );

      final decoded = WorkoutCompletedMessage.fromPayload(msg.toPayload());
      expect(decoded.workout.endedAtMs, isNull);
      expect(decoded.workout.routineSyncId, isNull);
    });
  });

  group('RoutineDeletedMessage', () {
    test('round-trips sync ids through payload', () {
      final decoded = RoutineDeletedMessage.fromPayload(
        const RoutineDeletedMessage(['a', 'b']).toPayload(),
      );
      expect(decoded.syncIds, ['a', 'b']);
    });

    test('skips non-string ids instead of throwing on a malformed payload', () {
      final decoded = RoutineDeletedMessage.fromPayload({
        'syncIds': <Object?>['keep-1', 42, null, 'keep-2'],
      });
      expect(decoded.syncIds, ['keep-1', 'keep-2']);
    });

    test('tolerates a missing syncIds key', () {
      final decoded = RoutineDeletedMessage.fromPayload(const {});
      expect(decoded.syncIds, isEmpty);
    });
  });

  group('ExerciseBundleMessage', () {
    test('round-trips live exercises and tombstones through payload', () {
      final msg = ExerciseBundleMessage([
        ExerciseDto(
          syncId: 'ex-1',
          name: 'Bench Press',
          kind: exerciseKindReps,
          version: 3,
          createdAtMs: 1000,
          muscleSyncIds: const ['muscle:chest', 'muscle:triceps'],
        ),
        ExerciseDto(
          syncId: 'ex-2',
          name: 'Plank',
          kind: exerciseKindTime,
          version: 5,
          createdAtMs: 2000,
          deletedAtMs: 9999,
        ),
      ]);

      final decoded = ExerciseBundleMessage.fromPayload(msg.toPayload());
      expect(decoded.exercises, hasLength(2));

      final live = decoded.exercises[0];
      expect(live.syncId, 'ex-1');
      expect(live.kind, exerciseKindReps);
      expect(live.version, 3);
      expect(live.muscleSyncIds, ['muscle:chest', 'muscle:triceps']);
      expect(live.deletedAtMs, isNull);

      final tomb = decoded.exercises[1];
      expect(tomb.syncId, 'ex-2');
      expect(tomb.kind, exerciseKindTime);
      expect(tomb.deletedAtMs, 9999);
      expect(tomb.muscleSyncIds, isEmpty);
    });
  });

  group('WorkoutDto versioning', () {
    WorkoutDto live({int version = 1, int? deletedAtMs}) => WorkoutDto(
      syncId: 'w1',
      routineSyncId: 'r1',
      routineName: 'Push',
      startedAtMs: 1000,
      endedAtMs: 2000,
      version: version,
      deletedAtMs: deletedAtMs,
      exercises: const [],
      completions: const [],
    );

    test('round-trips version and deletedAtMs', () {
      final json = live(version: 7, deletedAtMs: 9000).toJson();
      final back = WorkoutDto.fromJson(json);
      expect(back.version, 7);
      expect(back.deletedAtMs, 9000);
    });

    test('a live workout emits deletedAtMs as an explicit null', () {
      // The Firestore content compare needs the same key set on both sides.
      final json = live().toJson();
      expect(json.containsKey('deletedAtMs'), isTrue);
      expect(json['deletedAtMs'], isNull);
    });

    test('a legacy doc without version reads as version 1', () {
      final json = live(version: 4).toJson()
        ..remove('version')
        ..remove('deletedAtMs');
      final back = WorkoutDto.fromJson(json);
      expect(back.version, 1);
      expect(back.deletedAtMs, isNull);
    });

    test('tombstone carries no snapshot', () {
      final tomb = WorkoutDto.tombstone(
        syncId: 'w1',
        version: 3,
        deletedAtMs: 5000,
        startedAtMs: 1000,
      );
      expect(tomb.exercises, isEmpty);
      expect(tomb.completions, isEmpty);
      expect(tomb.routineSyncId, isNull);
      expect(WorkoutDto.fromJson(tomb.toJson()).deletedAtMs, 5000);
    });
  });

  group('pre-v15 supersetGroup key', () {
    // Documents written before the rename keep the old key until something
    // rewrites them, and past workout docs never will — their version is
    // frozen. Reading must still see the grouping.
    Map<String, Object?> routineExerciseJson(Map<String, Object?> groupKeys) => {
      'syncId': 're-1',
      'exerciseSyncId': 'ex-1',
      'exerciseName': 'Bench',
      'exerciseKind': exerciseKindReps,
      'orderIndex': 0,
      'restSeconds': 90,
      ...groupKeys,
      'plannedSets': <Object?>[],
    };

    test('the old key is read when the new one is absent', () {
      final dto = RoutineExerciseDto.fromJson(
        routineExerciseJson({'supersetGroup': 2}),
      );
      expect(dto.circuitGroup, 2);
    });

    test('the new key wins when both are present', () {
      final dto = RoutineExerciseDto.fromJson(
        routineExerciseJson({'supersetGroup': 2, 'circuitGroup': 5}),
      );
      expect(dto.circuitGroup, 5);
    });

    test('an explicit null on the new key is not overridden by the old one', () {
      // The web edits documents in place, so ungrouping writes
      // `circuitGroup: null` while a stale `supersetGroup` is still there. A
      // `??` fallback would revive the group that was just removed.
      final dto = RoutineExerciseDto.fromJson(
        routineExerciseJson({'supersetGroup': 2, 'circuitGroup': null}),
      );
      expect(dto.circuitGroup, isNull);
    });

    test('workout snapshots read the old key too', () {
      final dto = WorkoutExerciseDto.fromJson({
        'syncId': 'we-1',
        'exerciseSyncId': 'ex-1',
        'exerciseName': 'Bench',
        'kind': exerciseKindReps,
        'orderIndex': 0,
        'restSeconds': 90,
        'supersetGroup': 3,
        'sets': <Object?>[],
      });
      expect(dto.circuitGroup, 3);
    });
  });
}
