#!/bin/bash
# Builds build/Bolo.app and signs it with your Apple Development certificate.
# A stable signature keeps macOS permissions (Accessibility, Microphone…) across rebuilds.
#
#   scripts/build-app.sh            release build into build/Bolo.app
#   scripts/build-app.sh --install  also copy to ~/Applications and relaunch it
#
# Uses xcodebuild (full Xcode required): MLX's Metal kernels, which run Qwen on the GPU, only
# compile under Xcode. The compiled kernels (default.metallib) are copied into the app.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcode-select -p | grep -q "Xcode.app"; then
  echo "error: needs full Xcode selected: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

# Xcode 26 ships the Metal compiler as a separate component; MLX's GPU kernels need it.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Installing Xcode's Metal Toolchain (one time, ~700 MB)…"
  xcodebuild -downloadComponent MetalToolchain
fi

DERIVED=build/DerivedData
xcodebuild -scheme Bolo -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation -skipMacroValidation \
  -quiet build
PRODUCTS="$DERIVED/Build/Products/Release"

APP=build/Bolo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Bolo" "$APP/Contents/MacOS/Bolo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (MLX kernels, tokenizer data).
for bundle in "$PRODUCTS"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# MLX looks for mlx.metallib next to the executable first.
METALLIB=$(find "$PRODUCTS" -name "default.metallib" -path "*Cmlx*" | head -1)
if [ -n "$METALLIB" ]; then
  cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"
else
  echo "warning: MLX kernels (default.metallib) not found; Qwen won't run" >&2
fi

# First Apple Development identity, unless BOLO_SIGN_ID is set. Falls back to ad-hoc,
# which works but makes macOS ask for permissions again after every rebuild.
SIGN_ID="${BOLO_SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [ -n "$SIGN_ID" ]; then
  codesign --force --deep --sign "$SIGN_ID" --identifier dev.prgupta.bolo "$APP"
else
  echo "warning: no Apple Development certificate found; signing ad-hoc" >&2
  codesign --force --deep --sign - --identifier dev.prgupta.bolo "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  pkill -x Bolo 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Bolo.app"
  cp -R "$APP" "$HOME/Applications/Bolo.app"
  open "$HOME/Applications/Bolo.app"
  echo "Installed and launched ~/Applications/Bolo.app"
fi
