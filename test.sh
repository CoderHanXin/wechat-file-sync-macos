#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd -P)"
export CLANG_MODULE_CACHE_PATH="$root/build/test-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

arguments=(--disable-sandbox --disable-xctest
    --scratch-path "$root/build/swiftpm"
    --cache-path "$root/build/swiftpm-cache"
    --config-path "$root/build/swiftpm-config"
    --security-path "$root/build/swiftpm-security")

# Some standalone CLT toolchains place TestingMacros outside the default plugin directory.
compiler="$(xcrun --find swiftc)"
testing_plugin="$(dirname "$compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$testing_plugin" ]; then
    arguments+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi

cd "$root"
swift test "${arguments[@]}" "$@"
