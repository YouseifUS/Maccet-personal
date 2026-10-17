#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
swift build --product UpdaterCoreChecks --disable-sandbox --cache-path .build/cache --scratch-path .build
BIN_DIR="$(swift build --show-bin-path --disable-sandbox --cache-path .build/cache --scratch-path .build)"
CORE_OBJECTS=("$BIN_DIR"/UpdaterCore.build/*.o)
if [ ! -f "${CORE_OBJECTS[0]}" ]; then CORE_OBJECTS=("$BIN_DIR/UpdaterCore.o"); fi
swiftc -parse-as-library -I "$BIN_DIR/Modules" -I "$BIN_DIR" -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    Sources/UnifiedUpdater/AppModel.swift Tests/SetupRetryChecks/Main.swift "${CORE_OBJECTS[@]}" -o "$PROJECT_ROOT/.build/SetupRetryChecks"
# All source commands and setup tool discovery are controlled; no tools are maintained.
PACKAGE_RESOURCE_BUNDLE_PATH="$BIN_DIR" "$PROJECT_ROOT/.build/SetupRetryChecks"
