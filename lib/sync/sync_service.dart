import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import 'sync_codec.dart';
import 'sync_repository.dart';
import 'wear_bridge.dart';

class SyncService {
  SyncService(this._db, this._repo);

  final AppDatabase _db;
  final SyncRepository _repo;

  StreamSubscription<Set<TableUpdate>>? _localUpdatesSub;
  StreamSubscription<WearMessage>? _messagesSub;
  Timer? _debounce;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;

    final bridge = WearBridge.instance;
    bridge.start();

    _localUpdatesSub = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.workouts,
            _db.workoutExercises,
            _db.plannedSets,
            _db.exercises,
          ]),
        )
        .listen((_) => _scheduleContextPush());

    _messagesSub = bridge.messages.listen(_onIncoming);

    _scheduleContextPush();
  }

  Future<void> _onIncoming(WearMessage msg) async {
    try {
      switch (msg.type) {
        case workoutBundleType:
          final bundle = WorkoutBundleMessage.fromPayload(msg.payload);
          await _repo.applyWorkoutBundle(bundle);
        case sessionCompletedType:
          final session = SessionCompletedMessage.fromPayload(msg.payload);
          await _repo.applySessionCompleted(session);
      }
    } catch (_) {
      // best-effort: malformed inbound messages should not crash the app.
    }
  }

  void _scheduleContextPush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _pushContext);
  }

  Future<void> _pushContext() async {
    try {
      final workouts = await _repo.exportAllWorkouts();
      final msg = WorkoutBundleMessage(workouts);
      await WearBridge.instance.send(
        type: workoutBundleType,
        payload: msg.toPayload(),
      );
    } catch (_) {
      // best-effort
    }
  }

  Future<void> pushSession(int sessionId) async {
    final dto = await _repo.exportSession(sessionId);
    if (dto == null) return;
    try {
      final msg = SessionCompletedMessage(dto);
      await WearBridge.instance.send(
        type: sessionCompletedType,
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
  );
  svc.start();
  ref.onDispose(() => svc.dispose());
  return svc;
});
