#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
swift build -c release -debug-info-format none --product UnifiedUpdater --disable-sandbox --cache-path .build/cache --scratch-path .build
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/cache --scratch-path .build)"
APP_DIR="$PROJECT_ROOT/dist/Unified Updater.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/UnifiedUpdater" "$APP_DIR/Contents/MacOS/UnifiedUpdater"
cp "$PROJECT_ROOT/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$PROJECT_ROOT/.build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$PROJECT_ROOT/.build/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PROJECT_ROOT/dist/UnifiedUpdater-0.1.1-macOS-$(uname -m).zip"
printf '\nBuilt %s\n' "$APP_DIR"
