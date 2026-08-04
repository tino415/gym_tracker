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
const int kHeartRateSampleGapMs = 5000;

/// Whether a reading at [nowMs] should be persisted, given the timestamp of the
/// last one that was ([lastPersistedMs], null when none has been yet).
///
/// Pure so it can be unit-tested without standing up the run page, the same
/// treatment the superset walker gets.
///
/// Out-of-order or repeated timestamps say no: sensors occasionally deliver
/// them, and the table is keyed on `{workoutId, measuredAtMs}`, so letting one
/// through would silently overwrite a good reading with a stale one.
bool shouldPersistHeartRate({
  required int? lastPersistedMs,
  required int nowMs,
}) {
  if (lastPersistedMs == null) return true;
  return nowMs - lastPersistedMs >= kHeartRateSampleGapMs;
}
