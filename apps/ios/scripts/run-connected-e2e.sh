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

runtime_id="${MEDINAG_E2E_RUNTIME_ID:-$($xcrun_command simctl list runtimes \
  | sed -nE '/^iOS / s/.* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1/p' \
  | tail -n 1)}"
export MEDINAG_SIMULATOR_ID="$($xcrun_command simctl create \
  'MediNag Connected E2E' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
  "$runtime_id")"
cleanup() {
  "$xcrun_command" simctl delete "$MEDINAG_SIMULATOR_ID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$xcrun_command" simctl boot "$MEDINAG_SIMULATOR_ID"
"$xcrun_command" simctl bootstatus "$MEDINAG_SIMULATOR_ID" -b
"$xcrun_command" simctl ui "$MEDINAG_SIMULATOR_ID" appearance light
"$xcrun_command" simctl ui "$MEDINAG_SIMULATOR_ID" increase_contrast enabled
"$xcrun_command" simctl ui "$MEDINAG_SIMULATOR_ID" content_size medium
"$xcrun_command" simctl status_bar "$MEDINAG_SIMULATOR_ID" override \
  --time '2026-08-03T08:00:00.000-04:00' \
  --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4

export MEDINAG_E2E_PROJECT_ID="demo-medinag"
export MEDINAG_E2E_AUTH_HOST="127.0.0.1:9099"
export MEDINAG_E2E_FIRESTORE_HOST="127.0.0.1:8080"
export MEDINAG_E2E_ADVISOR_NAME="Lori"
export MEDINAG_E2E_SUBJECT_NAME="Steve"
export MEDINAG_E2E_STATE_FILE="$(mktemp /tmp/medinag-e2e-state.XXXXXX.json)"
export MEDINAG_E2E_MEDICATION_NAME="Morning Prescription Doses"
export MEDINAG_E2E_SCHEDULED_TIME="08:00"
export MEDINAG_E2E_SCHEDULED_DISPLAY_TIME="8:00"
export MEDINAG_E2E_REPEAT_DISPLAY_TIME="8:10"
export MEDINAG_E2E_DERIVED_DATA="${MEDINAG_E2E_DERIVED_DATA:-$repository_root/apps/ios/DerivedData/ConnectedE2E}"

npx firebase emulators:exec \
  --project "$MEDINAG_E2E_PROJECT_ID" \
  --only auth,firestore \
  "apps/ios/scripts/run-connected-e2e-session.sh"
