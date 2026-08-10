import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/sync_codec.dart';
import 'package:gym_tracker/sync/sync_repository.dart';
import 'package:gym_tracker/watch/heart_rate_thinning.dart';

/// Heart rate stored as a timestamped series, so Health Connect's
/// `HeartRateRecord` can be written from real samples rather than reconstructed
/// from the avg/max aggregates, which it can't honestly be.
void main() {
  group('series aggregates', () {
    List<HeartRateReadingView> series(List<(int, int)> pairs) =>
        [for (final (t, bpm) in pairs) (tMs: t, bpm: bpm)];

    test('an empty series has no average and no peak', () {
      expect(heartRateSeriesAverage(const []), isNull);
      expect(heartRateSeriesMax(const []), isNull);
    });

    test('a single reading averages to itself', () {
      expect(heartRateSeriesAverage(series([(1000, 130)])), 130);
    });

    test('readings are integrated over time, not counted', () {
      // 60 bpm held for 20 s, then a ramp to 120 over the last 5 s. Counting
      // the four readings equally says 75; integrating over the 25 s says 66.
      final s = series([
        (0, 60),
        (10000, 60),
        (20000, 60),
        (25000, 120),
      ]);
      expect(heartRateSeriesAverage(s, maxGapMs: 20000), 66);
    });

    test('the last reading still carries weight', () {
      // Holding each reading until the next one would score this session at
      // 60 — the closing effort would vanish entirely.
      final s = series([(0, 60), (5000, 180)]);
      expect(heartRateSeriesAverage(s), 120);
    });

    test('a dropout longer than the cap is not counted as steady', () {
      // Ten minutes of silence between two readings must not be scored as
      // "60 bpm for ten minutes" — it is missing data, not a measurement.
      final s = series([(0, 60), (600000, 160), (605000, 160)]);
      expect(heartRateSeriesAverage(s), 160);
    });

    test('unordered input is sorted before weighting', () {
      final s = series([(20000, 60), (0, 60), (25000, 120)]);
      expect(
        heartRateSeriesAverage(s, maxGapMs: 20000),
        heartRateSeriesAverage(
          series([(0, 60), (20000, 60), (25000, 120)]),
          maxGapMs: 20000,
        ),
      );
    });

    test('the peak survives even when it is a lone spike', () {
      expect(heartRateSeriesMax(series([(0, 60), (5000, 171), (10000, 62)])),
          171);
    });

    test('a window keeps only readings inside it, bounds included', () {
      final s = series([(0, 60), (5000, 100), (10000, 140), (15000, 90)]);
      final windowed = heartRateSeriesBetween(s, fromMs: 5000, toMs: 10000);
      expect(windowed.map((r) => r.bpm), [100, 140]);
    });
  });

  group('storage', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<Workout> seedWorkout() => db.createWorkout(
      startedAt: DateTime(2026, 3, 4, 18),
      endedAt: DateTime(2026, 3, 4, 19),
    );

    test('samples read back oldest first', () async {
      final w = await seedWorkout();
      for (final t in [3000, 1000, 2000]) {
        await db.addHeartRateSample(
          workoutId: w.syncId,
          measuredAtMs: t,
          bpm: 100 + t ~/ 1000,
        );
      }

      final samples = await db.heartRateSamplesFor(w.syncId);
      expect(samples.map((s) => s.measuredAtMs), [1000, 2000, 3000]);
      expect(samples.map((s) => s.bpm), [101, 102, 103]);
    });

    test('a repeated timestamp overwrites instead of throwing', () async {
      final w = await seedWorkout();
      await db.addHeartRateSample(
        workoutId: w.syncId,
        measuredAtMs: 1000,
        bpm: 120,
      );
      await db.addHeartRateSample(
        workoutId: w.syncId,
        measuredAtMs: 1000,
        bpm: 130,
      );

      final samples = await db.heartRateSamplesFor(w.syncId);
      expect(samples, hasLength(1));
      expect(samples.single.bpm, 130);
    });

    test('sub-second precision survives the database', () async {
      // The reason measuredAtMs is an integer column: drift stores DateTime as
      // unix seconds, and a truncated timestamp would break the export/apply
      // comparison that suppresses sync echoes.
      final w = await seedWorkout();
      await db.addHeartRateSample(
        workoutId: w.syncId,
        measuredAtMs: 1717171717123,
        bpm: 140,
      );

      final samples = await db.heartRateSamplesFor(w.syncId);
      expect(samples.single.measuredAtMs, 1717171717123);
    });

    test('deleting a workout takes its samples', () async {
      final w = await seedWorkout();
      await db.addHeartRateSample(
        workoutId: w.syncId,
        measuredAtMs: 1000,
        bpm: 120,
      );

      // A soft delete: the Workouts row survives as a tombstone, so no FK
      // cascade fires and the samples must be removed explicitly.
      await db.deleteWorkout(w.syncId);

      expect(await db.heartRateSamplesFor(w.syncId), isEmpty);
    });

    test('writing a sample does not bump the workout version, finishing does',
        () async {
      final w = await seedWorkout();
      Future<int> version() async => (await db.watchRecentWorkouts().first)
          .firstWhere((x) => x.syncId == w.syncId)
          .version;
      final before = await version();

      await db.addHeartRateSample(
        workoutId: w.syncId,
        measuredAtMs: 1000,
        bpm: 120,
      );

      // Samples arrive continuously through a live run; bumping per sample
      // would be hundreds of pointless writes, and a live workout isn't
      // pushable anyway.
      expect(await version(), before);

      await db.finishWorkout(w.syncId, avgHeartRate: 120, maxHeartRate: 130);

      // The single bump that carries the whole series out to peers.
      expect(await version(), greaterThan(before));
    });
  });

  group('sync round-trip', () {
    late AppDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    Future<String> seedWorkoutWithSamples() async {
      final w = await db.createWorkout(
        startedAt: DateTime(2026, 3, 4, 18),
        endedAt: DateTime(2026, 3, 4, 19),
      );
      for (var i = 0; i < 5; i++) {
        await db.addHeartRateSample(
          workoutId: w.syncId,
          measuredAtMs: 1717171717000 + i * kHeartRateSampleGapMs,
          bpm: 120 + i,
        );
      }
      return w.syncId;
    }

    test('samples survive export and re-import byte-identically', () async {
      final id = await seedWorkoutWithSamples();
      final exported = await repo.exportWorkout(id);
      expect(exported!.heartRateSamples, hasLength(5));

      // Round-trip through JSON and back into a *fresh* database, then export
      // again. Byte-identical JSON is the invariant applyWorkoutCompleted
      // relies on to suppress echoes — if it fails, every workout carrying
      // heart rate re-pushes on every sync, forever.
      final json = jsonDecode(jsonEncode(exported.toJson()))
          as Map<String, Object?>;
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      final otherRepo = SyncRepository(other);
      await otherRepo.applyWorkoutCompleted(
        WorkoutCompletedMessage(WorkoutDto.fromJson(json)),
      );

      final reExported = await otherRepo.exportWorkout(id);
      expect(
        jsonEncode(reExported!.toJson()),
        jsonEncode(exported.toJson()),
      );
      expect(reExported.heartRateSamples.map((s) => s.tMs),
          exported.heartRateSamples.map((s) => s.tMs));
    });

    test('a workout from a peer without the field still applies', () async {
      // Older peers and legacy Firestore docs have no heartRateSamples key.
      final id = await seedWorkoutWithSamples();
      final json = (await repo.exportWorkout(id))!.toJson()
        ..remove('heartRateSamples');

      final dto = WorkoutDto.fromJson(json);

      expect(dto.heartRateSamples, isEmpty);
    });

    test('re-applying replaces the series rather than appending', () async {
      final id = await seedWorkoutWithSamples();
      final exported = await repo.exportWorkout(id);

      await repo.applyWorkoutCompleted(
        WorkoutCompletedMessage(
          WorkoutDto.fromJson(exported!.toJson()),
        ),
      );

      expect(await db.heartRateSamplesFor(id), hasLength(5));
    });
  });
}
