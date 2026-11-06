#!/bin/bash
# 用确定性 QA 订阅做端到端链路验证：订阅 → 列表 → 详情 → 播放解析 → 真实出流。
#
# 为什么要有这个：xcodebuild 通过只能证明「能编译」，swift test 只能证明「纯逻辑对」。
# 两者都不碰「真的能不能拉到一个能播的流」。这个脚本用 qa-server.py 造的确定性订阅
# （它自己会返回真实的 range 响应媒体），把整条链跑一遍。
#
#   Scripts/verify-qa-chain.sh          # 自动起 qa-server（若未运行），跑完保留
#   PORT=8899 Scripts/verify-qa-chain.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8776}"
B="http://127.0.0.1:$PORT"
fail=0
ok()   { printf "  ✓ %s\n" "$1"; }
bad()  { printf "  ✗ %s\n" "$1"; fail=$((fail+1)); }

# 1) 起服务（端口已被占用说明已经在跑）
if ! curl -sf -o /dev/null "$B/config.json" 2>/dev/null; then
  python3 Scripts/qa-server.py --port "$PORT" >/tmp/qa-chain.log 2>&1 &
  for i in $(seq 1 20); do sleep 0.3; curl -sf -o /dev/null "$B/config.json" 2>/dev/null && break; done
fi
curl -sf -o /dev/null "$B/config.json" || { echo "qa-server 起不来（见 /tmp/qa-chain.log）"; exit 1; }

echo "① 订阅可解析"
n=$(curl -s "$B/config.json" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['sites']))" 2>/dev/null || echo 0)
[ "$n" -ge 5 ] && ok "订阅含 $n 个源" || bad "订阅源数异常: $n"

echo "② 每个源按预期行为"
declare -a EXPECT=("qa-index:200" "qa-standard:200" "qa-slow:200" "qa-empty:200" "qa-error:503")
for pair in "${EXPECT[@]}"; do
  k="${pair%%:*}"; want="${pair##*:}"
  api=$(curl -s "$B/config.json" | python3 -c "import json,sys;print([s['api'] for s in json.load(sys.stdin)['sites'] if s['key']=='$k'][0])" 2>/dev/null)
  got=$(curl -s -o /dev/null -w '%{http_code}' "${api}?ac=list" 2>/dev/null)
  [ "$got" = "$want" ] && ok "$k → $got" || bad "$k 期望 $want 实得 $got"
done

echo "③ 详情可解析（含剧集）"
ep=$(curl -s "$B/api?ac=detail&ids=1" | python3 -c "
import json,sys
v=json.load(sys.stdin)['list'][0]
print(v['vod_play_url'].count('\$'))" 2>/dev/null || echo 0)
[ "${ep:-0}" -ge 5 ] && ok "详情返回 $ep 个剧集" || bad "剧集数异常: $ep"

echo "④ 搜索有结果"
s=$(curl -s "$B/api?wd=%E6%B5%8B%E8%AF%95" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('list',[])))" 2>/dev/null || echo 0)
[ "${s:-0}" -gt 0 ] && ok "搜索返回 $s 条" || bad "搜索无结果"

echo "⑤ 播放解析 → 真实媒体"
u=$(curl -s "$B/api?ac=play&play=episode-1" | python3 -c "import json,sys;print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
if [ -n "$u" ]; then
  ok "解析出 $u"
  code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-2047 "$u" 2>/dev/null)
  ctype=$(curl -s -o /dev/null -w '%{content_type}' -r 0-2047 "$u" 2>/dev/null)
  [ "$code" = "206" ] && ok "Range 请求 206（AVPlayer 需要这个）" || bad "Range 期望 206 实得 $code"
  case "$ctype" in video/*) ok "Content-Type $ctype";; *) bad "Content-Type 异常: $ctype";; esac
else
  bad "播放解析返回空 url"
fi

echo "⑥ 故障源按预期失败"
m=$(curl -s -o /dev/null -w '%{http_code}' "$B/missing.mp4" 2>/dev/null)
[ "$m" = "404" ] && ok "missing.mp4 → 404" || bad "missing.mp4 期望 404 实得 $m"

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "失败 $fail 项"
exit "$fail"
