#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
source_app="$here/WeChatFileSync.app"
applications="$HOME/Applications"
target_app="$applications/WeChatFileSync.app"
identifier="io.github.coderhanxin.wechat-file-sync"
staging=""
backup=""
old_moved=0
new_installed=0

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        if [ "$new_installed" -eq 1 ]; then rm -rf "$target_app"; fi
        if [ "$old_moved" -eq 1 ]; then
            if ! mv "$backup/WeChatFileSync.app" "$target_app"; then
                echo "旧应用仍保留在：$backup/WeChatFileSync.app，请手动移回。" >&2
                backup=""
            fi
        fi
        echo "安装未完成。文件、微信链接、登录设置和配置数据未清除。" >&2
    fi
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    if [ -n "$backup" ]; then rm -rf "$backup"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_app() {
    local candidate="$1"
    local actual
    if [ ! -d "$candidate" ] || [ -L "$candidate" ]; then
        echo "应用目录不存在或是符号链接：$candidate" >&2; return 1
    fi
    actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")
    if [ "$actual" != "$identifier" ] || [ ! -x "$candidate/Contents/MacOS/WeChatFileSync" ]; then
        echo "应用身份或可执行文件不符，不覆盖。" >&2; return 1
    fi
    codesign --verify --strict "$candidate"
}

verify_app "$source_app"
for label in io.github.whaoo0.wechat-download-sync local.wechat-download-sync; do
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        echo "检测到旧版同步服务，请自行停用后再安装，避免同时处理相同微信文件。" >&2
        exit 1
    fi
done
if [ -L "$applications" ] || [ -L "$target_app" ]; then
    echo "安装目标为符号链接，请先自行处理。" >&2; exit 1
fi
if [ -e "$target_app" ]; then
    verify_app "$target_app"
    "$target_app/Contents/MacOS/WeChatFileSync" --check-stopped
fi
mkdir -p "$applications"
staging="$(mktemp -d "$applications/.wechat-file-sync-install.XXXXXX")"
ditto "$source_app" "$staging/WeChatFileSync.app"
verify_app "$staging/WeChatFileSync.app"
if [ -e "$target_app" ]; then
    "$target_app/Contents/MacOS/WeChatFileSync" --check-stopped
    backup="$(mktemp -d "$applications/.wechat-file-sync-backup.XXXXXX")"
    mv "$target_app" "$backup/WeChatFileSync.app"
    old_moved=1
fi
mv "$staging/WeChatFileSync.app" "$target_app"
new_installed=1
verify_app "$target_app"
# Installation does not configure directories or enable a login item.
echo "已安装到：$target_app。首次打开后在设置中配置；登录启动默认关闭。"
if ! open "$target_app"; then
    echo "应用已安装，但未能打开。请在访达中手动打开它。" >&2
fi
