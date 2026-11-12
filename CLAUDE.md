# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Everything runnable is a `just` recipe. **Prefer them over raw `flutter` /
`firebase` invocations** — several flags are load-bearing (`--force-jit` for
codegen, the fat `--target-platform` for the watch APK, the `flutter clean`
before a web build), and a recipe carries them for you.

`just` with no argument lists every recipe with its parameters and a one-line
description; that listing is the reference, so there is no need to open the
`Justfile` to find out what exists. Values that vary by machine or device — adb
serials, the release/debug APK mode, the target ABIs —
are variables, printed with their resolved values by `just --evaluate`. Override
any of them inline: `just PHONE_ABIS=android-x64 phone-apk`. The dev stack
(`just up`) is described in `process-compose.yaml`.

Device recipes take an adb serial or the alias `phone` / `watch`, resolved by
form factor (`tool/adb-device.sh`) so a wireless serial's changing port stops
mattering; `just devices-list` shows what is attached. Installs print the
resolved serial and model first — a `pm install` into the wrong device still
says `Success`, so the echo is the only thing that tells you where a build
went. `just phone-apk-demo` seeds demo routines (reps, a circuit pair, a
time-kind hold) on a **first launch into an empty library**, which is what makes
on-device checks cheap; `adb shell pm clear com.otin.gym_tracker` re-arms it.

`web` / `deploy` run `flutter clean` and so wipe `build/`, APKs included. Build
device APKs *after* deploying, or use `release-all`, which orders it for you.

**`flutter test integration_test/…` uninstalls the app when it finishes**, which
takes the local Drift database with it. Fine on an emulator, data loss on a
handset you actually train with — so `e2e` / `e2e-run` / `e2e-watch` refuse a
physical device (`ro.build.characteristics != emulator`) unless
`ALLOW_REAL_DEVICE=1`. Ordinary `phone-install` / `watch-install` are unaffected:
they `pm install -r`, which keeps app data.

`just backup-device` pulls that database off a handset (and `restore-device`
puts one back). Take one before installing a build that carries a schema
migration — a migration runs once, in place, and no release undoes it. Note
that restoring alone is not full recovery: the restored rows carry their
*pre-migration* `version`, so a bad higher-versioned copy already pushed to
Firestore would win the version-LWW arbitration and sync straight back.

## Pull requests

**Merge only a green PR.** `.github/workflows/ci.yml` runs on every non-draft PR
and on every push to `main` (analyze, both test suites, then codegen + schema +
l10n with `git diff --exit-code`, so a schema change pushed without `just
schema` fails). GitHub Free has no branch protection, so nothing enforces it:
check the run yourself. The Termux deploy button deploys only a `main` commit
whose `ci.yml` run completed green.

**A PR that changes anything visible carries screenshots**, one set per form
factor it touches: phone and watch from the emulators (`just phone-apk-demo`,
then `adb screencap`), web from headless Chromium, a flow as a `screenrecord`
clip or numbered stills, before and after for a visual change. Upload them with
the `pr-images` skill, never commit them. A PR with no visible change says so in
one line.

`just deploy` ships Hosting and `firestore:rules` together, so a rules change is
reviewed once, in its PR.

## Testing

Two traps that cost real time, neither guessable from the failure:

1. **Awaiting `.first` on a drift *stream* in a widget test hangs forever.**
   The widget tester's fake clock never advances real-time IO, so the
   subscription never emits and the test sits until the 10-minute timeout with
   no error. Wrap stream reads in `tester.runAsync(...)`. Plain futures
   (`loadFullWorkout`, `createWorkout`, …) are fine awaited directly — it is
   specifically streams. Only applies under `flutter test`: `integration_test/`
   runs on a real binding and real clock, where `.first` is fine.
2. **`integration_test/` files share one browser and one Firebase session.** A
   second `testWidgets` in the same file starts already signed in from the
   first, so it never sees the sign-up form it tries to fill and dies on a
   finder index. Put the extra assertions in one test, or handle both states.
3. **Measuring a dialog's width: scope the finder to *that* dialog.**
   `find.byType(Dialog).first` returns whichever opened first, so a dialog
   opened from another (the exercise picker → "New exercise") silently measures
   the one underneath — a test that passed identically with and without the bug.
   Use `find.ancestor(of: find.text('<title>'), matching: find.byType(Dialog))`,
   and measure the `Material` inside it: the `AlertDialog` render box spans the
   whole route and always reports the viewport width.
4. **Wide layouts only exist in the browser.** Anything gated on
   `masterDetailBreakpoint` — the picker's dialog form, the 3-pane routines view
   — never renders on a phone, and an Android emulator in landscape still takes
   the narrow branch. `just e2e-web-dialogs` is the only place that is checked.
   Plain layout constraints don't need a browser though: a widget test with
   `tester.view.physicalSize` set wide is faster and just as conclusive.
5. **`pumpAndSettle` never settles while a periodic ticker runs.** Any page with
   a rest/hold countdown (`watch_run_page`, `workout_run_page`) keeps a
   `Timer.periodic` alive, so settling times out. Drive those with explicit
   `pump(Duration(...))` calls, and unmount the tree at the end of the test
   (`pumpWidget(const SizedBox())`) or the run ends with a pending-timer
   failure.

### Web-only code paths need `just test-web`

`just test` runs on the VM, where `kIsWeb` is **always false**. Anything gated on
it is compiled but never executed, and a test asserting its absence passes for
the wrong reason. `just test-web` runs a curated subset under
`--platform chrome` so the other branch actually runs; write both directions and
`skip:` the one that doesn't apply (`test/selectable_on_web_test.dart` is the
pattern). Such a test only really passes once **both** recipes have run.

The subset is an explicit list in the `Justfile` because it can't be derived:
anything importing `lib/data/database.dart` pulls drift → sqlite3 → `dart:ffi`,
which a browser lacks, and the run fails to compile rather than skipping.

`just live-build` reads `BUILD_ID` out of the *served* `main.dart.js` and
compares it to HEAD. Unlike the account screen it bypasses the service worker,
so it separates the two failures that look identical: a deploy that didn't take
(mismatch) versus a browser holding a stale bundle (match, app still wrong).

### Schema migrations

`test/migration_test.dart` runs the real migration against a database actually
created at the old version, using drift's schema tooling. The demo seed can't
substitute: it writes through the *current* Drift classes, so it only ever
produces rows already in the new shape.

**After every schema change run `just schema`** (dump + regenerate), or the
tests still validate against the previous version. Then point the existing
`migrateAndValidate` calls at the new version and add the read-back through the
new `DatabaseAtV<n>` — a check-back class one version behind the migrated file
fails with "you've bumped the schema version … didn't provide a strategy",
which reads like a missing migration and is not one.

Three things that bite:

- **Column defaults must be literals.** `schema dump` copies the Dart
  expression verbatim, and the code generated from it imports only drift — so
  `withDefault(const Constant(exerciseKindReps))` compiles in the app and fails
  in the generated schema. Hence `const Constant('reps')` in `Exercises.kind`.
- **Dumping an *older* version needs that version's source.** Check the
  pre-change `database.dart` + `database.g.dart` out of git into place, dump,
  then restore — there's no way to re-derive a schema you never dumped.
- **`isNull` is ambiguous in `migration_test.dart`.** It imports
  `package:drift/drift.dart`, which exports a matcher of that name alongside
  `package:matcher`'s. Assert against plain `null`.

## MCP server

`mcp_server/` is a plain Dart package (mcp_dart, Streamable HTTP) that lets an AI
assistant read a user's data in Firestore; ADR 0001 records how it is
authenticated. It reads the app's DTOs through a path dependency on this
package, so it resolves with `flutter pub get`, and `flutter analyze` at the
root skips it. `just mcp` runs it against the emulators from `just up` (also a
process-compose entry); the dev token is `dev-token` unless `MCP_DEV_TOKEN` says
otherwise, and it maps to `MCP_DEV_UID` or the emulator's only account.

The emulator host variables pick the mode. Without them the server reads
production through Application Default Credentials and refuses to start unless
`GOOGLE_CLOUD_PROJECT`, `MCP_PERSONAL_TOKEN` (32+ characters),
`MCP_PERSONAL_UID` and `MCP_ALLOWED_HOSTS` are all set; the dev token is never
read there. `MCP_ALLOWED_HOSTS` must name the public hostname, or the
DNS-rebinding guard answers every request with a 403. The token and the request
budget (`RequestBudget`, 60 a minute and 1000 a day) are checked before any
Google call, so a flood costs no Firestore read. Deploying is
`docs/mcp-deploy.md`.

`just mcp-test` runs the package's tests on throwaway emulators (`firebase
emulators:exec`), so stop `just up` first: same ports. CI runs it too. `just
mcp-smoke [url]` walks initialize → tools/list → `list_routines` with curl,
token from `MCP_TOKEN`. `just mcp-bundle` builds the native bundle that
`mcp_server/Containerfile` packages, for the host's architecture only, which is
why the Cloud Run image is built in GitHub Actions.

Read tools: `list_routines`, `get_routine`, `list_workouts`, `get_workout`,
`find_exercises`. Workout reads name their fields (the heart-rate series is about
680 samples inline) and pass through `stripHealthData` (now in
`lib/sync/health_data.dart`, re-exported by `health_upload_consent.dart`): there
is no heart-rate scope in v1, so no tool may return one.

A tool never takes a uid. The only route to `users/{uid}/…` is `UserScope`,
which needs a `VerifiedAccount` from `AccountDirectory.verify` (Firebase Auth,
cached a minute). `GymMcpServer` owns the session map instead of using
`StreamableMcpServer`, because there a tool can't learn which user a request
belongs to.

## Web / PWA

`flutter build web` produces an installable PWA (Flutter generates the service
worker).

The web build is **Firestore-direct**: `firestoreDirectProvider`
(`lib/data/providers.dart`) is `kIsWeb && syncBackendEnabled`, so every
repository reads and writes Firestore and the Drift DB is never opened on web.
Every web build therefore passes `--dart-define=SYNC_BACKEND=firestore` (`just
web`, `just deploy`, `just e2e-web`); a build without it falls through to the
unsupported Drift web path in `database.dart` (`DriftWebOptions` → the
committed `web/sqlite3.wasm` + `web/drift_worker.js`, both now vestigial).

**Which bundle am I actually running?** The account screen ends with
`Build <sha>[-dirty]-<yyyymmdd-hhmm>`, stamped by every Justfile build recipe
(`BUILD_ID`). Compare it against the commit you deployed before believing a fix
didn't work — that is usually the whole story, per the next paragraph. `dev`
means the build didn't come from the Justfile at all. It identifies the *Dart*
bundle only: a stale `index.html` or `flutter_bootstrap.js` loads before any
Dart runs and won't be caught by it.

**Service-worker stale cache while iterating.** The generated service worker
serves the *previous* `main.dart.js` across reloads (it also serves its own
old `flutter_service_worker.js`, so the new version is never detected, and
`flutter_bootstrap.js` re-registers it every load) — a rebuilt bundle looks
like it never took effect. To test a fresh build: unregister the SW + clear
caches + reload in a *fresh tab* (the old active worker keeps controlling
existing clients until they close), or just build with `--pwa-strategy=none`
during dev iteration. Firestore's offline cache (IndexedDB) survives cache
clears; it's separate from the SW app-shell cache.

**This bit production, and the fix is in `firebase.json`.** Hosting's default is
`Cache-Control: max-age=3600` for every file, which included
`flutter_service_worker.js` and `flutter_bootstrap.js` — so the worker's own
update check was answered from the HTTP cache, and each time it was, the
cache-first worker re-served the shell it already had. The loop has no upper
bound: a three-day-old bundle survived repeated hard reloads. The `headers`
block now sends `no-cache` for **every** file, so a deploy propagates on the
next load.

It says `**` rather than a list because **Flutter content-hashes nothing in
`build/web`** — `canvaskit/canvaskit.wasm`, `flutter.js` and everything under
`assets/` have fixed names too. The first version of that block listed only the
six shell files and left the rest on `max-age=3600`, on the mistaken belief that
`assets/` and `canvaskit/` were hashed. That let a client pair a fresh
`main.dart.js` with an hour-old CanvasKit runtime — an engine talking to a
renderer it wasn't built against, which is a candidate cause of the WebGL
cross-context errors seen on desktop. `no-cache` is revalidation, not
no-storage, so an unchanged `canvaskit.wasm` still costs a 304 and no bytes.

Also: `web.app` and `firebaseapp.com` are separate *origins* of the same site, so
each keeps its own worker and cache — clearing one leaves the other stale, and
`just live-build` only ever checks `web.app`.

## Architecture

Decisions that were argued rather than obvious are recorded in `docs/adr/`,
one file each. Read the matching record before reopening one of them.

Single Flutter app shipped to both phone and Wear OS — the same binary, with a runtime branch.

### Entry point and shell selection
`lib/main.dart` calls `gym_tracker/platform.isWatch` (handled in Kotlin via `PackageManager.FEATURE_WATCH` — `WatchShape` alone is unreliable) and renders either `PhoneApp` or `_WearShell`. The result is also exposed as `isWatchProvider`, which `syncServiceProvider` reads to decide who is the routine authority.

### Data layer — Drift, snapshot model
`lib/data/database.dart` defines the schema. Five things to keep in mind:

1. **`PRAGMA foreign_keys = ON` lives in `beforeOpen`.** Drift / sqlite3 don't enable FKs by default; without that pragma, `ON DELETE CASCADE` / `SET NULL` silently no-op. Migrations that need the FKs *off* (rename-recreate dance) must explicitly `PRAGMA foreign_keys = OFF` at the start of the upgrade block — they'll be re-enabled by `beforeOpen` on the next connection.

2. **Workouts own a snapshot of their routine.** `WorkoutExercises` and `WorkoutSets` are copies of `RoutineExercises` / `PlannedSets` taken at workout start (`startWorkout` does it in a transaction). `SetCompletions.workoutSetId` binds to the workout's own snapshot, not back to the routine. Consequence: `Workouts.routineId` is nullable and deleting a routine severs the link but never deletes a workout. Deletion is now a *soft* delete (a versioned tombstone — see the sync section): `deleteRoutine` nulls the workout backrefs itself (matching the old FK `SET NULL`) and a routine tombstoned via sync reads as absent in `loadFullWorkout`. Anything that needs to render workout history (history page, sync export, watch run page) reads from the snapshot, not from the routine.

3. **Migration ordering matters.** When ALTER TABLE RENAME participates, SQLite re-points FK references at the rename target, so the order of recreate-table steps determines whether downstream tables end up with dangling FKs. The v3→v4 step exists specifically to repair snapshot tables whose `workout_id` FK pointed at the dropped `_workouts_v2`. When writing a new migration that recreates a table, also recreate (or sanity-check) anything whose FK targets it.

4. **Drift stream invalidation needs `customUpdate`.** `customStatement` doesn't notify Drift's stream tracker; pass `updates: {table1, table2}` (or use `tableUpdates` for multi-table watches) so reactive UI sees the change.

5. **Exercise kinds and circuits.** `Exercises.kind` is `'reps'` or `'time'` (constants `exerciseKindReps` / `exerciseKindTime`). Reps-kind sets use `targetReps` + `targetWeightKg`; time-kind sets use `targetSeconds`. The UI reads `kind` to decide which column to render — Drift enforces nothing. Circuits are encoded as `RoutineExercises.circuitGroup` / `WorkoutExercises.circuitGroup` (nullable int): consecutive exercises sharing a non-null group alternate their sets (set 1 of every member, then set 2, …). The walker is `lib/watch/circuit_nav.dart` (`CircuitSeq`) — pure logic, unit-tested in isolation.

   **Rest is per-exercise and follows every set** (`restSeconds` on the exercise just completed, in both run pages), which is the whole reason the concept was renamed from "superset" in v15: a two-member group with `restSeconds = 0` on the first *is* a classic superset, and anything longer with real rests is circuit training. `0` means advance immediately — the run pages branch on it rather than calling `_startRest(0)`, which would flash a 1s countdown. The v14→v15 migration translates old data (rule in `lib/data/circuit_rest_v15.dart`); `sync_codec.dart` still reads the pre-v15 `supersetGroup` JSON key, since frozen workout documents keep it forever.

### Watch run page lifecycle (`lib/watch/watch_run_page.dart`)
Subscribes to `db.watchFullWorkout(workoutId)`. The listener has a `_initialLoadDone` gate: only the first emission seeds `_exerciseIdx`/`_setIdx` and calls `_loadCurrentSetTargets`. Subsequent emissions update the snapshot for badges but **must not** reload targets, otherwise concurrent DB writes (sync push, rename, completion toggle) would cancel any active rest/countdown timer. If you add new logic that reacts to snapshot changes, keep target reloads gated behind explicit user navigation, never the stream.

### Heart rate on the watch

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

### Sync — `lib/sync/`
Phone ↔ watch over the Wear Data Layer (`MessageClient`). The native bridge `GymWearBridge.kt` (with `lib/sync/wear_bridge.dart` on the Dart side, path `/gym_tracker/sync`) is hand-rolled — the `voo_watch` plugin leaks JSONObject into the Flutter codec and crashes, so don't reintroduce it.

- `sync_codec.dart` — DTOs. `WorkoutDto` carries the snapshot (`exercises: [WorkoutExerciseDto{ sets: [...] }]`), so a workout received over sync is self-contained — the receiver doesn't need the source routine to exist.
- `sync_repository.dart` — `applyWorkoutCompleted` inserts the snapshot tables first, then binds completions to the new `workoutSet` ids.
- `sync_service.dart` — Phone is `isRoutineAuthority: true`; it pushes routine bundles on every local change to routines/exercises/planned_sets (500 ms debounce). Watch never pushes routines (so a phone-deleted routine doesn't get resurrected). Both sides push workouts. An **inbound `workout_completed` is relayed to the other transports** (`_relayToOthers`, skipping its source), so a workout finished on the watch reaches Firestore the moment it arrives over the Wear bridge — the phone is the only multi-transport hub. `pushAll()` is the manual "Sync now" entry point and sends a `syncRequest` to ask the peer for theirs back.

#### Delivery while the app is closed

`GymWearBridge`'s listener lives and dies with the Flutter engine, so a message
sent to a killed app used to be dropped. `SyncListenerService` (manifest-declared,
per-path `MESSAGE_RECEIVED`) now wakes the process and parks the raw envelope via
`SyncQueue.kt`; `SyncService.start()` drains it through `SyncTransport.drainPending()`
onto the ordinary inbound stream, so queued messages apply through `_onIncoming`
with no second code path. Three things that are load-bearing:

- **`GymWearBridge.isEngineListening` gates the queue.** Both the live listener and
  the service fire for the same message; queueing anyway would replay a stale
  `routine_bundle`, and that apply is authoritative (it deletes local routines
  absent from the bundle). The flag must be cleared in `detach()` and not only in
  `onCancel` — `setStreamHandler(null)` does **not** invoke `onCancel`, so relying
  on it alone leaves the flag stuck `true` and silently drops every later message.
- **The drain must complete before the `syncRequest`** (`start()` chains them). A
  queued bundle can be days old; if the peer's fresh reply landed first it would be
  clobbered.
- **Kotlin owns the file.** It reads and truncates itself and hands Dart a
  codec-safe `{type, payload}` list over the existing method channel, so there is no
  `path_provider` dependency and no cross-language file lock. `sync_request` is
  never queued and snapshot types collapse to the newest.

`SyncQueue`'s rules are not unit-tested — there is still no Android test
infrastructure (see the note in `CLAUDE.local.md` about bare Gradle). Keep the
Kotlin mechanical and verify it on-device.

#### Workouts are version-LWW, like routines

Workouts used to be append-only + idempotent-skip, so **editing a saved workout propagated nowhere**. `Workouts` now carries `version` + `deletedAt`:

- Every mutating `AppDatabase` workout method calls `_bumpWorkoutVersion` (raw SQL + `updates: {workouts}`); the child-id-only ones (`removeWorkoutSet`, `deleteCompletion`, …) resolve the owning workout *before* deleting the row. `startWorkout`/`createWorkout` don't bump — they insert at the default 1.
- `applyWorkoutCompleted` returns `bool applied` and replaces the whole snapshot in one transaction when `incoming.version >= local`. It assigns the DTO's version **verbatim, never incrementing** — that is what keeps an apply invisible to the push path. `SyncRepository` must never call an `AppDatabase` workout mutator, for the same reason.
- Two extra guards: a live local session (`endedAt == null`) is never clobbered, and an identical re-delivery at equal version writes nothing.
- Deletion is a tombstone (`deleteWorkout` drops children, sets `deletedAt`, bumps). Every workout read filters it — `watchInProgressWorkout` most critically, since a tombstone keeps its null `endedAt` and would otherwise offer "Resume" forever.
- `SyncService` watches the four workout tables on **every** device (the watch owns the workouts it runs), debounced 500 ms, and pushes only workouts whose version moved past `_syncedWorkoutVersions[id]`. The push predicate is `endedAt IS NOT NULL OR deletedAt IS NOT NULL`.
- **Loop safety** rests on that map: applying marks the id synced at the applied version, so an apply can never look like a local edit. A rejected *strictly older* inbound triggers one counter-push (a rejection writes no rows, so nothing else would repair the stale peer). The full argument is on `_relayToOthers`.
- Timestamps: drift stores `DateTime` as unix **seconds**, so a DTO carrying sub-second millis (e.g. a doc written by the web) won't survive an apply → export round trip byte-identical. Harmless — it costs one redundant write, then converges.

#### Heart rate needs explicit consent to reach the server

Heart rate is special-category data (GDPR Art. 9), and signing in is a contract
for syncing routines and history — it does not cover health data. So the upload
is gated on its own opt-in (`lib/sync/health_upload_consent.dart`), off until
granted, stored per-uid in SharedPreferences (**not** `SyncMeta`: the web build
never opens Drift, and web is signed-in by construction).

Three things are load-bearing:

- **The gate is at the transport, not at export.** `stripHealthData` is applied
  in `FirestoreSyncTransport._pushWorkout` and in the web repository's writes,
  so heart rate still flows phone ↔ watch over the Wear Data Layer — a link
  between two of the user's own devices that never reaches us. Stripping at
  `exportWorkout` would have broken watch → phone.
- **Both write paths must be gated.** Web bypasses the transport entirely
  (`FirestoreWorkoutRepository`), so it carries the same `allowHealthUpload`
  callback. Both default to **false** when unwired — forgetting to pass it
  withholds data rather than leaking it.
- **Withdrawal deletes, it doesn't just stop.** `set` replaces the whole
  document, so revoking re-pushes (phone) or runs `stripStoredHealthData`
  (web) and the readings go. The policy promises this, so it has to stay true.
  Skip documents where `hasHealthData` is false, or every workout gets a
  version bump for nothing.

#### Transport abstraction

`SyncService` is transport-agnostic: it fans every send out to a `List<SyncTransport>` and merges their inbound streams (`sync_transport.dart`). It does not know or care whether a message went over the Wear bridge or a server.

- `WearSyncTransport` wraps `WearBridge` (the phone↔watch path above). Always present.
- `addTransport()` attaches a transport at runtime (e.g. the server transport once the user is signed in) and immediately `pushAll()`s so the new channel catches up.
- Message vocabulary lives in `sync_codec.dart`: `routine_bundle` (authoritative full snapshot — the receiver deletes local routines not present; this is what the **watch** applies), `routine_upsert` (non-destructive merge), `routine_deleted` (explicit id list — a legacy hard-delete path, now only fired by a Firestore doc *removal*; ordinary deletions ride as tombstones inside the bundle), `workout_completed` (version-LWW, carries tombstones), `sync_request`.

#### Firestore backend — `firestore_transport.dart`, `firestore_backend.dart`

Optional server-backed sync, **off unless built with `--dart-define=SYNC_BACKEND=firestore`** — a normal phone/watch/test build pulls in no Firebase runtime. Layout: `users/{uid}/routines|workouts/{syncId}` hold the plain DTO JSON, so the server is only a document store. Data-loss traps that shaped the design:

- **Push is upsert-only.** It never deletes a doc just because it's absent from the local set — with two authorities (phone *and* web are `isRoutineAuthority`) that would let each wipe the other's routines.
- **Deletions are versioned tombstones (version-LWW).** `deleteRoutine` is a *soft* delete: it drops the routine's child rows and leaves the `Routines` row with `deletedAt` set and a bumped `version` (reads — `watchRoutineSummaries`, `loadFullRoutine`, `loadFullWorkout` — skip tombstoned rows). The tombstone travels inside the ordinary `routine_bundle`/`routine_upsert` as a routine with a non-null `deletedAtMs` and empty exercises, so `_upsertOneRoutine`'s existing version guard arbitrates delete-vs-edit like any other change: a delete at `version ≥ local` wins; a strictly-newer non-tombstone edit revives (clears `deletedAt`). The Firestore doc is *rewritten as a tombstone*, not removed, so it survives a concurrent lower-version upsert. This replaced the old `_pushContext` deletion-diff (`_lastPushedRoutineSyncIds`), which lost deletions across a restart (first push had no baseline) and let a concurrent upsert resurrect a delete. Not yet built: tombstone GC (server + local) — deliberately, since it's coupled to a wanted ~1-week audit log: the GC cutoff has to be that log's retention window, not zero, or a tombstone would vanish before the log could report the deletion.
- **Receive is document-granular and non-destructive.** Snapshot listeners turn added/modified docs (including tombstones) into `routine_upsert`; a genuine doc *removal* still maps to `routine_deleted` (hard delete) as a safety net for future server-side GC; workout docs are upserted by version (never clobbering a strictly newer one) and their deletions ride as tombstone docs, since doc removals are ignored on receive. An empty or stale server snapshot can therefore never wipe local routines.
- In-memory caches (`_lastWrittenRoutine`, `_lastWrittenExercise`, `_serverWorkouts`) suppress the push→own-snapshot→apply→push echo and avoid a per-push collection read. `_serverWorkouts` also holds the last doc *observed* per workout, so it doubles as the version guard; it's written **before** the `set` completes, because the snapshot for our own write can land first.
- The web repo bumps `version` on every workout edit and tombstones on delete. It uses read-modify-write rather than `runTransaction` on purpose: transactions need a server round-trip and fail offline, while a plain write queues in the local cache. The residual lost-update window (a web edit landing in the same instant as a phone push) is narrowed by the transport refusing to overwrite a strictly newer doc.
- Sign-in is real per-user auth — email/password plus Google (web: a `signInWithPopup`; Android: the native `google_sign_in` v7 Credential Manager flow, whose ID token is exchanged for a Firebase credential). See `auth_service.dart` for the per-platform gating. The uid is the account, not the install, so `users/{uid}/…` is genuinely shared across a user's devices, and `firestore.rules` enforces that isolation (`request.auth.uid == uid`). `FIREBASE_USE_EMULATOR` defaults **off**; a prod build must not silently dial localhost.
- **One local store, one owning account** (`sync_ownership.dart`). The server is isolated per account by `firestore.rules`, but the local Drift store is single and global — it is *not* partitioned by uid. The guard is a persisted owner marker (`SyncMeta.owner_uid`): `decideSyncOwnership` attaches the Firestore transport only on a first-ever sign-in (which adopts whatever local data exists) or for the owning account; a **different** account signing in leaves sync paused, so this device never pushes the owner's rows into someone else's collections nor pulls theirs on top. Taking over is an explicit action on the account page. That's defensive hardening, not isolation — a non-owner still *sees* whatever the previous owner left in the local DB. Per-account local scoping is a **non-goal** (decided 2026-08-02): this marker is the permanent answer, and multi-account on one install stays unsupported. Don't propose partitioning the schema by uid.

#### Emulator dev loop

`just up` runs the suite; ports and project live in `firebase.json`
(`demo-gym-tracker` = fully offline, no real project/billing).

The hosting emulator serves the *release* bundle, so it's how you exercise the
service worker, PWA install and the `**` → `/index.html` rewrite — none of
which the dev server produces. Build that bundle with `just web-emulator`, not
`just web`: the latter points at the **prod** project, and serving it from the
emulator writes to real data.

`just fs-get <path>` reads emulator documents (rules are enforced even locally;
the recipe carries the admin bypass header).

### Phone UI conventions
- Routine creation is **deferred**: `_ensurePersisted()` only writes the `Routines` row on first save or first add-exercise. The explicit ✓ in the app bar is the save action; on-blur autosave was removed.
- `lib/phone/history/workout_detail_page.dart` is the editable workout view — reps/weights/seconds, started/ended, add/remove completions and exercises, delete workout. It edits the workout's snapshot, never the routine.
