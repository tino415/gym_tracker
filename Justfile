# Common build / test / e2e commands for gym_tracker.
# `just` (or `nx just`) lists recipes; `just <name>` runs one.
#
# Lessons baked in:
#  * The watch never uses Firebase; phone/web opt in with
#    --dart-define=SYNC_BACKEND=firestore.
#  * Every APK recipe writes build/app/outputs/flutter-apk/app-debug.apk
#    (app-release.apk when APK_MODE resolves to --release).

# --- Host- and device-dependent knobs ----------------------------------------
# Override any of these on the command line, e.g. `just PHONE_ABIS=android-x64
# phone-apk` — no env plumbing needed.

# A release build needs gen_snapshot, which Flutter ships only for x86_64 Linux
# hosts; on an aarch64 host `flutter build apk --release` dies for lack of it.
# Debug (JIT) APKs are fine for on-device testing.
APK_MODE := if arch() == "aarch64" { "--debug" } else { "--release" }

# Target-device ABIs. The watch APK is fat (32 + 64) because plenty of shipping
# Wear OS watches are 32-bit armeabi-v7a while Wear emulators are arm64 — an
# arm64-only APK installs on such a watch and then crashes at launch with a
# missing libflutter.so.
WATCH_ABIS := "android-arm,android-arm64"
PHONE_ABIS := "android-arm64"

# adb serials for the e2e recipes. No default in the repo — a serial is a
# property of your local emulators/devices. Set them in the environment, or
# pass one explicitly: `just e2e <serial>`.
PHONE_DEVICE := env_var_or_default("GYM_PHONE_DEVICE", "")
WEAR_DEVICE := env_var_or_default("GYM_WEAR_DEVICE", "")

# List recipes
default:
    @just --list

# Static analysis
analyze:
    flutter analyze

# Unit + widget test suite. --no-pub skips the (slow) implicit `pub get` on every
# run; run `flutter pub get` yourself after changing dependencies.
[doc('Unit + widget test suite')]
test:
    flutter test --no-pub

# A single test file, e.g. `just test-file test/database_test.dart`
test-file file:
    flutter test --no-pub {{file}}

# A single test by name, e.g. `just test-name 'superset alternation'`
test-name name:
    flutter test --no-pub --plain-name '{{name}}'

# Drift codegen — run after editing lib/data/database.dart. --force-jit is
# mandatory: sqlite3_flutter_libs >= 3.0 ships a build hook that breaks
# `dart compile`, which build_runner uses by default.
[doc('Drift codegen (run after editing lib/data/database.dart)')]
codegen:
    flutter pub run build_runner build --force-jit

# APK for the watch + Wear emulator (fat 32+64 by default)
watch-apk:
    flutter build apk {{APK_MODE}} --target-platform {{WATCH_ABIS}}

# APK for the phone + Firestore backend. The Google Web client id
# (serverClientId for the native Android sign-in) is baked into the app as a
# const default, so no dart-define is needed here. Override only to target a
# different Firebase project: GOOGLE_SERVER_CLIENT_ID=... just phone-apk.
[doc('APK for the phone + Firestore backend')]
phone-apk:
    flutter build apk {{APK_MODE}} --target-platform {{PHONE_ABIS}} --dart-define=SYNC_BACKEND=firestore \
      {{ if env_var_or_default("GOOGLE_SERVER_CLIENT_ID", "") != "" { "--dart-define=GOOGLE_SERVER_CLIENT_ID=" + env_var("GOOGLE_SERVER_CLIENT_ID") } else { "" } }}

# Phone integration test on a device/emulator. Uses GYM_PHONE_DEVICE unless a
# serial is passed; `adb devices` lists them.
[doc('Phone integration test on a device/emulator')]
e2e device=PHONE_DEVICE:
    @test -n "{{device}}" || { echo "no device: pass an adb serial or set GYM_PHONE_DEVICE" >&2; exit 1; }
    flutter test integration_test/routine_flow_test.dart -d {{device}}

# Watch integration test on a Wear device/emulator (pass the adb serial, as for
# `e2e`). The test sets WorkoutBridge's platform-skip seam itself, so no
# permission dialog blocks the run.
[doc('Watch integration test on a Wear device/emulator')]
e2e-watch device=WEAR_DEVICE:
    @test -n "{{device}}" || { echo "no device: pass an adb serial or set GYM_WEAR_DEVICE" >&2; exit 1; }
    flutter test integration_test/watch_flow_test.dart -d {{device}}

# Web e2e in headless Chrome (needs the emulator suite running: just up)
e2e-web:
    #!/usr/bin/env bash
    chromedriver --port=4444 & cdpid=$!
    trap 'kill $cdpid 2>/dev/null' EXIT
    sleep 1
    flutter drive --driver=test_driver/integration_test.dart \
      --target=integration_test/web_flow_test.dart -d web-server \
      --browser-name=chrome --headless --driver-port=4444 \
      --dart-define=SYNC_BACKEND=firestore --dart-define=FIREBASE_USE_EMULATOR=true

# Dev stack (Firebase auth/firestore emulators + web dev server on
# dev.local:4116) via process-compose — processes, ports and the
# already-running-emulator guard all live in process-compose.yaml.
#
# TUI off so this stays readable in an Emacs compilation buffer; the REST API on
# 4115 drives it from another shell, e.g. restart just the dev server after a
# dependency change:
#   process-compose process restart web -p 4115
# Run `process-compose up` by hand instead if you want the interactive TUI.
[doc('Dev stack: Firebase emulators + web dev server, via process-compose')]
up:
    process-compose up --tui=false --port 4115

# Build the prod web app (Firestore-direct). `flutter clean` first: the web
# plugin registrant is cached per build-config and can go stale across
# dart-define configs, silently dropping a plugin (e.g. shared_preferences)
# from the release bundle -> MissingPluginException / white screen at runtime.
[doc('Build the PROD web app (Firestore-direct)')]
web:
    flutter clean
    flutter build web --dart-define=SYNC_BACKEND=firestore

# Build the web app against the LOCAL emulator suite, for serving on :4117.
# Distinct from `web`, which points the bundle at the PROD Firebase project —
# don't serve that one from the emulator or you'll write to real data.
[doc('Build the web app against the LOCAL emulator suite (serve on :4117)')]
web-emulator:
    flutter clean
    flutter build web --dart-define=SYNC_BACKEND=firestore \
      --dart-define=FIREBASE_USE_EMULATOR=true

# Build + deploy the web app to Firebase Hosting (prod)
deploy: web
    firebase deploy --only hosting --project gym-tracker-44a5f

# Regenerate the PWA icons into web/icons/ + web/favicon.png. Edit the script,
# never the PNGs. Dependency-free by design (no PIL/imagemagick on this host).
[doc('Regenerate the PWA icons in web/icons/ + web/favicon.png')]
icons:
    python3 tool/generate_web_icons.py

# Read a Firestore emulator path, e.g. `just fs-get users/<uid>/routines`.
# `Bearer owner` is the admin bypass — rules are enforced otherwise, even
# locally. Port/project are duplicated from firebase.json; a curl one-liner
# can't read it.
[doc('Read a Firestore emulator path, e.g. just fs-get users/<uid>/routines')]
fs-get path:
    curl -s -H 'Authorization: Bearer owner' \
      'http://127.0.0.1:4120/v1/projects/demo-gym-tracker/databases/(default)/documents/{{path}}'

# flutter clean
clean:
    flutter clean
