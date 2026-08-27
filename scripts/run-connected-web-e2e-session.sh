#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

eval "$(node scripts/setup-e2e-environment.mjs --shell)"
if [[ "${MEDINAG_E2E_UPDATE_SNAPSHOTS:-false}" == "true" ]]; then
  exec npx playwright test "$MEDINAG_E2E_PLAYWRIGHT_TARGET" --update-snapshots
fi
exec npx playwright test "$MEDINAG_E2E_PLAYWRIGHT_TARGET"
