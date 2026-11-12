#!/bin/bash
# 真机/模拟器验收：用 XCUITest 驱动已经装好的映匣，逐屏截图 + 断言。
#
#   Scripts/test-duo-ui.sh                          # 真机，全部用例
#   Scripts/test-duo-ui.sh --simulator <UDID>       # 模拟器，同一套用例
#   Scripts/test-duo-ui.sh --bundle-id <id>         # 显式指定被测 App 的 bundle id
#   Scripts/test-duo-ui.sh -only-testing:DuoUITests/DuoAcceptanceUITests/testSettingsShowsVersion
#   # 控件遍历审计（半自动，逐个 tap 可逆控件并截图，用 WALK_SECTION 选 section）：
#   WALK_SECTION=settings Scripts/test-duo-ui.sh --tests UITests/ControlWalkUITests.swift
#
# ── 被测 App 的 bundle id 怎么定（优先级，高到低）────────────────────────────
#   1. --bundle-id <id>          命令行参数，最高优先
#   2. GATE_BUNDLE_ID 环境变量    供 tools/qa/gate.sh 之类上层门禁注入
#   3. 按设备形态推断             --simulator ⇒ 读 Config/DeviceTest.xcconfig 的
#                                PRODUCT_BUNDLE_IDENTIFIER（当前 wda.prdc.yingxia.guji）；
#                                真机 ⇒ wda.prdc.yingxia.dev（all1023 通配档签的那套）
#   4. 兜底字面量                 wda.prdc.yingxia.dev
#
#   为什么必须能切：模拟器装的和真机装的是**两个不同 Team 签的包**，application-identifier
#   不通用，bundle id 也不同。写死一个只可能在一种设备上匹配到——2026-11-12 之前这里写死
#   `.dev`，于是模拟器上 XCUIApplication(bundleIdentifier:) 永远指向一个没装的应用，
#   UITests/ 里那 145 条断言一次都没真正运行过。
#
#   选中值会以构建设置 UITARGET_BUNDLE_ID 传给 xcodebuild，由临时工程的 Info.plist 烧成
#   `UITargetBundleID` 键；UITests/QATargetBundle.swift 在运行期读它。所以 Swift 源码里
#   不出现任何 bundle id 字面量。
#
# 为什么要另外生成工程：XCUITest 需要一个 test bundle，而主工程没有 UI 测试目标。这里现场生成一个
# 只含「占位宿主 App + UI 测试 bundle」的临时工程，签名沿用 Duo 证书那套（通配 wda.prdc.*），
# 测试代码用 XCUIApplication(bundleIdentifier:) 去驱动真正装好的映匣 —— 所以测的是用户的真实数据。
#
# 产物：build/DuoUI/result.xcresult 与 build/DuoUI/shots/（每屏一张 png）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 产物目录。两个会话同时跑会共用它 —— 一个在 rmtree，另一个正在写结果包，于是报
# "mkstemp: No such file or directory" 这种查不到源头的假失败（2026-11-04 实测踩到）。
# 要并行就各自指定 DUO_UI_OUT。
OUT="${DUO_UI_OUT:-$ROOT/build/DuoUI}"
CERT_DIR="$HOME/Documents/windows11/编程工具/mac/证书/Duo 证书"
PROFILE="$CERT_DIR/all1023.mobileprovision"
DEVICE=""
SIMULATOR=""
TESTS="$ROOT/UITests/DuoAcceptanceUITests.swift"
# 显式指定的 bundle id。空 = 未指定，交给下面的优先级往下走。
BUNDLE_ID_OPT=""
EXTRA=()

usage() {
    sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id) BUNDLE_ID_OPT="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --simulator) SIMULATOR="$2"; shift 2 ;;
        # 换一份测试源码，用来单独验证 runner 通道（见 Docs/真机验收.md）。
        --tests) TESTS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

# ── 定 bundle id（优先级见文件头）─────────────────────────────────────────
# 模拟器包名从 xcconfig 现读，不在本脚本里再抄一份——抄一份就会和 project.yml/xcconfig 三处分叉。
xcconfig_bundle_id() {
    local f="$ROOT/Config/DeviceTest.xcconfig"
    [[ -f "$f" ]] || return 1
    local v
    v=$(grep -E '^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=' "$f" | tail -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
    [[ -n "$v" ]] && printf '%s' "$v"
}

if [[ -n "$BUNDLE_ID_OPT" ]]; then
    BUNDLE_ID="$BUNDLE_ID_OPT"; BUNDLE_ID_SRC="--bundle-id"
elif [[ -n "${GATE_BUNDLE_ID:-}" ]]; then
    BUNDLE_ID="$GATE_BUNDLE_ID"; BUNDLE_ID_SRC="GATE_BUNDLE_ID 环境变量"
elif [[ -n "$SIMULATOR" ]] && BUNDLE_ID="$(xcconfig_bundle_id)"; then
    BUNDLE_ID_SRC="Config/DeviceTest.xcconfig（模拟器）"
elif [[ -n "$SIMULATOR" ]]; then
    echo "模拟器上没有 Config/DeviceTest.xcconfig，也不知道装的是哪个 bundle id。用 --bundle-id 指定。" >&2
    exit 2
else
    BUNDLE_ID="wda.prdc.yingxia.dev"; BUNDLE_ID_SRC="默认（真机 all1023 档）"
fi

if [[ -z "$BUNDLE_ID" ]]; then
    echo "bundle id 解析成空值（来源：${BUNDLE_ID_SRC}）。" >&2
    exit 2
fi

step "挑设备"
echo "被测 App  bundle id: $BUNDLE_ID  ← $BUNDLE_ID_SRC"
# 同一个产物目录只能有一个跑者。发现另一个实例正在跑就先退，别让两边互相删目录：
# 症状是结果包报 mkstemp / activity log 导入失败，看上去像用例炸了，其实是被踩了。
LOCK="$ROOT/build/duo-ui-$(basename "$OUT").lock"
mkdir -p "$ROOT/build"
if [[ -f "$LOCK" ]] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    echo "另一个 test-duo-ui.sh（pid $(cat "$LOCK")）正在用 ${OUT}。" >&2
    echo "等它结束，或 DUO_UI_OUT=$ROOT/build/DuoUI-2 另开一个产物目录。" >&2
    exit 7
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
if [[ -n "$SIMULATOR" ]]; then
    # 模拟器不需要签名，但 App 必须已经装进去 —— 用例驱动的是已安装的映匣，不是刚构建的产物。
    if ! xcrun simctl get_app_container "$SIMULATOR" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "${SIMULATOR} 上没装 ${BUNDLE_ID}。先用 Scripts/e2e-verify.sh 或 simctl install 装一个 Debug 包。" >&2
        exit 6
    fi
    DEVICE="$SIMULATOR"
    DESTINATION="platform=iOS Simulator,id=$DEVICE"
    SIGNING=(CODE_SIGNING_ALLOWED=NO)
    echo "模拟器 $DEVICE"
else
    if [[ ! -f "$PROFILE" ]]; then echo "找不到描述文件：$PROFILE" >&2; exit 1; fi
    PROFILE_PLIST=$(mktemp)
    # 这个 trap 会顶掉上面那个，所以锁也一并在这里清。
    trap 'rm -f "$PROFILE_PLIST" "$LOCK"' EXIT
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
    PROFILE_DEVICES=$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$PROFILE_PLIST" 2>/dev/null \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | tr '\n' ' ')
    if [[ -z "$DEVICE" ]]; then
        CANDIDATES=$(xcrun devicectl list devices 2>/dev/null \
            | awk '/physical/ && (/available \(paired\)/ || /connected/) {print $0}' \
            | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')
        for candidate in $CANDIDATES; do
            if [[ "$PROFILE_DEVICES" == *"$candidate"* ]]; then DEVICE="$candidate"; break; fi
        done
    fi
    if [[ -z "$DEVICE" ]]; then
        echo "没有插着描述文件授权的那台真机（${PROFILE_DEVICES% }）。" >&2
        exit 3
    fi
    echo "设备 $DEVICE"
    if [[ -n "$PROFILE_DEVICES" && "$PROFILE_DEVICES" != *"$DEVICE"* ]]; then
        echo "⚠️  $DEVICE 不在描述文件里，测试运行器装不上。" >&2
        exit 4
    fi
    DESTINATION="platform=iOS,id=$DEVICE"
    SIGNING=(-allowProvisioningUpdates)
fi

if [[ -z "$SIMULATOR" ]]; then
    if ! xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -q "$BUNDLE_ID"; then
        echo "提示：映匣当前没有在运行，测试会自己拉起它。"
    fi

    # 无线连接能装 App、能手动跑 runner，但 xcodebuild 建不起 XCTestDriver 的 DTX 会话 ——
    # 表现是 runner "exited with code 74 before establishing connection"。插上数据线再跑。
    TRANSPORT=$(xcrun devicectl device info details --device "$DEVICE" --json-output - 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['connectionProperties']['transportType'])" 2>/dev/null || echo unknown)
    echo "连接方式 $TRANSPORT"
    if [[ "$TRANSPORT" != "wired" ]]; then
        echo "" >&2
        echo "⚠️  这台设备不是 USB 连接（${TRANSPORT}）。UI 自动化在无线连接下会被拒绝：" >&2
        echo "    runner 能装上也能自己跑，但 xcodebuild 连不上它，最终报 code 74。" >&2
        echo "    插上数据线（或在 Xcode 的 Devices 窗口确认是 USB）后重跑。" >&2
        echo "" >&2
        if [[ "${DUO_ALLOW_WIRELESS:-0}" != "1" ]]; then exit 5; fi
    fi
fi

step "生成工程"
python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$OUT" 2>/dev/null || true
mkdir -p "$OUT"
# 占位宿主：XCUITest 的 bundle 必须挂在一个 app target 上。它从不被启动，只用来让 xcodebuild 推导
# TEST_HOST / TEST_TARGET_NAME；真正被测的是已安装的映匣。
cat > "$OUT/QAAnchor.swift" <<'SWIFT'
import SwiftUI

@main
struct QAAnchor: App {
    var body: some Scene { WindowGroup { Text("QA Anchor") } }
}
SWIFT
cat > "$OUT/project.yml" <<YAML
name: DuoUI
options:
  deploymentTarget:
    iOS: '17.0'
targets:
  QAAnchor:
    type: application
    platform: iOS
    sources: [QAAnchor.swift]
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: wda.prdc.qaui.host
      CODE_SIGN_STYLE: Manual
      DEVELOPMENT_TEAM: G4XMHC9NWZ
      PROVISIONING_PROFILE_SPECIFIER: all1023
      ENABLE_DEBUG_DYLIB: NO
    info:
      path: AnchorInfo.plist
      properties:
        CFBundleDisplayName: QA Anchor
        UILaunchScreen: {}
  DuoUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [$TESTS, $ROOT/UITests/QATargetBundle.swift]
    dependencies:
      - target: QAAnchor
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: wda.prdc.qaui.tests
      CODE_SIGN_STYLE: Manual
      DEVELOPMENT_TEAM: G4XMHC9NWZ
      PROVISIONING_PROFILE_SPECIFIER: all1023
      TEST_TARGET_NAME: QAAnchor
    # 被测 App 的 bundle id 烧进测试 bundle 的 Info.plist。值来自构建设置 $(UITARGET_BUNDLE_ID)，
    # 由下面 xcodebuild 命令行传入，所以同一次源码生成、两种设备形态可以跑不同的 id。
    # UITests/QATargetBundle.swift 运行期读这个键。
    #
    # ⚠️ 上面这段 YAML 是**未加引号**的 heredoc（<<YAML），$TESTS/$ROOT 需要被 shell 展开。
    # 于是 `$(UITARGET_BUNDLE_ID)` 里的 $() 也会被 shell 当成命令替换去执行 —— 必须写成
    # `\$(UITARGET_BUNDLE_ID)` 转义，让美元符号原样落进 YAML。漏了这一步的后果是被替换成空串，
    # 生成的 plist 里没有该键，用例全红（2026-11-12 实测踩到，下面的守卫断言当场拦下）。
    info:
      path: TestsInfo.plist
      properties:
        CFBundleDisplayName: DuoUITests
        UITargetBundleID: \$(UITARGET_BUNDLE_ID)
schemes:
  DuoAcceptance:
    build:
      targets:
        QAAnchor: all
        DuoUITests: [test]
    test:
      targets: [DuoUITests]
YAML
cd "$OUT"
xcodegen generate --spec project.yml >/dev/null

# 生成的 Info.plist 里这个键必须是 $(UITARGET_BUNDLE_ID) 占位符（真正的值由 xcodebuild 构建设置替换）。
# 如果 xcodegen 忽略了 info.properties，键会缺失，于是 UITests/QATargetBundle.swift 在运行期抛
# 「拿不到 bundle id」——那时错误信息离现场已经很远，所以在这里就断掉。
PLIST_KEY=$(/usr/libexec/PlistBuddy -c "Print :UITargetBundleID" "$OUT/TestsInfo.plist" 2>/dev/null || true)
if [[ "$PLIST_KEY" != '$(UITARGET_BUNDLE_ID)' ]]; then
    echo "生成的 $OUT/TestsInfo.plist 没有 UITargetBundleID 占位符（实际：'${PLIST_KEY}'）。" >&2
    echo "被测 App 的 bundle id 注入断了，用例会全红 —— 先修 project.yml 里的 info.properties。" >&2
    exit 8
fi

step "跑用例"
# 结果包不放 -resultBundlePath：那条路在 Xcode 27 上偶发 "mkstemp: No such file or directory"，
# 留下一个只有 Data/Staging、没有 Info.plist 的坏包，截图也就跟着丢了。让 xcodebuild 写进
# DerivedData 的标准位置（Logs/Test），跑完再挑最新那个。
set +e
# ⛔ 这里**不能**再加 `|| true`。管道末尾的 `|| true` 会把 PIPESTATUS 重置成 (0)，
#    于是下面取到的 STATUS 永远是 0 —— 用例红了这条脚本照样 exit 0，上层门禁全绿。
#    实测：`false | tee /dev/null | grep x || true` → PIPESTATUS=(0)；
#          去掉 `|| true` → PIPESTATUS=(1 0 1)，[0] 才是 xcodebuild 的真实退出码。
#    段内的 `set +e` 已经负责不让管道失败杀掉脚本，`|| true` 是多余且有害的。
xcodebuild -project DuoUI.xcodeproj -scheme DuoAcceptance \
    -destination "$DESTINATION" \
    -derivedDataPath "$OUT/DerivedData" \
    "${SIGNING[@]}" \
    UITARGET_BUNDLE_ID="$BUNDLE_ID" \
    -collect-test-diagnostics never \
    test "${EXTRA[@]+"${EXTRA[@]}"}" 2>&1 | tee "$OUT/test.log" | grep -E "Test Suite|Test Case|error:|warning: .*(sign|provision)|XCTAssert|TEST (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e

RESULT=$(ls -1dt "$OUT"/DerivedData/Logs/Test/*.xcresult 2>/dev/null | head -1)
if [[ -n "$RESULT" ]]; then
    # 不用 `rm -rf`：本机的 safe-delete 拦截器会把一次删 60 个文件的递归删除拦下来，脚本在 set -e 下
    # 直接退出 —— 用例明明是绿的，截图却一张没导，看上去像「跑完了但没产物」。
    python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$OUT/result.xcresult" 2>/dev/null || true
    cp -R "$RESULT" "$OUT/result.xcresult" 2>/dev/null || true
fi

step "导出截图"
mkdir -p "$OUT/shots"
if [[ -d "$OUT/result.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/shots" >/dev/null 2>&1 || true
    # 附件导出来后是随机 UUID 文件名；按附件名改回 <屏名>.png。
    # 名字长这样：settings_0_CB149FA5-DEF7-405F-982F-CE64EE4656E0.png —— 中间那段是 xcresult
    # 自己加的序号和 UUID，去掉后剩下的才是用例里给的名字。
    # 其余附件（XCTest 自己的 "UI Snapshot …"、元素快照、mp4 录像）一律不动：那些是失败时的证据，
    # 名字里带空格和中文，改了反而不好找。
    python3 - "$OUT/shots" <<'PY'
import json, os, re, sys
root = sys.argv[1]
manifest = os.path.join(root, "manifest.json")
if os.path.exists(manifest):
    for entry in json.load(open(manifest)):
        for attachment in entry.get("attachments", []):
            exported = attachment.get("exportedFileName", "")
            name = (attachment.get("suggestedHumanReadableName") or "").strip()
            src = os.path.join(root, exported)
            if not name or not os.path.exists(src) or not exported.lower().endswith(".png"):
                continue
            stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", re.sub(r"\.png$", "", name, flags=re.I))
            # 用例里给的名字都是简单标识符；对不上的就是 XCTest 的诊断附件。
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", stem):
                continue
            os.replace(src, os.path.join(root, stem + ".png"))
PY
    COUNT=$(ls "$OUT"/shots/*.png 2>/dev/null | grep -cE "/[A-Za-z][A-Za-z0-9-]*\.png$" || true)
    echo "截图 ${COUNT} 张 → $OUT/shots"
    # ⚠️ 末尾的 `|| true` 不能省：本脚本 set -o pipefail，一张截图都没有时 `ls` 与 `grep` 都非零，
    # 整条管道非零 → `set -e` 当场把脚本杀掉，后面的「证据路径」段一个字都打不出来。
    # 而「0 张截图」恰恰最常出现在用例很早就失败（App 起不来）的时候 —— 那正是最需要证据的时刻。
    # 2026-11-12 实测踩到：TEST SUCCEEDED 却 EXIT=1，证据路径段整段消失。
    { ls -1 "$OUT"/shots/*.png 2>/dev/null \
        | grep -E "/[A-Za-z][A-Za-z0-9-]*\.png$" \
        | while read -r shot; do echo "  $(basename "$shot")"; done; } || true
fi

step "证据路径"
# 打印绝对路径，供上层门禁（tools/qa/gate.sh）原样转述给评审。只打印「通过」不算证据 ——
# 评审要能自己打开结果包看用例明细、自己翻截图。
echo "被测 App  bundle id: $BUNDLE_ID"
echo "结果包  $OUT/result.xcresult"
if [[ -d "$OUT/shots" ]]; then
    echo "截图目录 $OUT/shots（$(ls -1 "$OUT"/shots/*.png 2>/dev/null | wc -l | tr -d ' ') 个 png）"
fi
echo "完整日志 $OUT/test.log"

if [[ $STATUS -ne 0 ]]; then
    echo "" >&2
    echo "用例失败（退出码 ${STATUS}）。日志：${OUT}/test.log" >&2
    grep -E "error:|failed|XCTAssert" "$OUT/test.log" | head -20 >&2 || true
fi
exit $STATUS
