#!/usr/bin/env bash
set -euo pipefail
set +x
cd "$(dirname "$0")/../../.."
device="${1:?Pass the target iPhone identifier from xcrun devicectl list devices}"
export DEVELOPER_DIR="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${MEDINAG_APPLE_CONFIG:-$HOME/.config/hunger/testflight.env}"
source "$configuration"
team="${MEDINAG_APPLE_TEAM_ID:-${HUNGER_APPLE_TEAM_ID:-}}"
key_path="${MEDINAG_ASC_KEY_PATH:-${HUNGER_ASC_KEY_PATH:-}}"
key_id="${MEDINAG_ASC_KEY_ID:-${HUNGER_ASC_KEY_ID:-}}"
issuer="${MEDINAG_ASC_ISSUER_ID:-${HUNGER_ASC_ISSUER_ID:-}}"
[[ -n "$team" && -f "$key_path" && -n "$key_id" && -n "$issuer" ]] || {
  echo 'Missing Apple development/signing configuration.' >&2; exit 1;
}
npm run ios:generate
device_info="$(mktemp /tmp/medinag-alarm-lab-device.XXXXXX)"
xcrun devicectl device info details --device "$device" --json-output "$device_info" >/dev/null
device_udid="$(node -e 'const j=require("node:fs").readFileSync(process.argv[1],"utf8"); const id=JSON.parse(j).result?.hardwareProperties?.udid; if(!id)process.exit(1);process.stdout.write(id)' "$device_info")"
xcodebuild build -project apps/ios/MediNag.xcodeproj -scheme MediNagAlarmDiagnostic \
  -configuration Debug -destination "platform=iOS,id=$device_udid" \
  -derivedDataPath apps/ios/DerivedData/AlarmLabDevice -quiet \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$key_path" -authenticationKeyID "$key_id" \
  -authenticationKeyIssuerID "$issuer" DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic
app=apps/ios/DerivedData/AlarmLabDevice/Build/Products/Debug-iphoneos/MediNagAlarmLab.app
codesign --verify --deep --strict "$app"
xcrun devicectl device install app --device "$device" "$app" --timeout 60
echo 'Installed MediNag Alarm Lab alongside MediNag. No test alarms have been armed.'
