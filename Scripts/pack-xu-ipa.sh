#!/bin/bash
# 用 xu 证书（allisonx xu / Team G4XMHC9NWZ / all1023 通配描述文件）重签并打成 IPA。
#
#   scripts/pack-xu-ipa.sh                    # 用 build/DD-xu 下刚编出来的 .app
#   scripts/pack-xu-ipa.sh <app 路径>
#
# 为什么要重签：project.yml 里团队是 U4TCPT39D5、bundle 是 com.jo32.yingxia.ios，
# 而真机装的那份是 xu 团队签的 wda.prdc.yingxia.guji。跨团队覆盖安装会报
# MismatchedApplicationIdentifierEntitlement，所以统一用这套 xu 身份出包。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="iPhone Developer: allisonx xu (Q4LPR7GXL8)"
TEAM="G4XMHC9NWZ"
BUNDLE_ID="wda.prdc.yingxia.guji"
PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/86319b0c-4457-4708-b7c6-b5ae12134b2f.mobileprovision"
APP_SRC="${1:-$ROOT/build/DD-xu/Build/Products/Debug-iphoneos/TVBox-iOS.app}"
STAGE="$ROOT/build/xu-stage"
OUT_DIR="$ROOT/build/ipa"

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }

step "准备"
[[ -d "$APP_SRC" ]] || { echo "找不到 .app：$APP_SRC" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "找不到描述文件：$PROFILE" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Q4LPR7GXL8" || { echo "钥匙串里没有 xu 证书" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$OUT_DIR"
cp -R "$APP_SRC" "$STAGE/Payload/"
APP="$STAGE/Payload/$(basename "$APP_SRC")"

step "换身份"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"

ENT="$STAGE/xu.entitlements"
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM</string>
	<key>get-task-allow</key>
	<true/>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM.*</string>
	</array>
</dict>
</plist>
PLIST

step "签名内层"
# 先签所有嵌套的 Mach-O（辅助可执行、插件、dylib），由内向外，最后才是 .app 本身。
while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q "Mach-O"; then
        codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der \
            --entitlements "$ENT" "$item" >/dev/null 2>&1 \
        || codesign --force --sign "$IDENTITY" --timestamp=none "$item" >/dev/null
        echo "  签名 $(basename "$item")"
    fi
done < <(find "$APP" -type f -perm +111 -print0 | grep -zv "\.dylib$" || true)

# 嵌套的 .bundle / .framework 整包再签一遍，避免资源包里的签名残留旧团队。
while IFS= read -r -d '' nested; do
    codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der \
        --entitlements "$ENT" "$nested" >/dev/null 2>&1 || true
done < <(find "$APP" -mindepth 1 -maxdepth 2 \( -name "*.bundle" -o -name "*.framework" -o -name "*.appex" \) -print0)

step "签名主包"
codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der \
    --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3

step "打包"
STAMP=$(date +%m%d-%H%M)
IPA="$OUT_DIR/顾及-$STAMP-xu签名.ipa"
( cd "$STAGE" && zip -qry "$IPA" Payload )
echo "$IPA"
ls -lh "$IPA" | awk '{print $5, $9}'
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist"
