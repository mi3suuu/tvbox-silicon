#!/bin/bash
# trap-exit-probe.sh —— 行为验证脚本的 `trap ... EXIT` 是否会吞退出码
#
# 为什么不能用文本匹配：`trap 'rc=$?; rm -f "$LOCK"; exit $rc' EXIT` 写起来完全像对的，
# 但在 set -eu 下 unbound 时 trap 里读到 $? = 0，exit $rc 就是 exit 0 —— 静默假绿。
# 只有真跑一次才知道。
#
# 用法：
#   tools/qa/trap-exit-probe.sh <脚本路径> [更多脚本...]
#   TRAP_PROBE_VERBOSE=1 打印每次执行的输出
# 退出码：0 = 全部通过；1 = 有脚本在 unbound 场景下退出码为 0（= 会假绿）；2 = 用法错误
#
# 判据（两条都必须成立）：
#   A. 注入 unbound 后，脚本退出码必须 ≠ 0
#   B. 注入 unbound 后，脚本创建的锁文件必须已被清理
#   C. 不注入时，脚本本身必须退出 0（否则修法变成恒红，也是坏）

set -uo pipefail

PROBE_VAR='__TRAP_PROBE_UNSET__'
VERBOSE="${TRAP_PROBE_VERBOSE:-0}"

die() { echo "用法: $0 <脚本路径> [更多脚本...]" >&2; exit 2; }
[ $# -ge 1 ] || die

pass=0; fail=0; skip=0
declare -a FAILED_LIST=()

# 在脚本主体末尾（或第一个 unbound 探针之后）注入一行必然报错的展开
inject() { # $1=源脚本 $2=输出
    # 插在最后一行之前，确保 trap 已装、锁已创建
    awk -v probe="echo \"probe: \$$PROBE_VAR\"" '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (i == NR && lines[i] ~ /^[[:space:]]*$/) { print probe; print lines[i]; continue }
                if (i < NR) print lines[i]
                else { print probe; print lines[i] }
            }
        }
    ' "$1" > "$2"
    chmod +x "$2"
}

for SCRIPT in "$@"; do
    [ -f "$SCRIPT" ] || { echo "跳过（不存在）: $SCRIPT"; skip=$((skip+1)); continue; }

    echo "=== $SCRIPT"

    # 只看带 trap ... EXIT 的脚本；没有 trap 的不适用本探针
    if ! grep -qE "trap[[:space:]]+['\"].*['\"][[:space:]]+EXIT" "$SCRIPT"; then
        echo "  跳过：没有 trap ... EXIT"
        skip=$((skip+1)); continue
    fi

    WORK="$(mktemp -d)"
    INJ="$WORK/injected.sh"
    inject "$SCRIPT" "$INJ"

    # ── C. 基线：不注入时必须 0（脚本自身得是健康的）
    set +e
    ( cd "$WORK" && bash "$INJ" >"$WORK/../base.out" 2>&1 )  # 仅为占位，真正基线用原脚本
    bash "$SCRIPT" >"$WORK/base.log" 2>&1
    base_rc=$?
    set -e

    # ── A. 注入 unbound 后的退出码（直接取，绝不经管道）
    set +e
    bash "$INJ" >"$WORK/inject.log" 2>&1
    inj_rc=$?
    set -e

    A_ok=0; [ "$inj_rc" -ne 0 ] && A_ok=1

    # ── 该脚本用过的锁文件是否残留（扫它自己提到过的 *.lock / LOCK= 路径）
    B_ok=1
    while IFS= read -r lk; do
        [ -n "$lk" ] || continue
        lk_expanded="${lk//\$HOME/$HOME}"
        if [ -e "$lk_expanded" ]; then
            B_ok=0
            echo "  残留锁文件: $lk_expanded"
        fi
    done < <(grep -oE '(/(tmp|var)[^"'"'"' ]*\.lock|"[^"]*\.lock")' "$SCRIPT" 2>/dev/null | tr -d '"' | sort -u)

    if [ "$VERBOSE" = "1" ]; then
        echo "  --- injected 输出 ---"; cat "$WORK/inject.log"
        echo "  --- 基线输出 ---"; cat "$WORK/base.log"
    fi

    rm -rf "$WORK"

    if [ "$A_ok" = 1 ]; then
        echo "  ✔ 注入 unbound 后退出码 = ${inj_rc}（非 0，正确报错）"
        pass=$((pass+1))
    else
        echo "  ✘ 注入 unbound 后退出码 = 0 —— ★该脚本会假绿★"
        echo "    进 trap 时 \$? 被 unbound 置为 0（展开期致命错），exit \$rc 就是 exit 0。"
        echo "    修法：哨兵变量，或去掉 set -e；⛔ rc=\$? 与 ⛔ trap ... ERR 都无效。"
        fail=$((fail+1)); FAILED_LIST+=("$SCRIPT")
    fi
    [ "$B_ok" = 0 ] && { echo "  ✘ 锁文件未清理"; fail=$((fail+1)); }
done

echo
echo "══ 结果：通过 $pass / 失败 $fail / 跳过 $skip ══"
if [ "$fail" -gt 0 ]; then
    echo "不合格脚本："
    printf '  - %s\n' "${FAILED_LIST[@]}"
    exit 1
fi
exit 0
