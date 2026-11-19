#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
source_app="$here/WeChatFileSync.app"
applications="$HOME/Applications"
target_app="$applications/WeChatFileSync.app"
identifier="io.github.coderhanxin.wechat-file-sync"
staging=""
backup=""
previous_identity=""
staged_identity=""
installation_complete=0

app_identity() {
    [ -d "$1" ] && [ ! -L "$1" ] && stat -f '%d:%i:%B' "$1"
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ "$status" -ne 0 ] && [ "$installation_complete" -eq 0 ]; then
        # Inspect actual rename results: a signal can arrive before the next shell assignment.
        if [ -n "$staged_identity" ] && [ "$(app_identity "$target_app" || true)" = "$staged_identity" ]; then
            rm -rf "$target_app"
        fi
        if [ -n "$backup" ] && [ -d "$backup/WeChatFileSync.app" ]; then
            if [ -e "$target_app" ] || [ -L "$target_app" ] || ! mv "$backup/WeChatFileSync.app" "$target_app"; then
                echo "旧应用仍保留在：$backup/WeChatFileSync.app，请手动移回。" >&2
                backup=""
            fi
        fi
        echo "安装未完成。文件、微信链接、登录设置和配置数据未清除。" >&2
    fi
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    if [ -n "$backup" ]; then rm -rf "$backup"; fi
    exit "$status"
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
    previous_identity="$(app_identity "$target_app")"
fi
mkdir -p "$applications"
staging="$(mktemp -d "$applications/.wechat-file-sync-install.XXXXXX")"
ditto "$source_app" "$staging/WeChatFileSync.app"
verify_app "$staging/WeChatFileSync.app"
staged_identity="$(app_identity "$staging/WeChatFileSync.app")"
if [ -n "$previous_identity" ]; then
    if [ "$(app_identity "$target_app" || true)" != "$previous_identity" ]; then
        echo "安装期间目标应用已变化，不覆盖。" >&2; exit 1
    fi
    verify_app "$target_app"
    "$target_app/Contents/MacOS/WeChatFileSync" --check-stopped
    backup="$(mktemp -d "$applications/.wechat-file-sync-backup.XXXXXX")"
    mv "$target_app" "$backup/WeChatFileSync.app"
elif [ -e "$target_app" ] || [ -L "$target_app" ]; then
    echo "安装期间出现新目标，不覆盖。" >&2; exit 1
fi
mv "$staging/WeChatFileSync.app" "$target_app"
if [ "$(app_identity "$target_app" || true)" != "$staged_identity" ]; then
    echo "最终安装位置不符，保留未知目标。" >&2; exit 1
fi
verify_app "$target_app"
installation_complete=1
# Installation does not configure directories or enable a login item.
echo "已安装到：${target_app}。首次打开后在设置中配置；登录启动默认关闭。"
if ! open "$target_app"; then
    echo "应用已安装，但未能打开。请在访达中手动打开它。" >&2
fi
