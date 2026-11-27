#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
export DEVELOPER_DIR="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
npm run ios:generate
lab_simulator="$(xcrun simctl create 'MediNag Alarm Lab Check' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
trap 'xcrun simctl delete "$lab_simulator" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$lab_simulator"
xcrun simctl bootstatus "$lab_simulator" -b
result="apps/ios/DerivedData/AlarmLab-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild test -project apps/ios/MediNag.xcodeproj -scheme MediNagAlarmDiagnostic \
  -configuration Debug -destination "platform=iOS Simulator,id=$lab_simulator" \
  -derivedDataPath apps/ios/DerivedData/AlarmLabSimulator -resultBundlePath "$result" -quiet
xcrun xcresulttool get test-results summary --path "$result" --format json \
  | jq -e '.failedTests == 0 and .skippedTests == 0 and .passedTests > 0'
