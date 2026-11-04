import 'package:mcp_dart/mcp_dart.dart';

import 'read_tool.dart';
import 'workout_json.dart';

void registerGetWorkout(McpServer server, ToolContext context) {
  registerReadTool(
    server,
    context,
    name: 'get_workout',
    title: 'Get a workout',
    description:
        'One workout with every exercise and set: the targets and what was '
        'actually done. Take the id from list_workouts.',
    input: {'id': JsonSchema.string(description: 'The workout id.')},
    required: ['id'],
    output: {'workout': workoutSchema},
    answer: (args) async {
      final document = await context.scope.workout(args['id'] as String);
      if (document == null || document['deletedAtMs'] != null) {
        throw ToolRefusal('No workout with that id.');
      }
      final workout = workoutFromDocument(document);
      return ToolAnswer(workoutDetail(workout), {
        'workout': workoutJson(workout),
      });
    },
  );
}
