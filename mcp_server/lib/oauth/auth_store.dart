import 'package:googleapis/firestore/v1.dart' as fs;

import '../firestore_values.dart';

class GrantedCode {
  GrantedCode({
    required this.grantId,
    required this.uid,
    required this.clientId,
    required this.redirectUri,
    required this.codeChallenge,
    required this.resource,
    required this.expiresAt,
  });

  final String grantId;
  final String uid;
  final String clientId;
  final String redirectUri;
  final String codeChallenge;
  final String resource;
  final DateTime expiresAt;
}

class RefreshGrant {
  RefreshGrant({
    required this.grantId,
    required this.uid,
    required this.clientId,
    required this.resource,
    required this.expiresAt,
  });

  final String grantId;
  final String uid;
  final String clientId;
  final String resource;
  final DateTime expiresAt;
}

sealed class Redemption<T> {}

class Redeemed<T> extends Redemption<T> {
  Redeemed(this.value);

  final T value;
}

class Unknown<T> extends Redemption<T> {}

/// The secret had been redeemed before, so whoever holds it now and whoever
/// holds the copy that was redeemed are two parties.
class Reused<T> extends Redemption<T> {
  Reused(this.grantId);

  final String grantId;
}

/// The three top-level collections that hold sign-in state. Secrets are keyed
/// by their SHA-256, so a read of the database yields nothing to present. Each
/// document has an `expiresAt` timestamp that a TTL policy sweeps.
class AuthStore {
  AuthStore(fs.FirestoreApi api, String projectId)
    : _documents = api.projects.databases.documents,
      _database = 'projects/$projectId/databases/(default)';

  static const codes = 'mcpCodes';
  static const refreshTokens = 'mcpRefreshTokens';
  static const revokedGrants = 'mcpRevokedGrants';

  final fs.ProjectsDatabasesDocumentsResource _documents;
  final String _database;

  String get _root => '$_database/documents';

  Future<void> saveCode(String hash, GrantedCode code) => _create(codes, hash, {
    'gid': code.grantId,
    'uid': code.uid,
    'clientId': code.clientId,
    'redirectUri': code.redirectUri,
    'codeChallenge': code.codeChallenge,
    'resource': code.resource,
    'used': false,
    'expiresAt': code.expiresAt,
  });

  Future<void> saveRefreshToken(String hash, RefreshGrant grant) =>
      _create(refreshTokens, hash, _refreshFields(grant));

  Future<Redemption<GrantedCode>> redeemCode(String hash, DateTime now) =>
      _redeem(codes, hash, now, (fields, markUsed) {
        return _Decision(
          writes: [markUsed],
          outcome: Redeemed(
            GrantedCode(
              grantId: fields['gid'] as String,
              uid: fields['uid'] as String,
              clientId: fields['clientId'] as String,
              redirectUri: fields['redirectUri'] as String,
              codeChallenge: fields['codeChallenge'] as String,
              resource: fields['resource'] as String,
              expiresAt: DateTime.parse(fields['expiresAt'] as String),
            ),
          ),
        );
      });

  /// Marks the presented refresh token used and stores its successor in one
  /// commit, so a crash between the two can't leave a grant with no token. A
  /// token presented by another client than it was issued to is left alone.
  Future<Redemption<RefreshGrant>> rotateRefreshToken(
    String hash, {
    required String clientId,
    required String successorHash,
    required DateTime successorExpiresAt,
    required DateTime now,
  }) => _redeem(refreshTokens, hash, now, (fields, markUsed) {
    final grant = RefreshGrant(
      grantId: fields['gid'] as String,
      uid: fields['uid'] as String,
      clientId: fields['clientId'] as String,
      resource: fields['resource'] as String,
      expiresAt: successorExpiresAt,
    );
    if (grant.clientId != clientId) return null;
    return _Decision(
      writes: [
        markUsed,
        fs.Write(
          update: fs.Document(
            name: '$_root/$refreshTokens/$successorHash',
            fields: _fieldsOf(_refreshFields(grant)),
          ),
          currentDocument: fs.Precondition(exists: false),
        ),
      ],
      outcome: Redeemed(grant),
    );
  });

  Future<void> revokeGrant(String grantId, DateTime expiresAt) async {
    await _documents.patch(
      jsonToDocument({'expiresAt': expiresAt}),
      '$_root/$revokedGrants/$grantId',
    );
  }

  Future<Set<String>> revokedGrantIds(DateTime now) async {
    final ids = <String>{};
    String? pageToken;
    do {
      final page = await _documents.list(
        _root,
        revokedGrants,
        pageSize: 300,
        pageToken: pageToken,
      );
      for (final document in page.documents ?? <fs.Document>[]) {
        final expiresAt = documentToJson(document)['expiresAt'];
        if (expiresAt is String && DateTime.parse(expiresAt).isAfter(now)) {
          ids.add(document.name!.split('/').last);
        }
      }
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return ids;
  }

  Map<String, Object?> _refreshFields(RefreshGrant grant) => {
    'gid': grant.grantId,
    'uid': grant.uid,
    'clientId': grant.clientId,
    'resource': grant.resource,
    'used': false,
    'expiresAt': grant.expiresAt,
  };

  Future<void> _create(
    String collection,
    String id,
    Map<String, Object?> fields,
  ) async {
    await _documents.createDocument(
      jsonToDocument(fields),
      _root,
      collection,
      documentId: id,
    );
  }

  fs.Write _markUsed(String name, String readAt) => fs.Write(
    update: fs.Document(name: name, fields: _fieldsOf({'used': true})),
    updateMask: fs.DocumentMask(fieldPaths: ['used']),
    currentDocument: fs.Precondition(updateTime: readAt),
  );

  Map<String, fs.Value> _fieldsOf(Map<String, Object?> fields) =>
      jsonToDocument(fields).fields!;

  /// Reads the document, then commits the decision's writes only if the
  /// document is still the one that was read. Two presentations of the same
  /// secret can't both win: the second commit finds the document changed.
  Future<Redemption<T>> _redeem<T>(
    String collection,
    String id,
    DateTime now,
    _Decision<T>? Function(Map<String, Object?> fields, fs.Write markUsed)
    decide,
  ) async {
    final name = '$_root/$collection/$id';
    final document = await _read(name);
    if (document == null) return Unknown();
    final fields = documentToJson(document);
    final expiresAt = DateTime.parse(fields['expiresAt'] as String);
    if (!expiresAt.isAfter(now)) return Unknown();
    final grantId = fields['gid'] as String;
    if (fields['used'] == true) return Reused(grantId);
    final decision = decide(fields, _markUsed(name, document.updateTime!));
    if (decision == null) return Unknown();
    try {
      await _documents.commit(
        fs.CommitRequest(writes: decision.writes),
        _database,
      );
      return decision.outcome;
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 400 || e.status == 409) return Reused(grantId);
      rethrow;
    }
  }

  Future<fs.Document?> _read(String name) async {
    try {
      return await _documents.get(name);
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }
}

class _Decision<T> {
  _Decision({required this.writes, required this.outcome});

  final List<fs.Write> writes;
  final Redemption<T> outcome;
}
