#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
swift build --product UpdaterCoreChecks --disable-sandbox --cache-path .build/cache --scratch-path .build
BIN_DIR="$(swift build --show-bin-path --disable-sandbox --cache-path .build/cache --scratch-path .build)"
swiftc -parse-as-library -I "$BIN_DIR" -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    Sources/UnifiedUpdater/AppModel.swift Tests/AppModelChecks/Main.swift "$BIN_DIR/UpdaterCore.o" -o "$PROJECT_ROOT/.build/AppModelChecks"
# AppModel uses only the injected command runner and temporary fixture apps/data.
PACKAGE_RESOURCE_BUNDLE_PATH="$BIN_DIR" "$PROJECT_ROOT/.build/AppModelChecks"
