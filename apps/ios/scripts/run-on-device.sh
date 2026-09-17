#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
developer_directory="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
firebase_configuration="${MEDINAG_FIREBASE_PLIST:-$repository_root/apps/ios/MediNag/Resources/GoogleService-Info.plist}"
derived_data_directory="${MEDINAG_DEVICE_DERIVED_DATA:-$repository_root/apps/ios/DerivedData/Device}"
apple_configuration="${MEDINAG_APPLE_CONFIG:-$HOME/.config/hunger/testflight.env}"
bundle_identifier="org.boardgamescafe.medinag"

if [[ ! -x "$developer_directory/usr/bin/xcodebuild" ]]; then
  echo "Xcode was not found at $developer_directory" >&2
  echo "Set MEDINAG_XCODE_DEVELOPER_DIR to the active Xcode developer directory." >&2
  exit 1
fi
export DEVELOPER_DIR="$developer_directory"

for command_name in jq plutil security; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required for physical-device installation." >&2
    exit 1
  fi
done

if [[ ! -f "$firebase_configuration" ]]; then
  echo "Firebase configuration is missing: $firebase_configuration" >&2
  echo "Register the Firebase iOS app and download GoogleService-Info.plist first." >&2
  exit 1
fi
plutil -lint "$firebase_configuration" >/dev/null
configured_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "$firebase_configuration")"
configured_project_identifier="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$firebase_configuration")"
configured_callback_scheme="$(/usr/libexec/PlistBuddy -c 'Print :REVERSED_CLIENT_ID' "$firebase_configuration")"
if [[ "$configured_bundle_identifier" != "$bundle_identifier" || "$configured_project_identifier" != "medinag" ]]; then
  echo "GoogleService-Info.plist does not describe the MediNag production iOS app." >&2
  exit 1
fi

if [[ -f "$apple_configuration" ]]; then
  # shellcheck disable=SC1090
  source "$apple_configuration"
fi
apple_team_identifier="${MEDINAG_APPLE_TEAM_ID:-${HUNGER_APPLE_TEAM_ID:-}}"
asc_key_path="${MEDINAG_ASC_KEY_PATH:-${HUNGER_ASC_KEY_PATH:-}}"
asc_key_identifier="${MEDINAG_ASC_KEY_ID:-${HUNGER_ASC_KEY_ID:-}}"
asc_issuer_identifier="${MEDINAG_ASC_ISSUER_ID:-${HUNGER_ASC_ISSUER_ID:-}}"
if [[ -z "$apple_team_identifier" ]]; then
  echo "Set MEDINAG_APPLE_TEAM_ID or provide MEDINAG_APPLE_CONFIG." >&2
  exit 1
fi

authentication_arguments=()
if [[ -n "$asc_key_path" || -n "$asc_key_identifier" || -n "$asc_issuer_identifier" ]]; then
  if [[ ! -f "$asc_key_path" || -z "$asc_key_identifier" || -z "$asc_issuer_identifier" ]]; then
    echo "The App Store Connect authentication configuration is incomplete." >&2
    exit 1
  fi
  authentication_arguments=(
    -authenticationKeyPath "$asc_key_path"
    -authenticationKeyID "$asc_key_identifier"
    -authenticationKeyIssuerID "$asc_issuer_identifier"
  )
fi

login_keychain="$HOME/Library/Keychains/login.keychain-db"
if [[ -f "$login_keychain" ]] && ! security show-keychain-info "$login_keychain" >/dev/null 2>&1; then
  echo "The login keychain is locked for command-line signing." >&2
  echo "Unlock it privately, then rerun this command:" >&2
  echo "  security unlock-keychain $login_keychain" >&2
  exit 1
fi

mkdir -p "$derived_data_directory"
device_json="$derived_data_directory/connected-devices.json"
xcrun devicectl list devices --json-output "$device_json" >/dev/null

device_identifier="${MEDINAG_IOS_DEVICE_ID:-}"
if [[ -z "$device_identifier" ]]; then
  device_count="$(jq '[.result.devices[] | select(
    .hardwareProperties.deviceType == "iPhone"
    and .connectionProperties.pairingState == "paired"
    and .deviceProperties.developerModeStatus == "enabled"
    and .deviceProperties.ddiServicesAvailable == true
  )] | length' "$device_json")"
  if [[ "$device_count" != "1" ]]; then
    echo "Expected exactly one paired, available iPhone in Developer Mode; found $device_count." >&2
    echo "Set MEDINAG_IOS_DEVICE_ID when more than one device is available." >&2
    exit 1
  fi
  device_identifier="$(jq -r '.result.devices[] | select(
    .hardwareProperties.deviceType == "iPhone"
    and .connectionProperties.pairingState == "paired"
    and .deviceProperties.developerModeStatus == "enabled"
    and .deviceProperties.ddiServicesAvailable == true
  ) | .identifier' "$device_json")"
fi
device_name="$(jq -r --arg identifier "$device_identifier" '.result.devices[] | select(.identifier == $identifier) | .deviceProperties.name' "$device_json")"
if [[ -z "$device_name" ]]; then
  echo "The selected iPhone is not currently available: $device_identifier" >&2
  exit 1
fi

cd "$repository_root"
npm run ios:generate

echo "Building MediNag for $device_name..."
xcodebuild \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration Debug \
  -destination "id=$device_identifier" \
  -derivedDataPath "$derived_data_directory" \
  -jobs 1 \
  -quiet \
  -allowProvisioningUpdates \
  "${authentication_arguments[@]}" \
  DEVELOPMENT_TEAM="$apple_team_identifier" \
  CODE_SIGN_STYLE=Automatic \
  build

application_path="$derived_data_directory/Build/Products/Debug-iphoneos/MediNag.app"
if [[ ! -d "$application_path" || ! -f "$application_path/GoogleService-Info.plist" ]]; then
  echo "The signed application or its Firebase configuration is missing." >&2
  exit 1
fi
embedded_callback_scheme="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$application_path/Info.plist")"
if [[ "$embedded_callback_scheme" != "$configured_callback_scheme" ]]; then
  echo "The signed application does not contain the configured Google callback URL scheme." >&2
  exit 1
fi
codesign --verify --deep --strict "$application_path"

echo "Installing MediNag on $device_name..."
xcrun devicectl device install app --device "$device_identifier" "$application_path"
xcrun devicectl device process launch \
  --device "$device_identifier" \
  --terminate-existing \
  "$bundle_identifier"

echo "MediNag is installed and connected to the production Firebase project."
