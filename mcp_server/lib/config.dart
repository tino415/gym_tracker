import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'emulator_client.dart';

class ServerConfig {
  ServerConfig({
    required this.host,
    required this.port,
    required this.projectId,
    required this.backend,
    required this.token,
    required this.allowedHosts,
    this.requestsPerMinute = 60,
    this.requestsPerDay = 1000,
  });

  final String host;
  final int port;
  final String projectId;
  final Backend backend;
  final StaticToken token;
  final Set<String> allowedHosts;
  final int requestsPerMinute;
  final int requestsPerDay;

  factory ServerConfig.fromEnvironment(Map<String, String> env) {
    final firestoreHost = env['FIRESTORE_EMULATOR_HOST'];
    final authHost = env['FIREBASE_AUTH_EMULATOR_HOST'];
    if (firestoreHost != null && authHost != null) {
      return ServerConfig._forEmulators(env, firestoreHost, authHost);
    }
    return ServerConfig._forGoogleCloud(env);
  }

  factory ServerConfig._forEmulators(
    Map<String, String> env,
    String firestoreHost,
    String authHost,
  ) => ServerConfig(
    host: env['MCP_HOST'] ?? '0.0.0.0',
    port: int.parse(env['MCP_PORT'] ?? '4121'),
    projectId: env['GCLOUD_PROJECT'] ?? 'demo-gym-tracker',
    backend: EmulatorBackend(firestoreHost: firestoreHost, authHost: authHost),
    token: StaticToken(env['MCP_DEV_TOKEN'] ?? 'dev-token', env['MCP_DEV_UID']),
    allowedHosts: {..._loopbackHosts, ...?env['MCP_ALLOWED_HOSTS']?.split(',')},
  );

  factory ServerConfig._forGoogleCloud(Map<String, String> env) {
    const required = [
      'GOOGLE_CLOUD_PROJECT',
      'MCP_PERSONAL_TOKEN',
      'MCP_PERSONAL_UID',
      'MCP_ALLOWED_HOSTS',
    ];
    final missing = required.where((name) => env[name] == null).toList();
    if (missing.isNotEmpty) {
      throw StateError(
        'Without FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST the '
        'server reads production, which needs ${missing.join(', ')}.',
      );
    }
    final token = env['MCP_PERSONAL_TOKEN']!;
    if (token.length < _minimumPersonalTokenLength) {
      throw StateError(
        'MCP_PERSONAL_TOKEN must be at least $_minimumPersonalTokenLength '
        'characters.',
      );
    }
    return ServerConfig(
      host: env['MCP_HOST'] ?? '0.0.0.0',
      port: int.parse(env['PORT'] ?? env['MCP_PORT'] ?? '8080'),
      projectId: env['GOOGLE_CLOUD_PROJECT']!,
      backend: GoogleCloudBackend(),
      token: StaticToken(token, env['MCP_PERSONAL_UID']),
      allowedHosts: {
        ..._loopbackHosts,
        ...env['MCP_ALLOWED_HOSTS']!.split(','),
      },
    );
  }

  static const _minimumPersonalTokenLength = 32;
  static const _loopbackHosts = {'localhost', '127.0.0.1', '[::1]'};
}

/// The one bearer token the server accepts until OAuth lands. Without a [uid]
/// it maps to the emulator's only account, which production never allows.
class StaticToken {
  StaticToken(this.value, this.uid);

  final String value;
  final String? uid;
}

sealed class Backend {
  Uri get firestoreRoot;
  Uri get identityToolkitRoot;

  Future<http.Client> connect();
}

class EmulatorBackend extends Backend {
  EmulatorBackend({required String firestoreHost, required String authHost})
    : firestoreRoot = Uri.parse('http://$firestoreHost/'),
      identityToolkitRoot = Uri.parse(
        'http://$authHost/identitytoolkit.googleapis.com/',
      );

  @override
  final Uri firestoreRoot;
  @override
  final Uri identityToolkitRoot;

  @override
  Future<http.Client> connect() async => EmulatorAdminClient();
}

class GoogleCloudBackend extends Backend {
  @override
  final firestoreRoot = Uri.parse('https://firestore.googleapis.com/');
  @override
  final identityToolkitRoot = Uri.parse(
    'https://identitytoolkit.googleapis.com/',
  );

  @override
  Future<http.Client> connect() => clientViaApplicationDefaultCredentials(
    scopes: [
      'https://www.googleapis.com/auth/datastore',
      'https://www.googleapis.com/auth/identitytoolkit',
    ],
  );
}
