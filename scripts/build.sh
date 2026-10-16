#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
swift build -c release -debug-info-format none --product UnifiedUpdater --disable-sandbox --cache-path .build/cache --scratch-path .build
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/cache --scratch-path .build)"
APP_DIR="$PROJECT_ROOT/dist/Maccet.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/UnifiedUpdater" "$APP_DIR/Contents/MacOS/UnifiedUpdater"
# SwiftPM resources must travel with the app, independently of the build folder.
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle; do
    [ -d "$RESOURCE_BUNDLE" ] || continue
    /usr/bin/ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
done
cp "$PROJECT_ROOT/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cp "$PROJECT_ROOT/assets/branding/Maccet.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PROJECT_ROOT/dist/Maccet-0.1.2-macOS-$(uname -m).zip"
printf '\nBuilt %s\n' "$APP_DIR"
