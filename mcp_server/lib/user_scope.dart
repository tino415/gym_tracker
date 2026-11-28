import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:gym_tracker/sync/health_data.dart';

import 'account_directory.dart';
import 'firestore_values.dart';

/// A document with the time it was last written, which a commit can require to
/// be unchanged.
class StoredDocument {
  StoredDocument(this.fields, this.updateTime);

  final Map<String, Object?> fields;
  final String updateTime;
}

/// A document to write, with the [StoredDocument.updateTime] it was read at,
/// or null when it must not exist yet.
class DocumentWrite {
  DocumentWrite(this.fields, {this.readAt});

  final Map<String, Object?> fields;
  final String? readAt;

  String get syncId => fields['syncId']! as String;
}

/// A commit's precondition failed: something wrote one of its documents after
/// it was read.
class CommitConflict implements Exception {}

/// One user's `users/{uid}/…` documents: reads, and the one write save_routine
/// makes. The server reaches Firestore with admin rights, which ignore the
/// security rules, so this is the only place a path with a uid in it is built.
class UserScope {
  UserScope(VerifiedAccount account, fs.FirestoreApi api, String projectId)
    : _uid = account.uid,
      _documents = api.projects.databases.documents,
      _database = 'projects/$projectId/databases/(default)',
      _root = 'projects/$projectId/databases/(default)/documents';

  final String _uid;
  final fs.ProjectsDatabasesDocumentsResource _documents;
  final String _database;
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

  Future<StoredDocument?> storedRoutine(String id) async {
    final document = await _get('$_root/users/$_uid/routines/$id');
    return document == null ? null : _stored(document);
  }

  Future<List<StoredDocument>> storedExercises() async => [
    for (final document in await _list('exercises')) _stored(document),
  ];

  /// The routine and the exercises it adds or revives, all or none.
  Future<void> commitRoutine(
    DocumentWrite routine,
    List<DocumentWrite> exercises,
  ) async {
    try {
      await _documents.commit(
        fs.CommitRequest(
          writes: [
            _write('routines', routine),
            for (final e in exercises) _write('exercises', e),
          ],
        ),
        _database,
      );
    } on fs.DetailedApiRequestError catch (e) {
      if (_failedPrecondition(e)) throw CommitConflict();
      rethrow;
    }
  }

  fs.Write _write(String collection, DocumentWrite write) => fs.Write(
    update: fs.Document(
      name: '$_root/users/$_uid/$collection/${write.syncId}',
      fields: jsonToDocument(write.fields).fields,
    ),
    currentDocument: write.readAt == null
        ? fs.Precondition(exists: false)
        : fs.Precondition(updateTime: write.readAt),
  );

  bool _failedPrecondition(fs.DetailedApiRequestError e) {
    final error = e.jsonResponse?['error'];
    final status = error is Map ? error['status'] : null;
    return e.status == 409 || status == 'FAILED_PRECONDITION';
  }

  StoredDocument _stored(fs.Document document) =>
      StoredDocument(documentToJson(document), document.updateTime!);

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
    final document = await _get(
      '$_root/users/$_uid/$collection/$id',
      fields: fields,
    );
    return document == null ? null : documentToJson(document);
  }

  Future<fs.Document?> _get(String name, {List<String>? fields}) async {
    try {
      return await _documents.get(name, mask_fieldPaths: fields);
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> _collection(String id) async => [
    for (final document in await _list(id)) documentToJson(document),
  ];

  Future<List<fs.Document>> _list(String id) async {
    final found = <fs.Document>[];
    String? pageToken;
    do {
      final page = await _documents.list(
        '$_root/users/$_uid',
        id,
        pageSize: 300,
        pageToken: pageToken,
      );
      found.addAll(page.documents ?? []);
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return found;
  }
}
