#!/bin/bash
# 用 xu 团队的证书与已有 profile 手动签名并装到真机。
#
# 为什么不走 xcodebuild 的内建签名：
#   本机 Xcode **没登录 Apple ID**（报 `No Accounts`），`-allowProvisioningUpdates`
#   开不出新档；而一旦在命令行传 `CODE_SIGN_STYLE=Manual`，
#   `project.yml` 里项目级的 `CODE_SIGN_STYLE: Automatic` 会与之冲突，
#   而且 SPM 的 TVCore target 不接受 provisioning profile（报
#   `TVCore_TVCore does not support provisioning profiles`）。
#   所以：**先出未签名包，再手工 codesign**，完全绕开 Xcode 的签名决策。
#
# 用法：Scripts/sign-and-install-xu.sh [--build-only] [--device UDID]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEAM=G4XMHC9NWZ
PROFILE_NAME=all1023
BUNDLE_ID=wda.prdc.yingxia.guji
DEVICE=""
BUILD_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --device) DEVICE="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -E "00008160" | grep -v unavailable | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}" | head -1)
fi
[[ -z "$DEVICE" ]] && { echo "找不到 Duo 真机" >&2; exit 3; }

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }

step "定位描述文件 $PROFILE_NAME"
PROFILE_PATH=""
for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
  security cms -D -i "$p" > /tmp/si.plist 2>/dev/null || continue
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :Name' /tmp/si.plist 2>/dev/null)" == "$PROFILE_NAME" ]]; then
    PROFILE_PATH="$p"; break
  fi
done
[[ -z "$PROFILE_PATH" ]] && { echo "找不到 profile $PROFILE_NAME" >&2; exit 4; }
APPID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' /tmp/si.plist)
echo "  $PROFILE_PATH"
echo "  application-identifier = $APPID"

step "生成工程"
xcodegen generate >/dev/null && echo "  xcodegen 已刷新"

step "构建（不签名）"
# ⛔ 必须用 `generic/platform=iOS`，不能写 `-destination id=<真机>`：
#    真机 destination 要求能签名（Xcode 会去校验 profile/团队），
#    与 `CODE_SIGNING_ALLOWED=NO` 直接冲突，报
#    「Supported platforms for the buildables in the current scheme is empty」
#    并且**什么产物都不出**。generic 目标只按 SDK 构建，不碰签名决策。
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS \
  -destination 'generic/platform=iOS' \
  -configuration Debug -xcconfig Config/DeviceTest.xcconfig \
  -derivedDataPath build/DD-xu \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -quiet build 2>&1 | grep -vE "^note:" | tail -5 || true

APP="build/DD-xu/Build/Products/Debug-iphoneos/TVBox-iOS.app"
[[ -d "$APP" ]] || { echo "没找到 $APP" >&2; exit 5; }

step "找一个可用的 xu 签名身份"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "allisonx xu" | head -1 | sed -E 's/.*"(.+)"/\1/')
[[ -z "$IDENTITY" ]] && { echo "找不到 xu 的签名身份" >&2; exit 6; }
echo "  $IDENTITY"

step "写 entitlements（照 profile 里的授予项）"
# ⛔ 必须用 `plutil -extract`，不能用 `PlistBuddy -c "Print :Entitlements"`：
#    后者输出的是 plist 内部的片段文本（带 `{ }` 但没有 XML 头/DTD），
#    codesign 直接报 `unrecognized blob type` / `invalid length in entitlement blob`。
security cms -D -i "$PROFILE_PATH" > /tmp/si-full.plist 2>/dev/null
plutil -extract Entitlements xml1 -o /tmp/si-ent.plist /tmp/si-full.plist

# ⛔ 通配 profile 的 application-identifier 是 `G4XMHC9NWZ.wda.prdc.*`。
#    签名权利里必须写成**实际 bundle id**，否则 codesign 会拒绝
#    （profile 的 AppID 是通配，但签名请求必须具体）。
#    不做这一步，装上去启动会直接被杀。
ACTUAL_APPID="$TEAM.$BUNDLE_ID"
/usr/libexec/PlistBuddy -c "Set :application-identifier $ACTUAL_APPID" /tmp/si-ent.plist
# keychain-access-groups 同理：通配的 `TEAM.*` 要展开成具体项。
/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" /tmp/si-ent.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" /tmp/si-ent.plist
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $ACTUAL_APPID" /tmp/si-ent.plist
echo "  application-identifier = $ACTUAL_APPID"

cp "$PROFILE_PATH" "$APP/embedded.mobileprovision"

step "签名 App 本体"
codesign --force --sign "$IDENTITY" --timestamp=none \
  --entitlements /tmp/si-ent.plist "$APP" 2>&1 | tail -3
echo "  TeamIdentifier: $(codesign -dv --entitlements :- "$APP" 2>&1 | grep -oE 'TeamIdentifier=[A-Z0-9]+' || echo '(未知)')"

step "重签内嵌 framework / dylib"
find "$APP/Frameworks" -maxdepth 2 \( -name "*.framework" -o -name "*.dylib" \) 2>/dev/null | while read -r f; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$f" >/dev/null 2>&1 || true
done
codesign --force --sign "$IDENTITY" --timestamp=none --entitlements /tmp/si-ent.plist "$APP" 2>&1 | tail -2

[[ $BUILD_ONLY -eq 1 ]] && { echo "只构建：$APP"; exit 0; }

step "安装到 $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -5

step "启动"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" 2>&1 | tail -3
