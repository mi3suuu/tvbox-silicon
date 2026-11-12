#!/bin/bash
# 质量门禁：改完代码后必须跑这个。红了不准声明「改好了」。
#
#   tools/qa/gate.sh              # 全部（单元测试 + UITests 编译 + UI 测试）
#   tools/qa/gate.sh --fast       # 只跑单元测试（约 10 秒，改后端逻辑够用）
#   tools/qa/gate.sh --ui         # 加上模拟器 UI 测试（慢，改 UI 必跑）
#
# 设计原则（见 映匣/质量门禁总纲-20261112.md）：
#   · 状态不是证据，产出物才是 —— 每步都打印可核对的数字，不打印「通过」了事
#   · 编译通过 ≠ 完成 —— BUILD SUCCEEDED 只是第 0 关
#   · 偶发红当红处理 —— 失败即失败，不自动重试
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SIM="${GATE_SIM:-364A1BDF-E7A7-483A-9273-8384573CD250}"   # DuoTest
HINGE="${HINGE_TOOL:-$HOME/WorkBuddy/2026-10-21-13-54-46/映匣/duo-skills/iPhone-Duo-by-Examples/.agents/skills/hinge/scripts/hinge}"
FAST=0; DO_UI=0
for a in "$@"; do
  case "$a" in
    --fast) FAST=1 ;;
    --ui)   DO_UI=1 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

FAILED=0
step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✘ %s\033[0m\n' "$1"; FAILED=1; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$1"; }

# ── 门禁 1：单元测试 ────────────────────────────────────────────────
step "门禁 1/4 · 单元测试 (TVCore)"
UT_OUT=$(swift test --package-path Packages/TVCore 2>&1)
UT_LINE=$(echo "$UT_OUT" | grep -E "^(✔|✘) Test run with" | tail -1)
echo "$UT_LINE"
if echo "$UT_LINE" | grep -q "^✔"; then
  ok "单元测试全绿"
else
  echo "$UT_OUT" | grep -E "^✘ Test .* (failed|recorded)" | head -20
  fail "单元测试有失败"
fi

# ── 门禁 2：RULES 哈希（规则被改过必须重新审阅）──────────────────
step "门禁 2/4 · 规则哈希"
if [ -x tools/qa/check-rules.sh ]; then
  if tools/qa/check-rules.sh >/tmp/gate-rules.log 2>&1; then
    ok "RULES.md 哈希匹配"
  else
    cat /tmp/gate-rules.log | head -10
    fail "RULES.md 被改动过，需重新审阅"
  fi
else
  echo "（无 check-rules.sh，跳过）"
fi

# ── 门禁 3：UITests 类型检查 ────────────────────────────────────────
# 主工程没有 test target，`xcodebuild -scheme TVBox-*` 编不到 UITests/。
# 所以必须单独 type-check，否则测试代码写错了也发现不了。
step "门禁 3/4 · UITests 类型检查"
if [ "$FAST" = "1" ]; then
  echo "（--fast 跳过）"
elif [ -x Scripts/check-uitests.sh ]; then
  if Scripts/check-uitests.sh >/tmp/gate-uitest.log 2>&1; then
    ok "UITests 可编译"
  else
    tail -20 /tmp/gate-uitest.log
    fail "UITests 编译失败"
  fi
else
  echo "（无 check-uitests.sh，跳过）"
fi

# ── 门禁 4：模拟器 UI 行为测试 ──────────────────────────────────────
step "门禁 4/4 · 模拟器 UI 测试"
if [ "$DO_UI" != "1" ]; then
  echo "（未指定 --ui，跳过。改 UI 时必须加 --ui）"
else
  # 装包：模拟器上的 bundle id 由 Config/DeviceTest.xcconfig 决定，与真机 .dev 不同
  APP_ID=$( [ -f Config/DeviceTest.xcconfig ] && grep -E "^PRODUCT_BUNDLE_IDENTIFIER" Config/DeviceTest.xcconfig | awk -F= '{gsub(/ /,"",$2); print $2}' || echo "wda.prdc.yingxia.guji")
  echo "模拟器 bundle id: $APP_ID"

  if ! xcrun simctl get_app_container "$SIM" "$APP_ID" >/dev/null 2>&1; then
    echo "模拟器未安装 $APP_ID，先构建安装…"
    xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -sdk iphonesimulator \
      -configuration Debug -destination "id=$SIM" -derivedDataPath build/DD-Sim \
      CODE_SIGNING_ALLOWED=NO build >/tmp/gate-build.log 2>&1
    if [ $? -ne 0 ]; then
      tail -15 /tmp/gate-build.log; fail "模拟器构建失败"
    else
      APP=$(find build/DD-Sim/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "*.app" | head -1)
      xcrun simctl install "$SIM" "$APP" && ok "已安装到模拟器"
    fi
  fi

  # UI 测试：用仓库既有的临时工程方案，bundle id 通过环境变量注入
  if [ -x Scripts/test-duo-ui.sh ]; then
    if GATE_BUNDLE_ID="$APP_ID" Scripts/test-duo-ui.sh --simulator "$SIM" >/tmp/gate-ui.log 2>&1; then
      ok "UI 测试通过"
      grep -E "Test Case .*(passed|failed)" /tmp/gate-ui.log | tail -20
    else
      grep -E "(failed|error:)" /tmp/gate-ui.log | head -20
      fail "UI 测试有失败"
    fi
  else
    echo "（无 test-duo-ui.sh，跳过）"
  fi
fi

# ── 结论 ────────────────────────────────────────────────────────────
printf '\n'
if [ "$FAILED" = "0" ]; then
  printf '\033[32m══ 门禁通过 ══\033[0m\n'
  exit 0
else
  printf '\033[31m══ 门禁未通过 —— 不得声明完成 ══\033[0m\n'
  exit 1
fi
