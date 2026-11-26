# Sync — `lib/sync/`
Phone ↔ watch over the Wear Data Layer (`MessageClient`). The native bridge `GymWearBridge.kt` (with `lib/sync/wear_bridge.dart` on the Dart side, path `/gym_tracker/sync`) is hand-rolled — the `voo_watch` plugin leaks JSONObject into the Flutter codec and crashes, so don't reintroduce it.

- `sync_codec.dart` — DTOs. `WorkoutDto` carries the snapshot (`exercises: [WorkoutExerciseDto{ sets: [...] }]`), so a workout received over sync is self-contained — the receiver doesn't need the source routine to exist.
- `sync_repository.dart` — `applyWorkoutCompleted` inserts the snapshot tables first, then binds completions to the new `workoutSet` ids.
- `sync_service.dart` — Phone is `isRoutineAuthority: true`; it pushes routine bundles on every local change to routines/exercises/planned_sets (500 ms debounce). Watch never pushes routines (so a phone-deleted routine doesn't get resurrected). Both sides push workouts. An **inbound `workout_completed` is relayed to the other transports** (`_relayToOthers`, skipping its source), so a workout finished on the watch reaches Firestore the moment it arrives over the Wear bridge — the phone is the only multi-transport hub. `pushAll()` is the manual "Sync now" entry point and sends a `syncRequest` to ask the peer for theirs back.

## Delivery while the app is closed

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
infrastructure (Gradle runs only through the `just` recipes, never bare). Keep the
Kotlin mechanical and verify it on-device.

## Workouts are version-LWW, like routines

Workouts used to be append-only + idempotent-skip, so **editing a saved workout propagated nowhere**. `Workouts` now carries `version` + `deletedAt`:

- Every mutating `AppDatabase` workout method calls `_bumpWorkoutVersion` (raw SQL + `updates: {workouts}`); the child-id-only ones (`removeWorkoutSet`, `deleteCompletion`, …) resolve the owning workout *before* deleting the row. `startWorkout`/`createWorkout` don't bump — they insert at the default 1.
- `applyWorkoutCompleted` returns `bool applied` and replaces the whole snapshot in one transaction when `incoming.version >= local`. It assigns the DTO's version **verbatim, never incrementing** — that is what keeps an apply invisible to the push path. `SyncRepository` must never call an `AppDatabase` workout mutator, for the same reason.
- Two extra guards: a live local session (`endedAt == null`) is never clobbered, and an identical re-delivery at equal version writes nothing.
- Deletion is a tombstone (`deleteWorkout` drops children, sets `deletedAt`, bumps). Every workout read filters it — `watchInProgressWorkout` most critically, since a tombstone keeps its null `endedAt` and would otherwise offer "Resume" forever.
- `SyncService` watches the four workout tables on **every** device (the watch owns the workouts it runs), debounced 500 ms, and pushes only workouts whose version moved past `_syncedWorkoutVersions[id]`. The push predicate is `endedAt IS NOT NULL OR deletedAt IS NOT NULL`.
- **Loop safety** rests on that map: applying marks the id synced at the applied version, so an apply can never look like a local edit. A rejected *strictly older* inbound triggers one counter-push (a rejection writes no rows, so nothing else would repair the stale peer). The full argument is on `_relayToOthers`.
- Timestamps: drift stores `DateTime` as unix **seconds**, so a DTO carrying sub-second millis (e.g. a doc written by the web) won't survive an apply → export round trip byte-identical. Harmless — it costs one redundant write, then converges.

## Heart rate needs explicit consent to reach the server

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

## Transport abstraction

`SyncService` is transport-agnostic: it fans every send out to a `List<SyncTransport>` and merges their inbound streams (`sync_transport.dart`). It does not know or care whether a message went over the Wear bridge or a server.

- `WearSyncTransport` wraps `WearBridge` (the phone↔watch path above). Always present.
- `addTransport()` attaches a transport at runtime (e.g. the server transport once the user is signed in) and immediately `pushAll()`s so the new channel catches up.
- Message vocabulary lives in `sync_codec.dart`: `routine_bundle` (authoritative full snapshot — the receiver deletes local routines not present; this is what the **watch** applies), `routine_upsert` (non-destructive merge), `routine_deleted` (explicit id list — a legacy hard-delete path, now only fired by a Firestore doc *removal*; ordinary deletions ride as tombstones inside the bundle), `workout_completed` (version-LWW, carries tombstones), `sync_request`.

## Firestore backend — `firestore_transport.dart`, `firestore_backend.dart`

Optional server-backed sync, **off unless built with `--dart-define=SYNC_BACKEND=firestore`** — a normal phone/watch/test build pulls in no Firebase runtime. Layout: `users/{uid}/routines|workouts/{syncId}` hold the plain DTO JSON, so the server is only a document store. Data-loss traps that shaped the design:

- **Push is upsert-only.** It never deletes a doc just because it's absent from the local set — with two authorities (phone *and* web are `isRoutineAuthority`) that would let each wipe the other's routines.
- **Deletions are versioned tombstones (version-LWW).** `deleteRoutine` is a *soft* delete: it drops the routine's child rows and leaves the `Routines` row with `deletedAt` set and a bumped `version` (reads — `watchRoutineSummaries`, `loadFullRoutine`, `loadFullWorkout` — skip tombstoned rows). The tombstone travels inside the ordinary `routine_bundle`/`routine_upsert` as a routine with a non-null `deletedAtMs` and empty exercises, so `_upsertOneRoutine`'s existing version guard arbitrates delete-vs-edit like any other change: a delete at `version ≥ local` wins; a strictly-newer non-tombstone edit revives (clears `deletedAt`). The Firestore doc is *rewritten as a tombstone*, not removed, so it survives a concurrent lower-version upsert. This replaced the old `_pushContext` deletion-diff (`_lastPushedRoutineSyncIds`), which lost deletions across a restart (first push had no baseline) and let a concurrent upsert resurrect a delete. Not yet built: tombstone GC (server + local) — deliberately, since it's coupled to a wanted ~1-week audit log: the GC cutoff has to be that log's retention window, not zero, or a tombstone would vanish before the log could report the deletion.
- **Receive is document-granular and non-destructive.** Snapshot listeners turn added/modified docs (including tombstones) into `routine_upsert`; a genuine doc *removal* still maps to `routine_deleted` (hard delete) as a safety net for future server-side GC; workout docs are upserted by version (never clobbering a strictly newer one) and their deletions ride as tombstone docs, since doc removals are ignored on receive. An empty or stale server snapshot can therefore never wipe local routines.
- In-memory caches (`_lastWrittenRoutine`, `_lastWrittenExercise`, `_serverWorkouts`) suppress the push→own-snapshot→apply→push echo and avoid a per-push collection read. `_serverWorkouts` also holds the last doc *observed* per workout, so it doubles as the version guard; it's written **before** the `set` completes, because the snapshot for our own write can land first.
- The web repo bumps `version` on every workout edit and tombstones on delete. It uses read-modify-write rather than `runTransaction` on purpose: transactions need a server round-trip and fail offline, while a plain write queues in the local cache. The residual lost-update window (a web edit landing in the same instant as a phone push) is narrowed by the transport refusing to overwrite a strictly newer doc.
- Sign-in is real per-user auth — email/password plus Google (web: a `signInWithPopup`; Android: the native `google_sign_in` v7 Credential Manager flow, whose ID token is exchanged for a Firebase credential). See `auth_service.dart` for the per-platform gating. The uid is the account, not the install, so `users/{uid}/…` is genuinely shared across a user's devices, and `firestore.rules` enforces that isolation (`request.auth.uid == uid`). `FIREBASE_USE_EMULATOR` defaults **off**; a prod build must not silently dial localhost.
- **One local store, one owning account** (`sync_ownership.dart`). The server is isolated per account by `firestore.rules`, but the local Drift store is single and global — it is *not* partitioned by uid. The guard is a persisted owner marker (`SyncMeta.owner_uid`): `decideSyncOwnership` attaches the Firestore transport only on a first-ever sign-in (which adopts whatever local data exists) or for the owning account; a **different** account signing in leaves sync paused, so this device never pushes the owner's rows into someone else's collections nor pulls theirs on top. Taking over is an explicit action on the account page. That's defensive hardening, not isolation — a non-owner still *sees* whatever the previous owner left in the local DB. Per-account local scoping is a **non-goal** (decided 2026-08-02): this marker is the permanent answer, and multi-account on one install stays unsupported. Don't propose partitioning the schema by uid.
