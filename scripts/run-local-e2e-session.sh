#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

eval "$(node scripts/setup-e2e-environment.mjs --shell)"
vite_log="$(mktemp /tmp/medinag-vite.XXXXXX)"
npm run dev >"$vite_log" 2>&1 &
vite_pid=$!
cleanup() {
  kill "$vite_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

apps/ios/scripts/run-notification-demo.sh "${1:-}"
if ! kill -0 "$vite_pid" 2>/dev/null; then
  echo "The dashboard dev server exited before the iOS build completed:" >&2
  sed -n '1,160p' "$vite_log" >&2
  exit 1
fi

dashboard_url="http://127.0.0.1:5174/#/schedules"
open "$dashboard_url"

echo
echo "Connected MediNag E2E environment is running."
echo "Dashboard: $dashboard_url"
echo "Firebase Emulator UI: http://127.0.0.1:4000"
echo "iOS Google patient: $MEDINAG_E2E_PATIENT_EMAIL"
echo
echo "In the browser, add a dose and publish Lori's schedule."
echo "In the iPhone app, sign in with Google, choose Lori, and follow the schedule."
echo "The dose and its medication event will appear through the live Firestore listener."
echo "Press Control-C here to stop the isolated environment."

wait "$vite_pid"
