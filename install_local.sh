#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$ROOT/dist/GestureControl.app"
TARGET_APP="/Applications/GestureControl.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "dist/GestureControl.app not found. Run ./build_release.sh first." >&2
  exit 1
fi

pkill -x GestureControl >/dev/null 2>&1 || true
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"

# Verify the exact installed copy before asking TCC for permission.
codesign --verify --deep --strict --verbose=2 "$TARGET_APP"

echo
printf 'Installed:\n  %s\n' "$TARGET_APP"
echo
echo 'IMPORTANT:'
echo '1. Always launch this /Applications copy.'
echo '2. If an older GestureControl entry is still in Accessibility, remove/reset it once,'
echo '   then launch this copy and authorize it again.'
echo
open "$TARGET_APP"
