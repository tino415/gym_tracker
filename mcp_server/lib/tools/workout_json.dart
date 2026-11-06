import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:mcp_dart/mcp_dart.dart';

final workoutSummarySchema = JsonSchema.object(
  properties: {
    'id': JsonSchema.string(),
    'routineName': JsonSchema.string(),
    'startedAt': JsonSchema.string(),
    'endedAt': JsonSchema.string(),
    'exercises': JsonSchema.array(items: JsonSchema.string()),
    'completedSets': JsonSchema.integer(),
  },
);

final workoutSchema = JsonSchema.object(
  properties: {
    'id': JsonSchema.string(),
    'routineName': JsonSchema.string(),
    'startedAt': JsonSchema.string(),
    'endedAt': JsonSchema.string(),
    'exercises': JsonSchema.array(
      items: JsonSchema.object(
        properties: {
          'name': JsonSchema.string(),
          'kind': JsonSchema.string(),
          'restSeconds': JsonSchema.integer(),
          'circuitGroup': JsonSchema.integer(),
          'sets': JsonSchema.array(items: JsonSchema.object()),
        },
      ),
    ),
  },
);

WorkoutDto workoutFromDocument(Map<String, Object?> document) =>
    WorkoutDto.fromJson(document);

String isoUtc(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

int completedSets(WorkoutDto w) => w.completions.length;

Map<String, Object?> workoutSummaryJson(WorkoutDto w) => {
  'id': w.syncId,
  if (w.routineName != null) 'routineName': w.routineName,
  'startedAt': isoUtc(w.startedAtMs),
  if (w.endedAtMs != null) 'endedAt': isoUtc(w.endedAtMs!),
  'exercises': [for (final e in w.exercises) e.exerciseName],
  'completedSets': completedSets(w),
};

String workoutSummaryLine(WorkoutDto w) =>
    '${isoUtc(w.startedAtMs).substring(0, 10)} ${w.routineName ?? 'Workout'}: '
    '${w.exercises.map((e) => e.exerciseName).join(', ')} '
    '(${completedSets(w)} sets)';

Map<String, Object?> workoutJson(WorkoutDto w) {
  final done = {for (final c in w.completions) c.workoutSetSyncId: c};
  return {
    ...workoutSummaryJson(w)
      ..remove('exercises')
      ..remove('completedSets'),
    'exercises': [
      for (final e in w.exercises)
        {
          'name': e.exerciseName,
          'kind': e.kind,
          'restSeconds': e.restSeconds,
          if (e.circuitGroup != null) 'circuitGroup': e.circuitGroup,
          'sets': [
            for (final s in e.sets)
              {
                if (s.targetReps != null) 'targetReps': s.targetReps,
                if (s.targetWeightKg != null)
                  'targetWeightKg': s.targetWeightKg,
                if (s.targetSeconds != null) 'targetSeconds': s.targetSeconds,
                if (done[s.syncId] case final c?) ...{
                  if (c.actualReps != null) 'reps': c.actualReps,
                  if (c.actualWeightKg != null) 'weightKg': c.actualWeightKg,
                  if (c.actualSeconds != null) 'seconds': c.actualSeconds,
                  'completedAt': isoUtc(c.completedAtMs),
                },
              },
          ],
        },
    ],
  };
}

String workoutDetail(WorkoutDto w) {
  final done = {for (final c in w.completions) c.workoutSetSyncId: c};
  final lines = [workoutSummaryLine(w)];
  for (final e in w.exercises) {
    final sets = [
      for (final s in e.sets)
        if (done[s.syncId] case final c?)
          e.kind == 'time'
              ? '${c.actualSeconds}s'
              : '${c.actualReps} x ${c.actualWeightKg ?? 0} kg',
    ];
    lines.add(
      '${e.exerciseName}: ${sets.isEmpty ? 'no sets done' : sets.join(', ')}',
    );
  }
  return lines.join('\n');
}
