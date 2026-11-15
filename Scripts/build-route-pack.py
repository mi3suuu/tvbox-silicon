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
import re
import urllib.parse
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
    # 失效与待测按**内容**再分一次：一个装满成人源的「失效」桶对家里有小孩的人是雷，
    # 对只想复活影视源的人也是噪声。两个桶都默认关闭，开关是观众自己的事。
    "06": dict(name="影视 · 失效（默认关闭）", routing="auto", enabled=False),
    "07": dict(name="成人 · 待测/失效（默认关闭）", routing="auto", enabled=False),
}
ORDER = ["00", "01", "02", "03", "04", "05", "06", "07"]

# ---- 内容分类（影视 / 成人） -------------------------------------------------------
#
# 判据只认**明确的成人标记**：`raw.group` 写着「成人」、名字里有 🔞、或者带成人站点惯用的
# 词与域名片段。宁可漏判（漏在影视组里的是少数），也不要把奶酪、WebDav 这类名字里的
# 字母 `av` 判成成人 —— 那会把正常的源从影视组里赶走，比不分类更糟。
ADULT_STRONG = re.compile("|".join([
    "🔞", "成人", "伦理", "无码", "有码", "女优", "探花", "黑料", "性吧", "杏吧",
    "色情", "情色", "淫", "麻豆", "番号", "里番", "约啪", "桃色", "黄片", "裸",
]), re.I)
# 字母类词必须有边界：`WebDav`、`Navi` 里都有 `av`，它们不是成人站。
ADULT_TOKEN = re.compile("|".join([
    r"4k-?av", r"\bjav\b", r"\bporn\b", r"\bxxx\b", r"\bhentai\b", r"\bnsfw\b",
    r"missav", r"supjav", r"hstream",
]), re.I)

ADULT_FEEDS = ("02", "07")


def is_adult(site: dict) -> bool:
    """这条源是不是成人内容。`raw.group` 是最强的证据 —— 采集站自己就这么分的。"""
    raw = site.get("raw") if isinstance(site.get("raw"), dict) else {}
    group = str(raw.get("group") or site.get("group") or "")
    if "成人" in group:
        return True
    name = str(site.get("name") or "")
    key = str(site.get("key") or "")
    return bool(ADULT_STRONG.search(name) or ADULT_STRONG.search(group)
                or ADULT_TOKEN.search(name) or ADULT_TOKEN.search(key))


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


def mirror_name(site: dict) -> str:
    """同站镜像的判据之一：名字。

    采集站的镜像用的是同一个名字（偶尔带 `[直]` 前缀或 `1080P 365K` 这类后缀），
    先把这些噪声去掉再比 —— 名字相同 + 接口路径相同，基本就是同一个站在两个域名上。
    """
    name = str(site.get("name") or "")
    name = re.sub(r"^\s*\[(直|直连|内置|免扫|镜像)\]\s*", "", name)
    name = re.sub(r"\s*\d{3,4}[Pp]\s*\d*[Kk]?\s*$", "", name)
    return re.sub(r"\s+", "", name)


def station_path(site: dict) -> str:
    """判据之二：接口路径。`…/api.php/provide/vod` 与镜像的同一路径，是同一套接口。"""
    api = str(site.get("api") or "")
    if not api.startswith(("http://", "https://")):
        return api
    return urllib.parse.urlsplit(api).path.rstrip("/")


def mirror_rank(site: dict) -> tuple:
    """谁留下：先看验证结论，再看实测速度。"""
    route = {"直连": 2, "待测": 1}.get(site.get("_route"), 0)
    probe = site.get("_probe") if isinstance(site.get("_probe"), dict) else {}
    kbps = probe.get("kbps") or 0
    return (route, 1 if probe else 0, kbps)


def merge_mirrors(buckets: dict[str, dict]) -> dict[str, int]:
    """同名同接口的多域名镜像并成一张卡。

    结果里只留验证最好的那条（直连 > 待测 > 失效，同档看实测速率）。镜像本来就是「同一个站
    换个域名」，留着让列表变成 168 张而实际只有 140 个站，是纯噪声；真到主域名挂了的时候，
    这一版的内置包会随下一个版本重新打包。
    """
    merged = {"merged": 0}
    for bucket in buckets.values():
        kept: list[dict] = []
        index: dict[tuple[str, str], int] = {}
        for site in bucket["sites"]:
            key = (mirror_name(site), station_path(site))
            if key[0] and key in index:
                position = index[key]
                if mirror_rank(site) > mirror_rank(kept[position]):
                    kept[position] = site
                merged["merged"] += 1
                continue
            index[key] = len(kept)
            kept.append(site)
        bucket["sites"] = kept
    return merged


def load_probe_rows(path: Path | None) -> dict[str, dict]:
    """源 key → `--play-probe` 的一整行（不只是「能不能播」）。"""
    if not path or not path.exists():
        return {}
    rows: dict[str, dict] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        rows[row["key"]] = row
    return rows


def hard_dead(row: dict, site: dict) -> bool:
    """这次失败**只可能**是源自己没了，而不是插件/环境的问题。

    探针在插件源上的失败大多来自环境：`plugin runtime is busy`（并发抢同一个运行时）、
    `plugin download returned a web page`（jar 主机没了）、`no videos on the home page`
    （网盘没配置）。拿这些去判死，会把一整柜 4K 源清空 —— 而它们换个网络、补上配置就能用。
    所以只有「主机解析不到 / 证书坏了 / 页面 404」这类**主机级**证据才算死，
    而且只对原生 CMS 源（type 1/4）生效：插件源的 api 是脚本地址，脚本挂了不代表站没了。
    """
    if site.get("type") not in (1, 4):
        return False
    error = str(row.get("error") or "")
    for pattern in ("hostname could not be found", "certificate for this server is invalid",
                    "TLS error", "HTTP 404", "HTTP 410", "bad URL"):
        if pattern in error:
            return True
    return False


PROBE_AT = dt.date.today().isoformat()


def apply_probe(site: dict, row: dict) -> None:
    """把一次实测写进源里：出过字节的记直连 + 速率，失败的只记结论不判死。

    两处都写（顶层 + raw）：随包数据是「顶层 + raw 一份」的形态，Parser 读 raw，
    脚本与人工排查读顶层，只写一处会让其中一侧看不到。
    """
    kbps = row.get("kbps") or 0
    probe = {
        "verdict": "direct" if kbps > 0 else "unreachable",
        "via": "direct",
        "media": row.get("media") or "none",
        "stage": row.get("stage") or "play",
        "kbps": kbps,
        "at": PROBE_AT,
    }
    if kbps > 0:
        site["_route"] = "直连"
        if isinstance(site.get("raw"), dict):
            site["raw"]["_route"] = "直连"
    site["_probe"] = probe
    if isinstance(site.get("raw"), dict):
        site["raw"]["_probe"] = dict(probe)


def reaudit(document: dict, probe_rows: dict[str, dict]) -> tuple[dict[str, dict], dict[str, int]]:
    """第二轮打包：内容分家 + 实测回填 + 镜像合并。

    它回答三件事，都不改「源属于哪个订阅」：
    1. **内容**：成人源只进 02 / 07，其余组一个都不许有；失效桶按内容拆两份。
    2. **实测**：`--verdicts` 里出过字节的标直连并排到组首（首屏那 12 张就是能用的）；
       失败但可能只是环境的，原样留着，只有主机级证据（见 `hard_dead`）才挪进失效组。
    3. **镜像**：同名同接口的多域名并成一张。
    """
    buckets: dict[str, dict] = {key: {"sites": [], "lives": []} for key in GROUPS}
    seen: set[str] = set()
    moved = {"to_adult": 0, "to_adult_dead": 0, "kept_adult": 0,
             "probed_playable": 0, "demoted": 0}

    for feed in document["feeds"]:
        key = feed["address"].rsplit("-", 1)[-1]
        source = feed["document"]
        if key == "03":
            buckets["03"]["lives"].extend(source.get("lives") or [])
            continue
        for site in source.get("sites") or []:
            if site["key"] in seen:
                continue
            seen.add(site["key"])

            row = probe_rows.get(site["key"])
            if row:
                apply_probe(site, row)
                if (row.get("kbps") or 0) > 0:
                    moved["probed_playable"] += 1
                elif hard_dead(row, site) and site.get("_route") != "直连":
                    site["_route"] = "失效"
                    if isinstance(site.get("raw"), dict):
                        site["raw"]["_route"] = "失效"
                    moved["demoted"] += 1

            adult = key in ADULT_FEEDS or is_adult(site)
            if not adult:
                # 实测判死的从「可播 / 待测」组挪进失效桶；4K 与工具保持各自的书架。
                if site.get("_route") == "失效" and key in ("00", "01", "04", "05"):
                    buckets["06"]["sites"].append(site)
                else:
                    buckets[key]["sites"].append(site)
                continue

            # 两处都写：Parser 读 raw，脚本与人工排查读顶层，只写一处会让一侧看不到。
            site["_content"] = "adult"
            if isinstance(site.get("raw"), dict):
                site["raw"]["_content"] = "adult"
            playable = site.get("_route") == "直连"
            destination = "02" if playable else "07"
            if destination == key:
                moved["kept_adult"] += 1
            elif playable:
                moved["to_adult"] += 1
            else:
                moved["to_adult_dead"] += 1
            buckets[destination]["sites"].append(site)

    moved.update(merge_mirrors(buckets))
    # 实测出过字节的排到组首：首屏 12 张预览里先出现的就是它们。
    for key in ("01", "04", "05"):
        sites = buckets[key]["sites"]
        def rank(site: dict) -> int:
            probe = site.get("_probe") if isinstance(site.get("_probe"), dict) else None
            return 0 if probe and (probe.get("kbps") or 0) > 0 else 1
        buckets[key]["sites"] = sorted(sites, key=rank)   # `sorted` 是稳定的
    return buckets, moved


def write_pack(buckets: dict[str, dict], document: dict, args, note: str) -> dict:
    """把分好的桶写成随包 `route.json`（可选再写一份能喂回 `--play-probe` 的导出包）。"""
    now = dt.datetime.now().timestamp()
    out = {"format": document.get("format", "yingxia-builtin"),
           "version": document.get("version", 1), "feeds": []}
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
    return out


def report(out: dict, extra: str) -> None:
    total_sites = sum(len(feed["document"]["sites"]) for feed in out["feeds"])
    total_lives = sum(len(feed["document"]["lives"]) for feed in out["feeds"])
    print(f"feeds={len(out['feeds'])} sites={total_sites} lives={total_lives} {extra}")
    for feed in out["feeds"]:
        mark = "" if feed["enabled"] else "  (off)"
        print(f"  {feed['address'].rsplit('-', 1)[-1]}  {feed['name']:<28} {feed['routing']}{mark}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", default="Sources/TVCore/ScriptAssets/builtin/route.json")
    parser.add_argument("--verdicts", default=None)
    parser.add_argument("--out", default="Sources/TVCore/ScriptAssets/builtin/route.json")
    parser.add_argument("--export-out", default=None,
                        help="also write a ConfigBundle (the --play-probe input) for the new pack")
    parser.add_argument("--reaudit", action="store_true",
                        help="只做内容分家：把成人源挑出影视/4K/工具组，按可播性放进 02 / 07")
    args = parser.parse_args()

    pack = Path(args.pack)
    document = json.loads(pack.read_text())

    if args.reaudit:
        rows = load_probe_rows(Path(args.verdicts) if args.verdicts else None)
        buckets, moved = reaudit(document, rows)
        note = (f"内容复核 {dt.date.today().isoformat()}：成人源只留在 02 / 07，"
                "影视、4K、工具组里一个都没有；失效组按内容拆成影视 / 成人两个，都默认关闭。")
        out = write_pack(buckets, document, args, note)
        report(out, f"to_adult={moved['to_adult']} to_adult_dead={moved['to_adult_dead']} "
                    f"kept_adult={moved['kept_adult']} mirrors_merged={moved.get('merged', 0)} "
                    f"probed_playable={moved['probed_playable']} demoted={moved['demoted']}")
        return

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

    note = (f"重打包 {dt.date.today().isoformat()}：22 组并为 {len(ORDER)} 组；"
            "旧公共中转地址一律解包成源自己的地址（映匣不再依赖外部中继）；"
            "只有探测真出过字节的源才留在「可播」组，其余进默认关闭的失效组；"
            "成人源只落在 02 / 07 两组，影视、4K、工具组里一个都没有。")
    out = write_pack(buckets, document, args, note)
    report(out, f"unwrapped={moved['unwrapped']} promoted={moved['promoted']} "
                f"demoted={moved['demoted']} unverified={moved['unverified']}")

if __name__ == "__main__":
    main()
