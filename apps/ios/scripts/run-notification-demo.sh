#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
default_developer_directory="/Applications/Xcode.app/Contents/Developer"
developer_directory="${MEDINAG_XCODE_DEVELOPER_DIR:-$default_developer_directory}"
derived_data_directory="${MEDINAG_DEMO_DERIVED_DATA:-/tmp/medinag-notification-demo-xcode-derived}"
bundle_identifier="org.boardgamescafe.medinag"

required_environment=(
  VITE_FIREBASE_API_KEY
  VITE_FIREBASE_PROJECT_ID
  VITE_FIREBASE_MESSAGING_SENDER_ID
  VITE_FIREBASE_APP_ID
)
for variable_name in "${required_environment[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "$variable_name is missing." >&2
    echo "Start the connected environment with: npm run e2e:local" >&2
    exit 1
  fi
done

if
  [[ -z "${MEDINAG_XCODE_DEVELOPER_DIR:-}" ]] \
    && [[ -n "${DEVELOPER_DIR:-}" ]] \
    && [[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]
then
  developer_directory="$DEVELOPER_DIR"
fi

if [[ ! -x "$developer_directory/usr/bin/xcodebuild" ]]; then
  echo "Xcode was not found at $developer_directory" >&2
  echo "Set MEDINAG_XCODE_DEVELOPER_DIR to an Xcode 26.2-or-newer developer directory." >&2
  exit 1
fi

export DEVELOPER_DIR="$developer_directory"
xcrun_command="/usr/bin/xcrun"
xcodebuild_command="$developer_directory/usr/bin/xcodebuild"

device_id="${1:-}"
if [[ -z "$device_id" ]]; then
  demo_device_name="MediNag Notification Demo"
  device_id="$("$xcrun_command" simctl list devices \
    | sed -nE '/MediNag Notification Demo/ s/.*\(([0-9A-Fa-f-]{36})\).*/\1/p' \
    | head -n 1)"

  if [[ -n "$device_id" ]]; then
    "$xcrun_command" simctl shutdown "$device_id" 2>/dev/null || true
    "$xcrun_command" simctl erase "$device_id"
  else
    runtime_id="$("$xcrun_command" simctl list runtimes \
      | sed -nE '/^iOS / s/.* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1/p' \
      | tail -n 1)"
    if [[ -z "$runtime_id" ]]; then
      echo "No installed iOS Simulator runtime was found." >&2
      exit 1
    fi
    device_id="$("$xcrun_command" simctl create \
      "$demo_device_name" \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
      "$runtime_id")"
  fi
  "$xcrun_command" simctl boot "$device_id"
fi

cd "$repository_root"
npm run ios:generate

"$xcrun_command" simctl bootstatus "$device_id" -b
"$xcrun_command" simctl ui "$device_id" appearance light
"$xcrun_command" simctl ui "$device_id" increase_contrast enabled
"$xcrun_command" simctl ui "$device_id" content_size medium
"$xcrun_command" simctl status_bar "$device_id" override \
  --time '2026-08-03T08:00:00.000-04:00' \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4

/usr/bin/env \
  -u AR \
  -u AS \
  -u CC \
  -u CFLAGS \
  -u CPP \
  -u CPPFLAGS \
  -u CPATH \
  -u CXX \
  -u CXXFLAGS \
  -u C_INCLUDE_PATH \
  -u CPLUS_INCLUDE_PATH \
  -u LD \
  -u LDFLAGS \
  -u LIBRARY_PATH \
  -u MACOSX_DEPLOYMENT_TARGET \
  -u NIX_BINTOOLS \
  -u NIX_CC \
  -u NIX_CFLAGS_COMPILE \
  -u NIX_ENFORCE_NO_NATIVE \
  -u NIX_HARDENING_ENABLE \
  -u NIX_LDFLAGS \
  -u OBJC_INCLUDE_PATH \
  -u SDKROOT \
  DEVELOPER_DIR="$developer_directory" \
  PATH="$developer_directory/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$xcodebuild_command" -quiet build \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath "$derived_data_directory"

application_path="$derived_data_directory/Build/Products/E2E-iphonesimulator/MediNag.app"
if [[ ! -d "$application_path" ]]; then
  echo "The built app was not found at $application_path" >&2
  exit 1
fi

"$xcrun_command" simctl terminate "$device_id" "$bundle_identifier" 2>/dev/null || true
"$xcrun_command" simctl uninstall "$device_id" "$bundle_identifier" 2>/dev/null || true
"$xcrun_command" simctl install "$device_id" "$application_path"
open -a Simulator --args -CurrentDeviceUDID "$device_id"
"$xcrun_command" simctl launch "$device_id" "$bundle_identifier" \
  -e2e \
  -firebase-emulator-project-id "$VITE_FIREBASE_PROJECT_ID" \
  -firebase-emulator-api-key "$VITE_FIREBASE_API_KEY" \
  -firebase-emulator-app-id "$VITE_FIREBASE_APP_ID" \
  -firebase-emulator-messaging-sender-id "$VITE_FIREBASE_MESSAGING_SENDER_ID" \
  -firebase-emulator-host 127.0.0.1 \
  -firebase-auth-emulator-port 9099 \
  -firebase-firestore-emulator-port 8080 \
  -AppleLanguages '(en)' \
  -AppleLocale en_CA \
  -UIPreferredContentSizeCategoryName UICTContentSizeCategoryM \
  -UIUserInterfaceStyle Light

echo
echo "MediNag is connected to the local Firebase emulators on Simulator $device_id."
