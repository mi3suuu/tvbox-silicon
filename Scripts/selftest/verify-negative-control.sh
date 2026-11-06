#!/usr/bin/env bash
# 门禁自检：证明第 ③④ 层有判定能力，不是只会输出「零问题」。
#
# 做法：把第 20 轮修过的 macOS PiP delegate 临时摘掉，
#       确认检查能把缺的 2 个方法报出来，然后还原。
#
# 教训来源：一个只会输出 OK 的检查器，和一个从不检查的检查器等价。
# 必须能用「已知缺陷」验证它真的会报错。

set -uo pipefail
cd "$(dirname "$0")/../.."

BAK=$(mktemp)
cp App/PlayerView.swift "$BAK"
trap 'cp "$BAK" App/PlayerView.swift; rm -f "$BAK"' EXIT

count_missing() {
python3 - <<'PY'
import subprocess, re, pathlib
def ls(r): return set(subprocess.run(['git','-c','core.quotepath=false','ls-tree','-r','--name-only',r],capture_output=True,text=True).stdout.splitlines())
PAT = re.compile(r'func\s+(\w*(?:Did|Will|Should|did|will|should)\w*)\s*\(')
u=set()
for x in ls('22180e4'):
    if not x.endswith('.swift'): continue
    t=subprocess.run(['git','show',f'22180e4:{x}'],capture_output=True,text=True).stdout
    for m in PAT.finditer(t): u.add(m.group(1))
c=set()
for d in ('App','Sources/TVCore','Tests'):
    for f in pathlib.Path(d).rglob('*.swift'):
        try: t=f.read_text(encoding='utf-8')
        except Exception: continue
        for m in PAT.finditer(t): c.add(m.group(1))
print(len(u-c))
PY
}

echo "  ① 基线（修复在位）"
BEFORE=$(count_missing)
echo "     缺失 $BEFORE 个"

echo "  ② 摘除 macOS PiP delegate（模拟缺陷）"
python3 - <<'PY'
import pathlib
p=pathlib.Path('App/PlayerView.swift'); t=p.read_text(encoding='utf-8')
old = """    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
        var host: PassthroughHostingView<AnyView>?
        var subtitles: SubtitleCues?
        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) { subtitles?.native = true }
        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { subtitles?.native = false }
    }"""
new = "    final class Coordinator { var host: PassthroughHostingView<AnyView>? }"
assert t.count(old)==1, "锚点不唯一，App/PlayerView.swift 可能已改"
p.write_text(t.replace(old,new,1), encoding='utf-8')
PY
AFTER=$(count_missing)
echo "     缺失 $AFTER 个"

cp "$BAK" App/PlayerView.swift
RESTORED=$(count_missing)

echo "  ③ 还原后"
echo "     缺失 $RESTORED 个"

if [ "$AFTER" -gt "$BEFORE" ] && [ "$RESTORED" -eq "$BEFORE" ]; then
  echo "  ✓ 正向对照成立：摘除后多报 $((AFTER-BEFORE)) 个，还原后回到 $BEFORE"
  exit 0
else
  echo "  ✗ 门禁无判定能力：摘除后 $AFTER，还原后 $RESTORED，基线 $BEFORE"
  exit 1
fi
