import 'package:mcp_dart/mcp_dart.dart';

import 'package:gym_tracker/sync/sync_dtos.dart';
import '../user_scope.dart';

void registerListRoutines(McpServer server, UserScope scope) {
  server.registerTool(
    'list_routines',
    title: 'List routines',
    description:
        "Lists the user's workout routines with their exercises and planned "
        'sets, ordered by name.',
    inputSchema: ToolInputSchema(properties: {}),
    outputSchema: ToolOutputSchema(
      properties: {
        'routines': JsonSchema.array(
          items: JsonSchema.object(
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
          ),
        ),
      },
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: true,
      openWorldHint: false,
    ),
    callback: (args, extra) async {
      final routines = await _liveRoutines(scope);
      return CallToolResult(
        content: [TextContent(text: _summary(routines))],
        structuredContent: {'routines': routines.map(_json).toList()},
      );
    },
  );
}

Future<List<RoutineTemplateDto>> _liveRoutines(UserScope scope) async {
  final routines = [
    for (final doc in await scope.routines()) RoutineTemplateDto.fromJson(doc),
  ].where((r) => r.deletedAtMs == null).toList();
  return routines..sort((a, b) => a.name.compareTo(b.name));
}

String _summary(List<RoutineTemplateDto> routines) {
  if (routines.isEmpty) return 'No routines.';
  return routines
      .map(
        (r) =>
            '${r.name}: ${r.exercises.map((e) => e.exerciseName).join(', ')}',
      )
      .join('\n');
}

Map<String, Object?> _json(RoutineTemplateDto routine) => {
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
