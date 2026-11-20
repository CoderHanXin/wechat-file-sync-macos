#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
pack="$fixture/package"
mocks="$fixture/mocks"
mkdir -p "$pack/WeChatFileSync.app/Contents/MacOS" "$mocks"
cp "$root/Install.command" "$root/Uninstall.command" "$pack/"
cp "$root/Info.plist" "$pack/WeChatFileSync.app/Contents/Info.plist"
cat > "$pack/WeChatFileSync.app/Contents/MacOS/WeChatFileSync" <<'MOCK'
#!/bin/bash
printf '%s\n' "$1" >> "$MOCK_HELPER_LOG"
if [ "$1" = --check-stopped ] && [ "${MOCK_RUNNING:-0}" = 1 ]; then exit 1; fi
if [ "$1" = --disable-login-item ] && [ "${MOCK_UNREGISTER_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "$1" = --disable-login-item ] && [ "${MOCK_REPLACE_ON_UNREGISTER:-0}" = 1 ]; then
    /bin/mv "$MOCK_TARGET_APP" "$MOCK_SAVED_APP"
    mkdir -p "$MOCK_TARGET_APP"
    echo foreign-untouched > "$MOCK_TARGET_APP/foreign.txt"
fi
case "$1" in --check-stopped|--disable-login-item) exit 0 ;; *) exit 99 ;; esac
MOCK
cat > "$mocks/codesign" <<'MOCK'
#!/bin/bash
if [ "${MOCK_SIGNATURE_FAIL:-0}" = 1 ]; then exit 1; fi
case "$*" in *'.wechat-file-sync-install.'*) [ "${MOCK_STAGED_SIGNATURE_FAIL:-0}" != 1 ] ;; *) exit 0 ;; esac
MOCK
cat > "$mocks/ditto" <<'MOCK'
#!/bin/bash
mkdir -p "$2"
cp -R "$1/." "$2/"
if [ "${MOCK_REPLACE_APP:-0}" = 1 ]; then
    /bin/mv "$MOCK_TARGET_APP" "$MOCK_SAVED_APP"
    mkdir -p "$MOCK_TARGET_APP"
    echo foreign-untouched > "$MOCK_TARGET_APP/foreign.txt"
fi
[ "${MOCK_COPY_FAIL:-0}" != 1 ]
MOCK
cat > "$mocks/mv" <<'MOCK'
#!/bin/bash
case "$1" in *'/.wechat-file-sync-install.'*'/WeChatFileSync.app') if [ "${MOCK_SWAP_FAIL:-0}" = 1 ]; then exit 1; fi ;; esac
case "$1" in *'/.wechat-file-sync-backup.'*'/WeChatFileSync.app') if [ "${MOCK_ROLLBACK_FAIL:-0}" = 1 ]; then exit 1; fi ;; esac
/bin/mv "$@"
case "$2" in *'/.wechat-file-sync-backup.'*'/WeChatFileSync.app')
    if [ "${MOCK_INTERRUPT_RENAME:-}" = old ]; then kill -TERM "$PPID"; fi ;;
esac
case "$1" in *'/.wechat-file-sync-install.'*'/WeChatFileSync.app')
    if [ "${MOCK_INTERRUPT_RENAME:-}" = new ]; then kill -TERM "$PPID"; fi ;;
esac
MOCK
cat > "$mocks/launchctl" <<'MOCK'
#!/bin/bash
[ "$1" = print ] && [ "${MOCK_LEGACY:-0}" = 1 ]
MOCK
cat > "$mocks/open" <<'MOCK'
#!/bin/bash
printf 'open %s\n' "$1" >> "$MOCK_HELPER_LOG"
[ "${MOCK_OPEN_FAIL:-0}" != 1 ]
MOCK
chmod +x "$pack/WeChatFileSync.app/Contents/MacOS/WeChatFileSync" "$mocks/"*
echo version-one > "$pack/WeChatFileSync.app/version.txt"

test_home="$fixture/用户 with spaces"
mkdir -p "$test_home/Library/Application Support/WeChatFileSync" "$test_home/归档" "$test_home/假微信"
echo config-preserved > "$test_home/Library/Application Support/WeChatFileSync/state.sqlite"
echo content-preserved > "$test_home/归档/file.txt"
ln -s "$test_home/归档/file.txt" "$test_home/假微信/file.txt"
helper_log="$fixture/helpers.log"

action() {
    env HOME="$test_home" PATH="$mocks:$PATH" MOCK_HELPER_LOG="$helper_log" \
        MOCK_RUNNING="${running:-0}" MOCK_UNREGISTER_FAIL="${unregister_fail:-0}" \
        MOCK_COPY_FAIL="${copy_fail:-0}" MOCK_SWAP_FAIL="${swap_fail:-0}" \
        MOCK_SIGNATURE_FAIL="${signature_fail:-0}" MOCK_STAGED_SIGNATURE_FAIL="${staged_signature_fail:-0}" \
        MOCK_LEGACY="${legacy:-0}" MOCK_OPEN_FAIL="${open_fail:-0}" MOCK_INTERRUPT_RENAME="${interrupt_rename:-}" MOCK_ROLLBACK_FAIL="${rollback_fail:-0}"         MOCK_REPLACE_APP="${replace_app:-0}" MOCK_REPLACE_ON_UNREGISTER="${replace_on_unregister:-0}" MOCK_TARGET_APP="$test_home/Applications/WeChatFileSync.app" MOCK_SAVED_APP="$fixture/saved-app" bash "$pack/$1"
}
expect_failure() {
    if action "$1"; then echo "预期失败却成功：$2" >&2; exit 1; fi
}
assert_preserved() {
    test "$(cat "$test_home/Library/Application Support/WeChatFileSync/state.sqlite")" = config-preserved
    test "$(cat "$test_home/归档/file.txt")" = content-preserved
    test -L "$test_home/假微信/file.txt"
    for leftover in "$test_home/Applications"/.wechat-file-sync-*; do test ! -e "$leftover"; done
}
app="$test_home/Applications/WeChatFileSync.app"
action Install.command
test -x "$app/Contents/MacOS/WeChatFileSync"
test -s "$helper_log" # A successful install must have reached the mocked open command.
test ! -e "$test_home/Library/LaunchAgents"
assert_preserved

# Uninstall must not traverse a redirected Applications parent.
redirected="$fixture/redirected-applications"
/bin/mv "$test_home/Applications" "$redirected"
ln -s "$redirected" "$test_home/Applications"
expect_failure Uninstall.command "Applications 父目录符号链接"
test -f "$app/version.txt"
rm "$test_home/Applications"
/bin/mv "$redirected" "$test_home/Applications"

running=1
expect_failure Install.command "运行中拒绝升级"
expect_failure Uninstall.command "运行中拒绝卸载"
running=0
assert_preserved

echo version-two > "$pack/WeChatFileSync.app/version.txt"
for scenario in copy_fail staged_signature_fail swap_fail; do
    case "$scenario" in copy_fail) copy_fail=1 ;; staged_signature_fail) staged_signature_fail=1 ;; swap_fail) swap_fail=1 ;; esac
    expect_failure Install.command "$scenario"
    test "$(cat "$app/version.txt")" = version-one
    copy_fail=0; staged_signature_fail=0; swap_fail=0
    assert_preserved
done

# A target changed during copy is preserved, never executed or overwritten.
replace_app=1
expect_failure Install.command "复制期间目标被替换"
replace_app=0
test "$(cat "$app/foreign.txt")" = foreign-untouched
test "$(cat "$fixture/saved-app/version.txt")" = version-one
rm -rf "$app"
/bin/mv "$fixture/saved-app" "$app"
assert_preserved

# Interrupt after rename completed but before the installer executes its next command.
for boundary in old new; do
    interrupt_rename="$boundary"
    expect_failure Install.command "rename 后中断：$boundary"
    interrupt_rename=""
    test "$(cat "$app/version.txt")" = version-one
    assert_preserved
done

# If rollback itself fails, the sole old application remains in its backup directory.
swap_fail=1; rollback_fail=1
expect_failure Install.command "回滚失败保留旧应用"
swap_fail=0; rollback_fail=0
test ! -e "$app"
backup_found=0
for saved in "$test_home/Applications"/.wechat-file-sync-backup.*/WeChatFileSync.app; do
    if [ -f "$saved/version.txt" ]; then
        test "$(cat "$saved/version.txt")" = version-one
        /bin/mv "$saved" "$app"
        rmdir "$(dirname "$saved")"
        backup_found=1
    fi
done
test "$backup_found" = 1
assert_preserved

action Install.command
test "$(cat "$app/version.txt")" = version-two
assert_preserved

legacy=1
expect_failure Install.command "旧服务仍运行"
legacy=0
signature_fail=1
expect_failure Install.command "源签名失败"
signature_fail=0
assert_preserved

unregister_fail=1
expect_failure Uninstall.command "注销登录项失败时不删除应用"
test -d "$app"
unregister_fail=0
replace_on_unregister=1
expect_failure Uninstall.command "注销期间应用被替换"
replace_on_unregister=0
test "$(cat "$app/foreign.txt")" = foreign-untouched
rm -rf "$app"
/bin/mv "$fixture/saved-app" "$app"
assert_preserved
action Uninstall.command
test ! -e "$app"
assert_preserved

# First install copy failure leaves no partial application.
copy_fail=1
expect_failure Install.command "首次复制失败"
copy_fail=0
test ! -e "$app"
assert_preserved

# Failure to open doesn't discard an otherwise verified installation.
open_fail=1
action Install.command
open_fail=0
test -d "$app"
assert_preserved
action Uninstall.command
assert_preserved

# A symlink target and a foreign bundle are never overwritten.
ln -s "$pack/WeChatFileSync.app" "$app"
expect_failure Install.command "安装目标符号链接"
expect_failure Uninstall.command "卸载目标符号链接"
rm "$app"
mkdir -p "$app/Contents/MacOS"
cp "$pack/WeChatFileSync.app/Contents/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier example.foreign' "$app/Contents/Info.plist"
expect_failure Install.command "其他应用身份"
expect_failure Uninstall.command "其他应用身份"
assert_preserved

while IFS= read -r helper; do
    case "$helper" in --configure|--check) echo "安装不应配置账号或访问微信" >&2; exit 1 ;; esac
done < "$helper_log"
echo "安装／升级／回滚／卸载隔离检查通过（临时 HOME、假应用、命令替身）"
