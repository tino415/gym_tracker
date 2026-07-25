# Common build / test / e2e commands for gym_tracker.
# `just` (or `nx just`) lists recipes; `just <name>` runs one.
#
# Lessons baked in:
#  * Release APKs fail on this aarch64 host (missing gen_snapshot), so APKs are
#    --debug (JIT). Fine for on-device testing.
#  * The physical watch (SM-L315F) is 32-bit armeabi-v7a; the Wear emulator is
#    arm64. The watch APK is built fat (arm + arm64) so it runs on both — an
#    arm64-only APK crashes on the real watch (missing libflutter.so).
#  * The phone (S24) is arm64. The watch never uses Firebase; phone/web opt in
#    with --dart-define=SYNC_BACKEND=firestore.
#  * Every APK recipe writes build/app/outputs/flutter-apk/app-debug.apk.

# List recipes
default:
    @just --list

# Static analysis
analyze:
    flutter analyze

# Unit + widget test suite
test:
    flutter test

# Debug APK for the watch + Wear emulator (fat 32+64)
watch-apk:
    flutter build apk --debug --target-platform android-arm,android-arm64

# Debug APK for the phone (arm64) + Firestore backend. The Google Web client id
# (serverClientId for the native Android sign-in) is baked into the app as a
# const default, so no dart-define is needed here. Override only to target a
# different Firebase project: GOOGLE_SERVER_CLIENT_ID=... just phone-apk.
phone-apk:
    flutter build apk --debug --target-platform android-arm64 --dart-define=SYNC_BACKEND=firestore \
      {{ if env_var_or_default("GOOGLE_SERVER_CLIENT_ID", "") != "" { "--dart-define=GOOGLE_SERVER_CLIENT_ID=" + env_var("GOOGLE_SERVER_CLIENT_ID") } else { "" } }}

# Integration test on a device/emulator (pass the serial, e.g. 127.0.0.1:5557)
e2e device:
    flutter test integration_test/routine_flow_test.dart -d {{device}}

# Web e2e in headless Chrome (needs the Firebase emulator running: just emulator)
e2e-web:
    #!/usr/bin/env bash
    chromedriver --port=4444 & cdpid=$!
    trap 'kill $cdpid 2>/dev/null' EXIT
    sleep 1
    flutter drive --driver=test_driver/integration_test.dart \
      --target=integration_test/web_flow_test.dart -d web-server \
      --browser-name=chrome --headless --driver-port=4444 \
      --dart-define=SYNC_BACKEND=firestore --dart-define=FIREBASE_USE_EMULATOR=true

# Web dev server on dev.local:4116 (auto-starts the Firebase emulator, stops it on exit)
up:
    #!/usr/bin/env bash
    if ! (exec 3<>/dev/tcp/127.0.0.1/4120) 2>/dev/null; then
      echo firebase emulators:start --only auth,firestore --project demo-gym-tracker
      firebase emulators:start --only auth,firestore --project demo-gym-tracker &
      emu=$!
      trap 'kill $emu 2>/dev/null' EXIT
      for _ in $(seq 60); do (exec 3<>/dev/tcp/127.0.0.1/4120) 2>/dev/null && break; sleep 0.5; done
    fi
    flutter run -d web-server \
      --web-hostname dev.local --web-port 4116 \
      --dart-define=SYNC_BACKEND=firestore --dart-define=FIREBASE_USE_EMULATOR=true

# Build the prod web app (Firestore-direct)
web:
    flutter build web --dart-define=SYNC_BACKEND=firestore

# Build + deploy the web app to Firebase Hosting (prod)
deploy: web
    firebase deploy --only hosting --project gym-tracker-44a5f

# Start the Firebase emulator suite (hosting + auth + firestore)
emulator:
    firebase emulators:start --only hosting,auth,firestore --project demo-gym-tracker

# flutter clean
clean:
    flutter clean
