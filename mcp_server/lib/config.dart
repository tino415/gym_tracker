import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'emulator_client.dart';
import 'oauth/signing_keys.dart';

class ServerConfig {
  ServerConfig({
    required this.host,
    required this.port,
    required this.projectId,
    required this.backend,
    required this.issuer,
    required this.appUrl,
    required this.signingKeys,
    required this.signingKid,
    required this.allowedHosts,
    this.devToken,
    this.webApiKey = 'demo-api-key',
    this.requestsPerMinute = 60,
    this.requestsPerDay = 1000,
    this.allRequestsPerMinute = 300,
    this.allRequestsPerDay = 10000,
    this.authRequestsPerMinute = 30,
    this.authRequestsPerDay = 1000,
  });

  final String host;
  final int port;
  final String projectId;
  final Backend backend;

  /// The origin the server is reached at, which is also the authorization
  /// server's issuer.
  final String issuer;

  /// The origin of the web app that serves the `/connect` page.
  final String appUrl;
  final Map<String, String> signingKeys;
  final String signingKid;
  final Set<String> allowedHosts;

  /// The Firebase web API key, which is public: Identity Toolkit asks for it
  /// when it checks a user's ID token.
  final String webApiKey;

  /// A fixed bearer token for the emulators; production never has one.
  final StaticToken? devToken;

  /// Per account.
  final int requestsPerMinute;
  final int requestsPerDay;
  final int allRequestsPerMinute;
  final int allRequestsPerDay;

  /// `/connect` and `/token` together.
  final int authRequestsPerMinute;
  final int authRequestsPerDay;

  String get mcpUrl => '$issuer/mcp';

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
  ) {
    final port = int.parse(env['MCP_PORT'] ?? '4121');
    return ServerConfig(
      host: env['MCP_HOST'] ?? '0.0.0.0',
      port: port,
      projectId: env['GCLOUD_PROJECT'] ?? 'demo-gym-tracker',
      backend: EmulatorBackend(
        firestoreHost: firestoreHost,
        authHost: authHost,
      ),
      issuer: _origin(env['MCP_PUBLIC_URL'] ?? 'http://localhost:$port'),
      appUrl: _origin(env['MCP_APP_URL'] ?? 'http://dev.local:4116'),
      signingKeys: {'dev': _devSigningKey},
      signingKid: 'dev',
      devToken: StaticToken(
        env['MCP_DEV_TOKEN'] ?? 'dev-token',
        env['MCP_DEV_UID'],
      ),
      allowedHosts: {
        ..._loopbackHosts,
        ...?env['MCP_ALLOWED_HOSTS']?.split(','),
      },
    );
  }

  factory ServerConfig._forGoogleCloud(Map<String, String> env) {
    const required = [
      'GOOGLE_CLOUD_PROJECT',
      'MCP_SIGNING_KEYS',
      'MCP_SIGNING_KID',
      'MCP_PUBLIC_URL',
      'MCP_APP_URL',
      'MCP_FIREBASE_API_KEY',
      'MCP_ALLOWED_HOSTS',
    ];
    final missing = required.where((name) => env[name] == null).toList();
    if (missing.isNotEmpty) {
      throw StateError(
        'Without FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST the '
        'server reads production, which needs ${missing.join(', ')}.',
      );
    }
    final keys = SigningKeys.fromJson(
      env['MCP_SIGNING_KEYS']!,
      env['MCP_SIGNING_KID']!,
    ).keys;
    return ServerConfig(
      host: env['MCP_HOST'] ?? '0.0.0.0',
      port: int.parse(env['PORT'] ?? env['MCP_PORT'] ?? '8080'),
      projectId: env['GOOGLE_CLOUD_PROJECT']!,
      backend: GoogleCloudBackend(),
      issuer: _origin(env['MCP_PUBLIC_URL']!),
      appUrl: _origin(env['MCP_APP_URL']!),
      webApiKey: env['MCP_FIREBASE_API_KEY']!,
      signingKeys: keys,
      signingKid: env['MCP_SIGNING_KID']!,
      allowedHosts: {
        ..._loopbackHosts,
        ...env['MCP_ALLOWED_HOSTS']!.split(','),
      },
    );
  }

  static String _origin(String url) => Uri.parse(url).origin;

  static final _devSigningKey = base64Url.encode(
    utf8.encode('gym-tracker-mcp-emulator-signing-key'),
  );
  static const _loopbackHosts = {'localhost', '127.0.0.1', '[::1]'};
}

/// A fixed bearer token, accepted on the emulators only. Without a [uid] it
/// maps to the emulator's only account.
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
