import 'package:gym_tracker/data/exercise_params.dart';
import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../user_scope.dart';

final _setsSchema = JsonSchema.array(items: JsonSchema.object());

final routineSchema = JsonSchema.object(
  properties: {
    'id': JsonSchema.string(),
    'name': JsonSchema.string(),
    'version': JsonSchema.integer(),
    'exercises': JsonSchema.array(
      items: JsonSchema.object(
        properties: {
          'slotId': JsonSchema.string(),
          'exerciseId': JsonSchema.string(),
          'name': JsonSchema.string(),
          'kind': JsonSchema.string(),
          'restSeconds': JsonSchema.integer(),
          'circuitGroup': JsonSchema.integer(),
          'sets': _setsSchema,
          'alternatives': JsonSchema.array(
            items: JsonSchema.object(
              properties: {
                'alternativeId': JsonSchema.string(),
                'exerciseId': JsonSchema.string(),
                'name': JsonSchema.string(),
                'kind': JsonSchema.string(),
                'sets': _setsSchema,
              },
            ),
          ),
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
  'version': routine.version,
  'exercises': [
    for (final e in routine.exercises)
      {
        'slotId': e.syncId,
        'exerciseId': e.exerciseSyncId,
        'name': e.exerciseName,
        'kind': e.exerciseKind,
        'restSeconds': e.restSeconds,
        if (e.circuitGroup != null) 'circuitGroup': e.circuitGroup,
        'sets': _setsJson(e.plannedSets, e.exerciseParams),
        'alternatives': [
          for (final a in e.alternatives)
            {
              'alternativeId': a.syncId,
              'exerciseId': a.exerciseSyncId,
              'name': a.exerciseName,
              'kind': a.exerciseKind,
              'sets': _setsJson(a.plannedSets, a.exerciseParams),
            },
        ],
      },
  ],
};

List<Map<String, Object?>> _setsJson(
  List<PlannedSetDto> sets,
  List<ParamEntry> order,
) => [
  for (final s in [...sets]..sort((a, b) => a.setIndex.compareTo(b.setIndex)))
    _setJson(s, order),
];

Map<String, Object?> _setJson(PlannedSetDto set, List<ParamEntry> order) => {
  if (set.targetReps != null) 'reps': set.targetReps,
  if (set.targetWeightKg != null) 'weightKg': set.targetWeightKg,
  if (set.targetSeconds != null) 'seconds': set.targetSeconds,
  if (namedParamValues(set.targetParams, order) case final named?)
    'parameters': named,
};
