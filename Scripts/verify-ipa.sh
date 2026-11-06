#!/bin/bash
# IPA / .app 静态验证：不装就能查的 7 条判据（见 Docs/IPA验证与测试规划-2026-11-04.md 第一节）。
#
#   Scripts/verify-ipa.sh <path-to-.app-or-.ipa> [期望的 TeamIdentifier]
#
# 输入可以是 .app 目录，也可以是 .ipa（自动解开 Payload/）。任何一条不过即退出非零。
# 判据与文档一致：签名自洽 / 团队与 app id / 目标平台 / 时效 / 体积 / 注入检测 / UUID↔dSYM。
set -euo pipefail

APP_PATH="$1"
TEAM_HINT="${2:-}"
FAIL=0

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=1; }

if [[ -z "$APP_PATH" ]]; then
    echo "用法：$0 <app|ipa> [TeamIdentifier]" >&2
    exit 2
fi

# .ipa → 解出 Payload/*.app
if [[ "$APP_PATH" == *.ipa ]]; then
    step "解开 ipa"
    UNPACK_DIR=$(mktemp -d)
    trap 'rm -rf "$UNPACK_DIR"' EXIT
    unzip -q "$APP_PATH" -d "$UNPACK_DIR"
    APP=$(find "$UNPACK_DIR" -maxdepth 2 -type d -name "*.app" | head -1)
    [[ -n "$APP" ]] || { echo "ipa 里没找到 .app" >&2; exit 1; }
else
    APP="$APP_PATH"
fi

BIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"

step "1. 签名自洽"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    ok "codesign --verify 通过"
else
    bad "签名校验失败（被改过或未签）"
fi

step "2. 团队 / bundle id / 调试权限"
ENT=$(mktemp); trap 'rm -f "$ENT"' EXIT
if codesign -d --entitlements "$ENT" "$APP" 2>/dev/null; then
    TEAM=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$ENT" 2>/dev/null || echo "?")
    GTA=$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$ENT" 2>/dev/null || echo "false")
else
    TEAM="（未签名）"; GTA="false"
fi
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
printf '  TeamIdentifier=%s  BundleId=%s  get-task-allow=%s\n' "$TEAM" "$BID" "$GTA"
if [[ "$TEAM" == "（未签名）" ]]; then
    bad "包未签名（模拟器包或未签产物）"
elif [[ -n "$TEAM_HINT" && "$TEAM" != "$TEAM_HINT" ]]; then
    bad "TeamIdentifier($TEAM) 与期望($TEAM_HINT) 不符"
else
    ok "团队标识${TEAM_HINT:+ 匹配期望}"
fi
[[ "$GTA" != "true" ]] || bad "带 get-task-allow=true（调试权限），不应是发版包"

step "3. 描述文件：时效 / 设备白名单 / app id"
PP="$APP/embedded.mobileprovision"
if [[ -f "$PP" ]]; then
    PP_PLIST=$(mktemp); trap 'rm -f "$PP_PLIST"' EXIT
    security cms -D -i "$PP" > "$PP_PLIST"
    EXP=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PP_PLIST" 2>/dev/null || echo "?")
    APPID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PP_PLIST" 2>/dev/null || echo "?")
    printf '  过期=%s  app-id=%s\n' "$EXP" "$APPID"
    NOW=$(date +%s); EXPS=$(date -j -f "%a %b %d %T %Z %Y" "$EXP" +%s 2>/dev/null || echo 0)
    [[ "$EXPS" -gt "$NOW" ]] && ok "描述文件在有效期内" || bad "描述文件已过期"
else
    echo "  无 embedded.mobileprovision（模拟器包或未内嵌）"
fi

step "4. 目标平台"
PLATFORMS=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms' "$APP/Info.plist" 2>/dev/null || echo "")
printf '  CFBundleSupportedPlatforms=%s\n' "$PLATFORMS"
echo "$PLATFORMS" | grep -q "iPhoneOS" && ok "真机包" || bad "不含 iPhoneOS（模拟器包改后缀装不上）"

step "5. 注入检测（外部动态库）"
if [[ -f "$BIN" ]]; then
    EXTERNAL=$(otool -L "$BIN" | grep -vE "^\s*(/usr/lib|/System|@rpath|$BIN)" | grep -v ":" | sed 's/^\s*//' | head)
    if [[ -z "$EXTERNAL" ]]; then ok "无外部 dylib（仅系统库与 @rpath）"; else echo "$EXTERNAL"; bad "检测到外部动态库"; fi
else
    bad "找不到可执行文件 $BIN"
fi

step "6. 可执行文件 UUID ↔ dSYM UUID"
if [[ -f "$BIN" ]]; then
    BIN_UUID=$(dwarfdump -u "$BIN" 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
    DSYM="$APP.dSYM"
    if [[ -d "$DSYM" ]]; then
        DSYM_UUID=$(dwarfdump -u "$DSYM" 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
        [[ -n "$BIN_UUID" && "$BIN_UUID" == "$DSYM_UUID" ]] && ok "UUID 一致（$BIN_UUID）" || bad "UUID 不一致：bin=$BIN_UUID dSYM=$DSYM_UUID"
    else
        echo "  无 dSYM（$APP.dSYM 不存在），跳过比对"
    fi
fi

step "7. 体积（供发版对比，不判失败）"
du -sh "$APP" | awk '{print "  " $0}'

echo ""
if [[ "$FAIL" -ne 0 ]]; then
    echo "❌ 验证未通过，见上方 ✗ 项" >&2
    exit 1
fi
echo "✅ 静态验证全部通过"
