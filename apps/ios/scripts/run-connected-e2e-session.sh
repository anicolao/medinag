#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
developer_directory="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
derived_data_directory="${MEDINAG_E2E_DERIVED_DATA:-$repository_root/apps/ios/DerivedData}"
simulator_id="${MEDINAG_SIMULATOR_ID:?MEDINAG_SIMULATOR_ID is required}"
xcodebuild_command="$developer_directory/usr/bin/xcodebuild"

cd "$repository_root"
if [[ "${MEDINAG_E2E_WEB_SERVER_READY:-false}" != "true" ]]; then
  eval "$(node scripts/setup-e2e-environment.mjs --shell)"
  export MEDINAG_E2E_WEB_SERVER_READY=true
  exec node scripts/with-web-server.mjs -- "$0"
fi

export MEDINAG_E2E_ALARM_MONITOR_PORT="${MEDINAG_E2E_ALARM_MONITOR_PORT:-18181}"
node scripts/monitor-ios-alarms.mjs &
alarm_monitor_pid=$!
cleanup_alarm_monitor() {
  kill "$alarm_monitor_pid" 2>/dev/null || true
  wait "$alarm_monitor_pid" 2>/dev/null || true
}
trap cleanup_alarm_monitor EXIT INT TERM

story="${MEDINAG_E2E_STORY:-dose-response}"
if [[ "$story" == "notification-failure" ]]; then
  setup_spec="tests/e2e/005-notification-failure/setup.spec.ts"
  completion_spec="tests/e2e/005-notification-failure/completion.spec.ts"
  recovery_spec="tests/e2e/005-notification-failure/recovery.spec.ts"
  native_test="MediNagUITests/NotificationFailureUITests/testDeniedPermissionAlertsAdministrator"
  result_name="NotificationFailure"
else
  setup_spec="tests/e2e/004-ios-respond-to-dose/web.spec.ts"
  completion_spec="tests/e2e/004-ios-respond-to-dose/completion.spec.ts"
  native_test="MediNagUITests/RespondToDoseUITests/testConnectedSystemNotificationDoseLoop"
  result_name="SystemNotification"
fi
run_playwright() {
  if [[ "${MEDINAG_E2E_UPDATE_SNAPSHOTS:-false}" == "true" ]]; then
    npx playwright test "$1" --update-snapshots
  else
    npx playwright test "$1"
  fi
}
run_playwright "$setup_spec"
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

run_native_test() {
  local test_name="$1"
  local bundle="$2"
  local test_results
  if run_xcodebuild -quiet test-without-building \
    -project apps/ios/MediNag.xcodeproj \
    -scheme MediNag \
    -configuration E2E \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$derived_data_directory" \
    -only-testing:"$test_name" \
    -resultBundlePath "$bundle"; then
    return
  fi

  test_results=$(DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun \
    xcresulttool get test-results tests --path "$bundle" --format json \
    2>/dev/null || true)
  if [[ "$test_results" != *"Timed out while launching application via Xcode"* ]]; then
    return 1
  fi

  echo "Xcode timed out before XCUIApplication launched; retrying once without a fixed delay."
  /usr/bin/find "$bundle" -depth -delete
  run_xcodebuild -quiet test-without-building \
    -project apps/ios/MediNag.xcodeproj \
    -scheme MediNag \
    -configuration E2E \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$derived_data_directory" \
    -only-testing:"$test_name" \
    -resultBundlePath "$bundle"
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
  MEDINAG_E2E_GOOGLE_ID_TOKEN_BASE64="$MEDINAG_E2E_GOOGLE_ID_TOKEN_BASE64" \
  MEDINAG_E2E_ADMINISTRATOR_ID="$MEDINAG_E2E_ADMINISTRATOR_ID" \
  MEDINAG_E2E_ADMINISTRATOR_NAME="$MEDINAG_E2E_ADMINISTRATOR_NAME" \
  MEDINAG_E2E_MEDICATION_NAME="$MEDINAG_E2E_MEDICATION_NAME" \
  MEDINAG_E2E_SCHEDULED_TIME="$MEDINAG_E2E_SCHEDULED_TIME" \
  MEDINAG_E2E_TIME_ZONE="$MEDINAG_E2E_TIME_ZONE" \
  MEDINAG_E2E_LOGICAL_NOW="$MEDINAG_E2E_LOGICAL_NOW" \
  MEDINAG_E2E_AUTH_PORT="$MEDINAG_E2E_AUTH_PORT" \
  MEDINAG_E2E_FIRESTORE_PORT="$MEDINAG_E2E_FIRESTORE_PORT" \
  MEDINAG_E2E_ALARM_MONITOR_PORT="$MEDINAG_E2E_ALARM_MONITOR_PORT"

result_bundle="$derived_data_directory/$result_name.xcresult"
if [[ -d "$result_bundle" ]]; then
  /usr/bin/find "$result_bundle" -depth -delete
fi
run_native_test "$native_test" "$result_bundle"

run_playwright "$completion_spec"

if [[ "$story" == "notification-failure" ]]; then
  DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun simctl uninstall \
    "$simulator_id" org.boardgamescafe.medinag
  DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun simctl keychain \
    "$simulator_id" reset
  recovery_bundle="$derived_data_directory/NotificationRecovery.xcresult"
  if [[ -d "$recovery_bundle" ]]; then
    /usr/bin/find "$recovery_bundle" -depth -delete
  fi
  run_native_test \
    MediNagUITests/NotificationFailureUITests/testRestoredPermissionResolvesIncident \
    "$recovery_bundle"
  run_playwright "$recovery_spec"
fi
