import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../user_scope.dart';

final routineSchema = JsonSchema.object(
  properties: {
    'id': JsonSchema.string(),
    'name': JsonSchema.string(),
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

Future<List<RoutineTemplateDto>> liveRoutines(UserScope scope) async {
  final routines = [
    for (final doc in await scope.routines()) RoutineTemplateDto.fromJson(doc),
  ].where((r) => r.deletedAtMs == null).toList();
  return routines..sort((a, b) => a.name.compareTo(b.name));
}

String routineSummary(RoutineTemplateDto r) =>
    '${r.name}: ${r.exercises.map((e) => e.exerciseName).join(', ')}';

Map<String, Object?> routineJson(RoutineTemplateDto routine) => {
  'id': routine.syncId,
  'name': routine.name,
  'exercises': [
    for (final e in routine.exercises)
      {
        'name': e.exerciseName,
        'kind': e.exerciseKind,
        'restSeconds': e.restSeconds,
        if (e.circuitGroup != null) 'circuitGroup': e.circuitGroup,
        'sets': [for (final s in e.plannedSets) _setJson(s)],
      },
  ],
};

Map<String, Object?> _setJson(PlannedSetDto set) => {
  if (set.targetReps != null) 'reps': set.targetReps,
  if (set.targetWeightKg != null) 'weightKg': set.targetWeightKg,
  if (set.targetSeconds != null) 'seconds': set.targetSeconds,
};
