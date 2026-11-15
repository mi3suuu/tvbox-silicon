#!/usr/bin/env python3
"""Rebuilds `Sources/TVCore/ScriptAssets/builtin/route.json` — the feed pack the app ships.

Why this exists
---------------
The pack that shipped until now had 22 groups, and 31 of its sources carried the address of a
public relay (`149.104.28.149:8100/cms/<token>/<host>/<path>`) baked into `api`. That relay is not
part of 映匣: it can be switched off, it sees the request, and every "中转" source dies with it.
映匣's own relay is a loopback server (`LocalProxyServer`) plus the viewer's own exit proxy — it
can change *which leg* a request leaves through, never whether the phone can reach a host at all.

So this pass does three things, and records what it did:

1. **Unwraps** every `149.104.28.149` address back to the source's own host.
2. **Regroups** 22 feeds into a handful with names that say what the viewer gets:
   影视 可播/待测, 成人 可播, 直播, 4K·网盘, 工具·插件, and one switched-off 失效 bucket.
3. **Moves by verdict**, not by hope: a source that was only ever "playable" through the old relay
   is only kept in a 可播 group if `--verdicts` (a `TVBoxProbe --play-probe` JSONL) says it played
   directly. Everything else lands in the switched-off group instead of silently failing.

Usage
-----
    python3 Scripts/build-route-pack.py \
        --verdicts /tmp/probe-relay.jsonl \
        --out Sources/TVCore/ScriptAssets/builtin/route.json

Without `--verdicts` the formerly-relay groups are treated as unverified: their sources keep their
old grouping (可播 → 待测) rather than being promoted or dropped.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path

RELAY = "149.104.28.149:8100/"
UNWRAPPED_SOURCE = "镜像补录（原中转站，已解包直连）"
LEGACY_NOTE = "源扩搜（旧公共中转站，已解包直连）"

# 旧组号 → (新组号, 内容类)。New groups are listed here once each.
PLAN = {
    "00": ("00", "playable"),   # 影视 · 直连可播
    "01": ("00", "playable"),   # 逆向 · 影视直连
    "15": ("00", "playable"),   # 逆向 · GS 聚合直连
    "17": ("00", "playable"),   # 逆向 · GS 聚合直连 #2
    "20": ("00", "playable"),   # 扩搜 · 补录
    "02": ("00", "relay"),      # 影视 · 需中转可播
    "03": ("00", "relay"),      # 逆向 · 影视中转
    "16": ("00", "relay"),      # 逆向 · GS 聚合中转
    "04": ("01", "untested"),   # 影视 · 模块待测
    "05": ("02", "playable"),   # 成人 · 直连可播
    "07": ("02", "relay"),      # 成人 · 需中转可播
    "08": ("02", "untested"),   # 成人 · 模块待测
    "21": ("02", "relay"),      # 镜像补录
    "06": ("03", "live"),       # 逆向 · 直播多仓
    "12": ("03", "live"),       # 直播 · 订阅
    "14": ("03", "live"),       # 直播 · 鉴黄内嵌
    "10": ("04", "sites"),      # 4K · 网盘端内
    "09": ("05", "sites"),      # 工具 · 模块
    "19": ("05", "sites"),      # WebBox · 内置插件
    "11": ("06", "sites"),      # 探测失效
    "13": ("06", "sites"),      # 列表可用但无剧集
    "18": ("06", "sites"),      # 无实现体
}

GROUPS = {
    "00": dict(name="影视 · 可播", routing="direct", enabled=True),
    "01": dict(name="影视 · 待测", routing="auto", enabled=True),
    "02": dict(name="成人 · 可播", routing="direct", enabled=True),
    "03": dict(name="直播 · 可播", routing="direct", enabled=True),
    "04": dict(name="4K · 网盘", routing="auto", enabled=True),
    "05": dict(name="工具 · 插件", routing="auto", enabled=True),
    "06": dict(name="探测失效（默认关闭）", routing="auto", enabled=False),
}
ORDER = ["00", "01", "02", "03", "04", "05", "06"]


def unwrap(api: str) -> str:
    """`…/cms[r]/<token>/<host>/<path>` → the source's own address."""
    if RELAY not in api:
        return api
    after = api.split(RELAY, 1)[1]
    parts = after.split("/", 2)
    if len(parts) < 3:
        return api
    scheme = "https" if parts[0] == "cmsr" else "http"
    return f"{scheme}://{parts[2]}"


def load_verdicts(path: Path | None) -> dict[str, bool]:
    """Source key → whether it really played (bytes came back), from `--play-probe` output."""
    if not path or not path.exists():
        return {}
    verdict: dict[str, bool] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        verdict[row["key"]] = bool(row.get("kbps") or 0) > 0
    return verdict


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", default="Sources/TVCore/ScriptAssets/builtin/route.json")
    parser.add_argument("--verdicts", default=None)
    parser.add_argument("--out", default="Sources/TVCore/ScriptAssets/builtin/route.json")
    parser.add_argument("--export-out", default=None,
                        help="also write a ConfigBundle (the --play-probe input) for the new pack")
    args = parser.parse_args()

    pack = Path(args.pack)
    document = json.loads(pack.read_text())
    feeds = {feed["address"].rsplit("-", 1)[-1]: feed for feed in document["feeds"]}
    verdict = load_verdicts(Path(args.verdicts) if args.verdicts else None)

    buckets: dict[str, dict] = {key: {"sites": [], "lives": []} for key in GROUPS}
    seen: set[str] = set()
    moved = {"promoted": 0, "demoted": 0, "unwrapped": 0, "unverified": 0}

    for old_key, feed in feeds.items():
        group, kind = PLAN[old_key]
        source = feed["document"]
        # Every feed's shared settings are empty in this pack (parses / flags / ijk / spider), so
        # the merged feed states that explicitly instead of inheriting one group's notes.
        buckets[group]["lives"].extend(source.get("lives") or [])

        for site in source.get("sites") or []:
            if site["key"] in seen:
                continue
            api = site.get("api", "")
            if RELAY in api:
                site["api"] = unwrap(api)
                if isinstance(site.get("raw"), dict):
                    site["raw"]["api"] = site["api"]
                moved["unwrapped"] += 1

            # 出处说明里也不要留那台机器的地址：它是纯文本，但没必要在随包数据里存一个外部 IP。
            for holder in (site, site.get("raw") if isinstance(site.get("raw"), dict) else None):
                if holder and isinstance(holder.get("_source"), str) and "149.104.28" in holder["_source"]:
                    holder["_source"] = LEGACY_NOTE

            # A group that only ever played through the old relay is settled by the probe, not by
            # its old name: bytes, or the switched-off bucket.
            played = verdict.get(site["key"])
            if kind == "relay":
                if played is True:
                    destination, route = group, "直连"
                    moved["promoted"] += 1
                elif played is False:
                    destination, route = "06", "失效"
                    moved["demoted"] += 1
                else:
                    # No verdict for this key: 影视 keeps it in 待测, 成人 has no such shelf and it
                    # does not belong next to things that were verified, so it stays switched off.
                    destination, route = ("01" if group == "00" else "06"), "待测"
                    moved["unverified"] += 1
            elif kind == "playable":
                destination, route = group, "直连"
            elif kind == "untested":
                destination, route = group, "待测"
            else:
                destination, route = group, (site.get("_route") or "待测")

            site["_route"] = route
            seen.add(site["key"])
            buckets[destination]["sites"].append(site)

    now = dt.datetime.now().timestamp()
    note = (f"重打包 {dt.date.today().isoformat()}：22 组并为 {len(ORDER)} 组；"
            "旧公共中转地址一律解包成源自己的地址（映匣不再依赖外部中继）；"
            "只有探测真出过字节的源才留在「可播」组，其余进默认关闭的失效组。")
    out = {"format": document.get("format", "yingxia-builtin"), "version": document.get("version", 1), "feeds": []}
    for key in ORDER:
        bucket = buckets[key]
        meta = GROUPS[key]
        count = len(bucket["sites"]) + len(bucket["lives"])
        if count == 0:
            continue
        address = f"builtin://yingxia-route-{key}"
        # `raw` keeps only the subscription-level settings. The source list lives once, at the top
        # level: copying it in here too cost 350 KB in the shipped pack and nothing reads it.
        raw = {"warning": [], "spider": [], "parses": [], "flags": [], "ijk": [], "_note": note}
        out["feeds"].append({
            "address": address,
            "name": f"{meta['name']}({count})",
            "enabled": meta["enabled"],
            "routing": meta["routing"],
            "document": {
                "origin": address,
                "importedAt": now,
                "sites": bucket["sites"],
                "lives": bucket["lives"],
                "raw": raw,
            },
        })

    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    if args.export_out:
        export = {
            "format": "yingxia-config",
            "version": 1,
            "exportedAt": now,
            "subscriptions": [
                {"rank": index, "entry": {"address": feed["address"], "name": feed["name"],
                                          "enabled": feed["enabled"], "routing": feed["routing"]},
                 "document": feed["document"]}
                for index, feed in enumerate(out["feeds"])
            ],
        }
        Path(args.export_out).write_text(json.dumps(export, ensure_ascii=False, separators=(",", ":")))
    total_sites = sum(len(feed["document"]["sites"]) for feed in out["feeds"])
    total_lives = sum(len(feed["document"]["lives"]) for feed in out["feeds"])
    print(f"feeds={len(out['feeds'])} sites={total_sites} lives={total_lives} "
          f"unwrapped={moved['unwrapped']} promoted={moved['promoted']} "
          f"demoted={moved['demoted']} unverified={moved['unverified']}")
    for feed in out["feeds"]:
        mark = "" if feed["enabled"] else "  (off)"
        print(f"  {feed['address'].rsplit('-', 1)[-1]}  {feed['name']:<24} {feed['routing']}{mark}")


if __name__ == "__main__":
    main()
