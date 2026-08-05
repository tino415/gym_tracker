import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'sync_codec.dart';
import 'sync_transport.dart';

/// Sync transport backed by Cloud Firestore.
///
/// Layout: `users/{uid}/routines/{syncId}` and `users/{uid}/workouts/{syncId}`
/// each hold the plain DTO JSON that already flows over the Wear bridge, so
/// the server is only a document store — no server-side logic.
///
/// Receive is document-granular (unlike the Wear transport's authoritative
/// full-bundle): added/modified routine docs become a non-destructive
/// [routineUpsertType], removed docs become a [routineDeletedType], and each
/// workout doc becomes a [workoutCompletedType]. This keeps an empty or stale
/// snapshot from ever wiping local routines.
///
/// Send diffs the authoritative set against the server: it writes only docs
/// whose content changed and deletes docs no longer present. Writing only real
/// changes is what stops the push → own-snapshot → apply → push echo from
/// looping — once the sets converge, no write fires and no snapshot follows.
class FirestoreSyncTransport implements SyncTransport {
  FirestoreSyncTransport({required this.uid, FirebaseFirestore? firestore})
    : _fs = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _fs;

  final StreamController<SyncMessage> _messages =
      StreamController<SyncMessage>.broadcast();
  final List<StreamSubscription<QuerySnapshot<Map<String, Object?>>>> _subs = [];
  bool _started = false;
  bool _disposed = false;

  /// Last content we wrote per routine doc, so an idempotent re-push writes
  /// nothing (echo suppression) without re-reading the collection from the
  /// server on every push.
  final Map<String, Map<String, Object?>> _lastWrittenRoutine = {};

  /// Same echo-suppression cache for exercise-library docs.
  final Map<String, Map<String, Object?>> _lastWrittenExercise = {};

  /// Last workout doc we wrote or observed, per sync id. Doubles as the echo
  /// suppression cache (like [_lastWrittenRoutine]) and the server-version
  /// guard, so a push neither rewrites an identical doc nor clobbers a newer
  /// one, without a read per push.
  final Map<String, Map<String, Object?>> _serverWorkouts = {};

  CollectionReference<Map<String, Object?>> get _routines =>
      _fs.collection('users').doc(uid).collection('routines');
  CollectionReference<Map<String, Object?>> get _workouts =>
      _fs.collection('users').doc(uid).collection('workouts');
  CollectionReference<Map<String, Object?>> get _exercises =>
      _fs.collection('users').doc(uid).collection('exercises');

  @override
  Stream<SyncMessage> get messages => _messages.stream;

  @override
  void start() {
    if (_started) return;
    _started = true;
    _subs.add(_routines.snapshots().listen(_onRoutinesSnapshot));
    _subs.add(_workouts.snapshots().listen(_onWorkoutsSnapshot));
    _subs.add(_exercises.snapshots().listen(_onExercisesSnapshot));
  }

  /// Nothing to drain: the snapshot listeners replay the whole collection on
  /// attach, so anything written while this device was offline arrives that
  /// way. The offline queue exists only for the Wear transport.
  @override
  Future<void> drainPending() async {}

  /// Added/modified exercise docs (including tombstones) become a non-destructive
  /// [exerciseBundleType]; the receiver applies them with version-LWW. A genuine
  /// doc removal is ignored — deletions ride as tombstone docs, not removals.
  void _onExercisesSnapshot(QuerySnapshot<Map<String, Object?>> snap) {
    final upserted = <Map<String, Object?>>[];
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;
      upserted.add(change.doc.data()!);
    }
    if (upserted.isNotEmpty) {
      _messages.add(
        SyncMessage(
          type: exerciseBundleType,
          payload: {'exercises': upserted},
        ),
      );
    }
  }

  void _onRoutinesSnapshot(QuerySnapshot<Map<String, Object?>> snap) {
    final upserted = <Map<String, Object?>>[];
    final removed = <String>[];
    for (final change in snap.docChanges) {
      switch (change.type) {
        case DocumentChangeType.added:
        case DocumentChangeType.modified:
          upserted.add(change.doc.data()!);
        case DocumentChangeType.removed:
          removed.add(change.doc.id);
      }
    }
    if (upserted.isNotEmpty) {
      _messages.add(
        SyncMessage(
          type: routineUpsertType,
          payload: {'routines': upserted},
        ),
      );
    }
    if (removed.isNotEmpty) {
      _messages.add(
        SyncMessage(
          type: routineDeletedType,
          payload: RoutineDeletedMessage(removed).toPayload(),
        ),
      );
    }
  }

  /// Added/modified workout docs (including tombstones) become a
  /// [workoutCompletedType]; the receiver applies them with version-LWW. A
  /// genuine doc removal is ignored — deletions ride as tombstone docs — but it
  /// does drop the cache entry, so a doc deleted out of band (console, future
  /// server-side GC) isn't suppressed forever.
  void _onWorkoutsSnapshot(QuerySnapshot<Map<String, Object?>> snap) {
    for (final change in snap.docChanges) {
      final id = change.doc.id;
      if (change.type == DocumentChangeType.removed) {
        _serverWorkouts.remove(id);
        continue;
      }
      final data = change.doc.data()!;
      // Our own write coming back: nothing to apply, and emitting it would
      // start the apply → relay → push round trip for no reason.
      if (jsonEquals(_serverWorkouts[id], data)) continue;
      _serverWorkouts[id] = data;
      _messages.add(SyncMessage(type: workoutCompletedType, payload: data));
    }
  }

  @override
  Future<void> send({
    required String type,
    required Map<String, Object?> payload,
  }) async {
    // Once disposed (e.g. detached on sign-out), never write again — the uid
    // this transport is bound to is no longer the signed-in user, so a straggler
    // send from an in-flight fan-out must not touch that account's documents.
    if (_disposed) return;
    switch (type) {
      case routineBundleType:
        await _pushRoutines(payload);
      case routineDeletedType:
        await _deleteRoutines(payload);
      case exerciseBundleType:
        await _pushExercises(payload);
      case workoutCompletedType:
        await _pushWorkout(payload);
      case syncRequestType:
        // Firestore's snapshot listeners already stream peer state; there is
        // nothing to request.
        break;
    }
  }

  /// Upsert only. Deletions are never inferred from absence here — a routine
  /// missing from this bundle may just belong to a peer we haven't merged yet;
  /// real deletions arrive as [routineDeletedType]. This is what keeps one
  /// authority from wiping another's routines.
  Future<void> _pushRoutines(Map<String, Object?> payload) async {
    final raw = (payload['routines'] as List?)?.cast<Object?>() ?? const [];
    final batch = _fs.batch();
    var writes = 0;
    for (final r in raw) {
      final data = (r as Map).cast<String, Object?>();
      final syncId = data['syncId'] as String;
      // Skip docs whose content we already wrote, so the push → own-snapshot →
      // apply → push echo terminates without a Firestore read.
      if (jsonEquals(_lastWrittenRoutine[syncId], data)) continue;
      batch.set(_routines.doc(syncId), data);
      _lastWrittenRoutine[syncId] = data;
      writes++;
    }
    if (writes > 0) await batch.commit();
  }

  /// Upsert exercise-library docs by syncId. Like [_pushRoutines], this is
  /// upsert-only (never deletes a doc for being absent) and skips docs whose
  /// content we already wrote, so the push → own-snapshot → apply → push echo
  /// terminates without a Firestore read. Deletions ride as tombstone docs.
  Future<void> _pushExercises(Map<String, Object?> payload) async {
    final raw = (payload['exercises'] as List?)?.cast<Object?>() ?? const [];
    final batch = _fs.batch();
    var writes = 0;
    for (final e in raw) {
      final data = (e as Map).cast<String, Object?>();
      final syncId = data['syncId'] as String;
      if (jsonEquals(_lastWrittenExercise[syncId], data)) continue;
      batch.set(_exercises.doc(syncId), data);
      _lastWrittenExercise[syncId] = data;
      writes++;
    }
    if (writes > 0) await batch.commit();
  }

  Future<void> _deleteRoutines(Map<String, Object?> payload) async {
    final syncIds = RoutineDeletedMessage.fromPayload(payload).syncIds;
    if (syncIds.isEmpty) return;
    final batch = _fs.batch();
    for (final syncId in syncIds) {
      batch.delete(_routines.doc(syncId));
      _lastWrittenRoutine.remove(syncId);
    }
    await batch.commit();
  }

  /// Version-LWW upsert. Two ways to skip: the server copy is strictly newer
  /// (don't clobber an edit made elsewhere), or it's the same version with the
  /// same content (an idempotent re-push or our own echo — writing it would
  /// fire a snapshot and go round again).
  Future<void> _pushWorkout(Map<String, Object?> payload) async {
    final syncId = payload['syncId'] as String?;
    if (syncId == null) return;
    final version = (payload['version'] as num?)?.toInt() ?? 1;
    final doc = _workouts.doc(syncId);

    var cached = _serverWorkouts[syncId];
    if (cached == null) {
      // Cold cache (first push this process): one read, then we track it.
      final snap = await doc.get();
      cached = snap.data();
      if (cached != null) _serverWorkouts[syncId] = cached;
    }
    if (cached != null) {
      final cachedVersion = (cached['version'] as num?)?.toInt() ?? 1;
      if (cachedVersion > version) return;
      if (cachedVersion == version && jsonEquals(cached, payload)) return;
    }
    // Cache before writing, like _pushRoutines does: the snapshot for our own
    // write can be delivered before `set` completes, and it must find the entry
    // already there or it would echo back as an inbound message. Rolled back if
    // the write fails, so a later push isn't wrongly suppressed.
    _serverWorkouts[syncId] = payload;
    try {
      await doc.set(payload);
    } catch (_) {
      _serverWorkouts.remove(syncId);
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _messages.close();
    _started = false;
  }
}

