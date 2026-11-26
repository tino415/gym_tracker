# Watch

## Watch run page lifecycle (`lib/watch/watch_run_page.dart`)
Subscribes to `db.watchFullWorkout(workoutId)`. The listener has a `_initialLoadDone` gate: only the first emission seeds `_exerciseIdx`/`_setIdx` and calls `_loadCurrentSetTargets`. Subsequent emissions update the snapshot for badges but **must not** reload targets, otherwise concurrent DB writes (sync push, rename, completion toggle) would cancel any active rest/countdown timer. If you add new logic that reacts to snapshot changes, keep target reloads gated behind explicit user navigation, never the stream.

## Heart rate on the watch

Capture is native and **must stay that way**. The screen is off through every
set, which pauses the Flutter engine, so anything that samples or thins in Dart
only ever sees the moments the user looks at the watch — i.e. rest. A session
recorded that way stored 50 readings instead of ~680, one per set, and synced to
Health Connect reading near-resting. Three rules came out of it:

- **`ExerciseClient`, not `MeasureClient`** (`WorkoutService.startExerciseOrFallback`).
  The latter is Health Services' on-demand spot measurement for a *visible* app.
  `MeasureClient` survives only as the fallback when the watch can't do a
  strength-training session; `startMeasureFallback` logs when it engages, and
  that log is the first thing to check if heart rate reads low again.
  `ExerciseClient` needs `ACTIVITY_RECOGNITION` on top of the heart rate
  permission, which is `BODY_SENSORS` up to API 35 and `health.READ_HEART_RATE`
  from API 36 (Wear OS 6) on (`HeartRatePermission.kt`). Checking only the
  old one is how heart rate silently stopped after a watch updated to Wear OS
  6; `WorkoutService` now logs `heart rate: … not granted` when the permission
  is why no readings come.
- **Thinning happens at the producer** (`HR_MIN_GAP_MS`, mirroring
  `kHeartRateSampleGapMs` in `lib/watch/heart_rate_thinning.dart` — keep the two
  in sync), and samples are buffered in the service across engine pauses, drained
  on `onListen`. Delivery is idempotent: the table is keyed on
  `{workoutId, measuredAtMs}` and upserts, so a replayed batch is harmless.
- **Aggregates are derived from the stored series, never accumulated live**
  (`heartRateSeriesAverage` / `heartRateSeriesMax`, applied in `_toggleDone` and
  `_finishWorkout`). Live accumulation had the same blind spot as live sampling,
  and it also lost everything when the page was rebuilt or the workout resumed.
  The session average is time-weighted and spans rest by design, so it sits well
  below working HR — that is the statistic, not a bug.

Only `NO_CONTACT` readings are dropped. `ACCURACY_LOW` / `UNRELIABLE` correlate
with a moving wrist, so filtering them cut out the work intervals — a gate that
was added to stop heart rate reading low and did the opposite.

The confidence itself *is* recorded, though (`HeartRateSamples.accuracy`, codes
in `WorkoutService.HR_ACCURACY_*` mirrored as `kHrAccuracy*` in
`heart_rate_thinning.dart` — keep the two in sync). Nothing filters on it yet,
deliberately: it exists so a statistic can weigh it later without any sample
being dropped at capture.

**Why a number can be too high and still not be an outlier.** Dense capture
exposed the opposite failure: sustained plateaus that are smooth,
physiologically shaped and wrong — optical PPG tracking wrist motion rather than
pulse. In the 2026-08-13 session the day's peak landed on cable biceps curls,
~30 bpm above chin-ups, and held for six minutes. Consecutive readings never
move more than ~14 bpm, so *no statistic over bpm alone can see it* — a median
or outlier filter changes nothing. The sensor's own confidence is the only
independent signal, which is what the column is for.
