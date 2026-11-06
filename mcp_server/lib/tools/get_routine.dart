import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'read_tool.dart';
import 'routine_json.dart';

void registerGetRoutine(McpServer server, ToolContext context) {
  registerReadTool(
    server,
    context,
    name: 'get_routine',
    title: 'Get a routine',
    description:
        'One routine with its exercises and planned sets. Take the id from '
        'list_routines.',
    input: {'id': JsonSchema.string(description: 'The routine id.')},
    required: ['id'],
    output: {'routine': routineSchema},
    answer: (args) async {
      final document = await context.scope.routine(args['id'] as String);
      final routine = document == null
          ? null
          : RoutineTemplateDto.fromJson(document);
      if (routine == null || routine.deletedAtMs != null) {
        throw ToolRefusal('No routine with that id.');
      }
      return ToolAnswer(routineSummary(routine), {
        'routine': routineJson(routine),
      });
    },
  );
}
