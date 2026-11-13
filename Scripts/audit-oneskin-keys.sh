#!/bin/bash
# One 皮肤 UserDefaults 键名的「单一真源 + 落盘契约」闸门。
#
# 两道检查，任一不满足即 exit 1：
#   ① 唯一性：`oneSkin*` 字面量只允许出现在 TVCore.OneSkinKeys（白名单外出现即红）。
#      —— 「一套状态两套键」的结构性判据，比运行期 assert 强：不必把 App 跑起来。
#   ② 契约：键名字面量与下方 PINNED 逐字一致。
#      —— 键名是落盘契约，改字符串 = 所有用户已存的皮肤偏好静默回落默认值。
#         有意改键时，同时改这里与 TVCore，让 diff 里看得见「我在迁移用户的偏好」。
#
# 用法：
#   ./Scripts/audit-oneskin-keys.sh              正常检查（pre-commit 调用）
#   ./Scripts/audit-oneskin-keys.sh --selftest   自检：在临时 fixture 里造已知违规，
#                                                要求自己必须抓到。抓不到即 exit 1。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SRC_ALLOW="Sources/TVCore/OneSkinShared.swift"
# backdrop 模糊半径是独立域，自有单一真源（OneWatchPageModel.Backdrop.blurRadiusKey）。
SRC_ALLOW_2="Sources/TVCore/OneWatchPageModel.swift"

PINNED="enabledKey=oneSkinEnabled
fitModeKey=oneSkinFitMode
speedKey=oneSkinSpeed
loopKey=oneSkinLoop
fillKey=oneSkinFill
autoFullScreenKey=oneSkinAutoFullScreen
twoColumnKey=oneSkinTwoColumn"

# ---- ① 唯一性 ----
check_unique() {
  local fail=0
  echo "== ① oneSkin* 字面量唯一性 =="
  local stray
  stray=$(grep -rn '"oneSkin[A-Za-z]*"' --include=*.swift App/ Sources/ 2>/dev/null \
          | grep -v "^${SRC_ALLOW}:" | grep -v "^${SRC_ALLOW_2}:")
  if [ -n "$stray" ]; then
    echo "❌ 字面量出现在单一真源之外（应改为引用 OneSkinKeys）："
    echo "$stray"
    fail=1
  else
    echo "✅ 无越界字面量"
  fi
  return "$fail"
}

# ---- ② 落盘契约 ----
check_pinned() {
  local fail=0
  echo ""
  echo "== ② 键名落盘契约 =="
  local actual
  actual=$(sed -n '/^public enum OneSkinKeys/,/^}/p' "$SRC_ALLOW" \
           | grep -oE 'static let [A-Za-z]+ = "oneSkin[A-Za-z]*"' \
           | sed -E 's/static let ([A-Za-z]+) = "([^"]+)"/\1=\2/' | sort)
  if [ "$actual" = "$(echo "$PINNED" | sort)" ]; then
    echo "✅ 7 个键名与钉住值逐字一致"
    echo "$actual" | sed 's/^/   /'
  else
    echo "❌ 键名与钉住值不符（改键 = 用户偏好静默丢失，必须有意为之）："
    diff <(echo "$PINNED" | sort) <(echo "$actual") | sed 's/^/   /'
    fail=1
  fi
  return "$fail"
}

# ---- 自检：证明「这道门真的能跑、真的能抓」 ----
# 背景（2026-11-13，本项目第三层同源缺陷）：
#   门闩最初用「grep 自己文件里有没有 'audit-oneskin-keys.sh' 这个字符串」判断
#   「这道门在不在」，而那个字符串就写在它自己上方的 marker 声明里 ⇒ 恒真。
#   实测：把两道检查的实体整段删掉、只留 marker 声明行，门闩仍判「功能完整」，
#   提交照常落地。**校验的对象与校验的依据是同一份东西。**
#
#   所以判据必须**跑一次真的**：在临时 fixture 里造一个已知违规，要求抓到它。
#   抓不到 = 脚本已死 / 被裁剪 / 逻辑坏掉，门闩据此变红。
#   fixture 里写入随机 nonce，要求输出中出现该串 —— 这样「通过」不可能来自
#   缓存、巧合或历史输出。
# M1：selftest 的**成功**行必须携带本次运行的不可伪造证据。
#   非阻塞参数：调用方（pre-commit 门闩）通过环境变量传入 nonce。
#   做法与 FAIL 分支对称：FAIL 分支已要求「输出里必须出现本次 nonce」，
#   成功分支同样要求。伪造者不知道本次 nonce ⇒ 造不出合法的 OK 行。
selftest() {
  local tmp rc=0
  tmp="$(mktemp -d)" || { echo "SELFTEST: FAIL (mktemp)"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # ⚠️ nonce 必须**纯字母**：检查正则 "oneSkin[A-Za-z]*" 不含数字，带数字的
  #    nonce 会让 fixture 自身不匹配该正则，导致自检假红。实测踩过。
  #
  # M1：优先采用调用方传入的 nonce（$ONESKIN_SELFTEST_NONCE）。
  #   门闩自己生成 nonce 并校验 OK 行回显它 ⇒ 被测方无法预置答案。
  #   直接手工运行时退回自生成，保持脚本可独立使用。
  local nonce="${ONESKIN_SELFTEST_NONCE:-}"
  if [ -z "$nonce" ]; then
    nonce="st$(printf '%s' "$$" | tr -d '0-9')$(printf '%s' "$RANDOM" | tr '0-9' 'abcdefghij')"
  fi
  mkdir -p "$tmp/App" "$tmp/Scripts" "$tmp/Sources/TVCore"
  local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cp "$self" "$tmp/Scripts/audit-oneskin-keys.sh"
  chmod +x "$tmp/Scripts/audit-oneskin-keys.sh"

  # 键名与 PINNED 对齐，让②通过，专测①
  printf 'public enum OneSkinKeys {\n' > "$tmp/Sources/TVCore/OneSkinShared.swift"
  printf '%s\n' "$PINNED" | while IFS='=' read -r k v; do
    printf '    public static let %s = "%s"\n' "$k" "$v"
  done >> "$tmp/Sources/TVCore/OneSkinShared.swift"
  printf '}\n' >> "$tmp/Sources/TVCore/OneSkinShared.swift"
  printf 'public enum OneWatchPageModel {}\n' > "$tmp/Sources/TVCore/OneWatchPageModel.swift"

  # 单一真源之外放一个带 nonce 的字面量 —— ①必须抓到
  printf 'enum Stray { static let k = "oneSkin%s" }\n' "$nonce" > "$tmp/App/Stray.swift"

  local out
  out="$(cd "$tmp" && ./Scripts/audit-oneskin-keys.sh 2>&1)"

  if ! printf '%s' "$out" | grep -q '❌ 字面量出现在单一真源之外'; then
    echo "SELFTEST: FAIL —— ① 唯一性检查没抓到已知违规"
    printf '%s\n' "$out" | head -8
    rc=1
  fi
  if ! printf '%s' "$out" | grep -q -- "$nonce"; then
    echo "SELFTEST: FAIL —— ① 输出里没有 nonce($nonce)，无法证明是本次运行抓到的"
    rc=1
  fi

  [ "$rc" -eq 0 ] && echo "SELFTEST: OK nonce=$nonce"
  return "$rc"
}

# ── 派发 ──
if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

fail=0
check_unique || fail=1
check_pinned || fail=1
echo ""
[ "$fail" -eq 0 ] && echo "GATE: PASS" || echo "GATE: FAIL"
exit "$fail"
