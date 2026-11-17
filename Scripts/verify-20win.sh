#!/bin/bash
# 20 个小窗的验收：把真机日志捞回来，只看**这几行**，别让人去翻几千行 jsonl。
#
#   Scripts/verify-20win.sh                       # 用连着的 iPhone Duo
#   Scripts/verify-20win.sh --device <UDID>
#   Scripts/verify-20win.sh --dir <已导出的目录>    # 不连设备，直接看本地导出的日志
#
# 它检查的五件事（对应 `映匣/20小窗-解码与增强-20261117.md`）：
#   ① 解码预算生效：`dock decoding now 8`（不是 20）
#   ② 增强让路：坞里 ≥3 路解码时出现 `pipeline released (...)`
#   ③ 赛跑只跑一次：同一 host 的 `racing` 只应出现一条窗的量级
#   ④ 每窗出口：`media direct|proxy` 的行数与窗口数相当
#   ⑤ 上游复用：`upstream reused` 有出现（HLS 分片不再每片握手）
#
# 只读，不改设备上的任何东西。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE=""
DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

BUNDLE_ID=$(grep -oE "PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*[^[:space:]]+" \
    "$ROOT/Config/DeviceTest.xcconfig" | sed -E "s/.*=[[:space:]]*//")

if [[ -z "$DIR" ]]; then
    if [[ -z "$DEVICE" ]]; then
        DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {print $3; exit}' | tr -d '()')
    fi
    [[ -n "$DEVICE" ]] || { echo "没有连着的真机（用 --device 指定，或用 --dir 看已导出的日志）" >&2; exit 1; }
    DIR=$(mktemp -d /tmp/tvbox-logs.XXXXXX)
    echo "▸ 从 $DEVICE 导出诊断日志（Application Support/com.tvbox.yingxia/Logs）"
    # ⛔ 不要整目录拷：Caches 里有 URLSession 的 fsCachedData，拷到一半文件就没了，
    #    devicectl 会整单失败（实测 error 7000 / NSCocoaErrorDomain 260）。
    #    按名字逐个拿日志，缺哪个跳过。
    got=0
    for index in $(seq 0 9); do
        if xcrun devicectl device copy from --device "$DEVICE" \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "Library/Application Support/com.tvbox.yingxia/Logs/runtime-$index.jsonl" \
            --destination "$DIR/runtime-$index.jsonl" >/dev/null 2>&1; then
            got=$((got + 1))
        fi
    done
    echo "   拿到 $got 个日志文件"
fi

logs=$(ls "$DIR"/runtime-*.jsonl 2>/dev/null | sort -V || true)
[[ -n "$logs" ]] || { echo "没找到 runtime-*.jsonl（应用至少启动过一次？）" >&2; exit 1; }
echo "▸ 日志：$(echo "$logs" | wc -l | tr -d ' ') 个文件，$(cat $logs | wc -l | tr -d ' ') 行"

count() { cat $logs | grep -c "$1" || true; }
last()  { cat $logs | grep "$1" | tail -1 || true; }

echo
echo "① 解码预算"
grep -o '"dock decoding now [0-9]*"' $logs | sort | uniq -c || echo "   （没有这一行：坞里可能一个窗都没起）"

echo
echo "② 增强让路（坞里 ≥3 路解码时）"
count '"enhance"' >/dev/null
cat $logs | grep -o 'pipeline released ([^)]*)' | sort | uniq -c || echo "   （没有：要么增强本来关着，要么坞里少于 3 路在解码）"

echo
echo "③ 赛跑次数（每个 host 只该有 1–2 次）"
cat $logs | grep -o 'racing [^ ]*' | sort | uniq -c | sort -rn | head -10 || true

echo
echo "④ 每窗出口"
printf "   media direct: %s\n" "$(count 'media direct')"
printf "   media proxy : %s\n" "$(count 'media proxy')"

echo
echo "⑤ 上游复用"
printf "   upstream reused : %s\n" "$(count 'upstream reused')"
printf "   pool hits 行    : %s\n" "$(count 'upstream pool hits')"

echo
echo "结论（人工核一眼）"
printf "  · 同时解码路数 = %s（应 = 机型档位 4/6/8，不是 20）\n" "$(grep -o 'dock decoding now [0-9]*' $logs | tail -1 | grep -o '[0-9]*' || echo '?')"
printf "  · 挂起数 = 20 − 上面这个数；卡片应显示海报 + 「已挂起」\n"
printf "  · 若 ⑤ 为 0 而 ④ 的 proxy 行很多：中继没复用（看 relayKeepAlive 开关与响应头）\n"
