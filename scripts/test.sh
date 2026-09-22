#!/bin/bash
# Runs the Swift Testing suite with only the Command Line Tools installed (no Xcode).
# The CLT ship Testing.framework but SwiftPM doesn't add its search paths on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
if [ -d /Applications/Xcode.app ] && xcode-select -p | grep -q Xcode.app; then
  exec swift test "$@"
fi
exec swift test \
  -Xswiftc -F"$DEV/Frameworks" \
  -Xlinker -F"$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
