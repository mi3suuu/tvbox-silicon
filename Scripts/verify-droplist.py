#!/usr/bin/env python3
"""drop-list ⟷ 代码一致性核对。

drop-list 里两类引用会过期：
  ① 文件路径 —— 文件被改名/移动/删除
  ② `文件:行号` —— 行号随代码变动漂移

两类都不会报错，只会让人按清单去查时找不到东西。
本脚本把每条引用解析回真实文件，并核对行号是否仍落在文件范围内。
"""
import re, sys, pathlib, glob

ROOT = pathlib.Path(__file__).resolve().parent.parent
DROP = ROOT / 'Docs/fusion/drop-list.md'

def build_index():
    files = set()
    for d in ('App','Sources','Tests','UITests','Runtime','Services','Config','Design','Scripts','website'):
        p = ROOT / d
        if not p.exists(): continue
        for f in p.rglob('*'):
            if f.is_file() and '.build' not in str(f):
                files.add(str(f.relative_to(ROOT)))
    return files

def main():
    files = build_index()
    text = DROP.read_text(encoding='utf-8')
    byname = {}
    for f in files: byname.setdefault(pathlib.Path(f).name, []).append(f)

    bad_file, bad_line = [], []
    checked_file = checked_line = 0

    # 只检查 `path/to/file.ext` 与 `path/file.swift:123` 形态
    for m in re.finditer(r'`([A-Za-z][\w./+-]*\.(?:swift|mjs|js|json|ts|strings|yml|plist|py|sh))(?::(\d+))?`', text):
        ref, line = m.group(1), m.group(2)
        checked_file += 1
        if ref in files:
            real = ref
        elif pathlib.Path(ref).name in byname and len(byname[pathlib.Path(ref).name]) == 1:
            real = byname[pathlib.Path(ref).name][0]
        else:
            bad_file.append(ref); continue
        if line:
            checked_line += 1
            n = sum(1 for _ in (ROOT / real).open(encoding='utf-8', errors='replace'))
            if int(line) > n:
                bad_line.append((ref, int(line), n))


    # 额外：N 组（保留本地不外推）声明的路径必须真的存在 —— 它的语义是
    # 「这些文件在我方仓库里、可用」，删了就是清单说谎。
    n_files, n_bad = 0, []
    in_n = False
    for line in text.splitlines():
        if line.startswith('## ') and 'N 组' in line:
            in_n = True; continue
        if in_n and line.startswith('## '):
            in_n = False
        if not in_n or not line.startswith('| N-'):
            continue
        for ref in re.findall(r'`([^`]+)`', line):
            if '*' in ref:
                # 通配：必须至少命中一个真实文件（如 Scripts/audit-*.sh）
                hits = glob.glob(str(ROOT / ref))
                if hits:
                    n_files += len(hits)
                else:
                    n_bad.append(ref)
                continue
            n_files += 1
            if not (ROOT / ref).exists():
                n_bad.append(ref)
    print("N 组（保留本地不外推）声明 %d 个路径" % n_files)
    if n_bad:
        print("  ✗ 声明保留但不存在 %d 个：" % len(n_bad))
        for x in n_bad[:12]: print("       ", x)
        bad_file.extend(n_bad)
    else:
        print("  声明保留但不存在   0 ✓")

    print("drop-list 文件引用 %d 处（含行号 %d 处）" % (checked_file, checked_line))
    if bad_file:
        print("  ✗ 文件不存在 %d 处：" % len(bad_file))
        for x in bad_file[:12]: print("       ", x)
    else:
        print("  文件不存在        0 ✓")
    if bad_line:
        print("  ✗ 行号越界 %d 处：" % len(bad_line))
        for f, l, n in bad_line[:12]: print("        %s:%d（文件仅 %d 行）" % (f, l, n))
    else:
        print("  行号越界          0 ✓")
    return 1 if (bad_file or bad_line) else 0

if __name__ == '__main__':
    sys.exit(main())
