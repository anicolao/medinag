#!/usr/bin/env bash
set -euo pipefail
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
cd "$repository_root"
export DEVELOPER_DIR="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MEDINAG_PATIENT_SCHEME="${MEDINAG_PATIENT_SCHEME:-MediNagAlarmPatient}"
case "$MEDINAG_PATIENT_SCHEME" in
  MediNagAlarmPatient|MediNagAlarmReliability|MediNagAlarmPresentation|MediNagNotificationPatient) ;;
  *) echo 'Unsupported connected phone scheme.' >&2; exit 1 ;;
esac
if ! java -version >/dev/null 2>&1; then
  echo 'Java 21 is required; run this script in nix develop.' >&2
  exit 1
fi
export MEDINAG_SIMULATOR_ID="$(xcrun simctl create 'MediNag Connected AlarmKit' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
cleanup() {
  local container
  container="$(xcrun simctl get_app_container "$MEDINAG_SIMULATOR_ID" org.boardgamescafe.medinag data 2>/dev/null || true)"
  if [[ -n "$container" && -f "$container/Library/Application Support/patient-alarmkit.json" ]]; then
    cp "$container/Library/Application Support/patient-alarmkit.json" apps/ios/DerivedData/AlarmPatientLastState.json
  fi
  xcrun simctl delete "$MEDINAG_SIMULATOR_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
xcrun simctl boot "$MEDINAG_SIMULATOR_ID"
xcrun simctl bootstatus "$MEDINAG_SIMULATOR_ID" -b
npm run ios:generate
# Build before choosing a near-future user-entered dose time. A cold SDK build
# must not make the actual test dose expire during infrastructure setup.
xcodebuild build-for-testing -project apps/ios/MediNag.xcodeproj -scheme "$MEDINAG_PATIENT_SCHEME" \
  -configuration E2E -destination "platform=iOS Simulator,id=$MEDINAG_SIMULATOR_ID" \
  -derivedDataPath "apps/ios/DerivedData/$MEDINAG_PATIENT_SCHEME" -quiet
export MEDINAG_E2E_PROJECT_ID=demo-medinag
export MEDINAG_E2E_AUTH_HOST=127.0.0.1:9099
export MEDINAG_E2E_FIRESTORE_HOST=127.0.0.1:8080
export MEDINAG_E2E_ADMINISTRATOR_NAME=Lori
export MEDINAG_E2E_PATIENT_NAME=Alex
export MEDINAG_E2E_MEDICATION_NAME='Connected medication dose'
export MEDINAG_E2E_SCHEDULED_TIME="$(node -e 'const d=new Date(Date.now()+8*60*1000); console.log(new Intl.DateTimeFormat("en-GB",{timeZone:"America/Toronto",hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).format(d))')"
export MEDINAG_E2E_STATE_FILE="$(mktemp /tmp/medinag-alarm-patient-state.XXXXXX)"
export MEDINAG_E2E_SMS_CAPTURE_FILE="$(mktemp /tmp/medinag-alarm-patient-sms.XXXXXX)"
npm run functions:build
node scripts/with-captured-sms-gateway.mjs -- npx firebase emulators:exec \
  --project demo-medinag --only auth,firestore,functions \
  "bash apps/ios/scripts/run-alarm-patient-e2e-session.sh"
