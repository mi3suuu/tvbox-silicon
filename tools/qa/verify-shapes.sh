#!/bin/bash
# One 皮肤形态验证（三形态，按真实屏幕方向逐个跑）
#
# 关键：转屏必须用 `hinge rotate`，不是 `orient`。
#   rotate 真的改 displays[].rotation，截图尺寸会跟着变；
#   orient 只改 orientation 字段，截图不变，App 内部尺寸也不变。
#
# 用法：
#   tools/qa/verify-shapes.sh            # 全部
#   tools/qa/verify-shapes.sh split      # 单个
set -u
DUO=${DUO_UDID:-364A1BDF-E7A7-483A-9273-8384573CD250}
BUNDLE=wda.prdc.yingxia.sim
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/Scripts/hinge/scripts/hinge"
SHAPES=${1:-"column fullBleed split"}

C=$(xcrun simctl get_app_container "$DUO" "$BUNDLE" data 2>/dev/null)
[ -z "$C" ] && { echo "X App 未安装到 $DUO"; exit 1; }
LOG="$C/Documents/oneskin.log"

shot_size() {  # echo "2853x2007" 之类
  "$H" -d "$DUO" screenshot /tmp/.qa_size.png >/dev/null 2>&1
  python3 -c "from PIL import Image;w,h=Image.open('/tmp/.qa_size.png').size;print(f'{w}x{h}')"
}
want_landscape() {  # $1 = 目标 "landscape"|"portrait"
  for i in 1 2 3 4; do
    sz=$(shot_size)
    if [ "$1" = landscape ] && [ "$sz" = "2853x2007" ]; then return 0; fi
    if [ "$1" = portrait ]  && [ "$sz" = "2007x2853" ]; then return 0; fi
    "$H" -d "$DUO" rotate left >/dev/null 2>&1
    sleep 2
  done
  echo "  ! 无法切到 $1（当前 $sz）"; return 1
}

printf "%-11s %-7s %-29s %-6s %-22s %s\n" 形态 屏幕 shape land 播放器 判定
printf -- "%.0s-" {1..100}; echo
fail=0
for s in $SHAPES; do
  case $s in
    split) target=landscape ;;
    *)     target=portrait  ;;
  esac
  want_landscape "$target" || { fail=$((fail+1)); continue; }

  xcrun simctl terminate "$DUO" "$BUNDLE" >/dev/null 2>&1
  sleep 1; rm -f "$LOG"
  xcrun simctl launch "$DUO" "$BUNDLE" \
    -qaSection home -qaPage one-preview -qaOneShape "$s" >/dev/null 2>&1
  sleep 10

  line=$(grep -oE "stage size=[0-9x]+ box=[0-9x]+ shape=[^ ]+ land=[a-z]+" "$LOG" 2>/dev/null | tail -1)
  pic=$(grep -oE "pictureColumn.*win=[0-9]+x[0-9]+ at=\([0-9-]+,[0-9-]+\)" "$LOG" 2>/dev/null | tail -1)
  shape=$(echo "$line" | grep -oE "shape=[^ ]+" | cut -d= -f2)
  land=$(echo "$line" | grep -oE "land=[a-z]+" | cut -d= -f2)
  win=$(echo "$pic" | grep -oE "win=[0-9]+x[0-9]+ at=\([0-9-]+,[0-9-]+\)")
  scr=$( [ "$target" = landscape ] && echo 951x669 || echo 669x951 )

  wl=false; [ "$s" = split ] && wl=true
  ok="X"
  if echo "$shape" | grep -q "^$s/"; then [ "$land" = "$wl" ] && ok="OK"; fi
  [ "$ok" = "X" ] && fail=$((fail+1))
  printf "%-11s %-7s %-29s %-6s %-22s %s\n" "$s" "$scr" "${shape:-} " "${land:-?}" "${win:-?}" "$ok"
done

echo
[ $fail -eq 0 ] && { echo "全形态通过"; exit 0; } || { echo "X $fail 个形态不符"; exit 1; }
