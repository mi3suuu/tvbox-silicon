#!/bin/bash
# 右栏 8 段结构与坐标核对（vs 真 One 内屏横持 AX 基准）
set -u
DUO=${DUO_UDID:-364A1BDF-E7A7-483A-9273-8384573CD250}
BUNDLE=wda.prdc.yingxia.sim
C=$(xcrun simctl get_app_container "$DUO" "$BUNDLE" data 2>/dev/null)
[ -z "$C" ] && { echo "✗ 未安装"; exit 1; }
LOG="$C/Documents/oneskin.log"

xcrun simctl terminate "$DUO" "$BUNDLE" >/dev/null 2>&1
sleep 1; rm -f "$LOG"
xcrun simctl launch "$DUO" "$BUNDLE" -qaSection home -qaPage one-preview -qaOneShape split >/dev/null 2>&1
sleep 9

echo "=== 真 One 基准（右栏 x=523，宽 428）==="
cat <<'BASELINE'
  1 标题       y=38.0   w=317.3  h=54.3
  2 副标题     y=100.3  w=316.7  h=38.0
  3 元信息     y=146.3  w=182.3  h=14.3
  4 统计       y=168.6  w=188.0  h=14.3
  5 继续播放   y=205.0  w=168.0  h=52.0
  6 标签行1    y=279.0  h=44
  7 标签行2    y=323.0  h=44
  8 说明       y=389.0  w=327.7  h=58.0
BASELINE
echo
echo "=== 我方实际 ==="
grep -E "detailColumn shape|pictureColumn" "$LOG" 2>/dev/null | tail -2
echo
echo "=== 用 AX 读真实渲染坐标 ==="
xcrun simctl io "$DUO" screenshot /tmp/dc.png >/dev/null 2>&1
python3 "$(dirname "$0")/measure_right_column.py" /tmp/dc.png 2>/dev/null || echo "（需先构建 measure_right_column.py）"
