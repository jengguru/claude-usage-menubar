#!/usr/bin/env bash
# Builds "Headroom.app" (menu bar only, ad-hoc signed) into ./build.
#   UNIVERSAL=1 scripts/build-app.sh   # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Headroom.app"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Headroom" "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: render every size macOS wants from the 1024px PNG.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature with the hardened runtime: macOS then refuses code injection
# (DYLD_INSERT_LIBRARIES, unsigned libraries, debugger attach) into the app.
codesign --force --sign - --options runtime --timestamp=none "$APP"

(cd build && rm -f Headroom.zip Headroom.zip.sha256 \
  && ditto -c -k --keepParent "Headroom.app" Headroom.zip \
  && shasum -a 256 Headroom.zip > Headroom.zip.sha256)
echo "Built $APP"
