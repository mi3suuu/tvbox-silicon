#!/bin/bash
# 质量门禁：改完代码后必须跑这个。红了不准声明「改好了」。
#
#   tools/qa/gate.sh              # 门禁 1/2/3（单元测试 + 规则哈希 + UITests 编译）
#   tools/qa/gate.sh --fast       # 只跑门禁 1/2（约 10 秒，改后端逻辑够用）
#   tools/qa/gate.sh --ui         # 加上门禁 4（模拟器上真跑 UITests，慢，改 UI 必跑）
#
# 设计原则（见 映匣/质量门禁总纲-20261112.md）：
#   · 状态不是证据，产出物才是 —— 每步都打印可核对的数字，不打印「通过」了事
#   · 编译通过 ≠ 完成 —— BUILD SUCCEEDED 只是第 0 关
#   · 偶发红当红处理 —— 失败即失败，不自动重试
#
# ── 门禁 3 与门禁 4 的分工（别在这两个入口之间自己挑）────────────────────
#   两个入口都要跑，它们是**前后串联**的，不是二选一：
#     门禁 3  Scripts/check-uitests.sh   只编译 UITests/，不跑。快（~30s）。
#                                      抓的是类型错误——主工程没有 test target，
#                                      `xcodebuild -scheme TVBox-*` 编不到 UITests/，
#                                      不单独 type-check 就是「改了测试代码，三平台
#                                      BUILD SUCCEEDED 也不报错」。
#     门禁 4  Scripts/test-duo-ui.sh     生成临时工程 → 编译 → 在模拟器/真机上真跑。
#                                      慢（分钟级），抓的是行为错误。
#   门禁 3 是门禁 4 的**子集前置**：门禁 4 自己也会编译同样的源码，所以门禁 3 绿了不代表
#   门禁 4 会绿；但如果门禁 4 要跑，就一定先过门禁 3 —— 分两步是为了让类型错误在 30 秒内
#   暴露，而不是等几分钟后在 UI 跑测里以奇怪的方式失败。
#   两个脚本都保留，职责不重叠，也不要再加第三个入口。
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

# ── 门禁 2.5：脚本 trap-EXIT 吞退出码自检 ─────────────────────────-
# 背景：`set -euo pipefail` + `trap 'rc=$?; rm -f "$LOCK"; exit $rc' EXIT` 这套写法
# **看起来完全正确**，但 bash 3.2 在 set -u 触发的 unbound 致命错下，进 trap 时读到的
# $? 是 0，于是 exit 0 —— 脚本明明炸了却报成功。文本匹配抓不到这种错，必须真跑一次。
#
# ⚠️ 两个已实测的坑，决定了这一关只能这么写：
#   1. 探针的「基线」那一档会**真执行**目标脚本。扫到 test-duo-ui.sh 就是完整跑一遍
#      iOS UI 测试（分钟级），扫到 build-apple-ffmpeg.sh 就是 make + xcodebuild。
#      ⇒ 所以先做静态筛选：只有 trap 里**带 exit** 的才可能吞码，也只对这些做真探测；
#        构建/下载/测速/UI 测试类一律不纳入。
#   2. 探针若扫到 gate.sh 自己，gate.sh 又调探针 ⇒ **无限递归**（本仓库实测卡死 17 分钟）。
#      ⇒ 显式排除 gate.sh 与探针自身。
#
# 判据分两段：
#   A（静态，必跑，零成本）：trap 语句里出现 exit 的脚本数 —— 目前应为 0。
#     不为 0 时，才交给探针真跑（探针会拒绝/放行，按它的结论判红绿）。
#   B（真探测）：仅在 A 发现候选时执行，且排除 gate.sh / 自身。
step "门禁 2.5 · 脚本 trap-EXIT 吞退出码自检"

# 只看真正的 trap 语句：去掉注释行，避免匹配到文档里举例的写法。
# 判据：trap '...exit...' EXIT —— 没有 exit 的 trap（如 `trap 'rm -f "$LOCK"' EXIT`）
# 不可能改变退出码，不存在吞码风险，无需真跑。
TRAP_EXIT_CANDIDATES=$(grep -rlnE "^[^#]*trap[[:space:]]+['\"][^'\"]*exit[^'\"]*['\"][[:space:]]+EXIT" \
    --include="*.sh" . 2>/dev/null \
  | grep -v "^./build/" \
  | grep -vE "^./tools/qa/(gate|trap-exit-probe)\.sh$" \
  | sort || true)

if [ -z "$TRAP_EXIT_CANDIDATES" ]; then
  ok "无脚本在 trap 里 exit（静态判据 0 命中，不存在吞退出码的写法）"
else
  echo "静态判据命中 $(printf '%s\n' "$TRAP_EXIT_CANDIDATES" | wc -l | tr -d ' ') 个候选，交给探针真跑："
  printf '  - %s\n' $TRAP_EXIT_CANDIDATES
  if [ ! -x tools/qa/trap-exit-probe.sh ]; then
    fail "有候选但缺少 tools/qa/trap-exit-probe.sh，无法验证"
  elif tools/qa/trap-exit-probe.sh $TRAP_EXIT_CANDIDATES >/tmp/gate-trapprobe.log 2>&1; then
    grep -E "✔|结果：" /tmp/gate-trapprobe.log | head -20
    ok "候选脚本在 unbound 下均正确报错"
  else
    grep -E "✘|★|结果：|不合格" /tmp/gate-trapprobe.log | head -20
    fail "有脚本在 unbound 下退出码为 0（会假绿）"
  fi
fi

# ── 门禁 3：UITests 类型检查（见文件头「门禁 3 与门禁 4 的分工」）──────────
# 主工程没有 test target，`xcodebuild -scheme TVBox-*` 编不到 UITests/。
# 所以必须单独 type-check，否则测试代码写错了也发现不了。
step "门禁 3/4 · UITests 类型检查（编译，不跑）"
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
step "门禁 4/4 · 模拟器 UI 测试（真跑）"
if [ "$DO_UI" != "1" ]; then
  echo "（未指定 --ui，跳过。改 UI 时必须加 --ui）"
else
  # 装包：模拟器上的 bundle id 由 Config/DeviceTest.xcconfig 决定，与真机 .dev 不同
  APP_ID=$( [ -f Config/DeviceTest.xcconfig ] && grep -E "^PRODUCT_BUNDLE_IDENTIFIER" Config/DeviceTest.xcconfig | awk -F= '{gsub(/ /,"",$2); print $2}' || echo "wda.prdc.yingxia.guji")
  echo "模拟器 bundle id: $APP_ID"

  # 装包：模拟器上的 bundle id 由 Config/DeviceTest.xcconfig 决定，与真机 .dev 不同
  #
  # ⚠️ 这里是 HEAD 原样保留的「已装就跳过」逻辑 —— 不是本任务的范围。
  #    另有并行会话（B 路）正在把这一段改成「无条件重建 + 重装 + 版本回读比对」，
  #    那份改动只存在于主工作树，**不属于 t1**，所以本分支刻意不带它，
  #    以免把别人未完成的半成品混进 t1 的提交里。
  if ! xcrun simctl get_app_container "$SIM" "$APP_ID" >/dev/null 2>&1; then
    # ⛔ `$APP_ID` 必须写成 `${APP_ID}`：裸写时后面紧跟的全角逗号「，」是多字节 UTF-8，
    #    bash 会把它并进变量名（APP_ID?），于是 set -u 报 unbound variable 并终止整个 gate.sh。
    #    这行在「模拟器没装 app」时才走到，所以装上 app 的机器上看不出问题 —— 哑雷。
    #    换机器/重装模拟器就会遇到。同型 bug 在 Scripts/test-duo-ui.sh 里已有三处（2026-11-13 修）。
    echo "模拟器未安装 ${APP_ID}，先构建安装…"
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

  # UI 测试：用仓库既有的临时工程方案。
  # bundle id 走 GATE_BUNDLE_ID 环境变量（test-duo-ui.sh 的优先级第 2 档），由脚本把它注进
  # 测试 bundle 的 Info.plist，UITests/QATargetBundle.swift 运行期读回 —— 所以 UITests/ 源码里
  # 没有 bundle id 字面量，模拟器与真机可以用同一份测试代码。
  if [ -x Scripts/test-duo-ui.sh ]; then
    # 产物目录单独指定，避免与人工跑 test-duo-ui.sh 抢锁（该脚本一个产物目录只允许一个跑者）。
    UI_OUT="$ROOT/build/GateUI"
    if GATE_BUNDLE_ID="$APP_ID" DUO_UI_OUT="$UI_OUT" \
        Scripts/test-duo-ui.sh --simulator "$SIM" >/tmp/gate-ui.log 2>&1; then
      ok "UI 测试跑完且全绿"
    else
      grep -E "(failed|error:)" /tmp/gate-ui.log | head -20
      fail "UI 测试有失败"
    fi

    # 用例明细 + 证据路径。无论红绿都打印：红了也要能指出是哪个用例、证据在哪。
    grep -E "Test Case .*(passed|failed)" /tmp/gate-ui.log | tail -20

    # ⛔ 不只看退出码 —— 退出码不是证据，产物才是。
    # 底下这几条是判红的**独立依据**：退出码被吞（本仓库 2026-11-13 实测过一次：
    # test-duo-ui.sh 里管道末尾的 `|| true` 把 PIPESTATUS 重置为 0，用例全红也 exit 0）、
    # 或者 runner 半路死掉留下一个空结果包，都只能靠这些产物检查兜住。
    UI_PASS=$(grep -cE "Test Case .* passed \(" /tmp/gate-ui.log 2>/dev/null || true)
    UI_FAIL=$(grep -cE "Test Case .* failed \(" /tmp/gate-ui.log 2>/dev/null || true)
    echo "用例计数：passed=${UI_PASS} failed=${UI_FAIL}"
    if [ "${UI_FAIL:-0}" -gt 0 ]; then
      fail "有 ${UI_FAIL} 个用例失败（见上面明细与 evidence 里的 test.log）"
    fi
    if [ "${UI_PASS:-0}" -eq 0 ]; then
      fail "没有任何用例通过 —— 0 passed 说明用例根本没跑起来，不能算绿"
    fi

    echo ""
    echo "── 可归档证据（评审复核用，路径均为绝对路径）──"
    # 从 test-duo-ui.sh 自己打印的「证据路径」段取，取不到就按约定路径兜底并标注来源。
    EVIDENCE=$(sed -n '/▸ 证据路径/,$p' /tmp/gate-ui.log | grep -E "^(被测 App|结果包|截图目录|完整日志) ")
    if [ -n "$EVIDENCE" ]; then
      echo "$EVIDENCE"
    else
      echo "（test-duo-ui.sh 未打印证据路径段，按约定兜底；说明脚本可能与门禁版本不一致）"
      echo "结果包  $UI_OUT/result.xcresult"
      echo "截图目录 $UI_OUT/shots"
      echo "完整日志 /tmp/gate-ui.log"
    fi
    if [ -d "$UI_OUT/result.xcresult" ]; then
      ok "结果包存在：$UI_OUT/result.xcresult"
    else
      fail "没有结果包 $UI_OUT/result.xcresult —— 没有产物就不算跑过"
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
