# android

Heart rate rules are argued in `docs/watch.md`, bridge and queue rules in
`docs/sync.md`.

- Heart rate capture stays native and uses `ExerciseClient`; `MeasureClient` is
  the fallback only.
- Only `NO_CONTACT` readings are dropped; nothing filters on accuracy.
- `HR_MIN_GAP_MS` and `HR_ACCURACY_*` mirror the Dart constants in
  `heart_rate_thinning.dart`.
- The heart rate permission is `BODY_SENSORS` up to API 35 and
  `health.READ_HEART_RATE` from API 36.
- `GymWearBridge.isEngineListening` is cleared in `detach()`, not only in
  `onCancel`.
- Kotlin owns the queue file; `sync_request` is never queued and snapshot types
  collapse to the newest.
- `SyncQueue` has no unit tests: keep it mechanical and verify it on a device.
- `isWatch` is `PackageManager.FEATURE_WATCH`, never `WatchShape`.
