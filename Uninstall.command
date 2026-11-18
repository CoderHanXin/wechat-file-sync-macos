#!/bin/bash
set -euo pipefail

app="$HOME/Applications/WeChatFileSync.app"
identifier="io.github.coderhanxin.wechat-file-sync"
if [ ! -e "$app" ]; then
    echo "未找到已安装应用。归档、微信链接和配置数据均未修改。"
    exit 0
fi
if [ -L "$app" ] || [ ! -d "$app" ]; then
    echo "应用路径不是普通目录，请自行处理。" >&2; exit 1
fi
actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
if [ "$actual" != "$identifier" ]; then echo "应用标识不同，不执行卸载。" >&2; exit 1; fi
codesign --verify --strict "$app"
executable="$app/Contents/MacOS/WeChatFileSync"
"$executable" --check-stopped
"$executable" --disable-login-item
rm -rf "$app"
echo "已注销登录启动并卸载应用。归档文件、微信链接和配置数据保留。"
