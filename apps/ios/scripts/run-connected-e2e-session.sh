#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
developer_directory="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
derived_data_directory="${MEDINAG_E2E_DERIVED_DATA:-$repository_root/apps/ios/DerivedData}"
simulator_id="${MEDINAG_SIMULATOR_ID:?MEDINAG_SIMULATOR_ID is required}"
xcodebuild_command="$developer_directory/usr/bin/xcodebuild"

cd "$repository_root"
eval "$(node scripts/setup-e2e-environment.mjs --shell)"
if [[ "${MEDINAG_E2E_UPDATE_SNAPSHOTS:-false}" == "true" ]]; then
  npx playwright test tests/e2e/004-ios-respond-to-dose/web.spec.ts --update-snapshots
else
  npx playwright test tests/e2e/004-ios-respond-to-dose/web.spec.ts
fi
npm run ios:generate

run_xcodebuild() {
  /usr/bin/env \
    -u AR -u AS -u CC -u CFLAGS -u CPP -u CPPFLAGS -u CPATH \
    -u CXX -u CXXFLAGS -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    -u LD -u LDFLAGS -u LIBRARY_PATH -u MACOSX_DEPLOYMENT_TARGET \
    -u NIX_BINTOOLS -u NIX_CC -u NIX_CFLAGS_COMPILE \
    -u NIX_ENFORCE_NO_NATIVE -u NIX_HARDENING_ENABLE -u NIX_LDFLAGS \
    -u OBJC_INCLUDE_PATH -u SDKROOT \
    DEVELOPER_DIR="$developer_directory" \
    PATH="$developer_directory/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$xcodebuild_command" "$@"
}

run_xcodebuild -quiet build-for-testing \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data_directory" \
  MEDINAG_E2E_PROJECT_ID="$VITE_FIREBASE_PROJECT_ID" \
  MEDINAG_E2E_API_KEY="$VITE_FIREBASE_API_KEY" \
  MEDINAG_E2E_APP_ID="$VITE_FIREBASE_APP_ID" \
  MEDINAG_E2E_MESSAGING_SENDER_ID="$VITE_FIREBASE_MESSAGING_SENDER_ID" \
  MEDINAG_E2E_SUBJECT_EMAIL="$MEDINAG_E2E_SUBJECT_EMAIL" \
  MEDINAG_E2E_SUBJECT_PASSWORD="$MEDINAG_E2E_SUBJECT_PASSWORD" \
  MEDINAG_E2E_HOUSEHOLD_ID="$MEDINAG_E2E_HOUSEHOLD_ID" \
  MEDINAG_E2E_MEDICATION_NAME="$MEDINAG_E2E_MEDICATION_NAME" \
  MEDINAG_E2E_SCHEDULED_DISPLAY_TIME="$MEDINAG_E2E_SCHEDULED_DISPLAY_TIME" \
  MEDINAG_E2E_REPEAT_DISPLAY_TIME="$MEDINAG_E2E_REPEAT_DISPLAY_TIME"

run_xcodebuild -quiet test-without-building \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data_directory" \
  -only-testing:MediNagTests

result_bundle="$derived_data_directory/SystemNotification.xcresult"
if [[ -d "$result_bundle" ]]; then
  /usr/bin/find "$result_bundle" -depth -delete
fi
run_xcodebuild -quiet test-without-building \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data_directory" \
  -only-testing:MediNagUITests/RespondToDoseUITests/testConnectedSystemNotificationDoseLoop \
  -resultBundlePath "$result_bundle"
