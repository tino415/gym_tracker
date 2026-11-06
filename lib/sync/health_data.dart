/// Whether a workout document actually carries readings.
///
/// Distinct from "has the keys": a document written under the current codec
/// carries `avgHeartRate: null` and an empty `heartRateSamples` whether or not
/// a sensor was involved, and rewriting those to drop empty keys would bump the
/// version of every workout a user owns for no gain.
bool hasHealthData(Map<String, Object?> workout) {
  if (workout['avgHeartRate'] != null) return true;
  if (workout['maxHeartRate'] != null) return true;
  final samples = workout['heartRateSamples'];
  if (samples is List && samples.isNotEmpty) return true;
  final completions = workout['completions'];
  if (completions is List) {
    for (final c in completions) {
      if (c is Map &&
          (c['avgHeartRate'] != null || c['maxHeartRate'] != null)) {
        return true;
      }
    }
  }
  return false;
}

/// Removes every heart-rate field from a workout document.
///
/// Operates on the serialized `WorkoutDto` map rather than the DTO so it can sit
/// at the transport boundary, and covers both the workout-level readings
/// (`heartRateSamples`, `avgHeartRate`, `maxHeartRate`) and the per-set copies
/// carried inside `completions`. Missing keys are fine — this runs on payloads
/// from peers too.
Map<String, Object?> stripHealthData(Map<String, Object?> workout) {
  final out = Map<String, Object?>.from(workout)
    ..remove('heartRateSamples')
    ..remove('avgHeartRate')
    ..remove('maxHeartRate');
  final completions = out['completions'];
  if (completions is List) {
    out['completions'] = [
      for (final c in completions)
        if (c is Map)
          Map<String, Object?>.from(c.cast<String, Object?>())
            ..remove('avgHeartRate')
            ..remove('maxHeartRate')
        else
          c,
    ];
  }
  return out;
}
