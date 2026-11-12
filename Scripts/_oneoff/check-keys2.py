import re

WANT = [
    "Speed & Grouping",
    "Tools",
    "Measure the sources, then file them by result.",
    "%lld measured",
    "%lld measured, %lld within the window",
]
paths = {
    "en": "Sources/TVCore/Resources/en.lproj/Localizable.strings",
    "zh-Hans": "Sources/TVCore/Resources/zh-Hans.lproj/Localizable.strings",
    "zh-Hant": "Sources/TVCore/Resources/zh-Hant.lproj/Localizable.strings",
    "ja": "Sources/TVCore/Resources/ja.lproj/Localizable.strings",
}
for lang, path in paths.items():
    text = open(path, encoding="utf-8").read()
    missing = [w for w in WANT if ('"' + w + '"') not in text]
    print(lang, "missing", len(missing))
    for m in missing:
        print("   MISS", m)
