import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../main.dart';
import 'sync_codec.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';

class SyncService {
  SyncService(
    this._db,
    this._repo, {
    required this.isRoutineAuthority,
    required List<SyncTransport> transports,
  }) : _transports = List.of(transports);

  final AppDatabase _db;
  final SyncRepository _repo;

  /// True on the device that owns routine state (the phone). On the watch this
  /// is false — the watch never pushes its routine bundle, so a routine
  /// deleted on the phone doesn't resurrect itself on the next sync.
  final bool isRoutineAuthority;

  final List<SyncTransport> _transports;
  final Map<SyncTransport, StreamSubscription<SyncMessage>> _messageSubs = {};
  StreamSubscription<Set<TableUpdate>>? _localUpdatesSub;
  Timer? _debounce;
  bool _started = false;

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
            ]),
          )
          .listen((_) => _scheduleContextPush());
    }

    if (isRoutineAuthority) {
      _scheduleContextPush();
    }
    // Ask the peer for their state when we come up. Best-effort — fails
    // silently if a transport isn't reachable yet.
    unawaited(_sendAll(type: syncRequestType, payload: const {}));
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
        case workoutCompletedType:
          final workout = WorkoutCompletedMessage.fromPayload(msg.payload);
          await _repo.applyWorkoutCompleted(workout);
          // Relay onward so a workout finished on the watch (arriving over the
          // Wear bridge) reaches Firestore immediately, instead of waiting for
          // the next manual pushAll. The phone is the only multi-transport hub;
          // a single-transport peer relays to nothing. Routines don't need this
          // — the routine table watcher re-pushes them on apply.
          await _relayToOthers(source, type: msg.type, payload: msg.payload);
        case syncRequestType:
          unawaited(_respondToSyncRequest());
      }
    } catch (_) {
      // best-effort: malformed inbound messages should not crash the app.
    }
  }

  /// Forward an inbound message to every transport except the one it arrived
  /// on. Loop-safe: the source is skipped, and workouts are append-only +
  /// idempotent on syncId (both [SyncRepository.applyWorkoutCompleted] and the
  /// Firestore transport's `_knownWorkouts` cache skip a known id), so an echo
  /// (Firestore snapshot → apply → relay to Wear → watch applies, idempotent)
  /// terminates within one bounded hop. Per-transport failures are swallowed,
  /// and the list is snapshotted so a concurrent attach/detach can't throw.
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
    final all = await (_db.select(
      _db.workouts,
    )..where((t) => t.endedAt.isNotNull())).get();
    for (final w in all) {
      await pushWorkout(w.id);
    }
  }

  void _scheduleContextPush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _pushContext);
  }

  Future<void> _pushContext() async {
    try {
      // Deletions ride inside the bundle as versioned tombstones (routines
      // with a non-null deletedAt), so a lost or empty snapshot can't wipe a
      // peer's routines and there's no per-process deletion diff to maintain.
      // Version-LWW on the receiver arbitrates a tombstone against a concurrent
      // edit; the Firestore transport persists it as a tombstone doc rather
      // than removing the doc, so it survives a stale lower-version upsert.
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
    final all = await (_db.select(
      _db.workouts,
    )..where((t) => t.endedAt.isNotNull())).get();
    for (final w in all) {
      await pushWorkout(w.id);
    }
    // Ask the peer to push their side back to us. Best-effort.
    await _sendAll(type: syncRequestType, payload: const {});
  }

  Future<void> pushWorkout(int workoutId) async {
    final dto = await _repo.exportWorkout(workoutId);
    if (dto == null) return;
    final msg = WorkoutCompletedMessage(dto);
    await _sendAll(type: workoutCompletedType, payload: msg.toPayload());
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    await _localUpdatesSub?.cancel();
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
  );
  svc.start();
  ref.onDispose(() => svc.dispose());
  return svc;
});
