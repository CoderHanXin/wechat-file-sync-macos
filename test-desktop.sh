#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd -P)"
mkdir -p "$root/build/module-cache"
sources=("$root"/Sources/Core/*.swift)
for file in "$root"/Sources/App/*.swift; do
    [[ "$file" == */main.swift ]] || sources+=("$file")
done
xcrun swiftc -D DESKTOP_TESTING -module-cache-path "$root/build/module-cache" \
    "${sources[@]}" "$root/Tests/DesktopPreview/main.swift" -lsqlite3 -o "$root/build/desktop-preview-test"
rm -f "$root/build/settings-preview.png" "$root/build/settings-preview.pdf"
"$root/build/desktop-preview-test" "$root/build/settings-preview.png"
test -s "$root/build/settings-preview.pdf"
