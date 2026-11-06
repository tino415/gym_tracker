import 'package:mcp_dart/mcp_dart.dart';

import '../user_scope.dart';

class ToolContext {
  ToolContext(this.scope, this.accountStillActive);

  final UserScope scope;
  final Future<bool> Function() accountStillActive;
}

/// What a read tool answers with: a line for the model to read, and the same
/// facts as data.
class ToolAnswer {
  ToolAnswer(this.summary, this.data);

  final String summary;
  final Map<String, Object?> data;
}

/// A refused call: shown to the model, flagged as an error.
class ToolRefusal implements Exception {
  ToolRefusal(this.message);

  final String message;
}

void registerReadTool(
  McpServer server,
  ToolContext context, {
  required String name,
  required String title,
  required String description,
  required Map<String, JsonSchema> input,
  required List<String> required,
  required Map<String, JsonSchema> output,
  required Future<ToolAnswer> Function(Map<String, dynamic> args) answer,
}) {
  server.registerTool(
    name,
    title: title,
    description: description,
    inputSchema: ToolInputSchema(properties: input, required: required),
    outputSchema: ToolOutputSchema(properties: output),
    annotations: const ToolAnnotations(
      readOnlyHint: true,
      openWorldHint: false,
    ),
    meta: {
      'securitySchemes': [
        {'type': 'oauth2'},
      ],
    },
    callback: (args, extra) async {
      if (!await context.accountStillActive()) return _signInAgain();
      try {
        final result = await answer(args);
        return CallToolResult(
          content: [TextContent(text: result.summary)],
          structuredContent: result.data,
        );
      } on ToolRefusal catch (refusal) {
        return CallToolResult(
          isError: true,
          content: [TextContent(text: refusal.message)],
        );
      }
    },
  );
}

CallToolResult _signInAgain() => CallToolResult(
  isError: true,
  content: [TextContent(text: 'The account is no longer signed in.')],
  meta: {
    'mcp/www_authenticate': ['Bearer error="invalid_token"'],
  },
);
