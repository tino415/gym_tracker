import 'package:mcp_dart/mcp_dart.dart';

import 'routine_json.dart';
import 'read_tool.dart';

void registerListRoutines(McpServer server, ToolContext context) {
  registerReadTool(
    server,
    context,
    name: 'list_routines',
    title: 'List routines',
    description:
        "Lists the user's workout routines with their exercises and planned "
        'sets, ordered by name.',
    input: {},
    required: [],
    output: {'routines': JsonSchema.array(items: routineSchema)},
    answer: (args) async {
      final routines = await liveRoutines(context.scope);
      return ToolAnswer(
        routines.isEmpty
            ? 'No routines.'
            : routines.map(routineSummary).join('\n'),
        {'routines': routines.map(routineJson).toList()},
      );
    },
  );
}
