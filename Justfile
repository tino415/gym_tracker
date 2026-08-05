# Common build / test / e2e commands for gym_tracker.
# `just` (or `nx just`) lists recipes; `just <name>` runs one.
#
# Lessons baked in:
#  * The watch never uses Firebase; phone/web opt in with
#    --dart-define=SYNC_BACKEND=firestore.
#  * flutter always writes app-<variant>.apk, so each APK recipe copies its
#    output to a per-target name (gym-watch.apk / gym-phone.apk). Install from
#    those, not from app-debug.apk, which the next build overwrites.

# --- Host- and device-dependent knobs ----------------------------------------
# Override any of these on the command line, e.g. `just PHONE_ABIS=android-x64
# phone-apk` — no env plumbing needed.

# A release build needs gen_snapshot, which Flutter ships only for x86_64 Linux
# hosts; on an aarch64 host `flutter build apk --release` dies for lack of it.
# Debug (JIT) APKs are fine for on-device testing.
APK_MODE := if arch() == "aarch64" { "--debug" } else { "--release" }

# "debug" / "release" — flutter names its output app-<variant>.apk.
APK_VARIANT := trim_start_match(APK_MODE, "--")
APK_OUT := "build/app/outputs/flutter-apk"

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

# Stamped into every build and shown at the bottom of the account screen, so
# "is the browser running the bundle I just deployed?" is answerable by looking
# rather than by hashing main.dart.js. `-dirty` means the tree had uncommitted
# changes, i.e. the build does not correspond to any commit. No spaces: it is
# passed through --dart-define.
BUILD_ID := `printf '%s%s-%s' "$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" "$(git diff --quiet HEAD 2>/dev/null || echo -dirty)" "$(date +%Y%m%d-%H%M)"`
BUILD_DEFINE := "--dart-define=BUILD_ID=" + BUILD_ID

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

# APK for the watch + Wear emulator (fat 32+64 by default). Copied to a
# per-target name because flutter always writes app-<variant>.apk — without
# the copy, building the other target overwrites this one.
[doc('APK for the watch + Wear emulator (fat 32+64)')]
watch-apk:
    flutter build apk {{APK_MODE}} --target-platform {{WATCH_ABIS}} {{BUILD_DEFINE}}
    cp {{APK_OUT}}/app-{{APK_VARIANT}}.apk {{APK_OUT}}/gym-watch.apk

# APK for the phone + Firestore backend. The Google Web client id
# (serverClientId for the native Android sign-in) is baked into the app as a
# const default, so no dart-define is needed here. Override only to target a
# different Firebase project: GOOGLE_SERVER_CLIENT_ID=... just phone-apk.
[doc('APK for the phone + Firestore backend')]
phone-apk:
    flutter build apk {{APK_MODE}} --target-platform {{PHONE_ABIS}} --dart-define=SYNC_BACKEND=firestore {{BUILD_DEFINE}} \
      {{ if env_var_or_default("GOOGLE_SERVER_CLIENT_ID", "") != "" { "--dart-define=GOOGLE_SERVER_CLIENT_ID=" + env_var("GOOGLE_SERVER_CLIENT_ID") } else { "" } }}
    cp {{APK_OUT}}/app-{{APK_VARIANT}}.apk {{APK_OUT}}/gym-phone.apk

# As phone-apk, but the app seeds demo routines on first launch (reps sets, a
# superset pair, a time-kind hold) — the fixtures worth having when verifying a
# change by hand, without a couple of dozen taps to build them. The seed refuses
# to run unless the routine library is completely empty, so it can't overwrite
# real data; `adb shell pm clear com.otin.gym_tracker` gives you a clean slate.
[doc('APK for the phone, pre-seeded with demo routines')]
phone-apk-demo:
    flutter build apk {{APK_MODE}} --target-platform {{PHONE_ABIS}} \
      --dart-define=SYNC_BACKEND=firestore --dart-define=SEED_DEMO=true {{BUILD_DEFINE}}
    cp {{APK_OUT}}/app-{{APK_VARIANT}}.apk {{APK_OUT}}/gym-phone.apk

# Install a built APK. Push + `pm install` rather than `adb install`: streamed
# install fails on some Wear devices. The remote path is per-target so two
# installs can run at once, and the staged copy is deleted afterwards — these
# are 130-160 MB debug APKs, and a watch fills up fast. The rm runs even when
# the install fails, so a bad build doesn't strand one either.
# `device` takes an adb serial, or the alias `watch` / `phone` to pick the one
# connected device of that form factor (see tool/adb-device.sh) — handy because
# a wireless-adb serial changes port on every reconnect. Both installs announce
# the resolved serial and model before touching anything: a silent install into
# the wrong device still prints "Success", which is how a build once went to the
# emulator while the handset sat there untouched.
[doc('Install the watch APK (build it first with watch-apk)')]
watch-install device=WEAR_DEVICE:
    #!/usr/bin/env bash
    set -uo pipefail
    test -n "{{device}}" || { echo "no device: pass an adb serial or 'watch', or set GYM_WEAR_DEVICE" >&2; exit 1; }
    dev=$(tool/adb-device.sh "{{device}}") || exit 1
    echo "→ installing gym-watch.apk to $dev ($(adb -s "$dev" shell getprop ro.product.model | tr -d '\r'))"
    adb -s "$dev" push {{APK_OUT}}/gym-watch.apk /data/local/tmp/gym-watch.apk || exit 1
    adb -s "$dev" shell pm install -r /data/local/tmp/gym-watch.apk; rc=$?
    adb -s "$dev" shell rm -f /data/local/tmp/gym-watch.apk
    exit $rc

[doc('Install the phone APK (build it first with phone-apk)')]
phone-install device=PHONE_DEVICE:
    #!/usr/bin/env bash
    set -uo pipefail
    test -n "{{device}}" || { echo "no device: pass an adb serial or 'phone', or set GYM_PHONE_DEVICE" >&2; exit 1; }
    dev=$(tool/adb-device.sh "{{device}}") || exit 1
    echo "→ installing gym-phone.apk to $dev ($(adb -s "$dev" shell getprop ro.product.model | tr -d '\r'))"
    adb -s "$dev" push {{APK_OUT}}/gym-phone.apk /data/local/tmp/gym-phone.apk || exit 1
    adb -s "$dev" shell pm install -r /data/local/tmp/gym-phone.apk; rc=$?
    adb -s "$dev" shell rm -f /data/local/tmp/gym-phone.apk
    exit $rc

# What adb can see, with each device's model and form factor — the serials to
# paste into the install / e2e recipes when an alias is ambiguous.
[doc('List connected devices with model and form factor')]
devices-list:
    #!/usr/bin/env bash
    set -uo pipefail
    # A for loop, not `... | while read`: `adb shell` reads stdin, so inside a
    # pipeline it swallows the remaining serials and only the first is listed.
    for s in $(adb devices | awk 'NR>1 && $2 == "device" { print $1 }'); do
      model=$(adb -s "$s" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
      if adb -s "$s" shell pm list features 2>/dev/null | grep -q 'android.hardware.type.watch'; then
        kind=watch
      else
        kind=phone
      fi
      printf '%-24s %-22s %s\n' "$s" "$model" "$kind"
    done

# Build both APKs and install them. The builds run in sequence (they share
# build/ and the Gradle daemon), then both installs run concurrently — over
# wireless adb the transfer dominates, so overlapping them roughly halves it.
[doc('Build + install both APKs (installs run in parallel)')]
devices: watch-apk phone-apk
    #!/usr/bin/env bash
    set -uo pipefail
    just watch-install & w=$!
    just phone-install & p=$!
    rc=0
    wait $w || rc=1
    wait $p || rc=1
    exit $rc

# Phone integration test on a device/emulator. Uses GYM_PHONE_DEVICE unless a
# serial is passed; `adb devices` lists them.
[doc('Phone integration test on a device/emulator')]
e2e device=PHONE_DEVICE:
    #!/usr/bin/env bash
    set -uo pipefail
    test -n "{{device}}" || { echo "no device: pass an adb serial or 'phone', or set GYM_PHONE_DEVICE" >&2; exit 1; }
    dev=$(tool/adb-device.sh --emulator-only "{{device}}") || exit 1
    flutter test integration_test/routine_flow_test.dart -d "$dev"

# The phone run flow end to end: start from a routine, log sets through a
# superset, finish, and find it in History. Same device argument as `e2e`.
[doc('Phone run-flow integration test on a device/emulator')]
e2e-run device=PHONE_DEVICE:
    #!/usr/bin/env bash
    set -uo pipefail
    test -n "{{device}}" || { echo "no device: pass an adb serial or 'phone', or set GYM_PHONE_DEVICE" >&2; exit 1; }
    dev=$(tool/adb-device.sh --emulator-only "{{device}}") || exit 1
    flutter test integration_test/run_flow_test.dart -d "$dev"

# Watch integration test on a Wear device/emulator (pass the adb serial, as for
# `e2e`). The test sets WorkoutBridge's platform-skip seam itself, so no
# permission dialog blocks the run.
[doc('Watch integration test on a Wear device/emulator')]
e2e-watch device=WEAR_DEVICE:
    #!/usr/bin/env bash
    set -uo pipefail
    test -n "{{device}}" || { echo "no device: pass an adb serial or 'watch', or set GYM_WEAR_DEVICE" >&2; exit 1; }
    dev=$(tool/adb-device.sh --emulator-only "{{device}}") || exit 1
    flutter test integration_test/watch_flow_test.dart -d "$dev"

# Web e2e in headless Chrome (needs the emulator suite running: just up)
e2e-web:
    @just _web-drive integration_test/web_flow_test.dart

# Account deletion against the real Auth + Firestore emulators. The unit tests
# fake Firestore; only this exercises reauthentication and user.delete().
[doc('Account-deletion e2e in headless Chrome (needs the emulator suite)')]
e2e-web-delete:
    @just _web-drive integration_test/account_deletion_web_test.dart

# Dialog widths at desktop size. Only the browser reaches the master-detail
# breakpoint — a phone, and an Android emulator even in landscape, render the
# narrow branch instead — so this is the only place the wide layout is checked.
[doc('Dialog-width e2e in headless Chrome (needs the emulator suite)')]
e2e-web-dialogs:
    @just _web-drive integration_test/dialog_width_web_test.dart

# Shared driver invocation for the web e2e targets.
[private]
_web-drive target:
    #!/usr/bin/env bash
    chromedriver --port=4444 & cdpid=$!
    trap 'kill $cdpid 2>/dev/null' EXIT
    sleep 1
    flutter drive --driver=test_driver/integration_test.dart \
      --target={{target}} -d web-server \
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
    flutter build web --dart-define=SYNC_BACKEND=firestore {{BUILD_DEFINE}}

# Build the web app against the LOCAL emulator suite, for serving on :4117.
# Distinct from `web`, which points the bundle at the PROD Firebase project —
# don't serve that one from the emulator or you'll write to real data.
[doc('Build the web app against the LOCAL emulator suite (serve on :4117)')]
web-emulator:
    flutter clean
    flutter build web --dart-define=SYNC_BACKEND=firestore {{BUILD_DEFINE}} \
      --dart-define=FIREBASE_USE_EMULATOR=true

# Build + deploy the web app to Firebase Hosting (prod).
#
# Inherits `web`'s `flutter clean`, so this WIPES build/ — including any APK you
# just built. Build device APKs *after* deploying, never before, or use
# `release-all`, which sequences it for you.
[doc('Build + deploy the web app to Firebase Hosting (prod)')]
deploy: web
    firebase deploy --only hosting --project gym-tracker-44a5f

# Ship everything, in the only order that works: `deploy` runs `flutter clean`
# and would destroy APKs built beforehand, so web goes first and the device
# builds follow. just runs dependencies in order, left to right.
[doc('Deploy web, then build + install both APKs (correct order)')]
release-all: deploy devices

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
