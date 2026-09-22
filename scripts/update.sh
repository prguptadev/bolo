#!/bin/bash
# On the Mac that runs Bolo: pull the latest code, run the tests, rebuild, reinstall and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only
LOG=$(mktemp)
if scripts/test.sh >"$LOG" 2>&1; then
  grep -E "Test run with" "$LOG" | tail -1
else
  cat "$LOG"
  echo "Tests failed; not installing." >&2
  exit 1
fi
scripts/build-app.sh --install
