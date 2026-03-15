#!/usr/bin/env bash

# Stream logcat output for the termigate Android app via adb.

set -euo pipefail

DEFAULT_PACKAGES=("org.tamx.termigate.debug" "org.tamx.termigate")
PACKAGE=""
SERIAL=""
CLEAR_LOGS=0

usage() {
  cat <<'EOF'
Usage: watch-logs.sh [-s SERIAL] [-p PACKAGE] [-c]
  -s SERIAL   Device serial if multiple devices are connected
  -p PACKAGE  Android package name (default: auto-detect release/debug)
  -c          Clear existing logcat buffer before streaming
EOF
}

while getopts "s:p:ch" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) PACKAGE="$OPTARG" ;;
    c) CLEAR_LOGS=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

get_pid_for_pkg() {
  local pkg="$1" pid=""
  pid="$(${ADB_CMD[@]} shell pidof -s "$pkg" 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$pid" ]]; then
    pid="$(${ADB_CMD[@]} shell "ps -A | grep -F $pkg" 2>/dev/null | awk 'NR==1 {print $2}' | tr -d '\r' || true)"
  fi
  echo "$pid"
}

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is not installed or not in PATH" >&2
  exit 1
fi

# Pick a device if none was specified.
if [[ -z "$SERIAL" ]]; then
  mapfile -t devices < <(adb devices | awk '/\tdevice$/ {print $1}')
  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "No connected devices. Plug in a device and enable USB debugging." >&2
    exit 1
  elif [[ ${#devices[@]} -gt 1 ]]; then
    echo "Multiple devices detected. Re-run with -s <serial>." >&2
    printf 'Connected: %s\n' "${devices[@]}" >&2
    exit 1
  else
    SERIAL="${devices[0]}"
  fi
fi

ADB_CMD=(adb -s "$SERIAL")

state="$(${ADB_CMD[@]} get-state 2>/dev/null || true)"
if [[ "$state" != "device" ]]; then
  echo "Device $SERIAL not ready (state: $state)." >&2
  exit 1
fi

if (( CLEAR_LOGS )); then
  ${ADB_CMD[@]} logcat -c
fi

candidate_packages=()
if [[ -n "$PACKAGE" ]]; then
  candidate_packages+=("$PACKAGE")
else
  candidate_packages+=("${DEFAULT_PACKAGES[@]}")
fi

pid=""
for pkg in "${candidate_packages[@]}"; do
  pid="$(get_pid_for_pkg "$pkg")"
  if [[ -n "$pid" ]]; then
    PACKAGE="$pkg"
    break
  fi
done

if [[ -z "$pid" ]]; then
  echo "No running termigate process found on $SERIAL." >&2
  echo "Checked packages: ${candidate_packages[*]}" >&2
  installed="$(${ADB_CMD[@]} shell pm list packages 2>/dev/null | tr -d '\r' | grep termigate || true)"
  if [[ -n "$installed" ]]; then
    echo "Installed matching packages:" >&2
    echo "$installed" >&2
  else
    echo "Tip: start the app, or specify the package with -p <name>." >&2
  fi
  exit 1
fi

echo "Streaming logcat for $PACKAGE (pid $pid) on $SERIAL. Press Ctrl+C to stop." >&2

exec ${ADB_CMD[@]} logcat --pid="$pid" -v color
