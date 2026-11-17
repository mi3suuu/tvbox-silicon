#!/usr/bin/env python3
"""把 `TVBoxProbe --line-audit` 的 JSONL 汇总成「有多少条线/多少个源会出同类问题」。

口径（每一条都对应一个用户能感觉到的现象）：

  · 解析出网页而非媒体     → 「点播放转圈很久，然后失败」（播放器拿到 HTML）
  · 首线不可用、别的线可用 → 「得换一条线才好」
  · 首线可用但画质不是最高 → 「自动选的不是最好那条」（kanju official→ordinary 同型）
  · 第一次失败、第二次成功 → 「切到第二集再切回来就好了」
  · 线路名写 4K/1080 但实测更低 → 「4K 源出来的不是 4K」

画质一律按**长边**判（竖屏 720×1280 的长边是 1280，电影 1920×818 的长边是 1920），
按高度判会把竖屏 720p 排到电影 1080p 前面。

用法：
    Scripts/analyze-line-audit.py build/line-audit/playable.jsonl [more.jsonl ...] [--json out.json]
"""
import argparse, collections, json, pathlib

# 线路名里写的画质 → 长边下限。低于它就按「名不副实」记一笔。
CLAIM_EDGE = {"4K": 3200, "1080": 1600, "720": 1000, "480": 700}


def long_edge(line):
    w, h = line.get("width"), line.get("height")
    if w and h:
        return max(w, h)
    return h or None


def load(paths):
    rows = []
    for path in paths:
        for text in pathlib.Path(path).read_text().splitlines():
            text = text.strip()
            if not text:
                continue
            try:
                rows.append(json.loads(text))
            except ValueError:
                continue
    # 同一个 key 只留最后一份（重跑覆盖）
    return list({row.get("key"): row for row in rows}.values())


def analyse(rows):
    lines_all, ok_all_edges, flags = [], [], collections.Counter()
    stats = collections.Counter()
    detail = []
    for row in rows:
        stats["sources"] += 1
        lines = row.get("lines") or []
        if not lines:
            stats["sourcesErrored" if row.get("error") else "sourcesNoLines"] += 1
            if row.get("error"):
                detail.append({"kind": "source-error", "key": row.get("key"), "name": row.get("name"),
                               "error": row["error"][:160]})
            continue
        stats["lines"] += len(lines)
        if len(lines) > 1:
            stats["sourcesMultiLine"] += 1
        for line in lines:
            lines_all.append((row, line))
            flags[line.get("flag", "")] += 1
            if line.get("ok"):
                stats["linesOk"] += 1
                if long_edge(line):
                    ok_all_edges.append((row, line, long_edge(line)))
            elif line.get("kind") in ("html", "json"):
                stats["linesPage"] += 1
            elif line.get("needsWeb"):
                stats["linesNeedsWeb"] += 1
            else:
                stats["linesDead"] += 1
        # 首线（App 的默认线路：`LinePreference` 在没历史时取第一条能播的）
        first_ok = next((l for l in lines if l.get("ok")), None)
        ok_lines = [l for l in lines if l.get("ok")]
        if not ok_lines:
            stats["sourcesAllDead"] += 1
            detail.append({"kind": "all-lines-dead", "key": row.get("key"), "name": row.get("name"),
                           "lines": [l.get("flag") for l in lines]})
        elif first_ok is not lines[0]:
            stats["sourcesFirstLineUnplayable"] += 1
            detail.append({"kind": "first-line-unplayable", "key": row.get("key"), "name": row.get("name"),
                           "first": lines[0].get("flag"), "firstKind": lines[0].get("kind")})
        if any(l.get("kind") in ("html", "json") for l in lines):
            stats["sourcesWithPageLine"] += 1
        if any(l.get("retryHelped") for l in lines):
            stats["sourcesRetryNeeded"] += 1
        for line in lines:
            if not line.get("claim") or not long_edge(line):
                continue
            claim = line["claim"]
            edge = long_edge(line)
            stats["claims"] += 1
            if edge < CLAIM_EDGE.get(claim, 0):
                stats["claimsFake"] += 1
                detail.append({"kind": "fake-quality", "key": row.get("key"), "name": row.get("name"),
                               "flag": line.get("flag"), "claim": claim, "width": line.get("width"),
                               "height": line.get("height")})
    # 同一部剧里「首条可播线」不是画质最高的一条
    best_missed = []
    for row in rows:
        lines = [l for l in row.get("lines") or [] if l.get("ok") and long_edge(l)]
        if len(lines) < 2:
            continue
        first = lines[0]
        best = max(lines, key=long_edge)
        if long_edge(best) >= long_edge(first) * 1.15:
            best_missed.append({"key": row.get("key"), "name": row.get("name"),
                                "first": (first.get("flag"), first.get("width"), first.get("height")),
                                "best": (best.get("flag"), best.get("width"), best.get("height"))})
    stats["sourcesFirstNotBestPicture"] = len(best_missed)
    return dict(stats), detail, best_missed, flags


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", nargs="+")
    parser.add_argument("--json")
    args = parser.parse_args()
    stats, detail, best_missed, flags = analyse(load(args.jsonl))
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    print("\n--- 线路旗标频次（前 25） ---")
    for flag, count in flags.most_common(25):
        print(f"{flag or '(空)'}: {count}")
    print("\n--- 首条可播线不是画质最高 ---")
    for item in best_missed:
        print(json.dumps(item, ensure_ascii=False))
    print("\n--- 明细 ---")
    for item in detail:
        print(json.dumps(item, ensure_ascii=False))
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(
            {"stats": stats, "detail": detail, "firstNotBest": best_missed,
             "flags": flags.most_common()}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
