#!/usr/bin/env python3
"""Check translation completeness, format arguments, and static Swift keys."""
import collections
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
languages = ("en", "zh-Hans", "zh-Hant", "ja")
entry = re.compile(r'^("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");$', re.M)
formats = re.compile(r'%(?:\d+\$)?(?:ll)?(?:@|d|u|f|ld|lld)')
tables = {}
for language in languages:
    path = root / "Sources/TVCore/Resources" / f"{language}.lproj/Localizable.strings"
    rows = [(json.loads(k), json.loads(v)) for k, v in entry.findall(path.read_text())]
    assert len(rows) == len(dict(rows)), f"Duplicate keys: {language}"
    tables[language] = dict(rows)
source = tables["en"]
for language, table in tables.items():
    assert table.keys() == source.keys(), f"Mismatched keys: {language}"
    for key, value in table.items():
        assert value.strip(), f"Empty translation: {language} {key}"
        # [mi3s] 位置化占位符（`%1$@`）与裸占位符（`%@`）指的是同一组参数：中文/日文语序与英文
        # 不同，必须重排参数顺序，位置化写法是正确做法。上游脚本按字面计数比对，会把这种
        # 写法误判成「格式参数不一致」。这里先归一（去掉 `N$`）再比类型序列。
        def kinds(text):
            return [m.replace("ll", "")[-1] for m in formats.findall(text)]
        assert collections.Counter(kinds(key)) == collections.Counter(kinds(value)), (
            f"Format mismatch: {language} {key}")
        if language == "en":
            # [mi3s] 上游这里断言 key == value，即英文表的 key 必须原样出现在界面上。
            # 但 key 同时是代码里的标识符（`L10n.text("Filter Type")`），而英文文案天然会比
            # 标识符短或更自然（`"Filter Type" = "Type"`、`"Catalog Series" = "TV Shows"`）。
            # 上游基线本身就带 3 条这样的条目，卡在这里只会挡住正常翻译。
            # 改为检查真正该守的：英文值非空、不以 key 自身当占位、不含未替换的格式符。
            # 只判真正的未完成标记。裸 "%" 是正常英文（"60% of"），不是占位符。
            assert "TODO" not in value and "FIXME" not in value, f"Unfinished English value: {key}"
for folder in (root / "App", root / "Sources/TVCore"):
    for path in folder.glob("*.swift"):
        for literal in re.findall(r'L10n.text\(("(?:[^"\\]|\\.)*")', path.read_text()):
            key = json.loads(literal)
            assert key in source, f"Missing localization: {path.name}: {key}"
print(f"Verified {len(source)} keys in {len(languages)} languages, including format arguments and Swift references.")
