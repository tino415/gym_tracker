#!/usr/bin/env bash
# Resolve an adb device spec to a serial, printed on stdout.
#
#   phone | watch  the single connected device of that form factor. Wear devices
#                  report android.hardware.type.watch; everything else counts as
#                  a phone. Resolving by form factor rather than by serial is
#                  what makes wireless-adb port churn stop mattering — the port
#                  changes on every reconnect, the form factor doesn't.
#   <serial>       used as-is, after checking it is actually connected.
#
# Exits non-zero, listing the candidates, when a form factor matches zero or
# more than one device — so an ambiguous "phone" (emulator *and* handset
# attached, the normal state here) never silently picks the wrong one. That is
# exactly the failure this script exists to prevent: an install that reports
# Success against a device you weren't looking at.
#
# With --emulator-only, refuse a physical device unless ALLOW_REAL_DEVICE=1.
# The integration-test recipes pass it, because `flutter test integration_test/`
# UNINSTALLS the app when it finishes — which deletes the local Drift database
# along with it. Harmless on an emulator, a data-loss event on the handset you
# actually train with.
set -uo pipefail

emulator_only=0
if [ "${1:-}" = "--emulator-only" ]; then
  emulator_only=1
  shift
fi

spec="${1:-}"
if [ -z "$spec" ]; then
  echo "usage: adb-device.sh [--emulator-only] phone|watch|<serial>" >&2
  exit 2
fi

serials=$(adb devices | awk 'NR>1 && $2 == "device" { print $1 }')
if [ -z "$serials" ]; then
  echo "no adb devices connected" >&2
  exit 1
fi

describe() {
  local model
  model=$(adb -s "$1" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  echo "$1 (${model:-unknown})"
}

# Emits the resolved serial, after the physical-device check.
emit() {
  if [ "$emulator_only" = 1 ] && [ "${ALLOW_REAL_DEVICE:-}" != 1 ]; then
    local chars
    chars=$(adb -s "$1" shell getprop ro.build.characteristics 2>/dev/null | tr -d '\r')
    case "$chars" in
      *emulator*) ;;
      *)
        {
          echo "refusing to run an integration test against $(describe "$1")."
          echo "It uninstalls the app afterwards, wiping the local database."
          echo "Use an emulator, or ALLOW_REAL_DEVICE=1 if you truly mean it."
        } >&2
        exit 1
        ;;
    esac
  fi
  echo "$1"
}

case "$spec" in
  phone | watch)
    matches=()
    for s in $serials; do
      if adb -s "$s" shell pm list features 2>/dev/null |
        grep -q 'android.hardware.type.watch'; then
        [ "$spec" = watch ] && matches+=("$s")
      else
        [ "$spec" = phone ] && matches+=("$s")
      fi
    done
    case "${#matches[@]}" in
      1)
        emit "${matches[0]}"
        ;;
      0)
        echo "no connected $spec — 'adb devices' lists what is attached" >&2
        exit 1
        ;;
      *)
        {
          echo "several $spec devices connected — pass a serial instead:"
          for s in "${matches[@]}"; do echo "  $(describe "$s")"; done
        } >&2
        exit 1
        ;;
    esac
    ;;
  *)
    for s in $serials; do
      if [ "$s" = "$spec" ]; then
        emit "$spec"
        exit 0
      fi
    done
    echo "$spec is not connected — 'adb devices' lists what is attached" >&2
    exit 1
    ;;
esac
