#!/usr/bin/env bash
set -euo pipefail
set +x

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
developer_directory="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
apple_configuration="${MEDINAG_APPLE_CONFIG:-$HOME/.config/hunger/testflight.env}"
firebase_configuration="${MEDINAG_FIREBASE_PLIST:-$repository_root/apps/ios/MediNag/Resources/GoogleService-Info.plist}"
bundle_identifier="org.boardgamescafe.medinag"
app_name="MediNag"
app_sku="medinag-ios"
testflight_group="${MEDINAG_TESTFLIGHT_GROUP:-Internal}"
marketing_version="${MEDINAG_MARKETING_VERSION:-0.1.0}"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

if [[ ! -x "$developer_directory/usr/bin/xcodebuild" ]]; then
  fail "Xcode was not found at $developer_directory"
fi
export DEVELOPER_DIR="$developer_directory"

for command_name in curl jq node openssl plutil security; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

[[ -f "$apple_configuration" ]] || fail "Apple handoff is missing: $apple_configuration"
# shellcheck disable=SC1090
source "$apple_configuration"

apple_team_identifier="${MEDINAG_APPLE_TEAM_ID:-${HUNGER_APPLE_TEAM_ID:-}}"
asc_key_path="${MEDINAG_ASC_KEY_PATH:-${HUNGER_ASC_KEY_PATH:-}}"
asc_key_identifier="${MEDINAG_ASC_KEY_ID:-${HUNGER_ASC_KEY_ID:-}}"
asc_issuer_identifier="${MEDINAG_ASC_ISSUER_ID:-${HUNGER_ASC_ISSUER_ID:-}}"
tester_email="${MEDINAG_TESTFLIGHT_TESTER_EMAIL:-${HUNGER_TESTFLIGHT_TESTER_EMAIL:-}}"

[[ "$apple_team_identifier" =~ ^[A-Z0-9]{10}$ ]] || fail "Apple Team ID is missing or invalid"
[[ "$asc_key_identifier" =~ ^[A-Z0-9]{10}$ ]] || fail "App Store Connect key ID is missing or invalid"
[[ "$asc_issuer_identifier" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "App Store Connect issuer ID is missing or invalid"
[[ -f "$asc_key_path" ]] || fail "App Store Connect private key is missing"
[[ "$tester_email" == *@*.* ]] || fail "The internal tester email is missing or invalid"
openssl pkey -in "$asc_key_path" -noout >/dev/null 2>&1 || fail "The App Store Connect key is not parseable"
login_keychain="$HOME/Library/Keychains/login.keychain-db"
if [[ -f "$login_keychain" ]] && ! security show-keychain-info "$login_keychain" >/dev/null 2>&1; then
  fail "The login keychain is locked; unlock it privately with: security unlock-keychain $login_keychain"
fi

[[ -f "$firebase_configuration" ]] || fail "Production GoogleService-Info.plist is missing"
plutil -lint "$firebase_configuration" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$firebase_configuration")" == "medinag" ]] \
  || fail "The Firebase plist is not for the medinag project"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "$firebase_configuration")" == "$bundle_identifier" ]] \
  || fail "The Firebase plist does not match $bundle_identifier"

asc_token() {
  node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const [path, issuer, keyID] = process.argv.slice(1);
    const encode = value => Buffer.from(JSON.stringify(value)).toString("base64url");
    const now = Math.floor(Date.now() / 1000);
    const input = encode({ alg: "ES256", kid: keyID, typ: "JWT" }) + "." +
      encode({ iss: issuer, iat: now - 5, exp: now + 600, aud: "appstoreconnect-v1" });
    const signature = crypto.sign("sha256", Buffer.from(input), {
      key: crypto.createPrivateKey(fs.readFileSync(path)),
      dsaEncoding: "ieee-p1363"
    }).toString("base64url");
    process.stdout.write(input + "." + signature);
  ' "$asc_key_path" "$asc_issuer_identifier" "$asc_key_identifier"
}

asc_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local token
  token="$(asc_token)"
  if [[ "$method" == "GET" ]]; then
    curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/json' \
      "https://api.appstoreconnect.apple.com$path"
  else
    curl --fail-with-body --silent --show-error -X "$method" \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --data "$body" \
      "https://api.appstoreconnect.apple.com$path"
  fi
}

url_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

encoded_bundle_identifier="$(url_encode "$bundle_identifier")"
bundle_response="$(asc_request GET "/v1/bundleIds?filter%5Bidentifier%5D=$encoded_bundle_identifier&limit=1")"
[[ "$(jq '.data | length' <<< "$bundle_response")" == "1" ]] \
  || fail "Register $bundle_identifier in Apple Developer before releasing"

app_response="$(asc_request GET "/v1/apps?filter%5BbundleId%5D=$encoded_bundle_identifier&limit=1")"
if [[ "$(jq '.data | length' <<< "$app_response")" != "1" ]]; then
  printf '%s\n' \
    "The App Store Connect app record is the one required manual step." \
    "Create an iOS app at https://appstoreconnect.apple.com/apps using:" \
    "  Name: $app_name" \
    "  Bundle ID: $bundle_identifier" \
    "  SKU: $app_sku" \
    "  Primary language: English (Canada)" >&2
  exit 2
fi
app_id="$(jq -r '.data[0].id' <<< "$app_response")"

group_response="$(asc_request GET "/v1/betaGroups?filter%5Bapp%5D=$app_id&filter%5BisInternalGroup%5D=true&limit=200")"
group_id="$(jq -r --arg name "$testflight_group" '.data[] | select(.attributes.name == $name) | .id' <<< "$group_response" | head -n 1)"
if [[ -z "$group_id" ]]; then
  group_body="$(jq -nc --arg appID "$app_id" --arg name "$testflight_group" \
    '{data:{type:"betaGroups",attributes:{name:$name,isInternalGroup:true,feedbackEnabled:true},relationships:{app:{data:{type:"apps",id:$appID}}}}}')"
  group_response="$(asc_request POST '/v1/betaGroups' "$group_body")"
  group_id="$(jq -r '.data.id' <<< "$group_response")"
  echo "Created the $testflight_group TestFlight group."
fi

builds_response="$(asc_request GET "/v1/builds?filter%5Bapp%5D=$app_id&limit=200")"
build_number="${MEDINAG_BUILD_NUMBER:-$(jq '([.data[].attributes.version | tonumber? // 0] | max // 0) + 1' <<< "$builds_response")}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "Could not determine a valid build number"

release_root="$repository_root/apps/ios/DerivedData/TestFlight/$build_number"
archive_path="$release_root/MediNag.xcarchive"
derived_data_path="$release_root/DerivedData"
result_bundle_path="$release_root/Archive.xcresult"
[[ ! -e "$archive_path" ]] || fail "Archive already exists for build $build_number: $archive_path"
mkdir -p "$release_root"

cd "$repository_root"
npm run ios:generate
echo "Archiving MediNag $marketing_version ($build_number)..."
xcodebuild archive \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data_path" \
  -resultBundlePath "$result_bundle_path" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$asc_key_path" \
  -authenticationKeyID "$asc_key_identifier" \
  -authenticationKeyIssuerID "$asc_issuer_identifier" \
  DEVELOPMENT_TEAM="$apple_team_identifier" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$build_number" \
  MARKETING_VERSION="$marketing_version"

application_path="$archive_path/Products/Applications/MediNag.app"
info_plist="$application_path/Info.plist"
[[ -d "$application_path" && -f "$info_plist" ]] || fail "The archive does not contain MediNag.app"
[[ -f "$application_path/GoogleService-Info.plist" ]] || fail "The archive is missing production Firebase configuration"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "$bundle_identifier" ]] \
  || fail "The archive has the wrong bundle identifier"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$marketing_version" ]] \
  || fail "The archive has the wrong marketing version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" == "$build_number" ]] \
  || fail "The archive has the wrong build number"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info_plist")" == "false" ]] \
  || fail "The archive is missing its encryption declaration"
codesign --verify --deep --strict "$application_path"

echo "Uploading MediNag $marketing_version ($build_number) to App Store Connect..."
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$release_root/export" \
  -exportOptionsPlist apps/ios/Config/TestFlightExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$asc_key_path" \
  -authenticationKeyID "$asc_key_identifier" \
  -authenticationKeyIssuerID "$asc_issuer_identifier"

build_id=""
for _ in {1..80}; do
  candidate_response="$(asc_request GET "/v1/builds?filter%5Bapp%5D=$app_id&filter%5Bversion%5D=$build_number&limit=1")"
  processing_state="$(jq -r '.data[0].attributes.processingState // empty' <<< "$candidate_response")"
  build_id="$(jq -r '.data[0].id // empty' <<< "$candidate_response")"
  if [[ "$processing_state" == "VALID" ]]; then
    break
  fi
  if [[ "$processing_state" == "FAILED" || "$processing_state" == "INVALID" ]]; then
    fail "App Store Connect rejected build $build_number during processing"
  fi
  sleep 15
done
[[ -n "$build_id" && "$processing_state" == "VALID" ]] \
  || fail "Timed out waiting for App Store Connect to process build $build_number"

group_builds="$(asc_request GET "/v1/betaGroups/$group_id/relationships/builds?limit=200")"
if ! jq -e --arg id "$build_id" 'any(.data[]; .id == $id)' <<< "$group_builds" >/dev/null; then
  build_link="$(jq -nc --arg id "$build_id" '{data:[{type:"builds",id:$id}]}')"
  asc_request POST "/v1/betaGroups/$group_id/relationships/builds" "$build_link" >/dev/null
fi

encoded_tester_email="$(url_encode "$tester_email")"
tester_response="$(asc_request GET "/v1/betaTesters?filter%5Bemail%5D=$encoded_tester_email&limit=200")"
tester_id="$(jq -r '.data[0].id // empty' <<< "$tester_response")"
if [[ -z "$tester_id" ]]; then
  user_response="$(asc_request GET "/v1/users?filter%5Busername%5D=$encoded_tester_email&limit=1")"
  [[ "$(jq '.data | length' <<< "$user_response")" == "1" ]] \
    || fail "The configured internal tester is not an accepted App Store Connect user"
  tester_body="$(jq -nc \
    --arg email "$tester_email" \
    --arg firstName "$(jq -r '.data[0].attributes.firstName // "MediNag"' <<< "$user_response")" \
    --arg lastName "$(jq -r '.data[0].attributes.lastName // "Tester"' <<< "$user_response")" \
    --arg groupID "$group_id" \
    '{data:{type:"betaTesters",attributes:{email:$email,firstName:$firstName,lastName:$lastName},relationships:{betaGroups:{data:[{type:"betaGroups",id:$groupID}]}}}}')"
  tester_response="$(asc_request POST '/v1/betaTesters' "$tester_body")"
  tester_id="$(jq -r '.data.id' <<< "$tester_response")"
else
  tester_groups="$(asc_request GET "/v1/betaTesters/$tester_id/relationships/betaGroups?limit=200")"
  if ! jq -e --arg id "$group_id" 'any(.data[]; .id == $id)' <<< "$tester_groups" >/dev/null; then
    tester_link="$(jq -nc --arg id "$tester_id" '{data:[{type:"betaTesters",id:$id}]}')"
    asc_request POST "/v1/betaGroups/$group_id/relationships/betaTesters" "$tester_link" >/dev/null
  fi
fi

echo "MediNag $marketing_version ($build_number) is processed and assigned to $testflight_group."
