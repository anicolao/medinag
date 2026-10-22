#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
developer_directory="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun_command="/usr/bin/xcrun"
cd "$repository_root"
export DEVELOPER_DIR="$developer_directory"

if ! java -version >/dev/null 2>&1; then
  if [[ -z "${MEDINAG_E2E_NIX_SHELL:-}" ]] && command -v nix >/dev/null 2>&1; then
    exec env MEDINAG_E2E_NIX_SHELL=1 nix develop --command "$0" "$@"
  fi
  echo "Java 21 is required by the Firestore emulator." >&2
  exit 1
fi

owns_simulator=false
if [[ -z "${MEDINAG_SIMULATOR_ID:-}" ]]; then
  runtime_id="${MEDINAG_E2E_RUNTIME_ID:-$($xcrun_command simctl list runtimes \
    | sed -nE '/^iOS / s/.* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1/p' \
    | tail -n 1)}"
  export MEDINAG_SIMULATOR_ID="$($xcrun_command simctl create \
    'MediNag Connected E2E' \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
    "$runtime_id")"
  owns_simulator=true
fi
cleanup() {
  if [[ "$owns_simulator" != "true" ]]; then
    return
  fi
  if [[ "${MEDINAG_E2E_KEEP_SIMULATOR:-false}" == "true" ]]; then
    echo "Keeping MediNag E2E Simulator $MEDINAG_SIMULATOR_ID for inspection."
    return
  fi
  "$xcrun_command" simctl delete "$MEDINAG_SIMULATOR_ID" 2>/dev/null || true
  if [[ -n "${MEDINAG_WATCH_SIMULATOR_ID:-}" ]]; then
    "$xcrun_command" simctl delete "$MEDINAG_WATCH_SIMULATOR_ID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ "${MEDINAG_E2E_STORY:-}" == "watch" && -z "${MEDINAG_WATCH_SIMULATOR_ID:-}" ]]; then
  export MEDINAG_WATCH_SIMULATOR_ID="$($xcrun_command simctl create \
    'MediNag Watch E2E' com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm \
    com.apple.CoreSimulator.SimRuntime.watchOS-26-5)"
  "$xcrun_command" simctl pair "$MEDINAG_WATCH_SIMULATOR_ID" "$MEDINAG_SIMULATOR_ID"
fi

if ! "$xcrun_command" simctl list devices --json | node -e '
  let input = ""; process.stdin.on("data", data => input += data);
  process.stdin.on("end", () => process.exit(Object.values(JSON.parse(input).devices).flat()
    .some(device => device.udid === process.env.MEDINAG_SIMULATOR_ID && device.state === "Booted") ? 0 : 1));
'; then
  "$xcrun_command" simctl boot "$MEDINAG_SIMULATOR_ID"
fi
"$xcrun_command" simctl bootstatus "$MEDINAG_SIMULATOR_ID" -b
"$xcrun_command" simctl spawn "$MEDINAG_SIMULATOR_ID" defaults write \
  com.apple.Accessibility ReduceMotionEnabled -bool true
# This is the Simulator preference behind UIAccessibility's Reduce Transparency
# value. The similarly named MDM key ReduceTransparencyEnabled has no effect here.
"$xcrun_command" simctl spawn "$MEDINAG_SIMULATOR_ID" defaults write \
  com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool true
"$xcrun_command" simctl shutdown "$MEDINAG_SIMULATOR_ID"
"$xcrun_command" simctl boot "$MEDINAG_SIMULATOR_ID"
"$xcrun_command" simctl bootstatus "$MEDINAG_SIMULATOR_ID" -b
"$xcrun_command" simctl ui "$MEDINAG_SIMULATOR_ID" appearance light
"$xcrun_command" simctl ui "$MEDINAG_SIMULATOR_ID" increase_contrast enabled
"$xcrun_command" simctl ui "$MEDINAG_SIMULATOR_ID" content_size medium
if [[ -n "${MEDINAG_WATCH_SIMULATOR_ID:-}" ]]; then
  if ! "$xcrun_command" simctl list devices --json | node -e '
    let input = ""; process.stdin.on("data", data => input += data);
    process.stdin.on("end", () => process.exit(Object.values(JSON.parse(input).devices).flat()
      .some(device => device.udid === process.env.MEDINAG_WATCH_SIMULATOR_ID && device.state === "Booted") ? 0 : 1));
  '; then
    "$xcrun_command" simctl boot "$MEDINAG_WATCH_SIMULATOR_ID"
  fi
  "$xcrun_command" simctl bootstatus "$MEDINAG_WATCH_SIMULATOR_ID" -b
  "$xcrun_command" simctl spawn "$MEDINAG_WATCH_SIMULATOR_ID" defaults write \
    com.apple.Accessibility ReduceMotionEnabled -bool true
  "$xcrun_command" simctl spawn "$MEDINAG_WATCH_SIMULATOR_ID" defaults write \
    com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool true
fi
status_bar_time=$(node -e '
  const date = new Date(2026, 7, 3, 8, 0, 0);
  const offset = -date.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0");
  const minutes = String(Math.abs(offset) % 60).padStart(2, "0");
  process.stdout.write(`2026-08-03T08:00:00.000${sign}${hours}:${minutes}`);
')
"$xcrun_command" simctl status_bar "$MEDINAG_SIMULATOR_ID" override \
  --time "$status_bar_time" \
  --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4
# watchOS does not support simctl status_bar overrides. Watch walkthroughs
# capture the real application scroll surface, excluding the system clock.

export MEDINAG_E2E_PROJECT_ID="demo-medinag"
export MEDINAG_E2E_AUTH_PORT="${MEDINAG_E2E_AUTH_PORT:-9099}"
export MEDINAG_E2E_FIRESTORE_PORT="${MEDINAG_E2E_FIRESTORE_PORT:-8080}"
export MEDINAG_E2E_AUTH_HOST="127.0.0.1:$MEDINAG_E2E_AUTH_PORT"
export MEDINAG_E2E_FIRESTORE_HOST="127.0.0.1:$MEDINAG_E2E_FIRESTORE_PORT"
export MEDINAG_E2E_ADMINISTRATOR_NAME="Lori"
export MEDINAG_E2E_PATIENT_NAME="Steve"
export MEDINAG_E2E_STATE_FILE="$(mktemp /tmp/medinag-e2e-state.XXXXXX)"
export MEDINAG_E2E_MEDICATION_NAME="Morning Prescription Doses"
export MEDINAG_E2E_SCHEDULED_TIME="08:00"
export MEDINAG_E2E_TIME_ZONE="America/Toronto"
export MEDINAG_E2E_LOGICAL_NOW="2026-09-23T13:00:00Z"
export MEDINAG_E2E_SMS_NUMBER="+15555550199"
export MEDINAG_E2E_STORY="${MEDINAG_E2E_STORY:-dose-response}"
export MEDINAG_E2E_DERIVED_DATA="${MEDINAG_E2E_DERIVED_DATA:-$repository_root/apps/ios/DerivedData/ConnectedE2E-$MEDINAG_E2E_STORY}"
export MEDINAG_E2E_SMS_CAPTURE_FILE="$(mktemp /tmp/medinag-e2e-sms.XXXXXX)"

npm run functions:build
node scripts/with-captured-sms-gateway.mjs -- npx firebase emulators:exec \
  --project "$MEDINAG_E2E_PROJECT_ID" \
  --config "${MEDINAG_E2E_FIREBASE_CONFIG:-firebase.json}" \
  --only auth,firestore,functions \
  "apps/ios/scripts/run-connected-e2e-session.sh"
