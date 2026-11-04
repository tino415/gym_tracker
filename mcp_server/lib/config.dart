class ServerConfig {
  ServerConfig({
    required this.host,
    required this.port,
    required this.projectId,
    required this.firestoreRoot,
    required this.authRoot,
    required this.devToken,
    required this.devUid,
    required this.allowedHosts,
  });

  final String host;
  final int port;
  final String projectId;
  final Uri firestoreRoot;
  final Uri authRoot;
  final String devToken;
  final String? devUid;
  final Set<String> allowedHosts;

  factory ServerConfig.fromEnvironment(Map<String, String> env) {
    final firestoreHost = env['FIRESTORE_EMULATOR_HOST'];
    final authHost = env['FIREBASE_AUTH_EMULATOR_HOST'];
    if (firestoreHost == null || authHost == null) {
      throw StateError(
        'The dev token is accepted only against the emulators: set '
        'FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST '
        '(`firebase emulators:exec` and `just up` do).',
      );
    }
    final host = env['MCP_HOST'] ?? '0.0.0.0';
    return ServerConfig(
      host: host,
      port: int.parse(env['MCP_PORT'] ?? '4121'),
      projectId: env['GCLOUD_PROJECT'] ?? 'demo-gym-tracker',
      firestoreRoot: Uri.parse('http://$firestoreHost/'),
      authRoot: Uri.parse('http://$authHost/'),
      devToken: env['MCP_DEV_TOKEN'] ?? 'dev-token',
      devUid: env['MCP_DEV_UID'],
      allowedHosts: {
        'localhost',
        '127.0.0.1',
        '[::1]',
        ...?env['MCP_ALLOWED_HOSTS']?.split(','),
      },
    );
  }
}
