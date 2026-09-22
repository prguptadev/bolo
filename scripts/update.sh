#!/bin/bash
# On the Mac that runs Bolo: pull the latest code, run the tests, rebuild, reinstall and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only
scripts/test.sh
scripts/build-app.sh --install
