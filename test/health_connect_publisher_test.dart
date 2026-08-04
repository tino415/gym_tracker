import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/health_connect_bridge.dart';
import 'package:gym_tracker/sync/health_connect_publisher.dart';

/// Records what would have been written, instead of touching the platform.
class _RecordingBridge implements HealthConnectBridge {
  final calls = <Map<String, Object?>>[];

  @override
  Future<bool> writeWorkout({
    required int startMs,
    required int endMs,
    String? title,
    String? clientRecordId,
    int clientRecordVersion = 0,
    List<({int tMs, int bpm})> samples = const [],
  }) async {
    calls.add({
      'startMs': startMs,
      'endMs': endMs,
      'title': title,
      'clientRecordId': clientRecordId,
      'clientRecordVersion': clientRecordVersion,
      'samples': samples,
    });
    return true;
  }

  @override
  Future<bool> hasPermissions() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<HealthConnectStatus> status() async => HealthConnectStatus.available;
}

void main() {
  late AppDatabase db;
  late _RecordingBridge bridge;
  late HealthConnectPublisher publisher;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bridge = _RecordingBridge();
    publisher = HealthConnectPublisher(db, bridge: bridge);
  });
  tearDown(() => db.close());

  Future<Workout> finishedWorkout() => db.createWorkout(
    startedAt: DateTime(2026, 3, 4, 18),
    endedAt: DateTime(2026, 3, 4, 19),
  );

  test('publishes a finished workout with its identity and version', () async {
    final w = await finishedWorkout();

    expect(await publisher.publish(w.syncId), isTrue);

    final call = bridge.calls.single;
    expect(call['startMs'], DateTime(2026, 3, 4, 18).millisecondsSinceEpoch);
    expect(call['endMs'], DateTime(2026, 3, 4, 19).millisecondsSinceEpoch);
    // The sync id becomes Health Connect's clientRecordId, which is what makes
    // republishing replace rather than duplicate.
    expect(call['clientRecordId'], w.syncId);
    expect(call['clientRecordVersion'], w.version);
  });

  test('carries the heart-rate series', () async {
    final w = await finishedWorkout();
    for (var i = 0; i < 3; i++) {
      await db.addHeartRateSample(
        workoutId: w.syncId,
        measuredAtMs: 1717171717000 + i * 5000,
        bpm: 120 + i,
      );
    }

    await publisher.publish(w.syncId);

    final samples =
        bridge.calls.single['samples']! as List<({int tMs, int bpm})>;
    expect(samples.map((s) => s.bpm), [120, 121, 122]);
    expect(samples.first.tMs, 1717171717000);
  });

  test('a workout without heart rate still publishes', () async {
    // Phone-run and backfilled workouts have no sensor behind them.
    final w = await finishedWorkout();

    expect(await publisher.publish(w.syncId), isTrue);
    expect(bridge.calls.single['samples'], isEmpty);
  });

  test('a running workout is not published', () async {
    final routine = await db.createRoutine('Push');
    final w = await db.startWorkout(routine.syncId);

    expect(await publisher.publish(w.syncId), isFalse);
    expect(bridge.calls, isEmpty);
  });

  test('a deleted workout is not published', () async {
    final w = await finishedWorkout();
    await db.deleteWorkout(w.syncId);

    expect(await publisher.publish(w.syncId), isFalse);
    expect(bridge.calls, isEmpty);
  });

  test('an unknown workout is not published', () async {
    expect(await publisher.publish('nope'), isFalse);
    expect(bridge.calls, isEmpty);
  });

  test('republishing after an edit carries the higher version', () async {
    final w = await finishedWorkout();
    await publisher.publish(w.syncId);
    final first = bridge.calls.single['clientRecordVersion']! as int;

    // Any edit bumps the workout version.
    await db.updateWorkoutTimes(
      workoutId: w.syncId,
      startedAt: DateTime(2026, 3, 4, 17),
      endedAt: DateTime(2026, 3, 4, 19),
    );
    await publisher.publish(w.syncId);

    // Same record id, higher version — Health Connect supersedes rather than
    // ending up with two copies of the session.
    expect(bridge.calls.last['clientRecordId'], w.syncId);
    expect(bridge.calls.last['clientRecordVersion'], greaterThan(first));
  });
}
