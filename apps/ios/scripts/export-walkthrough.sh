#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <xcresult-attachments-directory> <story-output-directory> [claims-file] [additional-attachments-directory ...]" >&2
  exit 2
fi

attachment_directories=("$1")
story_directory="$2"
claims_file="${3:-$repository_root/tests/e2e/004-ios-respond-to-dose/claims.json}"
shift $(( $# >= 3 ? 3 : 2 ))
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

while IFS= read -r screenshot; do
  copy_attachment "$screenshot" "$screenshot_directory/$screenshot"
done < <(jq -r '.steps[] | select(.surface == "ios") | .image' "$claims_file")

node "$repository_root/scripts/generate-walkthrough.mjs" \
  "$claims_file" \
  "$story_directory"
