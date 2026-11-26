# AGENTS.md

How the app works lives in `docs/`, the rules for tests, schema changes and
pull requests in `CONTRIBUTING.md`, and decisions that were argued in
`docs/adr/`. This file holds what surprises an agent. `lib/sync/`, `lib/watch/`,
`lib/data/`, `mcp_server/` and `android/` carry a short `AGENTS.md` of their own
with the rules that must not break there.

## Read before changing

- Read `CONTRIBUTING.md` before writing a test, changing the schema or opening a PR.
- `lib/sync/`, `lib/data/firestore_repositories.dart`, `GymWearBridge.kt`,
  `SyncListenerService.kt`, `SyncQueue.kt`: read `docs/sync.md`.
- `lib/data/`, `drift_schemas/`, `test/migration_test.dart`: read `docs/data-model.md`.
- `lib/watch/`, `lib/phone/run/`, `WorkoutService.kt`, `WorkoutBridge.kt`,
  `HeartRatePermission.kt`: read `docs/watch.md`. The phone run page keeps the
  watch run page's rule: only the first stream emission loads set targets.
- `mcp_server/`, `lib/phone/connect/`: read `docs/mcp-server.md`.
- `web/`, `firebase.json`, a web build or deploy: read `docs/web-pwa.md`.

## Web

- Every web build passes `--dart-define=SYNC_BACKEND=firestore`.
- Compare the account screen's `Build` id with the deployed commit before
  believing a fix did not take.

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

## Architecture

Decisions that were argued rather than obvious are recorded in `docs/adr/`,
one file each. Read the matching record before reopening one of them.

Single Flutter app shipped to both phone and Wear OS — the same binary, with a runtime branch.

### Entry point and shell selection
`lib/main.dart` calls `gym_tracker/platform.isWatch` (handled in Kotlin via `PackageManager.FEATURE_WATCH` — `WatchShape` alone is unreliable) and renders either `PhoneApp` or `_WearShell`. The result is also exposed as `isWatchProvider`, which `syncServiceProvider` reads to decide who is the routine authority.

### Emulator dev loop

`just up` runs the suite; ports and project live in `firebase.json`
(`demo-gym-tracker` = fully offline, no real project/billing).

The hosting emulator serves the *release* bundle, so it's how you exercise the
service worker, PWA install and the `**` → `/index.html` rewrite — none of
which the dev server produces. Build that bundle with `just web-emulator`, not
`just web`: the latter points at the **prod** project, and serving it from the
emulator writes to real data.

`just fs-get <path>` reads emulator documents (rules are enforced even locally;
the recipe carries the admin bypass header).

A phone emulator runs against the same suite with `just phone-apk-emulator` and
`just phone-install phone`, then `just phone-emulator-ports phone` before the
app starts, since the build dials the phone's own localhost.

### Phone UI conventions
- Routine creation is **deferred**: `_ensurePersisted()` only writes the `Routines` row on first save or first add-exercise. The explicit ✓ in the app bar is the save action; on-blur autosave was removed.
- `lib/phone/history/workout_detail_page.dart` is the editable workout view — reps/weights/seconds, started/ended, add/remove completions and exercises, delete workout. It edits the workout's snapshot, never the routine.
