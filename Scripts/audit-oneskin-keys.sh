#!/bin/bash
# One 皮肤 UserDefaults 键名的「单一真源 + 落盘契约」闸门。
#
# 两件事，任一不满足即 exit 1：
#   ① 唯一性：`oneSkin*` 字面量只允许出现在 TVCore.OneSkinKeys（白名单外出现即红）。
#      —— 这是「一套状态两套键」的结构性判据，比运行期 assert 强：不必把 App 跑起来。
#   ② 契约：键名字面量与下方 PINNED 逐字一致。
#      —— 键名是落盘契约，改字符串 = 所有用户已存的皮肤偏好静默回落默认值。
#         有意改键时，同时改这里与 TVCore，让 diff 里看得见「我在迁移用户的偏好」。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SRC_ALLOW="Sources/TVCore/OneSkinShared.swift"
# backdrop 模糊半径是独立域，自有单一真源（OneWatchPageModel.Backdrop.blurRadiusKey）。
SRC_ALLOW_2="Sources/TVCore/OneWatchPageModel.swift"

fail=0

# ---- ① 唯一性 ----
echo "== ① oneSkin* 字面量唯一性 =="
STRAY=$(grep -rn '"oneSkin[A-Za-z]*"' --include=*.swift App/ Sources/ 2>/dev/null \
        | grep -v "^${SRC_ALLOW}:" | grep -v "^${SRC_ALLOW_2}:")
if [ -n "$STRAY" ]; then
  echo "❌ 字面量出现在单一真源之外（应改为引用 OneSkinKeys）："
  echo "$STRAY"
  fail=1
else
  echo "✅ 无越界字面量"
fi

# ---- ② 落盘契约 ----
echo ""
echo "== ② 键名落盘契约 =="
PINNED="enabledKey=oneSkinEnabled
fitModeKey=oneSkinFitMode
speedKey=oneSkinSpeed
loopKey=oneSkinLoop
fillKey=oneSkinFill
autoFullScreenKey=oneSkinAutoFullScreen
twoColumnKey=oneSkinTwoColumn"

ACTUAL=$(sed -n '/^public enum OneSkinKeys/,/^}/p' "$SRC_ALLOW" \
         | grep -oE 'static let [A-Za-z]+ = "oneSkin[A-Za-z]*"' \
         | sed -E 's/static let ([A-Za-z]+) = "([^"]+)"/\1=\2/' | sort)

if [ "$ACTUAL" = "$(echo "$PINNED" | sort)" ]; then
  echo "✅ 7 个键名与钉住值逐字一致"
  echo "$ACTUAL" | sed 's/^/   /'
else
  echo "❌ 键名与钉住值不符（改键 = 用户偏好静默丢失，必须有意为之）："
  diff <(echo "$PINNED" | sort) <(echo "$ACTUAL") | sed 's/^/   /'
  fail=1
fi

echo ""
[ "$fail" -eq 0 ] && echo "GATE: PASS" || echo "GATE: FAIL"
exit "$fail"
