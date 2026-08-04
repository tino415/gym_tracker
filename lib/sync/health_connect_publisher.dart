import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import 'health_connect_bridge.dart';

/// Publishes a finished workout to Health Connect.
///
/// Best-effort throughout: the workout is already saved locally, so a missing
/// provider, a refused permission or an unfinished workout all mean "don't
/// publish", never an error the user has to deal with mid-session.
class HealthConnectPublisher {
  HealthConnectPublisher(this._db, {HealthConnectBridge? bridge})
      : _bridge = bridge ?? HealthConnectBridge.instance;

  final AppDatabase _db;
  final HealthConnectBridge _bridge;

  /// Publish [workoutId] if it is finished. Returns whether anything was
  /// written.
  ///
  /// Safe to call more than once for the same workout: the bridge passes the
  /// sync id as Health Connect's `clientRecordId`, so a second call replaces
  /// the record rather than creating a duplicate. That is what makes it
  /// reasonable to publish again after an edit.
  Future<bool> publish(String workoutId) async {
    final workout = await (_db.select(
      _db.workouts,
    )..where((t) => t.syncId.equals(workoutId)))
        .getSingleOrNull();
    if (workout == null) return false;
    // Nothing to publish for a session still running or already deleted.
    final endedAt = workout.endedAt;
    if (endedAt == null || workout.deletedAt != null) return false;

    final samples = await _db.heartRateSamplesFor(workoutId);
    return _bridge.writeWorkout(
      startMs: workout.startedAt.millisecondsSinceEpoch,
      endMs: endedAt.millisecondsSinceEpoch,
      title: workout.routineName,
      clientRecordId: workout.syncId,
      // The LWW version doubles as the record version, so an edited workout
      // supersedes what was published before rather than racing it.
      clientRecordVersion: workout.version,
      samples: [
        for (final s in samples) (tMs: s.measuredAtMs, bpm: s.bpm),
      ],
    );
  }
}

final healthConnectPublisherProvider = Provider<HealthConnectPublisher>(
  (ref) => HealthConnectPublisher(ref.watch(databaseProvider)),
);
