import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:gym_tracker/sync/health_data.dart';

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

  /// Workout documents carry the heart-rate series inline, about 680 samples,
  /// so every read names the fields it wants instead of fetching the document.
  static const _workoutFields = [
    'syncId',
    'routineSyncId',
    'routineName',
    'startedAtMs',
    'endedAtMs',
    'exercises',
    'completions',
    'version',
    'deletedAtMs',
  ];

  Future<List<Map<String, Object?>>> routines() => _collection('routines');

  Future<Map<String, Object?>?> routine(String id) => _document('routines', id);

  Future<List<Map<String, Object?>>> exercises() => _collection('exercises');

  Future<Map<String, Object?>?> workout(String id) async {
    final found = await _document('workouts', id, fields: _workoutFields);
    return found == null ? null : stripHealthData(found);
  }

  /// Newest first. Tombstones are skipped, so a page can come back short of
  /// [limit] without being the last one; it keeps asking until it has [limit]
  /// live workouts or runs out.
  Future<List<Map<String, Object?>>> workouts({
    int? sinceMs,
    int? untilMs,
    required int limit,
  }) async {
    final live = <Map<String, Object?>>[];
    var offset = 0;
    while (live.length < limit) {
      final page = await _workoutPage(sinceMs, untilMs, offset, limit);
      live.addAll(page.where((w) => w['deletedAtMs'] == null));
      if (page.length < limit) break;
      offset += page.length;
    }
    return [for (final w in live.take(limit)) stripHealthData(w)];
  }

  Future<List<Map<String, Object?>>> _workoutPage(
    int? sinceMs,
    int? untilMs,
    int offset,
    int limit,
  ) async {
    final filters = [
      if (sinceMs != null) _startedAt('GREATER_THAN_OR_EQUAL', sinceMs),
      if (untilMs != null) _startedAt('LESS_THAN_OR_EQUAL', untilMs),
    ];
    final response = await _documents.runQuery(
      fs.RunQueryRequest(
        structuredQuery: fs.StructuredQuery(
          from: [fs.CollectionSelector(collectionId: 'workouts')],
          select: fs.Projection(
            fields: [
              for (final f in _workoutFields) fs.FieldReference(fieldPath: f),
            ],
          ),
          where: filters.isEmpty
              ? null
              : fs.Filter(
                  compositeFilter: fs.CompositeFilter(
                    op: 'AND',
                    filters: filters,
                  ),
                ),
          orderBy: [
            fs.Order(
              field: fs.FieldReference(fieldPath: 'startedAtMs'),
              direction: 'DESCENDING',
            ),
          ],
          offset: offset,
          limit: limit,
        ),
      ),
      '$_root/users/$_uid',
    );
    return [
      for (final r in response)
        if (r.document != null) documentToJson(r.document!),
    ];
  }

  fs.Filter _startedAt(String op, int ms) => fs.Filter(
    fieldFilter: fs.FieldFilter(
      field: fs.FieldReference(fieldPath: 'startedAtMs'),
      op: op,
      value: jsonToValue(ms),
    ),
  );

  Future<Map<String, Object?>?> _document(
    String collection,
    String id, {
    List<String>? fields,
  }) async {
    try {
      final document = await _documents.get(
        '$_root/users/$_uid/$collection/$id',
        mask_fieldPaths: fields,
      );
      return documentToJson(document);
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

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
