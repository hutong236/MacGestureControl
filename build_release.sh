#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found. Run this script on macOS with full Xcode installed." >&2
  exit 1
fi

BUILD_DIR="$ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
LOG_FILE="$BUILD_DIR/xcodebuild.log"
APP_PATH="$DERIVED_DATA/Build/Products/Release/GestureControl.app"
OUT_DIR="$ROOT/dist"
OUTPUT_APP="$OUT_DIR/GestureControl.app"

# Local MacBook build: compile only the host architecture by default.
# This avoids running arm64 + x86_64 Whole-Module Swift compiles in parallel,
# which can use a large amount of memory on recent Xcode versions.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "ERROR: unsupported host architecture: $HOST_ARCH" >&2
    exit 1
    ;;
esac

JOBS="${GESTURECONTROL_XCODE_JOBS:-2}"
UNIVERSAL="${GESTURECONTROL_UNIVERSAL:-0}"

rm -rf "$BUILD_DIR" "$OUT_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

echo "GestureControl build"
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Host architecture: $HOST_ARCH"
echo "Parallel jobs: $JOBS"
if [[ "$UNIVERSAL" == "1" ]]; then
  echo "Build mode: Universal (arm64 + x86_64)"
  ARCH_ARGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
else
  echo "Build mode: Native ($HOST_ARCH)"
  ARCH_ARGS=(ARCHS="$HOST_ARCH" ONLY_ACTIVE_ARCH=YES)
fi

echo "Build log: $LOG_FILE"
echo

# Use incremental compilation even for Release. For this small application it
# materially reduces peak compiler memory and produces much better per-file
# diagnostics than Whole Module Optimization when a Swift file fails.
set +e
xcodebuild \
  -project GestureControl.xcodeproj \
  -scheme GestureControl \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -jobs "$JOBS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_COMPILATION_MODE=incremental \
  "${ARCH_ARGS[@]}" \
  clean build 2>&1 | tee "$LOG_FILE"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [[ "$BUILD_RC" -ne 0 ]]; then
  echo
  echo "================ REAL BUILD DIAGNOSTICS ================" >&2
  # Xcode sometimes prints a huge compiler invocation after the useful error.
  # Surface the diagnostic lines again at the end so they are easy to copy.
  if ! grep -nE '(^|[[:space:]])(error:|fatal error:)|failed due to signal|Command SwiftCompile failed|SwiftCompile.*failed' "$LOG_FILE" | tail -n 120 >&2; then
    echo "No explicit error: line was found. Last 120 log lines:" >&2
    tail -n 120 "$LOG_FILE" >&2
  fi
  echo "========================================================" >&2
  echo "Full log: $LOG_FILE" >&2
  exit "$BUILD_RC"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: build succeeded but app not found at $APP_PATH" >&2
  exit 1
fi

cp -R "$APP_PATH" "$OUTPUT_APP"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUTPUT_APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUTPUT_APP/Contents/Info.plist")"

# Accessibility/TCC ties permission to the application's code identity.
# Prefer a persistent signing identity; fall back to ad-hoc signing for local use.
SIGN_IDENTITY="${GESTURECONTROL_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -n 1)"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with persistent identity: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
    --identifier com.hutong.GestureControl "$OUTPUT_APP"
  SIGNING_MODE="persistent"
else
  echo "WARNING: no Apple code-signing identity found; using ad-hoc signing."
  echo "         Accessibility permission may need to be granted again after rebuilding the app."
  codesign --force --deep --sign - --identifier com.hutong.GestureControl "$OUTPUT_APP"
  SIGNING_MODE="adhoc"
fi

codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_APP" "$OUT_DIR/GestureControl-macOS.zip"

cat > "$OUT_DIR/BUILD_INFO.txt" <<INFO
GestureControl $APP_VERSION ($APP_BUILD)
Bundle ID: com.hutong.GestureControl
Architecture mode: $([[ "$UNIVERSAL" == "1" ]] && echo universal || echo "$HOST_ARCH")
Signing mode: $SIGNING_MODE
Signing identity: ${SIGN_IDENTITY:-ad-hoc}

Full build log:
$LOG_FILE

For stable Accessibility permission, run the installed copy from:
/Applications/GestureControl.app
INFO

echo
printf 'Built successfully:\n  %s\n  %s\n' "$OUTPUT_APP" "$OUT_DIR/GestureControl-macOS.zip"
echo "Signing mode: $SIGNING_MODE"
echo "Recommended next step: ./install_local.sh"
