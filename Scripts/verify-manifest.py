#!/usr/bin/env python3
"""manifest ⟷ 代码一致性核对。

manifest 的「已接」判据是三条：文件在 + 编译通过 + 已 grep 到真实入口。
前两条由 verify-fusion.sh 与 xcodebuild 覆盖，第三条第 1 项（文件在）从未机械化。

这条脚本把「落地文件」列的每个引用按四类解析：
  ① 精确存在
  ② 文件名唯一（路径写不全）
  ③ 符号存在（写的是符号不是路径）
  ④ 真不存在        ← 唯一需要人工处理的类别

用法: python3 Scripts/verify-manifest.py [--fix]
       --fix 会把类别 ② 的路径自动补全写回 manifest
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'Docs/fusion/01-功能清单与归属.md'
SCAN_DIRS = ('App','Sources','Tests','UITests','Runtime','Services',
             'Config','Design','Scripts','Packages','website','Resources')

def build_index():
    files = []
    for d in SCAN_DIRS:
        p = ROOT / d
        if not p.exists(): continue
        for f in p.rglob('*'):
            s = str(f.relative_to(ROOT))
            if f.is_file() and '.build' not in s and '.git' not in s:
                files.append(s)
    byname = {}
    for f in files: byname.setdefault(pathlib.Path(f).name, []).append(f)
    return files, byname

def build_source():
    src = ''
    for d in ('App','Sources','UITests','Tests','Runtime'):
        p = ROOT / d
        if not p.exists(): continue
        for f in p.rglob('*'):
            if f.suffix in ('.swift','.mjs','.js','.ts') and '.build' not in str(f):
                try: src += f.read_text(encoding='utf-8', errors='replace')
                except Exception: pass
    return src

def parse_manifest():
    s = MANIFEST.read_text(encoding='utf-8')
    rows = []
    for m in re.finditer(r'\|\s*(F-\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|', s):
        rows.append((m.group(1), m.group(2), m.group(3)))
    return rows

def classify(ref, byname, src):
    if '*' in ref: return 'wildcard', None
    if (ROOT / ref).exists(): return 'exact', None
    bn = pathlib.Path(ref).name
    if bn in byname:
        cands = byname[bn]
        return ('by-name', cands[0]) if len(cands) == 1 else ('by-name-ambiguous', cands)
    stem = bn.rsplit('.', 1)[0]
    if re.search(r'\b' + re.escape(stem) + r'\b', src): return 'symbol', None
    return 'missing', None

def main():
    fix = '--fix' in sys.argv
    files, byname = build_index()
    src = build_source()
    rows = parse_manifest()

    buckets = {'exact': 0, 'by-name': 0, 'symbol': 0, 'wildcard': 0,
               'by-name-ambiguous': 0, 'missing': 0}
    fixes = {}
    missing = []

    for fid, cap, files_col in rows:
        for ref in re.findall(r'`([^`]+)`', files_col):
            kind, data = classify(ref, byname, src)
            buckets[kind] += 1
            if kind == 'by-name': fixes[ref] = data
            elif kind == 'missing': missing.append((fid, cap.strip(), ref))
            elif kind == 'by-name-ambiguous': missing.append((fid, cap.strip(), ref + ' (多义)'))

    print("manifest 条目 %d，引用 %d 处" % (len(rows), sum(buckets.values())))
    print("  ① 精确存在         %d" % buckets['exact'])
    print("  ② 文件名唯一       %d" % buckets['by-name'])
    print("  ③ 符号存在         %d" % buckets['symbol'])
    print("  ④ 通配/目录        %d" % buckets['wildcard'])
    print("  ⑤ 真不存在         %d  ← 需要人工处理" % (buckets['missing'] + buckets['by-name-ambiguous']))
    for fid, cap, ref in missing:
        print("       %-6s %-28s %s" % (fid, ref, cap[:30]))

    if fix and fixes:
        s = MANIFEST.read_text(encoding='utf-8')
        for old, new in fixes.items():
            s = s.replace('`%s`' % old, '`%s`' % new)
        MANIFEST.write_text(s, encoding='utf-8')
        print("\n已补全 %d 处路径写回 manifest" % len(fixes))

    return 1 if (buckets['missing'] + buckets['by-name-ambiguous']) else 0

if __name__ == '__main__':
    sys.exit(main())
