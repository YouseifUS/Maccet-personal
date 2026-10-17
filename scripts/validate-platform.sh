#!/bin/bash
# Controlled tests and local ad-hoc packaging only; no source preparation or updates.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
EXPECTED_ARCHITECTURE="${1:-$(uname -m)}"
case "$EXPECTED_ARCHITECTURE" in
    arm64|x86_64) ;;
    *) printf 'Expected architecture must be arm64 or x86_64.\n' >&2; exit 2 ;;
esac
LOG_DIR="$PROJECT_ROOT/.build/platform-validation"
mkdir -p "$LOG_DIR"
# Remove previous evidence so a failed rerun cannot retain stale success logs.
rm -f "$LOG_DIR"/*.log
{
    git rev-parse HEAD
    /usr/bin/sw_vers
    uname -m
    /usr/bin/xcrun swift --version
    /usr/bin/xcrun --show-sdk-version
    /usr/bin/xcode-select -p
    if ! /usr/bin/xcodebuild -version; then
        printf 'Xcode version unavailable; selected developer directory and Swift/SDK versions are recorded above.\n'
    fi
    /usr/bin/python3 --version
    test "$(uname -m)" = "$EXPECTED_ARCHITECTURE"
} 2>&1 | tee "$LOG_DIR/environment.log"

bash scripts/test.sh 2>&1 | tee "$LOG_DIR/core.log"
bash scripts/test-ui-model.sh 2>&1 | tee "$LOG_DIR/ui-model.log"
bash scripts/test-setup-retry.sh 2>&1 | tee "$LOG_DIR/setup.log"
/usr/bin/python3 scripts/test-release.py 2>&1 | tee "$LOG_DIR/release-orchestration.log"
bash scripts/build.sh 2>&1 | tee "$LOG_DIR/build.log"

EXTRACTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/maccet-platform.XXXXXXXX")"
trap 'rm -rf "$EXTRACTION_DIR"' EXIT
{
    ARCHIVE="$PROJECT_ROOT/dist/Maccet-0.1.2-macOS-$EXPECTED_ARCHITECTURE.zip"
    /usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACTION_DIR"
    APP="$EXTRACTION_DIR/Maccet.app"
    EXECUTABLE="$APP/Contents/MacOS/UnifiedUpdater"
    /usr/bin/codesign --verify --deep --strict "$APP"
    test "$(/usr/bin/lipo -archs "$EXECUTABLE")" = "$EXPECTED_ARCHITECTURE"
    /usr/bin/plutil -lint "$APP/Contents/Info.plist"
    # Inspect the delivered resource itself, independently of SwiftPM lookup fallbacks.
    SCRIPT="$APP/Contents/Resources/UnifiedUpdater_UpdaterCore.bundle/Contents/Resources/prepare-sources.sh"
    test -f "$SCRIPT"
    /bin/bash -n "$SCRIPT"
    cmp Sources/UpdaterCore/Resources/prepare-sources.sh "$SCRIPT"
    (cd "$EXTRACTION_DIR" && "$EXECUTABLE" --check-startup-script)
    /usr/bin/shasum -a 256 "$ARCHIVE"
    printf 'PASS: extracted package signature, architecture, metadata and startup resource.\n'
} 2>&1 | tee "$LOG_DIR/package.log"
