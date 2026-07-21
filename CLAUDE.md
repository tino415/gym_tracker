# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter analyze                       # static analysis
flutter test                          # full suite
flutter test test/database_test.dart  # single file
flutter test --plain-name 'superset alternation'  # single test by name
```

Drift codegen — required after editing `lib/data/database.dart`:

```bash
flutter pub run build_runner build --force-jit
```

`--force-jit` is mandatory: `sqlite3_flutter_libs` ≥ 3.0 has a build hook that breaks `dart compile`, which `build_runner` uses by default.

## Web / PWA

`flutter build web` produces an installable PWA (Flutter generates the service
worker). Two committed binaries in `web/` must stay in step with pubspec when
upgrading drift/sqlite3: `sqlite3.wasm` (from the sqlite3.dart GitHub release
matching the `sqlite3` package version) and `drift_worker.js` (from the drift
release matching `drift`). A mismatch fails only at runtime in the browser.

Hosting needs `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` headers, otherwise drift silently
falls back from OPFS to IndexedDB. PWA icons are generated, not hand-drawn —
edit `tool/generate_web_icons.py` and re-run it rather than replacing the PNGs.

**Service-worker stale cache while iterating.** The generated service worker
serves the *previous* `main.dart.js` across reloads (it also serves its own
old `flutter_service_worker.js`, so the new version is never detected, and
`flutter_bootstrap.js` re-registers it every load) — a rebuilt bundle looks
like it never took effect. To test a fresh build: unregister the SW + clear
caches + reload in a *fresh tab* (the old active worker keeps controlling
existing clients until they close), or just build with `--pwa-strategy=none`
during dev iteration. Drift's OPFS DB survives cache clears; it's separate from
the SW app-shell cache.

## Architecture

Single Flutter app shipped to both phone and Wear OS — the same binary, with a runtime branch.

### Entry point and shell selection
`lib/main.dart` calls `gym_tracker/platform.isWatch` (handled in Kotlin via `PackageManager.FEATURE_WATCH` — `WatchShape` alone is unreliable) and renders either `PhoneApp` or `_WearShell`. The result is also exposed as `isWatchProvider`, which `syncServiceProvider` reads to decide who is the routine authority.

### Data layer — Drift, snapshot model
`lib/data/database.dart` defines the schema. Five things to keep in mind:

1. **`PRAGMA foreign_keys = ON` lives in `beforeOpen`.** Drift / sqlite3 don't enable FKs by default; without that pragma, `ON DELETE CASCADE` / `SET NULL` silently no-op. Migrations that need the FKs *off* (rename-recreate dance) must explicitly `PRAGMA foreign_keys = OFF` at the start of the upgrade block — they'll be re-enabled by `beforeOpen` on the next connection.

2. **Workouts own a snapshot of their routine.** `WorkoutExercises` and `WorkoutSets` are copies of `RoutineExercises` / `PlannedSets` taken at workout start (`startWorkout` does it in a transaction). `SetCompletions.workoutSetId` binds to the workout's own snapshot, not back to the routine. Consequence: `Workouts.routineId` is nullable with `SET NULL` on delete — deleting a routine severs the link but never deletes a workout. Anything that needs to render workout history (history page, sync export, watch run page) reads from the snapshot, not from the routine.

3. **Migration ordering matters.** When ALTER TABLE RENAME participates, SQLite re-points FK references at the rename target, so the order of recreate-table steps determines whether downstream tables end up with dangling FKs. The v3→v4 step exists specifically to repair snapshot tables whose `workout_id` FK pointed at the dropped `_workouts_v2`. When writing a new migration that recreates a table, also recreate (or sanity-check) anything whose FK targets it.

4. **Drift stream invalidation needs `customUpdate`.** `customStatement` doesn't notify Drift's stream tracker; pass `updates: {table1, table2}` (or use `tableUpdates` for multi-table watches) so reactive UI sees the change.

5. **Exercise kinds and supersets.** `Exercises.kind` is `'reps'` or `'time'` (constants `exerciseKindReps` / `exerciseKindTime`). Reps-kind sets use `targetReps` + `targetWeightKg`; time-kind sets use `targetSeconds`. The UI reads `kind` to decide which column to render — Drift enforces nothing. Supersets are encoded as `RoutineExercises.supersetGroup` / `WorkoutExercises.supersetGroup` (nullable int): consecutive exercises sharing a non-null group form a superset; rest is taken from the first member's `restSeconds`. The alternation walker is `lib/watch/superset_nav.dart` (`SupersetSeq`) — pure logic, unit-tested in isolation.

### Watch run page lifecycle (`lib/watch/watch_run_page.dart`)
Subscribes to `db.watchFullWorkout(workoutId)`. The listener has a `_initialLoadDone` gate: only the first emission seeds `_exerciseIdx`/`_setIdx` and calls `_loadCurrentSetTargets`. Subsequent emissions update the snapshot for badges but **must not** reload targets, otherwise concurrent DB writes (sync push, rename, completion toggle) would cancel any active rest/countdown timer. If you add new logic that reacts to snapshot changes, keep target reloads gated behind explicit user navigation, never the stream.

### Sync — `lib/sync/`
Phone ↔ watch over the Wear Data Layer (`MessageClient`). The native bridge `GymWearBridge.kt` (with `lib/sync/wear_bridge.dart` on the Dart side, path `/gym_tracker/sync`) is hand-rolled — the `voo_watch` plugin leaks JSONObject into the Flutter codec and crashes, so don't reintroduce it.

- `sync_codec.dart` — DTOs. `WorkoutDto` carries the snapshot (`exercises: [WorkoutExerciseDto{ sets: [...] }]`), so a workout received over sync is self-contained — the receiver doesn't need the source routine to exist.
- `sync_repository.dart` — `applyWorkoutCompleted` inserts the snapshot tables first, then binds completions to the new `workoutSet` ids. Idempotent on `sync_id`.
- `sync_service.dart` — Phone is `isRoutineAuthority: true`; it pushes routine bundles on every local change to routines/exercises/planned_sets (500 ms debounce). Watch never pushes routines (so a phone-deleted routine doesn't get resurrected). Both sides push completed workouts. `pushAll()` is the manual "Sync now" entry point and sends a `syncRequest` to ask the peer for theirs back.

#### Transport abstraction

`SyncService` is transport-agnostic: it fans every send out to a `List<SyncTransport>` and merges their inbound streams (`sync_transport.dart`). It does not know or care whether a message went over the Wear bridge or a server.

- `WearSyncTransport` wraps `WearBridge` (the phone↔watch path above). Always present.
- `addTransport()` attaches a transport at runtime (e.g. the server transport once the user is signed in) and immediately `pushAll()`s so the new channel catches up.
- Message vocabulary lives in `sync_codec.dart`: `routine_bundle` (authoritative full snapshot — the receiver deletes local routines not present; this is what the **watch** applies), `routine_upsert` (non-destructive merge), `routine_deleted` (explicit id list), `workout_completed` (append-only), `sync_request`.

#### Firestore backend — `firestore_transport.dart`, `firestore_backend.dart`

Optional server-backed sync, **off unless built with `--dart-define=SYNC_BACKEND=firestore`** — a normal phone/watch/test build pulls in no Firebase runtime. Layout: `users/{uid}/routines|workouts/{syncId}` hold the plain DTO JSON, so the server is only a document store. Data-loss traps that shaped the design:

- **Push is upsert-only.** It never deletes a doc just because it's absent from the local set — with two authorities (phone *and* web are `isRoutineAuthority`) that would let each wipe the other's routines. Deletions travel **explicitly**: `SyncService._pushContext` diffs successive pushes and emits `routine_deleted` for ids that vanished. `_lastPushedRoutineSyncIds` is the baseline (null on first push, so we never fabricate a deletion for a peer routine we haven't merged yet).
- **Receive is document-granular and non-destructive.** Snapshot listeners turn added/modified docs into `routine_upsert` and removed docs into `routine_deleted`; workouts are append-only. An empty or stale server snapshot can therefore never wipe local routines.
- In-memory caches (`_lastWrittenRoutine`, `_knownWorkouts`) suppress the push→own-snapshot→apply→push echo and avoid a per-push collection read / per-workout existence read.
- Sign-in is **anonymous** for now (uid is per-install, so cross-device sync isn't real yet — real Google/email auth is the next step). `FIREBASE_USE_EMULATOR` defaults **off**; a prod build must not silently dial localhost.

#### Emulator dev loop

Config in `firebase.json` (`demo-gym-tracker` = fully offline, no real project/billing). The Auth/Firestore emulators need a JRE — the nix env sets `JAVA_HOME` but not `java` on PATH, so start with:

```bash
nx bash -c 'export PATH="$JAVA_HOME/bin:$PATH"; firebase emulators:start \
  --only hosting,auth,firestore --project demo-gym-tracker'
```

Ports: hosting 4117, UI 4118, auth 4119, firestore 4120. Build + serve the release PWA against it, and reach it over the nginx TLS vhost (`https://gym.dev.localhost`, needed for `crossOriginIsolated` → OPFS):

```bash
flutter build web --dart-define=SYNC_BACKEND=firestore --dart-define=FIREBASE_USE_EMULATOR=true
```

Inspect emulator data over REST with the admin bypass header `Authorization: Bearer owner` (rules are otherwise enforced, even locally).

### Phone UI conventions
- Routine creation is **deferred**: `_ensurePersisted()` only writes the `Routines` row on first save or first add-exercise. The explicit ✓ in the app bar is the save action; on-blur autosave was removed.
- `lib/phone/history/workout_detail_page.dart` is the editable workout view — reps/weights/seconds, started/ended, add/remove completions and exercises, delete workout. It edits the workout's snapshot, never the routine.
