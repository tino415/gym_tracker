import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'read_tool.dart';

const _maxMatches = 50;

void registerFindExercises(McpServer server, ToolContext context) {
  registerReadTool(
    server,
    context,
    name: 'find_exercises',
    title: 'Find exercises',
    description:
        'Finds exercises in the user\'s library whose name contains the '
        'query, ignoring case.',
    input: {
      'query': JsonSchema.string(description: 'Part of an exercise name.'),
    },
    required: ['query'],
    output: {
      'exercises': JsonSchema.array(
        items: JsonSchema.object(
          properties: {
            'id': JsonSchema.string(),
            'name': JsonSchema.string(),
            'kind': JsonSchema.string(),
          },
        ),
      ),
    },
    answer: (args) async {
      final query = (args['query'] as String).trim().toLowerCase();
      final matches =
          [
                for (final doc in await context.scope.exercises())
                  ExerciseDto.fromJson(doc),
              ]
              .where((e) => e.deletedAtMs == null)
              .where((e) => e.name.toLowerCase().contains(query))
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      final shown = matches.take(_maxMatches).toList();
      return ToolAnswer(
        shown.isEmpty
            ? 'No exercises match.'
            : shown.map((e) => '${e.name} (${e.kind})').join('\n'),
        {
          'exercises': [
            for (final e in shown)
              {'id': e.syncId, 'name': e.name, 'kind': e.kind},
          ],
        },
      );
    },
  );
}
