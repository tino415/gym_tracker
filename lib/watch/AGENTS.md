# lib/watch

Read `docs/watch.md` before changing a file here.

- Only the first stream emission loads set targets; a later reload follows user
  navigation, never the stream.
- `lib/phone/run/workout_run_page.dart` holds the same invariant.
- Heart rate is never sampled or thinned in Dart: the engine is paused through
  every set.
- Heart rate aggregates are derived from the stored series, never accumulated
  live.
- `kHeartRateSampleGapMs` and `kHrAccuracy*` mirror the Kotlin constants in
  `WorkoutService`.
- Rest is per exercise and follows every set; `restSeconds` 0 advances at once,
  never through `_startRest(0)`. `docs/data-model.md` item 5 argues it.
