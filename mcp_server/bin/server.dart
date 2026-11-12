import 'dart:io';

import 'package:gym_tracker_mcp/config.dart';
import 'package:gym_tracker_mcp/gym_mcp_server.dart';

Future<void> main() async {
  final config = ServerConfig.fromEnvironment(Platform.environment);
  final server = GymMcpServer(config, client: await config.backend.connect());
  await server.start();
  stdout.writeln(
    'GymTracker MCP listening on ${config.host}:${server.port}/mcp '
    '(${config.backend.runtimeType})',
  );
}
