#!/bin/bash
# 装到 iPhone Duo（设备测试专用，桌面名「顾及」）：用 Config/DeviceTest.xcconfig 里的
# 测试 bundle id（wda.prdc.yingxia.guji，Team U4TCPT39D5），与设备上已有的
# wda.prdc.yingxia.dev（另一 Team 签的）区分开，避免 MismatchedApplicationIdentifierEntitlement。
#
#   Scripts/install-duo-test.sh                  # 构建 + 装 + 启动
#   Scripts/install-duo-test.sh --build-only     # 只出包
#   Scripts/install-duo-test.sh --device <UDID>  # 指定设备
#
# 与 install-duo.sh 的区别：那个用 all1023 描述文件（G4XMHC9NWZ）装 wda.prdc.yingxia.dev；
# 这个用 Team U4TCPT39D5 的 wildcard profile + -allowProvisioningUpdates 装「顾及」。
# 测试 id 只来自 Config/DeviceTest.xcconfig，project.yml 始终保持正式 id（com.jo32.yingxia.ios）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XC_CONFIG="$ROOT/Config/DeviceTest.xcconfig"
# 测试 id 从 xcconfig 读，避免两处写死不一致。
BUNDLE_ID=$(grep -oE "PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*[^[:space:]]+" "$XC_CONFIG" | sed -E "s/.*=[[:space:]]*//")
DEVICE=""
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) BUILD_ONLY=1; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }

step "生成工程"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null && echo "xcodegen 已刷新"

step "挑设备"
if [[ -z "$DEVICE" ]]; then
    # 只认 physical 且已连上的那台；UDID 形如 00008160-0002698C0A900036（8-16 十六进制）。
    CANDIDATES=$(xcrun devicectl list devices 2>/dev/null \
        | grep "physical" \
        | grep -Ev "unavailable" \
        | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}")
    DEVICE=$(echo "$CANDIDATES" | head -1)
fi
if [[ -z "$DEVICE" ]]; then
    echo "没有可用的真机。解锁手机、开开发者模式、连上数据线后再跑。" >&2
    if [[ $BUILD_ONLY -eq 1 ]]; then echo "（构建已完成。）" >&2; exit 0; fi
    exit 3
fi
echo "设备 $DEVICE"

step "构建"
# ⛔ 不能只传 `-xcconfig`：那个 xcconfig 会被**所有 target**（含 SPM 的 TVCore）读到，
# 而 TVCore 不参与打包、不允许指定 provisioning profile —— 直接报
# `TVCore_TVCore does not support provisioning profiles`。
# 所以签名相关的三项在这里**按 target 精确覆盖**，xcconfig 只提供团队与 bundle id 的默认值。
TEAM=$(grep -oE "DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[^[:space:]]+" "$XC_CONFIG" | sed -E "s/.*=[[:space:]]*//")
PROFILE=$(grep -oE "TEST_PROVISIONING_PROFILE[[:space:]]*=[[:space:]]*[^[:space:]]*" "$XC_CONFIG" | sed -E "s/.*=[[:space:]]*//")
STYLE=$(grep -oE "CODE_SIGN_STYLE[[:space:]]*=[[:space:]]*[^[:space:]]+" "$XC_CONFIG" | sed -E "s/.*=[[:space:]]*//")

# 先试「自动」：Xcode 有账号时它能自己开档，最省事。
# 失败（本机常见：`No Accounts`）再退回「手动 + 指定 profile」。
if xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -destination "id=$DEVICE" \
    -configuration Debug -xcconfig "$XC_CONFIG" -allowProvisioningUpdates \
    -derivedDataPath build/DD-duo -quiet build 2>/tmp/install-auto.log; then
    echo "自动签名成功"
else
    echo "自动签名不可用（$(grep -oE 'No Accounts|No profiles for[^:]*' /tmp/install-auto.log | head -1)），改用手动 profile：$PROFILE"
    [[ -z "$PROFILE" ]] && { echo "xcconfig 里没有 TEST_PROVISIONING_PROFILE，无法手动签名" >&2; exit 4; }
    xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -destination "id=$DEVICE" \
        -configuration Debug -xcconfig "$XC_CONFIG" \
        -derivedDataPath build/DD-duo -quiet build \
        DEVELOPMENT_TEAM="$TEAM" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="iPhone Developer" \
        PROVISIONING_PROFILE_SPECIFIER="$PROFILE"
fi
APP="build/DD-duo/Build/Products/Debug-iphoneos/TVBox-iOS.app"
if [[ ! -d "$APP" ]]; then
    APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/TVBox-*/Build/Products/Debug-iphoneos/TVBox-iOS.app 2>/dev/null | head -1)
fi
echo "$APP"
codesign -dv --entitlements :- "$APP" 2>&1 | grep -E "TeamIdentifier|Identifier=" || true
[[ $BUILD_ONLY -eq 1 ]] && exit 0

step "安装"
xcrun devicectl device install app --device "$DEVICE" "$APP"

step "启动"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true
