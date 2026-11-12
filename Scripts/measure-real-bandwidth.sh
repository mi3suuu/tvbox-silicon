#!/bin/bash
# 实测本机真实下行带宽，对照 One/映匣 显示的速度到底超没超。
#
# 三组数据，缺一不可：
#   1. 单连接 curl  —— 运营商/服务器对「单流」的限制
#   2. 多连接 curl  —— 聚合后真实链路能到多少
#   3. 单位换算表   —— 显示 MB/s 和套餐 Mbps 的关系（最常见的「超带宽」错觉来源）
#
# 用法：./measure-real-bandwidth.sh [测试URL] [连接数]
#   测试 URL 默认用 Cloudflare 的 100MB 测速文件。

set -u
URL="${1:-https://speed.cloudflare.com/__down?bytes=104857600}"
CONNS="${2:-8}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

hr() { printf '%s\n' "------------------------------------------------------------"; }
mbps() { awk -v b="$1" -v s="$2" 'BEGIN{printf "%.2f MB/s  =  %.1f Mbps", b/s/1048576, b*8/s/1000000}'; }

hr
echo "1) 单位换算（先排除这一条，它是 80% 的误会来源）"
hr
cat <<'TABLE'
   运营商套餐      理论峰值        等价下载显示
   100 Mbps    =  12.5 MB/s     看到 12 MB/s 就是满速，不是超了
   200 Mbps    =  25.0 MB/s
   300 Mbps    =  37.5 MB/s
   500 Mbps    =  62.5 MB/s
  1000 Mbps    = 125.0 MB/s
   注意：1 MB/s = 8 Mbps。把 MB 当 Mb 读，就会觉得「翻了 8 倍」。
TABLE

hr
echo "2) 单连接实测（这条代表「单流限速」）"
hr
START=$(python3 -c 'import time;print(time.time())')
BYTES=$(curl -s -o /dev/null -w '%{size_download}' --max-time 30 "$URL")
END=$(python3 -c 'import time;print(time.time())')
SECS=$(python3 -c "print(max(0.001,$END-$START))")
printf '  单连接: %s 字节 / %.2f 秒 = %s\n' "$BYTES" "$SECS" "$(mbps "$BYTES" "$SECS")"
SINGLE=$BYTES

hr
echo "3) 多连接实测（$CONNS 路并行，这条代表「链路真实上限」）"
hr
START=$(python3 -c 'import time;print(time.time())')
for i in $(seq 1 "$CONNS"); do
  curl -s -o "$TMP/$i" --max-time 30 "$URL" &
done
wait
END=$(python3 -c 'import time;print(time.time())')
SECS=$(python3 -c "print(max(0.001,$END-$START))")
TOTAL=$(cat "$TMP"/* 2>/dev/null | wc -c | tr -d ' ')
printf '  %d 连接: %s 字节 / %.2f 秒 = %s\n' "$CONNS" "$TOTAL" "$SECS" "$(mbps "$TOTAL" "$SECS")"

hr
echo "4) 判定"
hr
python3 - "$SINGLE" "$TOTAL" <<'PY'
import sys
single, total = int(sys.argv[1]), int(sys.argv[2])
if single <= 0:
    print("  单连接没下到数据，换一个测试地址再跑。")
    sys.exit()
ratio = total / single
print("  单连接 : 多连接 = 1 : %.2f" % ratio)
if ratio > 1.5:
    print("  → 服务器或线路对「单流」有限速。多连接聚合有效，这就是 Steam 式加速的立足点。")
elif ratio > 1.15:
    print("  → 单流本身已接近链路上限，多连接的收益有限。")
else:
    print("  → 单流已跑满链路。此时任何 App 都不可能更快；若它显示更快，是它算错了。")
PY
echo
echo "  把第 2、3 步的数字，和 App 里显示的速度对照："
echo "   • App 显示 ≤ 第 3 步      → 正常，多连接聚合的结果"
echo "   • App 显示 >  第 3 步      → 显示口径有问题（单位/重复计数/续下把旧字节算成新字节）"
echo
