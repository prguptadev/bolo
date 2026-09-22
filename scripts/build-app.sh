#!/bin/bash
# Builds build/Bolo.app and signs it with your Apple Development certificate.
# A stable signature keeps macOS permissions (Accessibility, Microphone…) across rebuilds.
#
#   scripts/build-app.sh            release build into build/Bolo.app
#   scripts/build-app.sh --install  also copy to ~/Applications and relaunch it
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Bolo"

APP=build/Bolo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bolo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# First Apple Development identity, unless BOLO_SIGN_ID is set. Falls back to ad-hoc,
# which works but makes macOS ask for permissions again after every rebuild.
SIGN_ID="${BOLO_SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [ -n "$SIGN_ID" ]; then
  codesign --force --sign "$SIGN_ID" --identifier dev.prgupta.bolo "$APP"
else
  echo "warning: no Apple Development certificate found; signing ad-hoc" >&2
  codesign --force --sign - --identifier dev.prgupta.bolo "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Bolo 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Bolo.app"
  cp -R "$APP" "$HOME/Applications/Bolo.app"
  open "$HOME/Applications/Bolo.app"
  echo "Installed and launched ~/Applications/Bolo.app"
fi
