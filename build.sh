#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd -P)"
version="${1:-0.6.1}"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([.-][A-Za-z0-9.-]+)?$ ]]; then
    echo "版本号格式不正确：$version" >&2
    exit 1
fi

numeric_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

build="$root/build"
dist="$root/dist"
release="$build/WeChatFileSync-v$version"
app="$release/WeChatFileSync.app"
mkdir -p "$build/module-cache" "$dist"
rm -rf "$release"
mkdir -p "$app/Contents/MacOS"

sources=("$root"/Sources/Core/*.swift "$root"/Sources/App/*.swift)
for arch in arm64 x86_64; do
    xcrun swiftc -O -module-cache-path "$build/module-cache" \
        -target "$arch-apple-macos13.0" "${sources[@]}" -lsqlite3 -o "$build/WeChatFileSync-$arch"
done
xcrun lipo -create "$build/WeChatFileSync-arm64" "$build/WeChatFileSync-x86_64" \
    -output "$app/Contents/MacOS/WeChatFileSync"
cp "$root/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $numeric_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $numeric_version" "$app/Contents/Info.plist"
codesign --force --sign - --entitlements "$root/entitlements.plist" "$app"
codesign --verify --strict "$app"

cp "$root/Install.command" "$root/Uninstall.command" "$root/README.md" "$root/CHANGELOG.md" "$root/LICENSE" "$release/"
cp -R "$root/docs" "$release/docs"
chmod +x "$release/Install.command" "$release/Uninstall.command"
archive="$dist/WeChatFileSync-v$version-macOS.zip"
rm -f "$archive"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$release" "$archive"
(cd "$dist" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "构建完成：$archive"
