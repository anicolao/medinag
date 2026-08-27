#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

if ! java -version >/dev/null 2>&1; then
  if [[ -z "${MEDINAG_E2E_NIX_SHELL:-}" ]] && command -v nix >/dev/null 2>&1; then
    exec env MEDINAG_E2E_NIX_SHELL=1 nix develop --command "$0" "$@"
  fi
  echo "Java 21 is required by the Firestore emulator." >&2
  exit 1
fi

export MEDINAG_E2E_PROJECT_ID="demo-medinag"
export MEDINAG_E2E_AUTH_HOST="127.0.0.1:9099"
export MEDINAG_E2E_FIRESTORE_HOST="127.0.0.1:8080"
export MEDINAG_E2E_ADVISOR_NAME="Lori"
export MEDINAG_E2E_SUBJECT_NAME="Steve"
export MEDINAG_E2E_STATE_FILE="$(mktemp /tmp/medinag-e2e-state.XXXXXX.json)"

exec npx firebase emulators:exec \
  --project "$MEDINAG_E2E_PROJECT_ID" \
  --only auth,firestore \
  "scripts/run-local-e2e-session.sh"
