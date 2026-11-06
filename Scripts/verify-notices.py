#!/usr/bin/env python3
"""第三方声明 ⟷ 代码一致性核对。

THIRD_PARTY_NOTICES.md 里凡是声称「bundled / retained / copied into」的路径，
必须真的存在。声明了不存在的文件 = 合规文档说谎（无论哪种方向都有问题：
说了没有的代码，会让人误以为有 GPL 义务；说有却删了，则是漏遵守）。

两个方向都查：
  ① 声明中提到的路径 → 必须存在
  ② 仓库里的 LICENSE/NOTICE 文件 → 应在声明中有对应提及
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NOTICE = ROOT / 'Docs/THIRD_PARTY_NOTICES.md'

def main():
    if not NOTICE.exists():
        print("  THIRD_PARTY_NOTICES.md 不存在"); return 1
    text = NOTICE.read_text(encoding='utf-8')

    # ① 提取所有反引号里的路径样式串
    refs = re.findall(r'`([A-Za-z][\w./+-]*(?:LICENSE[\w.]*|\.(?:js|swift|m|txt|md|json)))`', text)
    # 只保留看起来是仓库路径的（含 / 或已知扩展名）
    checked = bad = 0
    external = 0
    known = []
    derived = []
    missing = []
    def resolve(r):
        """把声明里的路径解析回本仓库真实文件；解析不到返回 None。
        声明里有两类路径不是本仓库的：
          ① 第三方仓库内部路径（src/native/xifan.js 等）—— 前面紧邻 github.com 链接
          ② 明确写明由构建脚本产出的路径（ScriptHost/LICENSE.node）
        ③ 省略了顶层目录前缀的（ScriptAssets/sites/index.json → Sources/TVCore/...）
        """
        if (ROOT / r).exists():
            return ROOT / r
        # ① 第三方仓库内部路径（声明里紧邻 github 链接），不是本仓库的
        if r.startswith(('src/', 'quickjs/', 'lib/')):
            return 'EXTERNAL'
        # ② 省略了顶层目录前缀的：按「路径尾部」在本仓库找
        #    ScriptAssets/sites/index.json → Sources/TVCore/ScriptAssets/sites/index.json
        #    ScriptHost/LICENSE.assets     → Runtime/ScriptHost/LICENSE.assets
        parts = r.split('/')
        for skip in (0, 1):
            tail = '/'.join(parts[skip:])
            hits = [q for q in ROOT.glob('**/' + tail)
                    if q.is_file() and '.git' not in str(q)
                    and '/build/' not in str(q) and '/.build/' not in str(q)]
            if hits:
                return hits[0]
        return None

    for r in sorted(set(refs)):
        if '/' not in r:
            continue
        checked += 1
        # ② 该引用所在句子若说明了「由脚本复制/生成」，则它不是源码树文件
        ctx = ''
        for line in text.splitlines():
            if r in line:
                ctx = line
                break
        if any(k in ctx for k in ('copies that file', 'build-', 'bundled standalone',
                                  'joins the official', 'distributed license')):
            derived.append(r)
            continue
        got = resolve(r)
        if got == 'EXTERNAL':
            external += 1
            continue
        if got is None:
            # ③ 只有文档在 Known gap 段落里点名提到这一条，才放过
            if 'Known gap' in text and r in text.split('Known gap', 1)[1]:
                known.append(r)
                continue
            missing.append(r); bad += 1

    print("声明中的路径引用 %d 处" % checked)
    if external:
        print("  其中第三方仓库内路径 %d 处（不检查）" % external)
    if derived:
        print("  声明为构建产物（源码树无、构建后才有）%d 处：" % len(derived))
        for d in derived: print("       ", d)
    if known:
        print("  已登记为 Known gap %d 处：" % len(known))
        for k in known: print("       ", k)
    if missing:
        print("  ✗ 声称打包/保留但不存在 %d 处：" % len(missing))
        for m in missing[:12]:
            print("       ", m)
    else:
        print("  声称存在但缺失      0 ✓")

    # ② 仓库内实存 LICENSE / *.LICENSE 文件
    on_disk = [str(p.relative_to(ROOT)) for p in ROOT.rglob('LICENSE*')
               if '.git' not in str(p) and 'build/' not in str(p)]
    on_disk += [str(p.relative_to(ROOT)) for p in ROOT.rglob('*.LICENSE')
                if '.git' not in str(p) and 'build/' not in str(p)]
    unmentioned = [f for f in on_disk if pathlib.Path(f).name not in text and f not in text]
    print("仓库内 LICENSE 类文件 %d 个" % len(on_disk))
    if unmentioned:
        print("  ⚠ 未在声明中提及 %d 个（仅提示，不判失败）：" % len(unmentioned))
        for f in unmentioned[:8]:
            print("       ", f)
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
