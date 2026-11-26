import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'firestore_retry.dart';
import 'health_upload_consent.dart';
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
  FirestoreSyncTransport({
    required this.uid,
    FirebaseFirestore? firestore,
    bool Function()? allowHealthUpload,
  })  : _fs = firestore ?? FirebaseFirestore.instance,
        _allowHealthUpload = allowHealthUpload ?? (() => false);

  final String uid;
  final FirebaseFirestore _fs;

  /// Whether the signed-in user has explicitly consented to storing heart rate
  /// in the cloud. Read per push rather than captured once, so revoking takes
  /// effect on the next write without rebuilding the transport.
  ///
  /// Defaults to **false**: a caller that forgets to wire consent uploads no
  /// health data, which is the safe way to be wrong.
  final bool Function() _allowHealthUpload;

  final StreamController<SyncMessage> _messages =
      StreamController<SyncMessage>.broadcast();
  final List<StreamSubscription<QuerySnapshot<Map<String, Object?>>>> _subs = [];
  bool _started = false;
  bool _disposed = false;

  /// Last routine doc written or seen from the server, per sync id. It is both
  /// the echo suppression and the version guard, so it changes only on what
  /// the server is known to hold: a committed write, the gate's server read,
  /// or a server snapshot with no pending writes. Anything weaker would let a
  /// stale phone copy look identical to, or newer than, the server's.
  final Map<String, Map<String, Object?>> _serverRoutines = {};

  /// Last content we wrote per exercise doc, so an idempotent re-push writes
  /// nothing (echo suppression) without re-reading the collection from the
  /// server on every push.
  final Map<String, Map<String, Object?>> _lastWrittenExercise = {};

  /// Server version per exercise doc, so a push can refuse to overwrite a
  /// newer one. Deliberately holds versions rather than content and is kept
  /// apart from [_lastWrittenExercise]: it is filled from the whole collection
  /// at once, and a *content* cache filled that way would make the next push
  /// believe it had already written every doc.
  final Map<String, int> _serverExerciseVersions = {};

  /// Pushing blind is what lets a freshly seeded library at version 1 flatten
  /// an account that has been edited for months.
  late final _ServerReadGate _exerciseGate = _ServerReadGate(
    collection: 'exercises',
    readServer: () => readServerExercises(),
    recordServerDocs: _recordServerExerciseVersions,
    write: _writeExercises,
  );

  /// Pushing blind is what lets the phone's copy of a routine, pushed in full
  /// the moment the transport attaches, revert an edit the web or the
  /// assistant made while the app was closed.
  late final _ServerReadGate _routineGate = _ServerReadGate(
    collection: 'routines',
    readServer: () => readServerRoutines(),
    recordServerDocs: _recordServerRoutines,
    write: _writeRoutines,
  );

  /// Last workout doc we wrote or observed, per sync id. Doubles as the echo
  /// suppression cache (like [_lastWrittenExercise]) and the server-version
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
    // Head start on both gates. Not awaited: start() is synchronous by
    // contract, and each gate awaits its read properly.
    _exerciseGate.warmUp();
    _routineGate.warmUp();
  }

  /// The one read the exercise gate makes, as its own method so a test can
  /// fail it. `fake_cloud_firestore` routes neither `mock_exceptions` nor its
  /// security rules through a collection `get`, so the offline path is
  /// otherwise unreachable from outside, and it is the path the gate exists
  /// for.
  @visibleForTesting
  Future<QuerySnapshot<Map<String, Object?>>> readServerExercises() =>
      _exercises.get(const GetOptions(source: Source.server));

  /// The routine gate's read, overridable for the same reason.
  @visibleForTesting
  Future<QuerySnapshot<Map<String, Object?>>> readServerRoutines() =>
      _routines.get(const GetOptions(source: Source.server));

  /// Whether either gate will try again. Cancelling it strands whatever bundle
  /// is being held, so "did that failure end the retries" is the thing worth
  /// asserting about classification.
  @visibleForTesting
  bool get guardRetryArmed =>
      _exerciseGate.retryArmed || _routineGate.retryArmed;

  /// One retry attempt of each gate, so a test can drive it without waiting
  /// 30 seconds of wall clock.
  @visibleForTesting
  Future<void> runGuardRetryTick() async {
    await _exerciseGate.retryTick();
    await _routineGate.retryTick();
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
    // Keep the guard current from the listener, so a rename pushed by another
    // device updates it without a second read. This only refreshes versions it
    // is already tracking; it does not decide whether the guard is loaded,
    // because a metadata-only transition raises no event here (see
    // [_ServerReadGate._readServer]).
    if (!snap.metadata.isFromCache) _recordServerExerciseVersions(snap.docs);

    final upserted = <Map<String, Object?>>[];
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) {
        // Keep the guard honest about a doc that is gone (console edit, future
        // server-side GC). A stale entry would make the same id, recreated at
        // version 1, unpushable for the rest of the process.
        //
        // Only on a server snapshot, matching the refresh above. Dropping a
        // guard entry on a cache-only removal would tell the next push that a
        // document is absent when it is not, and a version-1 seeded row would
        // then be written straight over a higher-versioned one that still
        // exists.
        //
        // The echo cache goes too, which means the next push rewrites the
        // document. That is deliberate, and it is a real trade. A removal is
        // not a deletion channel here: deletions ride as tombstone documents,
        // so a doc that merely vanished is divergence, and re-pushing the row
        // we still hold repairs it. Keeping the echo entry instead would leave
        // the two stores permanently out of step with nothing to notice. The
        // cost is that a console deletion comes back, and that server-side
        // tombstone GC, if it is ever built, would need to delete the local row
        // rather than just the document.
        if (!snap.metadata.isFromCache) {
          _serverExerciseVersions.remove(change.doc.id);
          _lastWrittenExercise.remove(change.doc.id);
        }
        continue;
      }
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

  void _recordServerExerciseVersions(
    Iterable<DocumentSnapshot<Map<String, Object?>>> docs,
  ) {
    for (final doc in docs) {
      final v = (doc.data()?['version'] as num?)?.toInt();
      if (v != null) _serverExerciseVersions[doc.id] = v;
    }
  }

  /// Every added or modified doc is emitted, our own writes included: the
  /// receiver's version-LWW makes an echo a no-op. Only what the server is
  /// known to hold is recorded, so a cached or pending doc never vouches for
  /// the next push.
  void _onRoutinesSnapshot(QuerySnapshot<Map<String, Object?>> snap) {
    final fromServer = !snap.metadata.isFromCache;
    final upserted = <Map<String, Object?>>[];
    final removed = <String>[];
    for (final change in snap.docChanges) {
      final doc = change.doc;
      switch (change.type) {
        case DocumentChangeType.added:
        case DocumentChangeType.modified:
          if (fromServer) _recordServerRoutines([doc]);
          upserted.add(doc.data()!);
        case DocumentChangeType.removed:
          if (fromServer) _serverRoutines.remove(doc.id);
          removed.add(doc.id);
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
        await _routineGate.push(_rows(payload, 'routines'));
      case routineDeletedType:
        await _deleteRoutines(payload);
      case exerciseBundleType:
        await _exerciseGate.push(_rows(payload, 'exercises'));
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
  ///
  /// A routine whose server copy is strictly newer is left alone: the inbound
  /// snapshot corrects the local row instead. Equal versions write, because a
  /// phone-side exercise rename changes a routine's content without bumping
  /// its version, and skipping it would strand the rename on the phone.
  Future<void> _writeRoutines(List<Map<String, Object?>> rows) async {
    final batch = _fs.batch();
    final written = <String, Map<String, Object?>>{};
    for (final data in rows) {
      final syncId = data['syncId'] as String;
      final server = _serverRoutines[syncId];
      if (server != null && _versionOf(server) > _versionOf(data)) continue;
      if (jsonEquals(server, data)) continue;
      batch.set(_routines.doc(syncId), data);
      written[syncId] = data;
    }
    if (written.isEmpty) return;
    await batch.commit();
    // A server snapshot that landed while the commit was in flight may already
    // hold a newer doc, and overwriting its record with ours would let a later
    // equal-version push revert it.
    written.forEach((syncId, data) {
      final seen = _serverRoutines[syncId];
      if (seen == null || _versionOf(seen) <= _versionOf(data)) {
        _serverRoutines[syncId] = data;
      }
    });
  }

  void _recordServerRoutines(
    Iterable<DocumentSnapshot<Map<String, Object?>>> docs,
  ) {
    for (final doc in docs) {
      final data = doc.data();
      if (data != null && !doc.metadata.hasPendingWrites) {
        _serverRoutines[doc.id] = data;
      }
    }
  }

  /// Upsert exercise-library docs by syncId. Like [_writeRoutines], this is
  /// upsert-only (never deletes a doc for being absent) and skips docs whose
  /// content we already wrote, so the push → own-snapshot → apply → push echo
  /// terminates without a Firestore read. Deletions ride as tombstone docs.
  Future<void> _writeExercises(List<Map<String, Object?>> rows) async {
    final batch = _fs.batch();
    final pendingContent = <String, Map<String, Object?>>{};
    final pendingVersions = <String, int>{};
    for (final data in rows) {
      final syncId = data['syncId'] as String;
      final version = _versionOf(data);
      final serverVersion = _serverExerciseVersions[syncId];
      // Someone else edited this exercise more recently. Our copy will be
      // corrected by the inbound snapshot; overwriting theirs would lose it.
      //
      // Strictly newer, matching _pushWorkout. At equal versions the guard
      // does not arbitrate, so a seeded row at version 1 does overwrite a
      // server document still at version 1, replacing its tags, kind and
      // createdAt with the catalogue's. That is the intended direction for a
      // document nobody has edited, and rows the account *has* edited sit at 2
      // or above and are safe. It is not the same claim as "a fresh seed always
      // loses", which is what the surrounding comments used to say.
      if (serverVersion != null && serverVersion > version) continue;
      if (jsonEquals(_lastWrittenExercise[syncId], data)) continue;
      batch.set(_exercises.doc(syncId), data);
      pendingContent[syncId] = data;
      pendingVersions[syncId] = version;
    }
    if (pendingContent.isEmpty) return;
    // Cache only once the write lands. Caching inside the loop, as this used
    // to, leaves the caches claiming every doc was written when the commit
    // throws, which suppresses the retry.
    //
    // The opposite of _pushWorkout, deliberately. That one caches first because
    // the snapshot for its own write can arrive before `set` resolves and its
    // listener consults the cache to decide whether to emit. This listener does
    // not: _onExercisesSnapshot emits every added or modified doc regardless,
    // so caching earlier would suppress nothing. What the cache decides here is
    // whether the *next push* rewrites, and the gate's queue guarantees the
    // next push cannot start until this one has finished filling it.
    await batch.commit();
    _lastWrittenExercise.addAll(pendingContent);
    _serverExerciseVersions.addAll(pendingVersions);
  }

  Future<void> _deleteRoutines(Map<String, Object?> payload) async {
    final syncIds = RoutineDeletedMessage.fromPayload(payload).syncIds;
    if (syncIds.isEmpty) return;
    final batch = _fs.batch();
    for (final syncId in syncIds) {
      batch.delete(_routines.doc(syncId));
    }
    await batch.commit();
    syncIds.forEach(_serverRoutines.remove);
  }

  /// Version-LWW upsert. Two ways to skip: the server copy is strictly newer
  /// (don't clobber an edit made elsewhere), or it's the same version with the
  /// same content (an idempotent re-push or our own echo — writing it would
  /// fire a snapshot and go round again).
  Future<void> _pushWorkout(Map<String, Object?> rawPayload) async {
    // Health data leaves this device only with explicit consent. Stripping here
    // rather than at export keeps heart rate flowing phone ↔ watch over the
    // Wear Data Layer, which never reaches a server of ours.
    //
    // This also *undoes* an upload: `set` replaces the whole document, so once
    // consent is withdrawn the next push rewrites each workout without its
    // readings. That is why the account page re-pushes on revoke.
    final payload =
        _allowHealthUpload() ? rawPayload : stripHealthData(rawPayload);
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
    // Cache before writing: the snapshot for our own
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
    _exerciseGate.dispose();
    _routineGate.dispose();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _messages.close();
    _started = false;
  }
}

List<Map<String, Object?>> _rows(Map<String, Object?> payload, String key) =>
    [
      for (final row in (payload[key] as List?) ?? const [])
        (row as Map).cast<String, Object?>(),
    ];

int _versionOf(Map<String, Object?> doc) =>
    (doc['version'] as num?)?.toInt() ?? 1;

/// Fails one collection's pushes closed until the server's copy of that
/// collection has been read once in this process, then lets them through one
/// at a time. Until the server has answered there is no way to tell a local
/// row that is genuinely newer from one that is merely fresh.
///
/// A bundle that arrives early is held, not dropped, and retried on a timer:
/// every other route back into a push needs an external trigger (an edit, a
/// peer's sync request, "Sync now"), so a user who signs in with no network
/// and then does not touch the app would otherwise never upload, however long
/// they are online afterwards.
class _ServerReadGate {
  _ServerReadGate({
    required this.collection,
    required Future<QuerySnapshot<Map<String, Object?>>> Function() readServer,
    required void Function(Iterable<DocumentSnapshot<Map<String, Object?>>>)
        recordServerDocs,
    required Future<void> Function(List<Map<String, Object?>> rows) write,
  })  : _read = readServer,
        _record = recordServerDocs,
        _write = write;

  final String collection;
  final Future<QuerySnapshot<Map<String, Object?>>> Function() _read;
  final void Function(Iterable<DocumentSnapshot<Map<String, Object?>>>)
      _record;
  final Future<void> Function(List<Map<String, Object?>> rows) _write;

  bool _loaded = false;
  Future<void>? _load;
  bool _disposed = false;

  /// Counts failed reads so a failure that is usually permanent can still get
  /// a couple of goes. The transport attaches and reads the moment the user
  /// signs in, which is exactly when a token has not reached the backend yet
  /// and the read comes back permission-denied for a second.
  int _failedReads = 0;

  /// One timer covering both ways a push can be stuck: the read has never
  /// succeeded, or it has and a replay failed. It has to cover the second as
  /// well, or restoring the bundle on a failed replay would be decorative: the
  /// load is memoized on success and would never run again.
  Timer? _retry;

  List<Map<String, Object?>>? _held;

  /// Pushes run one at a time.
  ///
  /// Dropping a held bundle when a fresher one arrives only helps while the
  /// held one is still held. Once its commit is in flight nothing supersedes
  /// it, so a slow replay and a quick edit-triggered push become two batch
  /// writes over the same documents with no ordering between them, and if the
  /// older lands last the server keeps the pre-edit content while the local
  /// row is newer. The inbound snapshot is then correctly rejected on version,
  /// so the two stay diverged with nothing scheduled to repair it.
  Future<void> _queue = Future<void>.value();

  bool get retryArmed => _retry != null;

  void warmUp() => unawaited(_ensureLoaded());

  Future<void> push(List<Map<String, Object?>> rows) {
    final next = _queue.then((_) => _pushInTurn(rows));
    // The chain must survive a failure, or one error wedges every later push.
    // The caller still sees it: `next` keeps the error, this only detaches it
    // from the queue.
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> _pushInTurn(List<Map<String, Object?>> rows) async {
    // Re-checked here, not just in send(). A push admitted while the transport
    // was alive runs whenever the queue reaches it, which can be after a
    // sign-out or an account switch has disposed it.
    if (_disposed) return;

    // The load is started, never awaited here. SyncService awaits each
    // transport's send serially and pushAll runs the context push before the
    // workout pushes, and a Source.server read has no client deadline: on a
    // reachable but slow connection, awaiting would park "Sync now" on this
    // bundle and the workouts behind it would never go out at all.
    //
    // Only a non-empty bundle is worth holding: a later empty bundle arriving
    // while the read is still pending would replace a real one with nothing,
    // and the eventual replay would write nothing at all.
    if (!_loaded) {
      unawaited(_ensureLoaded());
      if (rows.isNotEmpty) {
        _held = rows;
        _scheduleRetry();
      }
      return;
    }

    // This bundle is a full export and supersedes anything held from before
    // the read. Keeping the older one would leave two batch commits racing
    // over the same documents, with the stale one able to land last.
    _held = null;
    try {
      await _write(rows);
    } catch (_) {
      // Without this the exception reaches _sendAll, which swallows it, and
      // nothing would come back for a bundle that was never written.
      if (!_disposed) {
        _held ??= rows;
        _scheduleRetry();
      }
      rethrow;
    }
  }

  Future<void> _ensureLoaded() async {
    if (_loaded || _disposed) return;
    await (_load ??= _readServer());
  }

  /// An explicit read rather than waiting for the snapshot listener to report
  /// a non-cached snapshot.
  ///
  /// The listener cannot carry this. Firestore suppresses an event whose only
  /// change is metadata unless the subscription opts into metadata changes, so
  /// the `isFromCache` true-to-false transition raises nothing when the server
  /// documents match the cache. That is the steady state, and it is trivially
  /// true for a new account where both are empty, which is exactly the offline
  /// sign-in this gate was built for: it would never open and every push would
  /// be held for the life of the process.
  Future<void> _readServer() async {
    try {
      final snap = await _read();
      // A cache-served snapshot says nothing about the server. The SDK falls
      // back to cache without throwing, and offline that is an empty snapshot,
      // which would read as "the server holds nothing" and open the gate.
      if (snap.metadata.isFromCache) return;
      _record(snap.docs);
      _loaded = true;
    } catch (e) {
      // Counted here rather than per call, so only failures spend the budget.
      // Charging every attempt let an offline stretch — which returns above
      // without failing at all — exhaust it, and the first permission-denied
      // afterwards would then be judged permanent on its first occurrence.
      _failedReads++;
      // A permanent failure stops the retry as well: rules that reject this
      // read reject it every time. Pushes stay blocked, which is the right way
      // to be stuck.
      if (!isRetryableFirestoreFailure(e, attempt: _failedReads)) {
        _cancelRetry();
        debugPrint('$collection guard read failed permanently: $e');
      }
    } finally {
      _load = null;
    }
    // Not awaited. The flush commits a batch, and offline a Firestore write
    // resolves only on reconnection, so awaiting it here would hang the
    // original send() and stall _pushContext's fan-out for this transport.
    if (_loaded) unawaited(_flushHeld());
  }

  void _scheduleRetry() {
    if (_retry != null || _disposed) return;
    _retry = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(retryTick()),
    );
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  Future<void> retryTick() async {
    if (_disposed || (_loaded && _held == null)) {
      _cancelRetry();
      return;
    }
    if (_loaded) {
      await _flushHeld();
    } else {
      await _ensureLoaded();
    }
  }

  /// The held bundle is taken when its turn in the queue comes, not when the
  /// flush is asked for. Taken earlier, it would be written after any fresher
  /// push already waiting in the queue and undo it.
  Future<void> _flushHeld() async {
    if (_held == null || _disposed) return;
    final next = _queue.then((_) async {
      final held = _held;
      if (held == null) return;
      await _pushInTurn(held);
    });
    _queue = next.catchError((_) {});
    try {
      await next;
      if (_held == null) _cancelRetry();
    } catch (_) {
      // _pushInTurn has put the bundle back and kept a retry armed. Dropping
      // it, or restoring without rearming, breaks the reason for holding it.
    }
  }

  void dispose() {
    _disposed = true;
    _cancelRetry();
  }
}

