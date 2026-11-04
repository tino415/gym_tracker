import 'package:googleapis/firestore/v1.dart' as fs;

import 'account_directory.dart';
import 'firestore_values.dart';

/// Reads of one user's `users/{uid}/…` documents, and nothing else. The server
/// reaches Firestore with admin rights, which ignore the security rules, so
/// this is the only place a path with a uid in it is built.
class UserScope {
  UserScope(VerifiedAccount account, fs.FirestoreApi api, String projectId)
    : _uid = account.uid,
      _documents = api.projects.databases.documents,
      _root = 'projects/$projectId/databases/(default)/documents';

  final String _uid;
  final fs.ProjectsDatabasesDocumentsResource _documents;
  final String _root;

  Future<List<Map<String, Object?>>> routines() => _collection('routines');

  Future<List<Map<String, Object?>>> _collection(String id) async {
    final found = <Map<String, Object?>>[];
    String? pageToken;
    do {
      final page = await _documents.list(
        '$_root/users/$_uid',
        id,
        pageSize: 300,
        pageToken: pageToken,
      );
      found.addAll((page.documents ?? []).map(documentToJson));
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return found;
  }
}
