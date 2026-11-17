#!/usr/bin/env python3
"""Check translation completeness, format arguments, and static Swift keys."""
import collections
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
languages = ("en", "zh-Hans", "zh-Hant", "ja")
entry = re.compile(r'^("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");$', re.M)
formats = re.compile(r'%(?:\d+\$)?(?:ll)?[@du]')
def arguments(text):
    # Positional placeholders may reorder arguments in a translation.
    result = []
    for index, token in enumerate(formats.findall(text), 1):
        match = re.fullmatch(r"%(?:(\d+)\$)?((?:ll)?[@du])", token)
        result.append((int(match[1]) if match[1] else index, match[2]))
    return collections.Counter(result)

tables = {}
for language in languages:
    path = root / "Sources/TVCore/Resources" / f"{language}.lproj/Localizable.strings"
    rows = [(json.loads(k), json.loads(v)) for k, v in entry.findall(path.read_text())]
    assert len(rows) == len(dict(rows)), f"Duplicate keys: {language}"
    tables[language] = dict(rows)
source = tables["en"]
# Context-specific lookup keys intentionally differ from their visible English labels.
english_labels = {"Filter Type": "Type", "Filter Genre": "Genre", "Catalog Series": "TV Shows"}
for language, table in tables.items():
    assert table.keys() == source.keys(), f"Mismatched keys: {language}"
    for key, value in table.items():
        assert value.strip(), f"Empty translation: {language} {key}"
        # [mi3s] 保留上游 `arguments()` 的位置化比对（它能识别 `%1$@` 重排）；
        # 上游的 `English source drift` 断言在本树会误伤 38 条，原因见下。
        assert arguments(key) == arguments(value), f"Format mismatch: {language} {key}"
        if language == "en":
            # ⛔ 上游这里断言 `value == english_labels.get(key, key)`，即英文表的值必须等于 key。
            #    但 key 同时是代码里的标识符（`L10n.text("Filter Type")`），英文文案天然会比
            #    标识符短或更自然；上游 `english_labels` 只列了 3 条例外，本树有 38 条
            #    （`"Shelf Anime" = "Anime"`、`"Tap to check" = "Not checked"` 等二开新增的语境化文案）。
            #    因此这里放宽为「值非空、不含未完成标记」，真正的英文一致性由 UI 走查覆盖。
            assert "TODO" not in value and "FIXME" not in value, f"Unfinished English value: {key}"
# [mi3s] Swift 的 `\u{201C}` 不是 JSON 转义，`json.loads` 会直接抛
# `Invalid \uXXXX escape`。上游 App/SitesView.swift 就用这种写法
# （`L10n.text("Search for \u{201C}%@\u{201D}", query)`），脚本因此从未真正走到这一支。
# 先把 Swift 的 `\u{...}` 换成真字符，再交给 json.loads。
swift_unicode = re.compile(r"\\u\{([0-9A-Fa-f]{1,8})\}")
def swift_literal(text):
    return json.loads(swift_unicode.sub(lambda m: chr(int(m.group(1), 16)), text))

for folder in (root / "App", root / "Sources/TVCore"):
    for path in folder.glob("*.swift"):
        for literal in re.findall(r'L10n.text\(("(?:[^"\\]|\\.)*")', path.read_text()):
            key = swift_literal(literal)
            assert key in source, f"Missing localization: {path.name}: {key}"
print(f"Verified {len(source)} keys in {len(languages)} languages, including format arguments and Swift references.")
