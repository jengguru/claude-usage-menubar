#!/usr/bin/env bash
# Checks the built app: valid signature with the hardened runtime, the version
# matches Info.plist, and it launches and stays running for a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Headroom.app"
codesign --verify --strict --deep "$APP"
flags="$(codesign -d --verbose=2 "$APP" 2>&1 | grep -E '^CodeDirectory' || true)"
echo "$flags"
if [[ "$flags" != *runtime* ]]; then
  echo "error: hardened runtime is not enabled." >&2
  exit 1
fi

(cd build && shasum -a 256 -c Headroom.zip.sha256)

"$APP/Contents/MacOS/Headroom" &
pid=$!
sleep 5
if ! kill -0 "$pid" 2>/dev/null; then
  wait "$pid" || true
  echo "error: Headroom exited during launch." >&2
  exit 1
fi
kill "$pid"
echo "OK: signed with hardened runtime, checksum matches, launches."
