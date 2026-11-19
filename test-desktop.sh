#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd -P)"
case "${1:-}" in ""|--manual|--capture) ;; *) echo "用法：bash test-desktop.sh [--manual|--capture]" >&2; exit 1 ;; esac
mkdir -p "$root/build/module-cache"
sources=("$root"/Sources/Core/*.swift)
for file in "$root"/Sources/App/*.swift; do
    [[ "$file" == */main.swift ]] || sources+=("$file")
done
xcrun swiftc -D DESKTOP_TESTING -module-cache-path "$root/build/module-cache" \
    "${sources[@]}" "$root/Tests/DesktopPreview/main.swift" -lsqlite3 -o "$root/build/desktop-preview-test"
rm -f "$root/build/settings-preview.png" "$root/build/settings-preview.pdf"
if [ -n "${1:-}" ]; then
    "$root/build/desktop-preview-test" "$root/build/settings-preview.png" "$1"
else
    "$root/build/desktop-preview-test" "$root/build/settings-preview.png"
fi
if [ "${1:-}" != --manual ]; then test -s "$root/build/settings-preview.pdf"; fi
if [ "${1:-}" = --capture ]; then
    test -s "$root/build/settings-preview.png"
    test -s "$root/build/settings-preview.general.png"
fi
