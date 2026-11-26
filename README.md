# GymTracker

An offline-first gym workout tracker. One Flutter binary runs on an Android
phone and on a Wear OS watch, picking its shell at runtime, and the same code
builds a web app that installs as a PWA.

- Web build: https://gym-tracker-44a5f.web.app
- Android package `com.otin.gym_tracker`, minSdk 30. Not on Play yet.

## What it does

Routines are lists of exercises with planned sets. A set is either reps plus
weight or a timed hold, rest is configured per exercise, and consecutive
exercises can share a circuit group so their sets alternate. A pristine install
seeds a starter exercise library with muscle tags.

You run a workout from the watch, one set at a time, with the rest countdown on
screen and heart rate sampled natively through the whole session. The phone can
run a workout too, and it can backfill or edit one afterwards.

A workout copies the routine when it starts and owns that copy forever, so
editing or deleting a routine never rewrites past history.

Finished workouts can publish to Health Connect as exercise sessions with their
heart-rate series, behind a toggle on the account screen.

## Running it

`just` is the entry point for everything. Run it with no argument to get every
recipe with its parameters and a one-line description. That listing is the
reference. Read it rather than copying flags out of the `Justfile`, because a
few of them are load-bearing and easy to drop.

A fresh machine needs Flutter (3.38 stable, Dart SDK `^3.10.1`), the Android SDK
with `adb`, the Firebase CLI, `just` and `process-compose` on PATH. Nothing in
the repo installs a toolchain, so how they get there is your choice.

The ones you want first:

- `just test`, `just test-web`, `just analyze`
- `just up` starts the dev stack, which is the Firebase emulator suite plus the
  Flutter web dev server. See `process-compose.yaml`.
- `just phone-apk` then `just phone-install phone`, and `watch-apk` /
  `watch-install` for the watch. Device recipes take an adb serial or the alias
  `phone` / `watch`, resolved by form factor. `just devices-list` shows what is
  attached.
- `just web` builds the production bundle, `just deploy` ships it to Firebase
  Hosting, `just live-build` tells you whether what is served matches HEAD.
- `just phone-apk-demo` seeds demo routines on a first launch into an empty
  library, which makes on-device checks cheap.

Two things that cost data if you learn them the hard way. `web` and `deploy` run
`flutter clean` and so wipe `build/`, APKs included, which is why `release-all`
exists to order a full release correctly. And a run of `flutter test
integration_test/…` uninstalls the app when it finishes, taking the local
database with it, so the `e2e` recipes refuse a physical device unless you pass
`ALLOW_REAL_DEVICE=1`. Use `just backup-device` before installing anything that
carries a schema migration.

Device serials, emulator names, local domains and whatever puts the toolchain on
PATH are machine-specific and live in `CLAUDE.local.md`, which is gitignored. A
fresh checkout has none of them, so you supply your own.

## Sync and storage

The app is usable with no account. Phone and watch each keep everything in a
local Drift/SQLite database and sync directly to each other over the Wear Data
Layer, with no server involved.

Signing in with email or Google adds a second transport that reads and writes
`users/{uid}/…` in Firestore, so a phone, a watch and a browser converge on the
same routines and history. Firebase is compiled in only with
`--dart-define=SYNC_BACKEND=firestore`; without it the build carries no Firebase
runtime and stays local-only.

The web build is the exception: it talks to Firestore directly, never opens
Drift, and therefore always needs an account. It is the comfortable place to
edit routines with a keyboard.

Routines and workouts carry a version, the later version wins, and deletions
travel as tombstones instead of removals so an empty snapshot can never wipe a
device. `lib/sync/` holds all of it.

## Privacy

No analytics, no ads, no crash reporting. Signed out, nothing leaves the device.

Heart rate is handled apart from the rest. It flows between your own phone and
watch over the Wear Data Layer, but sending it to the server takes its own
consent, which is off until you grant it. Withdrawing it deletes the readings
already uploaded rather than only stopping new ones. The published policy is at
https://gym-tracker-44a5f.web.app/privacy.html and its source is
`web/privacy.html`.

## Layout

- `lib/main.dart` detects the watch and picks the phone or watch shell.
- `lib/data/` is the Drift schema, the repositories over it and the seed data.
- `lib/phone/`, `lib/watch/` are the two UIs.
- `lib/sync/` is the transports, the codec, auth and the Health Connect
  publisher.
- `android/app/src/main/kotlin/…` is the native side: watch detection, the Wear
  message bridge and its wake-up service, the Health Services heart-rate
  session, and the Health Connect writer.
- `test/`, `integration_test/`, `drift_schemas/`, `tool/`, `web/`.

## Internals

`docs/` documents how the thing actually works and which invariants break if
you ignore them: the workout snapshot model, migration ordering, why heart-rate
capture has to stay native, how sync arbitrates and avoids loops, and the
service-worker traps in the web build. `CONTRIBUTING.md` holds the rules for
tests, schema changes and pull requests, and `AGENTS.md`, in the root and beside
the code, the short rules an agent must not break. All of it is written for
someone changing the code, not for someone meeting the app, which is why this
README does not repeat it.
