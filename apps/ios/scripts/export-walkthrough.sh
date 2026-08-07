#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <xcresult-attachments-directory> <story-output-directory>" >&2
  exit 2
fi

attachments_directory="$1"
story_directory="$2"
manifest="$attachments_directory/manifest.json"
screenshot_directory="$story_directory/screenshots/ios"

if [[ ! -f "$manifest" ]]; then
  echo "XCTest attachment manifest is missing: $manifest" >&2
  exit 1
fi

mkdir -p "$screenshot_directory"

copy_attachment() {
  local attachment_name="$1"
  local destination="$2"
  local exported_name
  local attachment_stem="${attachment_name%.*}"

  exported_name="$(
    jq -r \
      --arg attachment_name "$attachment_name" \
      --arg attachment_stem "$attachment_stem" '
      [
        .[]?.attachments[]?
        | select(
            .suggestedHumanReadableName == $attachment_name
            or (.suggestedHumanReadableName | startswith($attachment_stem + "_"))
          )
        | .exportedFileName
      ][0] // empty
    ' "$manifest"
  )"

  if [[ -z "$exported_name" || ! -f "$attachments_directory/$exported_name" ]]; then
    echo "XCTest attachment is missing: $attachment_name" >&2
    exit 1
  fi

  cp "$attachments_directory/$exported_name" "$destination"
}

copy_attachment "000-pending-dose.png" "$screenshot_directory/000-pending-dose.png"
copy_attachment "001-dose-snoozed.png" "$screenshot_directory/001-dose-snoozed.png"
copy_attachment "002-dose-completed.png" "$screenshot_directory/002-dose-completed.png"

if jq -e '[.[]?.attachments[]? | select(.suggestedHumanReadableName | startswith("README"))] | length > 0' "$manifest" >/dev/null; then
  copy_attachment "README.md" "$story_directory/README.md"
fi
