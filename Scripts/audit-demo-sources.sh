#!/bin/bash
# 用上游演示订阅（fty.json）跑真实的源加载审计。
#
# 这是「能编译、单测过」之外的一层：真的把每个源的 JAR/spider 跑起来，看首页和搜索能不能出内容。
# 用的是 App「添加源 → 使用演示地址」里那个 URL（App/Store.swift 的 defaultURL）。
#
#   Scripts/audit-demo-sources.sh              # 全量 48 个源
#   LIMIT=5 Scripts/audit-demo-sources.sh      # 只跑前 5 个（调脚本本身时用）
#
# 产物：build/audit-demo/results.json
#
# 快照格式（audit-source-loading.py 要的）：
#   顶层  origin = 订阅 URL
#   顶层  raw    = 订阅里除 sites 外的内容（spider / hosts / rules …）
#   sites[]      = { "raw": <单个 site 对象> }
set -uo pipefail
cd "$(dirname "$0")/.."
DEMO="${DEMO:-https://raw.githubusercontent.com/qist/tvbox/master/fty.json}"
OUT="${OUT:-build/audit-demo}"
SNAP="build/audit-snap/fty.json"

mkdir -p build/audit-snap
echo "① 拉演示订阅"
curl -s --max-time 30 -o /tmp/fty.json "$DEMO" || { echo "  拉取失败"; exit 1; }
echo "  $(wc -c < /tmp/fty.json | tr -d ' ') bytes"

echo "② 转成 audit 快照"
python3 - "$SNAP" "$DEMO" <<'PY'
import json, sys
snap_path, origin = sys.argv[1], sys.argv[2]
d = json.load(open('/tmp/fty.json'))
json.dump({
    'origin': origin,
    'raw': {k: v for k, v in d.items() if k != 'sites'},
    'sites': [{'raw': s} for s in d['sites']],
}, open(snap_path, 'w'), ensure_ascii=False)
print("  %d 个源 → %s" % (len(d['sites']), snap_path))
PY

echo "③ 跑审计（每个源都要起一次 JVM，慢）"
rm -rf "$OUT"
ARGS=(--output "$OUT" --workers "${WORKERS:-3}")
[ -n "${LIMIT:-}" ] && ARGS+=(--limit "$LIMIT")
python3 Scripts/audit-source-loading.py "$SNAP" "${ARGS[@]}" > /tmp/audit-stdout.log 2>&1
rc=$?

echo "④ 汇总"
python3 - "$OUT" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]) / 'results.json'
if not p.exists(): print("  没有 results.json"); raise SystemExit(1)
r = json.load(open(p))
init_ok = [x for x in r if x.get('initialized')]
home_ok = [x for x in init_ok if (x.get('home') or {}).get('videos', 0) > 0]
home_empty = [x for x in init_ok if (x.get('home') or {}).get('videos', 0) == 0 and 'error' not in (x.get('home') or {})]
home_err = [x for x in init_ok if 'error' in (x.get('home') or {})]
print("  总源数 %d ｜ 初始化成功 %d 失败 %d" % (len(r), len(init_ok), len(r) - len(init_ok)))
print("  首页有内容 %d ｜ 空 %d ｜ 报错 %d" % (len(home_ok), len(home_empty), len(home_err)))
PY
exit $rc
