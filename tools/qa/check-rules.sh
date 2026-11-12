#!/bin/bash
# 校验 RULES.md 哈希。不匹配 => 规则被改过，必须重新审阅后再动代码。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ ! -f RULES.md ]; then echo "X RULES.md 不存在"; exit 1; fi
if [ ! -f .rules.sha ]; then echo "X .rules.sha 不存在"; exit 1; fi

now="$(shasum -a 256 RULES.md | cut -d' ' -f1)"
want="$(cat .rules.sha)"

if [ "$now" = "$want" ]; then
  echo "OK RULES.md 未改动 ($now)"
  echo
  echo "--- 三条最重要的（其余读 RULES.md）---"
  echo "1. 形态判据 = __pageSize 的 w>h 一次比较。没有阈值/宽高比/滞回。"
  echo "2. 尺寸源唯一 = GeometryReader.geo.size。禁用 fixedScreenSize/keyWindow/liveGeometry.box。"
  echo "3. 自打日志不可作证据。用 AX / fixedLayer / 代码推导并交叉验证。"
  exit 0
else
  echo "X RULES.md 已改动！"
  echo "  现在: $now"
  echo "  记录: $want"
  echo "  -> 请先读 RULES.md 全文，确认改动是有意的，再更新 .rules.sha"
  exit 1
fi
