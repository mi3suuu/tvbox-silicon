T = [
    ("Tools", "工具", "工具", "ツール"),
    ("Measure the sources, then file them by result.",
     "先测速，再按结果分组。", "先測速，再按結果分組。", "ソースを計測し、結果でグループ分けします。"),
    ("%lld measured", "已测 %lld 个", "已測 %lld 個", "%lld 件を計測済み"),
    ("%lld measured, %lld within the window", "已测 %lld 个，其中 %lld 个在时间窗内",
     "已測 %lld 個，其中 %lld 個在時間窗內", "%lld 件を計測済み、うち %lld 件は時間内"),
]
INDEX = {"en": 0, "zh-Hans": 1, "zh-Hant": 2, "ja": 3}

def esc(s):
    return s.replace('"', '\\"')

for lang, idx in INDEX.items():
    path = "Sources/TVCore/Resources/%s.lproj/Localizable.strings" % lang
    text = open(path, encoding="utf-8").read()
    block = []
    for row in T:
        if ('"' + row[0] + '"') in text:
            continue
        block.append('"%s" = "%s";' % (esc(row[0]), esc(row[idx])))
    if block:
        text = text.rstrip() + "\n\n/* Sources page: speed card */\n" + "\n".join(block) + "\n"
        open(path, "w", encoding="utf-8").write(text)
    print(lang, "added", len(block))
