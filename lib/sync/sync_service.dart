import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import '../main.dart';
import 'sync_codec.dart';
import 'sync_repository.dart';
import 'wear_bridge.dart';

class SyncService {
  SyncService(this._db, this._repo, {required this.isRoutineAuthority});

  final AppDatabase _db;
  final SyncRepository _repo;

  /// True on the device that owns routine state (the phone). On the watch this
  /// is false — the watch never pushes its routine bundle, so a routine
  /// deleted on the phone doesn't resurrect itself on the next sync.
  final bool isRoutineAuthority;

  StreamSubscription<Set<TableUpdate>>? _localUpdatesSub;
  StreamSubscription<WearMessage>? _messagesSub;
  Timer? _debounce;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;

    final bridge = WearBridge.instance;
    bridge.start();

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

    _messagesSub = bridge.messages.listen(_onIncoming);

    if (isRoutineAuthority) {
      _scheduleContextPush();
    }
    // Ask the peer for their state when we come up. Best-effort — fails
    // silently if the bridge isn't reachable yet.
    unawaited(_requestPeerSync());
  }

  Future<void> _requestPeerSync() async {
    try {
      await WearBridge.instance.send(type: syncRequestType, payload: const {});
    } catch (_) {
      // best-effort
    }
  }

  Future<void> _onIncoming(WearMessage msg) async {
    try {
      switch (msg.type) {
        case routineBundleType:
          final bundle = RoutineBundleMessage.fromPayload(msg.payload);
          await _repo.applyRoutineBundle(bundle);
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
      final msg = RoutineBundleMessage(routines);
      await WearBridge.instance.send(
        type: routineBundleType,
        payload: msg.toPayload(),
      );
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
    try {
      await WearBridge.instance.send(type: syncRequestType, payload: const {});
    } catch (_) {
      // best-effort
    }
  }

  Future<void> pushWorkout(int workoutId) async {
    final dto = await _repo.exportWorkout(workoutId);
    if (dto == null) return;
    try {
      final msg = WorkoutCompletedMessage(dto);
      await WearBridge.instance.send(
        type: workoutCompletedType,
        payload: msg.toPayload(),
      );
    } catch (_) {
      // best-effort
    }
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    await _localUpdatesSub?.cancel();
    await _messagesSub?.cancel();
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
  );
  svc.start();
  ref.onDispose(() => svc.dispose());
  return svc;
});
