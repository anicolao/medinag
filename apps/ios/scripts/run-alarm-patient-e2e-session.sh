#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "--ready" ]]; then
  eval "$(node scripts/setup-e2e-environment.mjs --shell)"
  exec node scripts/with-web-server.mjs -- bash "$0" --ready
fi
diagnostics() { node scripts/inspect-alarm-patient-e2e.mjs || true; }
trap diagnostics EXIT
npx playwright test tests/e2e/008-alarmkit-patient/setup.spec.ts
npm run ios:generate
export TEST_RUNNER_MEDINAG_PATIENT_LAUNCH_ARGUMENTS="$(node --input-type=module -e '
  import fs from "node:fs";
  const s=JSON.parse(fs.readFileSync(process.env.MEDINAG_E2E_STATE_FILE,"utf8"));
  console.log(JSON.stringify([
    "-firebase-emulator-project-id",s.firebase.projectId,
    "-firebase-emulator-api-key",s.firebase.apiKey,
    "-firebase-emulator-app-id",s.firebase.appId,
    "-firebase-emulator-messaging-sender-id",s.firebase.messagingSenderId,
    "-firebase-emulator-host","127.0.0.1",
    "-firebase-auth-emulator-port","9099","-firebase-firestore-emulator-port","8080",
    "-e2e-google-id-token-base64",Buffer.from(s.patient.googleIdToken).toString("base64"),
    "-AppleLanguages","(en)","-AppleLocale","en_CA"
  ]));')"
export DEVELOPER_DIR="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MEDINAG_PATIENT_RESULT_BUNDLE="${MEDINAG_PATIENT_RESULT_BUNDLE:-apps/ios/DerivedData/AlarmPatientConnected-$(date +%Y%m%d-%H%M%S).xcresult}"
xcodebuild test-without-building -project apps/ios/MediNag.xcodeproj -scheme "$MEDINAG_PATIENT_SCHEME" \
  -configuration E2E -destination "platform=iOS Simulator,id=$MEDINAG_SIMULATOR_ID" \
  -derivedDataPath "apps/ios/DerivedData/$MEDINAG_PATIENT_SCHEME" \
  -resultBundlePath "$MEDINAG_PATIENT_RESULT_BUNDLE" -quiet
xcrun xcresulttool get test-results summary \
  --path "$MEDINAG_PATIENT_RESULT_BUNDLE" --format json \
  | jq -e '.failedTests == 0 and .skippedTests == 0 and .passedTests > 0'
npx playwright test tests/e2e/008-alarmkit-patient/completion.spec.ts
