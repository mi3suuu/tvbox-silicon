#!/bin/bash
# 融合完整性终局核对。五项判据一次跑完，每项都给出可复跑的数值。
#
# 判据口径（关键）：
#   ① 二开文件融入 —— 要排除「已在 drop-list 明确丢弃」的项。
#      直接算 ours-base 的差集会把我方主动删掉的东西也算成「缺失」（2026-11-06 踩过）。
#   ② 侵入登记 —— 必须双向：登记→代码、代码→登记，两边都要 0。
set -uo pipefail
cd "$(dirname "$0")/.."

echo "########## 融合完整性核对 ##########"
echo

echo "① 二开文件融入"
python3 - <<'PY'
import subprocess, re, os
def f(r): return set(subprocess.run(['git','ls-tree','-r','--name-only',r],capture_output=True,text=True).stdout.splitlines())
ours, base, head = f('import/ours'), f('22180e4'), f('HEAD')
ext = ('.swift','.strings','.yml','.md','.js','.json','.plist')
added = {x for x in ours - base if x.endswith(ext)}
missing = sorted(x for x in added if x not in head)

# 排除 drop-list 里明确丢弃的（D-03 = 本地站点脚本）
drop = open('Docs/fusion/02-未纳入清单.md', encoding='utf-8').read()
dropped = set()
if 'D-03' in drop:
    for line in drop.splitlines():
        if line.startswith('| D-03'):
            dropped = {p for p in re.findall(r'[\w/.\-]+\.(?:js|swift|json)', line)}
            break
dropped |= {x for x in missing if '/ScriptAssets/sites/' in x and (
    os.path.basename(x) in ('Bili.js','Hema.js','Hongguo.js','Xifan.js')
    or '/sites/hongguo/' in x)}

real = [x for x in missing if x not in dropped]
print("   代码类新增 %d 个" % len(added))
print("   其中已按 D-03 主动丢弃 %d 个" % len(dropped & set(missing)))
print("   真缺失 %d 个%s" % (len(real), ('：' + str(real[:5])) if real else " ✓"))
PY

echo
echo "② 侵入登记（双向）"
python3 - <<'PY'
import re, subprocess
s = open('Docs/fusion/03-侵入点登记表.md', encoding='utf-8').read()
rows = re.findall(r'^\|\s*(I-\d+)\s*\|\s*`([^`]+)`', s, re.M)
reg = set(f for _, f in rows)
no_mark = [i for i, f in rows if '[mi3s]' not in open(f, encoding='utf-8', errors='replace').read()]
marked = set(subprocess.run(['bash','-c','grep -rl "\\[mi3s\\]" App Sources --include=*.swift'],
                            capture_output=True, text=True).stdout.splitlines())
unreg = sorted(marked - reg)
n = subprocess.run(['bash','-c','grep -rn "\\[mi3s\\]" App Sources --include=*.swift | wc -l'],
                   capture_output=True, text=True).stdout.strip()
print("   登记 %d 条 / %d 个文件 / %s 处标记" % (len(rows), len(reg), n))
print("   登记→代码 缺标记 %d%s" % (len(no_mark), ('：' + str(no_mark)) if no_mark else " ✓"))
print("   代码→登记 未登记 %d%s" % (len(unreg), ('：' + str(unreg)) if unreg else " ✓"))
PY

echo
echo "③ drop-list"
printf "   %s 条\n" "$(grep -cE '^\| (D|DUO|N|V|P|UP)-' Docs/fusion/drop-list.md)"

echo
echo "④ 验收报告"
printf "   %s 份：%s\n" "$(ls Docs/fusion/验收-*.md 2>/dev/null | wc -l | tr -d ' ')" "$(ls Docs/fusion/验收-*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"

echo
echo "⑤ manifest"
python3 - <<'PY'
import re
s = open('Docs/fusion/01-功能清单与归属.md', encoding='utf-8').read()
ids = [int(m) for m in re.findall(r'^\|\s*F-(\d+)', s, re.M)]
print("   条目 %d / 编号 %d-%d / 缺号 %s" % (len(ids), min(ids), max(ids),
      sorted(set(range(1, max(ids)+1)) - set(ids)) or "无 ✓"))
PY

echo
echo "⑥ 站点脚本恒等式"
python3 - <<'PY'
import json, os
d = 'Sources/TVCore/ScriptAssets/sites'
c = json.load(open(d + '/index.json'))['classes']
local = [k for k, v in c.items() if not v['script'].startswith('https://')]
miss = [k for k in local if not os.path.exists(d + '/' + c[k]['script'])]
ondisk = {f for f in os.listdir(d) if f.endswith('.js')}
ref = {c[k]['script'] for k in local}
orphan = sorted(ondisk - ref)
print("   index.json 本地引用 %d 个 → 文件缺失 %d%s" % (len(local), len(miss), " ✓" if not miss else "：" + str(miss)))
print("   磁盘孤儿 %d 个（应全为共享库）：%s" % (len(orphan), orphan))
PY

echo
echo "⑦ Java host 版本一致（陈旧 jar 会让源在设备上全空）"
python3 - <<'PY2'
import subprocess, re, os
src = 'Runtime/JavaHost/src/main/java/tvbox/runtime/BytecodeCompatibility.java'
want = re.search(r'VERSION = "(host-v[0-9]+)"', open(src).read())
want = want.group(1) if want else '?'
# 只查「会被 Xcode 拷进 App」的与源产物，不查历史 DerivedData
targets = ['build/JavaHost/host.jar']
for d in os.listdir('build/AppleRuntime') if os.path.isdir('build/AppleRuntime') else []:
    p = 'build/AppleRuntime/%s/Resources/JavaHost/host.jar' % d
    if os.path.exists(p): targets.append(p)
bad = []
for t in targets:
    out = subprocess.run(['unzip', '-p', t, 'tvbox/runtime/BytecodeCompatibility.class'],
                         capture_output=True).stdout
    got = re.search(rb'host-v[0-9]+', out)
    got = got.group(0).decode() if got else '?'
    if got != want: bad.append((t, got))
print("   源码 %s / 检查 %d 个产物 → 不符 %d%s" % (want, len(targets), len(bad),
      ("：" + str(bad)) if bad else " ✓"))
PY2
