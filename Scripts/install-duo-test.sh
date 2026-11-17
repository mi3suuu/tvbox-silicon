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
# ⛔ 命令行**不能**带 `-xcconfig`，也不能带 `PROVISIONING_PROFILE_SPECIFIER=`：
#    这两种写法对所有 target 生效，包括 SPM 的 TVCore_TVCore —— 包 target 不接受描述文件，
#    直接 `TVCore_TVCore does not support provisioning profiles` → BUILD FAILED。
#    签名与 bundle id 已经由 project.yml 的 target 级 `configFiles: Debug: Config/DeviceTest.xcconfig`
#    注入，只作用于 TVBox-iOS，这里什么都不用补。
if xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -destination "id=$DEVICE" \
    -configuration Debug -derivedDataPath build/DD-duo -allowProvisioningUpdates -quiet build \
    2>/tmp/install-duo.log; then
    echo "构建成功"
else
    echo "构建失败，日志尾部：" >&2
    tail -25 /tmp/install-duo.log >&2
    exit 4
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
