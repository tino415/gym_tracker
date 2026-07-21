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
  final List<StreamSubscription<SyncMessage>> _messageSubs = [];
  StreamSubscription<Set<TableUpdate>>? _localUpdatesSub;
  Timer? _debounce;
  bool _started = false;

  /// Sync ids present at the previous context push, used to derive which
  /// routines were deleted since. Null until the first push so we never
  /// fabricate a deletion for routines a peer holds that we simply haven't
  /// pushed yet. See [_pushContext].
  Set<String>? _lastPushedRoutineSyncIds;

  void start() {
    if (_started) return;
    _started = true;

    for (final transport in _transports) {
      transport.start();
      _messageSubs.add(transport.messages.listen(_onIncoming));
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

  /// Register an extra transport after start (e.g. the server transport once
  /// the user signs in). Immediately pushes local state so the new channel
  /// catches up; existing transports just receive an idempotent re-push.
  void addTransport(SyncTransport transport) {
    _transports.add(transport);
    if (!_started) return;
    transport.start();
    _messageSubs.add(transport.messages.listen(_onIncoming));
    unawaited(pushAll());
  }

  /// Send one message to every transport, swallowing per-transport failures —
  /// an unreachable watch must not stop a server push and vice versa.
  Future<void> _sendAll({
    required String type,
    required Map<String, Object?> payload,
  }) async {
    for (final transport in _transports) {
      try {
        await transport.send(type: type, payload: payload);
      } catch (_) {
        // best-effort
      }
    }
  }

  Future<void> _onIncoming(SyncMessage msg) async {
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
        case syncRequestType:
          unawaited(_respondToSyncRequest());
      }
    } catch (_) {
      // best-effort: malformed inbound messages should not crash the app.
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
      final routines = await _repo.exportAllRoutines();
      final currentIds = routines.map((r) => r.syncId).toSet();

      // Propagate deletions explicitly rather than by omission. A transport
      // like Firestore holds a shared document set, so "push my whole set and
      // delete anything else" would let one authority wipe another's routines
      // (a peer's routine we simply haven't received yet looks the same as a
      // deleted one). Instead we send a routineDeleted only for ids that were
      // present at our last push and are now gone. Skipped on the first push
      // (no baseline). Deletions that happen while the app is closed aren't
      // re-derived here; the Wear bundle stays authoritative for the watch.
      final previous = _lastPushedRoutineSyncIds;
      if (previous != null) {
        final deleted = previous.difference(currentIds);
        if (deleted.isNotEmpty) {
          await _sendAll(
            type: routineDeletedType,
            payload: RoutineDeletedMessage(deleted.toList()).toPayload(),
          );
        }
      }
      _lastPushedRoutineSyncIds = currentIds;

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
    for (final sub in _messageSubs) {
      await sub.cancel();
    }
    _messageSubs.clear();
    for (final transport in _transports) {
      await transport.dispose();
    }
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
