#!/bin/bash
# 启用本仓库入库的 git 钩子（A 方案：core.hooksPath → Scripts/hooks）。
#
# 为什么需要这个脚本而不是「手动 git config」：
#   见 Scripts/hooks/pre-commit 头部说明 —— 钩子以前只装在 <common-dir>/hooks，
#   只存在某台机器，clone/新建 worktree 后不存在且无告警。
#
# ⚠️ 顺序铁律（实测 git 2.54.0）：
#   core.hooksPath 指向**不存在的目录**时，git **不回落** <common-dir>/hooks，
#   而是认为「无钩子」并**完全静默**。所以必须先确认 Scripts/hooks/pre-commit
#   存在（本脚本已内置该校验），再设 core.hooksPath；否则会静默禁掉现有闸门。
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

HP="Scripts/hooks"

# ① 前置校验：目标钩子必须存在且可执行，否则拒绝设置（防静默禁门）
if [ ! -x "$HP/pre-commit" ]; then
  echo "❌ 拒绝设置：$HP/pre-commit 不存在或不可执行。" >&2
  echo "   若此时设置 core.hooksPath，git 会静默认为无钩子，" >&2
  echo "   连现有的断言闸门也会一并失效（已实测）。" >&2
  exit 1
fi

# ② 记录切换前状态，便于回退
OLD="$(git config --get core.hooksPath || true)"
if [ -n "$OLD" ] && [ "$OLD" != "$HP" ]; then
  echo "ℹ️  原 core.hooksPath = $OLD（将被替换为 $HP）"
fi

git config core.hooksPath "$HP"

# ③ 设完立刻回读校验（不靠「设置命令没报错」当成功）
GOT="$(git config --get core.hooksPath || true)"
if [ "$GOT" != "$HP" ]; then
  echo "❌ 设置后回读不符：期望 $HP，实得 '${GOT}'" >&2
  exit 1
fi

echo "✅ core.hooksPath = $GOT"
echo "   生效钩子："
for h in "$HP"/pre-* "$HP"/post-* "$HP"/commit-msg; do
  [ -x "$h" ] && echo "     ${h#"$HP"/}"
done
echo ""
echo "说明：core.hooksPath 是**每仓库**配置（非每 worktree），"
echo "      因此本仓库所有 worktree 立即生效，无需逐个安装。"
echo "      新建 clone 需各跑一次本脚本。"
