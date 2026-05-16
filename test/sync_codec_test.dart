import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/sync/sync_codec.dart';

void main() {
  group('WorkoutBundleMessage', () {
    test('round-trips through payload unchanged', () {
      final bundle = WorkoutBundleMessage([
        WorkoutTemplateDto(
          syncId: 'w-1',
          name: 'Push Day',
          version: 3,
          createdAtMs: 1700000000000,
          exercises: [
            WorkoutExerciseDto(
              syncId: 'we-1',
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
            WorkoutExerciseDto(
              syncId: 'we-2',
              exerciseSyncId: 'ex-2',
              exerciseName: 'Overhead Press',
              orderIndex: 1,
              restSeconds: 120,
              plannedSets: [],
            ),
          ],
        ),
      ]);

      final decoded = WorkoutBundleMessage.fromPayload(bundle.toPayload());

      expect(decoded.workouts, hasLength(1));
      final w = decoded.workouts.single;
      expect(w.syncId, 'w-1');
      expect(w.name, 'Push Day');
      expect(w.version, 3);
      expect(w.createdAtMs, 1700000000000);
      expect(w.exercises, hasLength(2));

      final e1 = w.exercises[0];
      expect(e1.syncId, 'we-1');
      expect(e1.exerciseName, 'Bench Press');
      expect(e1.restSeconds, 90);
      expect(e1.plannedSets, hasLength(2));
      expect(e1.plannedSets[0].targetReps, 10);
      expect(e1.plannedSets[1].targetWeightKg, 62.5);

      final e2 = w.exercises[1];
      expect(e2.exerciseName, 'Overhead Press');
      expect(e2.restSeconds, 120);
      expect(e2.plannedSets, isEmpty);
    });

    test('empty bundle round-trips', () {
      final bundle = WorkoutBundleMessage(const []);
      final decoded = WorkoutBundleMessage.fromPayload(bundle.toPayload());
      expect(decoded.workouts, isEmpty);
    });
  });

  group('SessionCompletedMessage', () {
    test('round-trips through payload unchanged', () {
      final msg = SessionCompletedMessage(
        SessionDto(
          syncId: 's-1',
          workoutSyncId: 'w-1',
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

      final decoded = SessionCompletedMessage.fromPayload(msg.toPayload());

      expect(decoded.session.syncId, 's-1');
      expect(decoded.session.workoutSyncId, 'w-1');
      expect(decoded.session.startedAtMs, 1700001000000);
      expect(decoded.session.endedAtMs, 1700004000000);
      expect(decoded.session.completions, hasLength(2));
      expect(decoded.session.completions[0].plannedSetSyncId, 'ps-1');
      expect(decoded.session.completions[1].actualReps, 7);
    });

    test('preserves null endedAtMs (in-progress session)', () {
      final msg = SessionCompletedMessage(
        SessionDto(
          syncId: 's-2',
          workoutSyncId: 'w-1',
          startedAtMs: 1700001000000,
          endedAtMs: null,
          completions: const [],
        ),
      );

      final decoded = SessionCompletedMessage.fromPayload(msg.toPayload());
      expect(decoded.session.endedAtMs, isNull);
    });
  });
}
