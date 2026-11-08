import 'dart:convert';
import 'dart:io';

import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:gym_tracker_mcp/config.dart';
import 'package:gym_tracker_mcp/emulator_client.dart';
import 'package:gym_tracker_mcp/firestore_values.dart';
import 'package:http/http.dart' as http;

class Emulators {
  Emulators()
    : config = ServerConfig.fromEnvironment({
        ...Platform.environment,
        'MCP_PORT': '0',
        'MCP_HOST': '127.0.0.1',
      }),
      _client = EmulatorAdminClient() {
    _firestore = fs.FirestoreApi(
      _client,
      rootUrl: config.backend.firestoreRoot.toString(),
    );
  }

  final ServerConfig config;
  final http.Client _client;
  late final fs.FirestoreApi _firestore;
  var _accounts = 0;

  Future<String> createAccount() async {
    final response = await _post('accounts', {
      'localId': 'user-${_accounts++}-${DateTime.now().microsecondsSinceEpoch}',
      'email':
          'user$_accounts-${DateTime.now().microsecondsSinceEpoch}@test.dev',
      'password': 'password123',
    }, 'signUp');
    return response['localId'] as String;
  }

  Future<void> deleteAccount(String uid) async {
    await _post('accounts:delete', {'localId': uid});
  }

  Future<void> disableAccount(String uid) async {
    await _post('accounts:update', {'localId': uid, 'disableUser': true});
  }

  Future<void> putDocument(
    String uid,
    String collection,
    String id,
    Map<String, Object?> json,
  ) async {
    await _firestore.projects.databases.documents.patch(
      jsonToDocument(json),
      'projects/${config.projectId}/databases/(default)/documents/users/$uid/$collection/$id',
    );
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body, [
    String? action,
  ]) async {
    final root = config.backend.identityToolkitRoot;
    final url = action == null
        ? root.resolve('v1/projects/${config.projectId}/$path')
        : root.resolve('v1/accounts:$action?key=test');
    final response = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw StateError('$path: ${response.statusCode} ${response.body}');
    }
    return (jsonDecode(response.body) as Map).cast();
  }

  void close() => _client.close();
}
