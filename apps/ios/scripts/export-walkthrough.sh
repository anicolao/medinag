#!/bin/bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <xcresult-attachments-directory> <story-output-directory> [additional-attachments-directory ...]" >&2
  exit 2
fi

attachment_directories=("$1")
story_directory="$2"
shift 2
attachment_directories+=("$@")
screenshot_directory="$story_directory/screenshots/ios"

mkdir -p "$screenshot_directory"

copy_attachment() {
  local attachment_name="$1"
  local destination="$2"
  local exported_name
  local attachment_stem="${attachment_name%.*}"
  local attachments_directory
  local manifest

  for attachments_directory in "${attachment_directories[@]}"; do
    manifest="$attachments_directory/manifest.json"
    if [[ ! -f "$manifest" ]]; then
      echo "XCTest attachment manifest is missing: $manifest" >&2
      exit 1
    fi
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
    if [[ -n "$exported_name" && -f "$attachments_directory/$exported_name" ]]; then
      cp "$attachments_directory/$exported_name" "$destination"
      return
    fi
  done

  echo "XCTest attachment is missing: $attachment_name" >&2
  exit 1
}

copy_attachment "000-first-reminder.png" "$screenshot_directory/000-first-reminder.png"
copy_attachment "001-dose-snoozed.png" "$screenshot_directory/001-dose-snoozed.png"
copy_attachment "002-repeat-reminder.png" "$screenshot_directory/002-repeat-reminder.png"
copy_attachment "003-dose-completed.png" "$screenshot_directory/003-dose-completed.png"
copy_attachment "README.md" "$story_directory/README.md"
