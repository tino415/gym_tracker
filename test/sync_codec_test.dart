import 'package:flutter_test/flutter_test.dart';
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
              supersetGroup: null,
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
              supersetGroup: 1,
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
      expect(e1.supersetGroup, isNull);
      expect(e1.plannedSets[0].targetReps, 10);
      expect(e1.plannedSets[0].targetSeconds, isNull);

      final e2 = r.exercises[1];
      expect(e2.exerciseKind, 'time');
      expect(e2.supersetGroup, 1);
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
              supersetGroup: null,
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
              supersetGroup: 1,
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
      expect(decoded.workout.exercises, hasLength(2));
      expect(decoded.workout.exercises[1].kind, 'time');
      expect(decoded.workout.exercises[1].supersetGroup, 1);
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
}
