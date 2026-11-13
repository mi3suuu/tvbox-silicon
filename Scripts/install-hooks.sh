#!/bin/bash
# 把入库的钩子安装到 <common-dir>/hooks/（**不使用 core.hooksPath**）。
#
# 覆盖范围：本仓库全部 worktree 共享同一个 common-dir（已实测 21 棵），
#           因此装一次即全部生效；新建 clone 需各跑一次。
#
# 为什么不用 core.hooksPath（实测 git 2.54.0，本轮实际踩过）：
#   core.hooksPath 是每仓库配置。它指向的目录**不存在**时，git **不回落**
#   <common-dir>/hooks，而是认为「无钩子」并**完全静默**。三组对照：
#     未设 hooksPath         → common 钩子运行 ✅
#     设 hooksPath=缺失目录  → common 钩子**静默不运行**（新旧两道门一起失效）
#     设 hooksPath=存在目录  → 新钩子运行
#   入库目录尚未检出的树上切换 hooksPath，会让它们同时失去两道门且无提示。
#   复制到 common hooks 不依赖任何路径存在性，陷阱在结构上不存在。
#
# ⚠️ 本脚本只做「安装」，不负责校验闸门是否真的在跑 —— 那道校验在钩子体内
#    （Scripts/hooks/pre-commit 的⓿门闩段），因为只有钩子真的运行时它才能生效。
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

SRC="Scripts/hooks/pre-commit"
COMMON="$(git rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$ROOT/$COMMON" ;; esac
DST="$COMMON/hooks/pre-commit"

# ① 源必须存在且可执行
if [ ! -x "$SRC" ]; then
  echo "❌ 拒绝安装：$SRC 不存在或不可执行。" >&2
  exit 1
fi

# ② 若 core.hooksPath 已被设过，先撤销 —— 否则装到 common 也不会被 git 采用
OLD="$(git config --get core.hooksPath || true)"
if [ -n "$OLD" ]; then
  echo "⚠️  检测到 core.hooksPath = $OLD"
  echo "    该配置会覆盖 common hooks 安装位置，正在撤销…"
  git config --unset core.hooksPath
  echo "    已撤销（core.hooksPath 现为空）"
fi

# ③ 若要覆盖一个**内容不同**的现有钩子，先备份并明示
if [ -f "$DST" ] && ! cmp -s "$SRC" "$DST"; then
  BAK="$DST.bak.$(date +%Y%m%d%H%M%S)"
  cp "$DST" "$BAK"
  echo "ℹ️  已备份原钩子 → $BAK"
fi

mkdir -p "$COMMON/hooks"
cp "$SRC" "$DST"
chmod +x "$DST"

# ④ 回读校验（不以「cp 没报错」当成功）
if ! cmp -s "$SRC" "$DST"; then
  echo "❌ 安装后内容比对不一致" >&2
  exit 1
fi

echo "✅ 已安装到 $DST"
echo "   sha256 $(shasum -a 256 "$DST" | cut -d' ' -f1 | cut -c1-16)…"
echo ""
echo "覆盖范围：本仓库所有 worktree 共享此 common-dir（装一次全生效）。"
echo "验证：在任意 worktree 提交一次，输出应出现"
echo "      「== lint-agent-diff · base=HEAD ==」与「== ① oneSkin* 字面量唯一性 ==」。"
