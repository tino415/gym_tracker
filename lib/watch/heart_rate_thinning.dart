/// How often a heart-rate reading is written down, in milliseconds.
///
/// Health Services delivers roughly one sample a second; storing all of them
/// would be ~3.6k rows an hour and ~100 KB of JSON inside a workout's sync
/// document, against Firestore's 1 MiB per-document cap. At one every five
/// seconds it is ~720 rows and ~20 KB, which is ample resolution — heart rate
/// under strength training moves slowly.
///
/// This is *write policy, not schema*: changing it needs no migration, and
/// older workouts simply keep whatever density they were recorded at.
///
/// Thinning itself happens natively, in `WorkoutService.recordHeartRate`
/// (`HR_MIN_GAP_MS`) — keep the two constants in sync. It has to live at the
/// producer: the watch buffers samples while the Flutter engine is asleep, and
/// a gate on the Dart side could only thin what it had already been handed.
const int kHeartRateSampleGapMs = 5000;

/// One stored reading. Structural so the aggregate helpers stay pure — they
/// work equally on rows read back from Drift and on samples still in flight.
typedef HeartRateReadingView = ({int tMs, int bpm});

/// The sensor's confidence in a reading, as stored in
/// `HeartRateSamples.accuracy`. Mirrors `HR_ACCURACY_*` in `WorkoutService.kt`,
/// which mirrors Health Services' `HeartRateAccuracy.SensorStatus` — keep the
/// three in sync. Ordered by confidence, so `>= kHrAccuracyMedium` is a
/// meaningful test.
///
/// Nothing filters on these yet, deliberately. Dropping low-confidence readings
/// at capture was tried and reverted: PPG reports exactly that while the wrist
/// is moving, so the gate removed the work intervals and heart rate read
/// near-resting. The label is recorded first, and what to do with it is decided
/// from a real session's data.
const int kHrAccuracyUnknown = 0;
const int kHrAccuracyNoContact = 1;
const int kHrAccuracyUnreliable = 2;
const int kHrAccuracyLow = 3;
const int kHrAccuracyMedium = 4;
const int kHrAccuracyHigh = 5;

/// Longest gap between two readings that still counts as continuous, for
/// [heartRateSeriesAverage]. A dropout longer than this contributes nothing
/// rather than being counted as steady heart rate across the hole.
const int kHeartRateMaxGapMs = 10000;

/// Time-weighted mean bpm over [samples], or null if there is nothing to
/// average.
///
/// Readings are integrated over time rather than counted, so a dense stretch
/// doesn't outvote a sparse one — the statistic tracks effort over the session
/// the way Samsung Health and Hevy report it, rather than being a plain mean of
/// however many samples happened to land.
///
/// Each interval contributes the mean of the two readings that bound it
/// (trapezoidal). Holding the left reading across the interval instead would
/// give the final reading of the series no weight at all, which biases a
/// session that ends on a hard set.
///
/// Gaps longer than [maxGapMs] are excluded from both the numerator and the
/// denominator. A single reading averages to itself.
int? heartRateSeriesAverage(
  List<HeartRateReadingView> samples, {
  int maxGapMs = kHeartRateMaxGapMs,
}) {
  if (samples.isEmpty) return null;
  if (samples.length == 1) return samples.single.bpm;
  final ordered = [...samples]..sort((a, b) => a.tMs.compareTo(b.tMs));
  var weightedSum = 0.0;
  var weightedMs = 0;
  for (var i = 0; i < ordered.length - 1; i++) {
    final dt = ordered[i + 1].tMs - ordered[i].tMs;
    if (dt <= 0 || dt > maxGapMs) continue;
    weightedSum += (ordered[i].bpm + ordered[i + 1].bpm) / 2 * dt;
    weightedMs += dt;
  }
  // Every interval was a dropout (or duplicates): fall back to the plain mean
  // rather than reporting nothing.
  if (weightedMs == 0) {
    final sum = ordered.fold<int>(0, (a, s) => a + s.bpm);
    return (sum / ordered.length).round();
  }
  return (weightedSum / weightedMs).round();
}

/// Peak bpm over [samples], or null when empty.
int? heartRateSeriesMax(List<HeartRateReadingView> samples) {
  if (samples.isEmpty) return null;
  return samples.map((s) => s.bpm).reduce((a, b) => a > b ? a : b);
}

/// The readings measured within `[fromMs, toMs]` inclusive.
///
/// Used to score a single set from the stored series. Deriving per-set numbers
/// from the series rather than accumulating them live is what makes them
/// survive the screen sleeping mid-set: the samples arrive late, but they
/// arrive stamped with when they were actually measured.
List<HeartRateReadingView> heartRateSeriesBetween(
  List<HeartRateReadingView> samples, {
  required int fromMs,
  required int toMs,
}) =>
    [
      for (final s in samples)
        if (s.tMs >= fromMs && s.tMs <= toMs) s,
    ];
