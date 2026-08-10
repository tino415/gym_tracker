import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/sync/sync_codec.dart';

/// A guard on *what leaves the device*.
///
/// [WorkoutDto.toJson] is the payload the Firestore transport writes verbatim
/// to `users/{uid}/workouts/{syncId}`, so every key below — at any depth — is
/// personal data stored on a server the moment a user signs in. Some of it
/// (the heart-rate series) is health data, which Play treats as personal and
/// sensitive.
///
/// This is deliberately a test rather than a paragraph in CLAUDE.md: prose
/// describing a data flow goes stale silently, while a failing test arrives at
/// the moment the decision is being made. Adding a field to a workout DTO is
/// allowed — it just has to be a decision, not a side effect.
///
/// **If this test fails, before changing the expectation:** check whether
/// `web/privacy.html` still describes what is collected, and whether the Play
/// data-safety declaration still matches. A new field may also change the
/// answer to "is this sensitive data?".
///
/// Known gap: the Firestore-direct **web** build does not go through this
/// codec — `firestore_repositories.dart` builds its document maps itself, so
/// its shape is unguarded. Sharing the codec is a V2 task.
void main() {
  test('the synced workout payload carries exactly these fields', () {
    // Every optional field is populated, so nothing is missed by being null:
    // toJson emits keys unconditionally, but a nested list left empty would
    // hide the shape of its elements entirely.
    final dto = WorkoutDto(
      syncId: 'w1',
      routineSyncId: 'r1',
      routineName: 'Push day',
      startedAtMs: 1000,
      endedAtMs: 2000,
      version: 3,
      deletedAtMs: 3000,
      avgHeartRate: 120,
      maxHeartRate: 165,
      heartRateSamples: [HeartRateSampleDto(tMs: 1500, bpm: 130)],
      exercises: [
        WorkoutExerciseDto(
          syncId: 'we1',
          exerciseSyncId: 'e1',
          exerciseName: 'Bench press',
          kind: 'reps',
          orderIndex: 0,
          restSeconds: 90,
          circuitGroup: 1,
          routineExerciseSyncId: 're1',
          sets: [
            WorkoutSetDto(
              syncId: 'ws1',
              setIndex: 0,
              targetReps: 8,
              targetWeightKg: 60,
              targetSeconds: null,
            ),
          ],
        ),
      ],
      completions: [
        SetCompletionDto(
          syncId: 'c1',
          workoutSetSyncId: 'ws1',
          actualReps: 8,
          actualWeightKg: 60,
          actualSeconds: null,
          completedAtMs: 1800,
          avgHeartRate: 128,
          maxHeartRate: 150,
        ),
      ],
    );

    expect(_paths(dto.toJson()), {
      'syncId',
      'routineSyncId',
      'routineName',
      'startedAtMs',
      'endedAtMs',
      'version',
      'deletedAtMs',
      // Health data. See the note above before touching these.
      'avgHeartRate',
      'maxHeartRate',
      'heartRateSamples[].t',
      'heartRateSamples[].bpm',
      'exercises[].syncId',
      'exercises[].exerciseSyncId',
      'exercises[].exerciseName',
      'exercises[].kind',
      'exercises[].orderIndex',
      'exercises[].restSeconds',
      'exercises[].circuitGroup',
      'exercises[].routineExerciseSyncId',
      'exercises[].sets[].syncId',
      'exercises[].sets[].setIndex',
      'exercises[].sets[].targetReps',
      'exercises[].sets[].targetWeightKg',
      'exercises[].sets[].targetSeconds',
      'completions[].syncId',
      'completions[].workoutSetSyncId',
      'completions[].actualReps',
      'completions[].actualWeightKg',
      'completions[].actualSeconds',
      'completions[].completedAtMs',
      'completions[].avgHeartRate',
      'completions[].maxHeartRate',
    });
  });

  test('a tombstone carries no training data', () {
    // A deletion travels as a full document, so it is worth knowing that it
    // ships an id, timestamps and a name — and no sets, completions or heart
    // rate.
    final json = WorkoutDto.tombstone(
      syncId: 'w1',
      version: 4,
      deletedAtMs: 5000,
      startedAtMs: 1000,
      routineName: 'Push day',
    ).toJson();

    expect(json['exercises'], isEmpty);
    expect(json['completions'], isEmpty);
    expect(json['heartRateSamples'], isEmpty);
    expect(json['avgHeartRate'], isNull);
    expect(json['maxHeartRate'], isNull);
  });
}

/// Every key in [json], depth-first, as dotted paths with `[]` marking a list.
/// Paths rather than bare names so a failure says *where* the new field is.
Set<String> _paths(Map<String, Object?> json, [String prefix = '']) {
  final out = <String>{};
  for (final entry in json.entries) {
    final path = '$prefix${entry.key}';
    final value = entry.value;
    if (value is Map) {
      out.addAll(_paths(value.cast<String, Object?>(), '$path.'));
    } else if (value is List && value.isNotEmpty && value.first is Map) {
      for (final item in value) {
        out.addAll(_paths((item as Map).cast<String, Object?>(), '$path[].'));
      }
    } else {
      out.add(path);
    }
  }
  return out;
}
