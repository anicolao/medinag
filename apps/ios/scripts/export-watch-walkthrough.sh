#!/usr/bin/env bash
set -euo pipefail
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
derived_data="${1:?usage: export-watch-walkthrough.sh derived-data output-directory}"
output="${2:?output-directory is required}"
export DEVELOPER_DIR="${MEDINAG_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
attachment_directories=()
for result in WatchPhoneSignIn WatchSetup WatchPhoneFollowing WatchResponses; do
  /usr/bin/xcrun xcresulttool get test-results summary \
    --path "$derived_data/$result.xcresult" --format json | jq -e \
    '.result == "Passed" and .failedTests == 0 and .skippedTests == 0 and .passedTests > 0' >/dev/null
  directory="$output/$result-attachments"
  mkdir -p "$directory"
  /usr/bin/xcrun xcresulttool export attachments \
    --path "$derived_data/$result.xcresult" --output-path "$directory"
  attachment_directories+=("$directory")
done
mkdir -p "$output/screenshots/web"
cp "$repository_root/tests/e2e/006-watch-companion/screenshots/web/"*.png "$output/screenshots/web/"
"$script_directory/export-walkthrough.sh" "${attachment_directories[0]}" "$output" \
  "$repository_root/tests/e2e/006-watch-companion/claims.json" \
  "${attachment_directories[1]}" "${attachment_directories[2]}" "${attachment_directories[3]}"
