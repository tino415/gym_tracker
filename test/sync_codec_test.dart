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
              orderIndex: 0,
              restSeconds: 90,
              plannedSets: [
                PlannedSetDto(
                  syncId: 'ps-1',
                  setIndex: 0,
                  targetReps: 10,
                  targetWeightKg: 60.0,
                ),
                PlannedSetDto(
                  syncId: 'ps-2',
                  setIndex: 1,
                  targetReps: 8,
                  targetWeightKg: 62.5,
                ),
              ],
            ),
            RoutineExerciseDto(
              syncId: 're-2',
              exerciseSyncId: 'ex-2',
              exerciseName: 'Overhead Press',
              orderIndex: 1,
              restSeconds: 120,
              plannedSets: [],
            ),
          ],
        ),
      ]);

      final decoded = RoutineBundleMessage.fromPayload(bundle.toPayload());

      expect(decoded.routines, hasLength(1));
      final r = decoded.routines.single;
      expect(r.syncId, 'r-1');
      expect(r.name, 'Push Day');
      expect(r.version, 3);
      expect(r.createdAtMs, 1700000000000);
      expect(r.exercises, hasLength(2));

      final e1 = r.exercises[0];
      expect(e1.syncId, 're-1');
      expect(e1.exerciseName, 'Bench Press');
      expect(e1.restSeconds, 90);
      expect(e1.plannedSets, hasLength(2));
      expect(e1.plannedSets[0].targetReps, 10);
      expect(e1.plannedSets[1].targetWeightKg, 62.5);

      final e2 = r.exercises[1];
      expect(e2.exerciseName, 'Overhead Press');
      expect(e2.restSeconds, 120);
      expect(e2.plannedSets, isEmpty);
    });

    test('empty bundle round-trips', () {
      final bundle = RoutineBundleMessage(const []);
      final decoded = RoutineBundleMessage.fromPayload(bundle.toPayload());
      expect(decoded.routines, isEmpty);
    });
  });

  group('WorkoutCompletedMessage', () {
    test('round-trips through payload unchanged', () {
      final msg = WorkoutCompletedMessage(
        WorkoutDto(
          syncId: 'w-1',
          routineSyncId: 'r-1',
          startedAtMs: 1700001000000,
          endedAtMs: 1700004000000,
          completions: [
            SetCompletionDto(
              syncId: 'c-1',
              plannedSetSyncId: 'ps-1',
              actualReps: 10,
              actualWeightKg: 60.0,
              completedAtMs: 1700001060000,
            ),
            SetCompletionDto(
              syncId: 'c-2',
              plannedSetSyncId: 'ps-2',
              actualReps: 7,
              actualWeightKg: 62.5,
              completedAtMs: 1700001180000,
            ),
          ],
        ),
      );

      final decoded = WorkoutCompletedMessage.fromPayload(msg.toPayload());

      expect(decoded.workout.syncId, 'w-1');
      expect(decoded.workout.routineSyncId, 'r-1');
      expect(decoded.workout.startedAtMs, 1700001000000);
      expect(decoded.workout.endedAtMs, 1700004000000);
      expect(decoded.workout.completions, hasLength(2));
      expect(decoded.workout.completions[0].plannedSetSyncId, 'ps-1');
      expect(decoded.workout.completions[1].actualReps, 7);
    });

    test('preserves null endedAtMs (in-progress workout)', () {
      final msg = WorkoutCompletedMessage(
        WorkoutDto(
          syncId: 'w-2',
          routineSyncId: 'r-1',
          startedAtMs: 1700001000000,
          endedAtMs: null,
          completions: const [],
        ),
      );

      final decoded = WorkoutCompletedMessage.fromPayload(msg.toPayload());
      expect(decoded.workout.endedAtMs, isNull);
    });
  });
}
