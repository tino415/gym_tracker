import 'dart:convert';

import 'package:http/http.dart' as http;

/// A uid that Firebase Auth has just confirmed exists and is enabled. The only
/// way to obtain one is [AccountDirectory.verify], and a [UserScope] needs one.
class VerifiedAccount {
  VerifiedAccount._(this.uid);

  final String uid;
}

class AccountDirectory {
  AccountDirectory({
    required http.Client client,
    required Uri identityToolkitRoot,
    required String projectId,
    required String webApiKey,
    DateTime Function() now = DateTime.now,
    this.cacheFor = const Duration(minutes: 1),
  }) : _client = client,
       _accountsUrl = identityToolkitRoot.resolve(
         'v1/projects/$projectId/accounts',
       ),
       _idTokenLookupUrl = identityToolkitRoot.resolve(
         'v1/accounts:lookup?key=$webApiKey',
       ),
       _now = now;

  final http.Client _client;

  /// The ID-token lookup is a public endpoint: carrying the admin credential
  /// turns it into an admin lookup that ignores the token.
  final http.Client _publicClient = http.Client();
  final Uri _accountsUrl;
  final Uri _idTokenLookupUrl;
  final DateTime Function() _now;
  final Duration cacheFor;
  final Map<String, _Answer> _answers = {};

  Future<VerifiedAccount?> verify(String uid) async {
    final cached = _answers[uid];
    final usable = cached != null && _now().difference(cached.at) < cacheFor;
    final active = usable ? cached.active : await _lookUpActive(uid);
    if (!usable) _answers[uid] = _Answer(active, _now());
    return active ? VerifiedAccount._(uid) : null;
  }

  /// The account a Firebase ID token was issued to. Identity Toolkit checks the
  /// token itself, which also works on the emulator, whose tokens are unsigned.
  Future<VerifiedAccount?> verifyIdToken(String idToken) async {
    final response = await _publicClient.post(
      _idTokenLookupUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken}),
    );
    if (response.statusCode == 400) return null;
    if (response.statusCode != 200) {
      throw StateError('Firebase Auth :lookup: ${response.statusCode}');
    }
    final users = (jsonDecode(response.body) as Map)['users'] as List? ?? [];
    if (users.length != 1) return null;
    final user = (users.single as Map).cast<String, Object?>();
    return user['disabled'] == true
        ? null
        : VerifiedAccount._(user['localId'] as String);
  }

  Future<String?> soleUid() async {
    final users = await _post(':query', {'returnUserInfo': true});
    return users.length == 1 ? users.single['localId'] as String : null;
  }

  Future<bool> _lookUpActive(String uid) async {
    final users = await _post(':lookup', {
      'localId': [uid],
    });
    return users.isNotEmpty && users.single['disabled'] != true;
  }

  Future<List<Map<String, Object?>>> _post(
    String action,
    Map<String, Object?> body,
  ) async {
    final response = await _client.post(
      Uri.parse('$_accountsUrl$action'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw StateError('Firebase Auth $action: ${response.statusCode}');
    }
    final users =
        (jsonDecode(response.body) as Map)['userInfo'] ??
        (jsonDecode(response.body) as Map)['users'];
    return [for (final u in (users as List? ?? [])) (u as Map).cast()];
  }
}

class _Answer {
  _Answer(this.active, this.at);

  final bool active;
  final DateTime at;
}
