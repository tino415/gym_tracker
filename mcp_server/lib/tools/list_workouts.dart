import 'package:mcp_dart/mcp_dart.dart';

import 'read_tool.dart';
import 'workout_json.dart';

const maxWorkouts = 50;

void registerListWorkouts(McpServer server, ToolContext context) {
  registerReadTool(
    server,
    context,
    name: 'list_workouts',
    title: 'List workouts',
    description:
        'Lists the user\'s workouts, newest first, with the exercises done '
        'and the number of completed sets. Use get_workout for the sets. '
        'since and until are ISO 8601 dates or timestamps.',
    input: {
      'since': JsonSchema.string(
        description: 'Only workouts started at or after this.',
      ),
      'until': JsonSchema.string(
        description: 'Only workouts started at or before this.',
      ),
      'limit': JsonSchema.integer(
        minimum: 1,
        maximum: maxWorkouts,
        description: 'How many to return, default 20.',
      ),
    },
    required: [],
    output: {'workouts': JsonSchema.array(items: workoutSummarySchema)},
    answer: (args) async {
      final documents = await context.scope.workouts(
        sinceMs: _parseTime(args['since'], 'since'),
        untilMs: _parseTime(args['until'], 'until'),
        limit: _parseLimit(args['limit']),
      );
      final workouts = documents.map(workoutFromDocument).toList();
      return ToolAnswer(
        workouts.isEmpty
            ? 'No workouts.'
            : workouts.map(workoutSummaryLine).join('\n'),
        {'workouts': workouts.map(workoutSummaryJson).toList()},
      );
    },
  );
}

int? _parseTime(Object? value, String name) {
  if (value == null) return null;
  final parsed = DateTime.tryParse(value as String);
  if (parsed == null) {
    throw ToolRefusal('$name is not an ISO 8601 date: $value');
  }
  return parsed.millisecondsSinceEpoch;
}

int _parseLimit(Object? value) {
  final limit = (value as num?)?.toInt() ?? 20;
  if (limit < 1 || limit > maxWorkouts) {
    throw ToolRefusal('limit must be between 1 and $maxWorkouts.');
  }
  return limit;
}
