import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../main.dart';
import '../phone/settings/health_connect_controller.dart';
import 'health_connect_publisher.dart';
import 'sync_codec.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';

class SyncService {
  SyncService(
    this._db,
    this._repo, {
    required this.isRoutineAuthority,
    required List<SyncTransport> transports,
    this.onWorkoutApplied,
  }) : _transports = List.of(transports);

  final AppDatabase _db;
  final SyncRepository _repo;

  /// True on the device that owns routine state (the phone). On the watch this
  /// is false — the watch never pushes its routine bundle, so a routine
  /// deleted on the phone doesn't resurrect itself on the next sync.
  final bool isRoutineAuthority;

  /// Called with a workout's syncId once an inbound copy has actually been
  /// applied. The phone uses it to publish workouts run on the watch to Health
  /// Connect — those are the ones carrying heart rate, and the watch has no
  /// health store of its own to write to.
  ///
  /// A hook rather than a direct call so this file stays ignorant of Health
  /// Connect. It must not write to the database: a write here would bump the
  /// workout version and make an apply look like a local edit, which is exactly
  /// the loop the relay invariant below depends on not happening.
  final void Function(String workoutSyncId)? onWorkoutApplied;

  final List<SyncTransport> _transports;
  final Map<SyncTransport, StreamSubscription<SyncMessage>> _messageSubs = {};
  StreamSubscription<Set<TableUpdate>>? _localUpdatesSub;
  StreamSubscription<Set<TableUpdate>>? _workoutUpdatesSub;
  Timer? _debounce;
  Timer? _workoutDebounce;
  bool _started = false;

  /// Per workout, the version we last put on the wire or accepted from it.
  /// A workout is pushed only when its local version has moved past this, which
  /// is what keeps applying an inbound workout from bouncing straight back —
  /// see the loop argument on [_relayToOthers].
  final Map<String, int> _syncedWorkoutVersions = {};

  void start() {
    if (_started) return;
    _started = true;

    for (final transport in _transports) {
      transport.start();
      _messageSubs[transport] =
          transport.messages.listen((msg) => _onIncoming(msg, transport));
    }

    if (isRoutineAuthority) {
      _localUpdatesSub = _db
          .tableUpdates(
            TableUpdateQuery.onAllTables([
              _db.routines,
              _db.routineExercises,
              _db.plannedSets,
              _db.exercises,
              _db.exerciseMuscles,
            ]),
          )
          .listen((_) => _scheduleContextPush());
    }

    // Workouts are watched on every device, authority or not: the watch owns
    // the workouts it runs (and can delete them), and the phone owns the
    // history editor. Separate subscription and debounce from the routine push
    // so neither delays the other.
    _workoutUpdatesSub = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.workouts,
            _db.workoutExercises,
            _db.workoutSets,
            _db.setCompletions,
          ]),
        )
        .listen((_) => _scheduleWorkoutPush());

    // Seed the synced-version map from what's already on disk, so coming up
    // doesn't look like every workout was just edited. Catching a peer up is
    // the sync-request exchange's job, not the watcher's.
    unawaited(_reconcileThenSeedWorkoutVersions());

    if (isRoutineAuthority) {
      _scheduleContextPush();
    }
    // Apply anything a transport parked while this app wasn't running (Wear: a
    // WearableListenerService writing to disk), *then* ask the peer for their
    // state. Best-effort — fails silently if a transport isn't reachable yet.
    //
    // The order matters and is not cosmetic: a queued routine bundle can be
    // days old, and if the peer's fresh reply landed first the stale bundle
    // would clobber it — applyRoutineBundle is authoritative and deletes local
    // routines absent from it.
    unawaited(
      _drainPending().then(
        (_) => _sendAll(type: syncRequestType, payload: const {}),
      ),
    );
  }

  /// Drain every transport's offline queue onto its inbound stream, which
  /// [start] has already subscribed to — so the messages land in [_onIncoming]
  /// exactly as a live one would. Per-transport failures are swallowed: a
  /// broken queue must not stop the others or the sync request that follows.
  Future<void> _drainPending() async {
    for (final transport in List<SyncTransport>.of(_transports)) {
      try {
        await transport.drainPending();
      } catch (_) {
        // best-effort
      }
    }
  }

  /// Register an extra transport after start (e.g. the Firestore channel once
  /// the user signs in). Idempotent — re-adding a transport already present is
  /// a no-op.
  ///
  /// When [pushOnAttach] is true (the default) the local state is immediately
  /// pushed so the new channel catches up; existing transports just receive an
  /// idempotent re-push. Pass false to attach without that initial push (the
  /// transport still sends on later local changes).
  void addTransport(SyncTransport transport, {bool pushOnAttach = true}) {
    if (_transports.contains(transport)) return;
    _transports.add(transport);
    if (!_started) return;
    transport.start();
    _messageSubs[transport] =
        transport.messages.listen((msg) => _onIncoming(msg, transport));
    if (pushOnAttach) unawaited(pushAll());
  }

  /// Detach a transport that was added after start (e.g. the Firestore channel
  /// on sign-out or account switch). The collection mutations happen
  /// synchronously before the first await, so a rapid remove(old)+add(new)
  /// swap never interleaves. Cancels the inbound subscription *before*
  /// disposing the transport, so no in-flight snapshot lands in a torn-down
  /// [_onIncoming]. Teardown is best-effort — a throw is swallowed so the
  /// caller (often unawaited from the auth binder) never sees an unhandled
  /// rejection. No-op for a transport that isn't attached.
  Future<void> removeTransport(SyncTransport transport) async {
    if (!_transports.remove(transport)) return;
    final sub = _messageSubs.remove(transport);
    try {
      await sub?.cancel();
      await transport.dispose();
    } catch (_) {
      // best-effort
    }
  }

  /// Send one message to every transport, swallowing per-transport failures —
  /// an unreachable watch must not stop a server push and vice versa.
  Future<void> _sendAll({
    required String type,
    required Map<String, Object?> payload,
  }) async {
    // Iterate a snapshot: a transport may attach or detach (addTransport /
    // removeTransport, driven by sign-in/out) while we're awaiting a send, and
    // mutating the live list mid-iteration would throw. A transport removed
    // mid-send just gets one last best-effort message it can ignore.
    for (final transport in List<SyncTransport>.of(_transports)) {
      try {
        await transport.send(type: type, payload: payload);
      } catch (_) {
        // best-effort
      }
    }
  }

  Future<void> _onIncoming(SyncMessage msg, SyncTransport source) async {
    try {
      switch (msg.type) {
        case routineBundleType:
          final bundle = RoutineBundleMessage.fromPayload(msg.payload);
          await _repo.applyRoutineBundle(bundle);
        case routineUpsertType:
          final bundle = RoutineBundleMessage.fromPayload(msg.payload);
          await _repo.applyRoutineBundleUpsert(bundle);
        case routineDeletedType:
          final del = RoutineDeletedMessage.fromPayload(msg.payload);
          await _repo.deleteRoutinesBySyncId(del.syncIds);
        case exerciseBundleType:
          final bundle = ExerciseBundleMessage.fromPayload(msg.payload);
          await _repo.applyExerciseBundle(bundle);
        case workoutCompletedType:
          final workout = WorkoutCompletedMessage.fromPayload(msg.payload);
          final dto = workout.workout;
          final applied = await _repo.applyWorkoutCompleted(workout);
          if (applied) {
            // Mark it synced *before* the watcher's debounce can fire, so the
            // rows this apply just wrote don't read as a local edit.
            _syncedWorkoutVersions[dto.syncId] = dto.version;
            // Relay onward so a workout finished on the watch (arriving over
            // the Wear bridge) reaches Firestore immediately, instead of
            // waiting for the next manual pushAll. The phone is the only
            // multi-transport hub; a single-transport peer relays to nothing.
            await _relayToOthers(source, type: msg.type, payload: msg.payload);
            // After the relay, so publishing can never delay getting the
            // workout onward to Firestore.
            onWorkoutApplied?.call(dto.syncId);
          } else {
            // Rejected. If ours is strictly newer, the sender is stale and
            // nothing else will fix it — a rejection writes no rows, so the
            // watcher stays quiet. Counter-push once; it carries a strictly
            // greater version, so the peer accepts it and stops there.
            unawaited(_repairStaleWorkout(dto.syncId, dto.version));
          }
        case syncRequestType:
          unawaited(_respondToSyncRequest());
      }
    } catch (_) {
      // best-effort: malformed inbound messages should not crash the app.
    }
  }

  /// Re-push our copy when a peer sent us a strictly older one; no-op when the
  /// message was rejected for any other reason (equal-version no-op, or a live
  /// local session we refuse to clobber).
  Future<void> _repairStaleWorkout(String syncId, int incomingVersion) async {
    try {
      final local = await (_db.select(
        _db.workouts,
      )..where((t) => t.syncId.equals(syncId))).getSingleOrNull();
      if (local == null || local.version <= incomingVersion) return;
      await pushWorkout(syncId);
    } catch (_) {
      // best-effort
    }
  }

  /// Forward an inbound message to every transport except the one it arrived
  /// on.
  ///
  /// Loop-safe by this invariant: for each workout syncId every device keeps
  /// [_syncedWorkoutVersions] = the version it last sent or last accepted from
  /// the wire, and pushes only when the local version has moved past it.
  /// [SyncRepository.applyWorkoutCompleted] assigns the sender's version
  /// verbatim and never increments, and the id is marked synced the moment it
  /// applies — so applying can never leave the workout looking dirty, and no
  /// inbound message can produce an outbound push. The only source of a push is
  /// a local edit, which strictly increases the version. (Corollaries worth
  /// guarding in review: [SyncRepository] must never call an [AppDatabase]
  /// workout mutator, since those bump.)
  ///
  /// The relay itself is one hop — the source is skipped, and a receiver that
  /// already holds the same content applies nothing and relays nothing.
  /// Per-transport failures are swallowed, and the list is snapshotted so a
  /// concurrent attach/detach can't throw.
  Future<void> _relayToOthers(
    SyncTransport source, {
    required String type,
    required Map<String, Object?> payload,
  }) async {
    for (final transport in List<SyncTransport>.of(_transports)) {
      if (identical(transport, source)) continue;
      try {
        await transport.send(type: type, payload: payload);
      } catch (_) {
        // best-effort
      }
    }
  }

  Future<void> _respondToSyncRequest() async {
    if (isRoutineAuthority) {
      await _pushContext();
    }
    for (final w in await _syncableWorkouts()) {
      await pushWorkout(w.syncId);
    }
  }

  void _scheduleContextPush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _pushContext);
  }

  void _scheduleWorkoutPush() {
    _workoutDebounce?.cancel();
    _workoutDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_pushDirtyWorkouts()),
    );
  }

  /// Key marking the one-time post-migration reconciliation as done.
  static const _workoutLwwReconciledKey = 'workout_lww_v13';

  Future<void> _reconcileThenSeedWorkoutVersions() async {
    try {
      await _reconcileWorkoutVersionsOnce();
      for (final w in await _syncableWorkouts()) {
        _syncedWorkoutVersions[w.syncId] = w.version;
      }
    } catch (_) {
      // best-effort
    }
  }

  /// Schema v13 starts every local workout at version 1, and a legacy server
  /// doc with no `version` also reads as 1 — so the first sync after upgrading
  /// would arbitrate equal versions by arrival order and could overwrite phone
  /// history edits that were never pushable before. Bump ours once on the
  /// authority device so those edits win. Runs a single time, ever.
  Future<void> _reconcileWorkoutVersionsOnce() async {
    if (!isRoutineAuthority) return;
    if (await _db.getSyncMeta(_workoutLwwReconciledKey) != null) return;
    await _db.customUpdate(
      'UPDATE workouts SET version = version + 1',
      updates: {_db.workouts},
    );
    await _db.setSyncMeta(_workoutLwwReconciledKey, '1');
  }

  /// Workouts eligible to travel: finished ones, plus tombstones — a workout
  /// abandoned and then deleted never gets an `endedAt`, and its deletion still
  /// has to reach the other devices. A live in-progress workout stays put.
  Future<List<Workout>> _syncableWorkouts() {
    return (_db.select(
      _db.workouts,
    )..where((t) => t.endedAt.isNotNull() | t.deletedAt.isNotNull())).get();
  }

  /// Push only workouts whose local version moved past what we last synced, so
  /// one edit sends one workout instead of re-exporting the whole history.
  Future<void> _pushDirtyWorkouts() async {
    try {
      for (final w in await _syncableWorkouts()) {
        if (_syncedWorkoutVersions[w.syncId] == w.version) continue;
        await pushWorkout(w.syncId);
      }
    } catch (_) {
      // best-effort
    }
  }

  /// Each bundle gets its own try: [_sendAll] already swallows per-transport
  /// failures, so an export is the only thing here that can throw, and a
  /// failure to read one of the two must not silence the other.
  Future<void> _pushContext() async {
    // The library goes out first. Routine slots reference exercises by syncId,
    // and a receiver resolving a slot whose id it has never seen falls back to
    // matching the *name* (_findOrCreateExerciseBySyncId), keeping its own row
    // and discarding the incoming id. A slot left pointing at the wrong row is
    // not self-correcting in the way it looks: a workout started before the
    // next bundle freezes that exercise's name into its snapshot, and nothing
    // rewrites a snapshot.
    //
    // This only orders delivery on a transport that preserves send order,
    // which means the Wear bridge. Over Firestore the two bundles land in
    // separate collections and reach the peer through two independent snapshot
    // listeners, so a web or phone peer can still apply routines first. Closing
    // that needs the routine apply path to tolerate an unseen exercise id,
    // which is a change to every device's apply and is not attempted here.
    // Ordering still buys the watch, which is where the frozen snapshot hurts.
    //
    // The library is authority-owned (phone/web push, watch doesn't) and
    // versioned-LWW like routines, so a lost or empty bundle can't wipe a
    // peer's library. Deletions travel as tombstones inside the bundle.
    try {
      final exercises = await _repo.exportAllExercises();
      await _sendAll(
        type: exerciseBundleType,
        payload: ExerciseBundleMessage(exercises).toPayload(),
      );
    } catch (_) {
      // best-effort
    }

    // Deletions ride inside the bundle as versioned tombstones (routines
    // with a non-null deletedAt), so a lost or empty snapshot can't wipe a
    // peer's routines and there's no per-process deletion diff to maintain.
    // Version-LWW on the receiver arbitrates a tombstone against a concurrent
    // edit; the Firestore transport persists it as a tombstone doc rather
    // than removing the doc, so it survives a stale lower-version upsert.
    try {
      final routines = await _repo.exportAllRoutines();
      final msg = RoutineBundleMessage(routines);
      await _sendAll(type: routineBundleType, payload: msg.toPayload());
    } catch (_) {
      // best-effort
    }
  }

  /// Manually drive a bidirectional sync: push everything we have to the
  /// peer, and ask the peer to push everything they have to us. Used by the
  /// in-app "Sync now" trigger.
  Future<void> pushAll() async {
    if (isRoutineAuthority) {
      await _pushContext();
    }
    for (final w in await _syncableWorkouts()) {
      await pushWorkout(w.syncId);
    }
    // Ask the peer to push their side back to us. Best-effort.
    await _sendAll(type: syncRequestType, payload: const {});
  }

  Future<void> pushWorkout(String workoutId) async {
    final dto = await _repo.exportWorkout(workoutId);
    if (dto == null) return;
    final msg = WorkoutCompletedMessage(dto);
    await _sendAll(type: workoutCompletedType, payload: msg.toPayload());
    // What's on the wire is now our synced baseline; the watcher only fires
    // again once a local edit moves the version past it.
    _syncedWorkoutVersions[workoutId] = dto.version;
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    _workoutDebounce?.cancel();
    await _localUpdatesSub?.cancel();
    await _workoutUpdatesSub?.cancel();
    for (final sub in _messageSubs.values) {
      await sub.cancel();
    }
    _messageSubs.clear();
    for (final transport in _transports) {
      await transport.dispose();
    }
    _transports.clear();
    _started = false;
  }
}

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  return SyncRepository(ref.watch(databaseProvider));
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final svc = SyncService(
    ref.watch(databaseProvider),
    ref.watch(syncRepositoryProvider),
    // Phone is the authority for routine state; the watch only consumes them.
    isRoutineAuthority: !ref.watch(isWatchProvider),
    transports: [WearSyncTransport()],
    // Publish workouts that arrive from the watch — the ones that actually
    // carry heart rate. Phone only: the watch has no Health Connect provider,
    // so the bridge would no-op anyway, but not calling makes that explicit.
    //
    // The opt-in is read at delivery, not captured here, so turning the switch
    // off takes effect immediately rather than at the next restart.
    // Publishing is idempotent (the sync id is the clientRecordId), which is
    // what makes it safe to fire on every apply, including re-deliveries.
    onWorkoutApplied: ref.watch(isWatchProvider)
        ? null
        : (workoutId) {
            if (!ref.read(healthConnectEnabledProvider)) return;
            unawaited(
              ref.read(healthConnectPublisherProvider).publish(workoutId),
            );
          },
  );
  svc.start();
  ref.onDispose(() => svc.dispose());
  return svc;
});
