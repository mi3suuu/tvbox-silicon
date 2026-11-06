#!/usr/bin/env python3
"""上游文件被改了多少 —— 无 [mi3s] 标记的实质改动必须可见。

判据：
  ① 纯品牌改名（Yingxia/映匣 → Mi3s 归一后增删完全相同）→ 不计入
  ② 归一后增删不同 = 实质逻辑改动
     - 带 [mi3s] 标记 → 已登记，OK
     - 不带标记    → 未登记，计入「无标记实质改动」基数

本脚本对基数做棘轮：允许等于清单里登记的数量，超过即失败。
这样数字不会悄悄增长，且修好一条可以同步下调基线。
"""
import subprocess, sys, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE_FILE = ROOT / 'Docs/fusion/12-未登记侵入清单.md'

def git(*a):
    return subprocess.run(['git', '-c', 'core.quotepath=false', *a],
                          capture_output=True, text=True, cwd=ROOT).stdout

def files(rev):
    return set(git('ls-tree', '-r', '--name-only', rev).splitlines())

def norm(s):
    return s.replace('Mi3s', 'X').replace('Yingxia', 'X').replace('映匣', 'X')

def main():
    try:
        base, ours = files('22180e4'), files('import/ours')
    except Exception as e:
        print("  git 读取失败：%s" % e); return 1
    if not base or not ours:
        print("  缺少 22180e4 或 import/ours 分支"); return 1

    sw = sorted(x for x in (ours & base) if x.endswith('.swift'))
    changed, marked, unmarked_logic = 0, 0, []
    for p in sw:
        a = git('rev-parse', f'import/ours:{p}').strip()
        b = git('rev-parse', f'22180e4:{p}').strip()
        if not (a and b and a != b):
            continue
        changed += 1
        head = git('show', f'HEAD:{p}')
        if '[mi3s]' in head:
            marked += 1
            continue
        d = git('diff', '22180e4', 'HEAD', '--', p)
        adds = [norm(l[1:]) for l in d.splitlines()
                if l.startswith('+') and not l.startswith('+++') and l[1:].strip()]
        dels = [norm(l[1:]) for l in d.splitlines()
                if l.startswith('-') and not l.startswith('---') and l[1:].strip()]
        if adds != dels:
            unmarked_logic.append(p)

    print("我方改过的上游 .swift：%d 个" % changed)
    print("  已标记 [mi3s]：      %d" % marked)
    print("  纯品牌改名（不计）： %d" % (changed - marked - len(unmarked_logic)))
    print("  ✗ 无标记实质改动：   %d" % len(unmarked_logic))

    baseline = None
    if BASELINE_FILE.exists():
        txt = BASELINE_FILE.read_text(encoding='utf-8')
        m = re.search(r'无标记实质改动基线[：:]\s*(\d+)', txt)
        if m:
            baseline = int(m.group(1))
    if baseline is None:
        print("  （清单未写基线，跳过棘轮比对）")
        return 0
    print("  清单基线：           %d" % baseline)
    if len(unmarked_logic) > baseline:
        print("  ✗ 比基线多了 %d 个 —— 新的无标记侵入，必须处理" % (len(unmarked_logic) - baseline))
        for p in unmarked_logic:
            print("       ", p)
        return 1
    if len(unmarked_logic) < baseline:
        print("  ✓ 比基线少 %d 个 —— 记得同步下调清单基线" % (baseline - len(unmarked_logic)))
    else:
        print("  ✓ 与基线一致（不增长）")
    return 0

if __name__ == '__main__':
    sys.exit(main())
