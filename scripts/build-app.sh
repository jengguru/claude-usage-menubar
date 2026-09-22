#!/usr/bin/env bash
# Builds "Claude Meter.app" (menu bar only, ad-hoc signed) into ./build.
#   UNIVERSAL=1 scripts/build-app.sh   # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Claude Meter.app"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeMeter" "$APP/Contents/MacOS/ClaudeMeter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"

(cd build && rm -f ClaudeMeter.zip && ditto -c -k --keepParent "Claude Meter.app" ClaudeMeter.zip)
echo "Built $APP"
