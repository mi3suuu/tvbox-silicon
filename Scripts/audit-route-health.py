#!/usr/bin/env python3
"""体检随包源：直连能不能用、封面是不是灰的、哪些源其实只有境外出口能读。

为什么需要它
============
149 那台公共中继拆掉之后，一批源从「经中转」变成「直连」。但**解包只改地址，不改网络**：
当初它们走中转，很多正是因为本机连不上（TLS 握手被网关打断、空回复、403 按地域拒）。
拆掉中转之后，它们并不会自己好起来 —— 而 `route.json` 里如果还写着「直连」，
源列表就会把一个点进去必然失败的源摆在「可播」里。这个脚本把这件事测出来。

`--relay` 那一路不是为了让 App 依赖它
------------------------------------
旧中继**只作诊断出口**：`/cms/<token>/<host>/<path>` 把请求从境外发出去，用来回答
「这个站还活着吗，还是只是我这台机器到不了」。它不产生任何运行期依赖 ——
App 里的替代品是观众自己的出口代理（`CustomProxyStore.fallbackEndpoint`），
这条路走的是 `LocalProxyServer` 回环中继，和这里测的是同一个问题。

用法
====
    python3 Scripts/audit-route-health.py                     # 全量 type 1
    python3 Scripts/audit-route-health.py --feeds 00 02       # 只看这两组
    python3 Scripts/audit-route-health.py --posters           # 顺带测封面图
    python3 Scripts/audit-route-health.py --json out.json     # 机器可读

输出四类，各对应一种修法：
    direct_ok          直连可用，什么都不用做
    proxy_only         直连不通、境外可读 → 标 `_route: 需代理`（App 会在有出口时代理）
    dead               两路都不通 → 标 `_route: 失效`
    poster_blocked     接口通、封面域名在本机被阻断 → 播得了、封面灰
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# 与 App 里发的 UA 一致：不少采集站按 UA 给不同的东西。
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
RELAY = "http://149.104.28.149:8100"
TOKEN = "rex8f3a2c1d"
DEFAULT_PACK = "Sources/TVCore/ScriptAssets/builtin/route.json"


def curl(url: str, timeout: int, headers: list[str] | None = None) -> tuple[int, str, int, bytes]:
    """(exit code, http code, bytes, head) —— exit code 比 http code 更能说明「为什么连不上」：
    35 = TLS 握手被中断，52 = 空回复，28 = 超时，6 = DNS。"""
    cmd = ["curl", "-sS", "-m", str(timeout), "-A", UA, "-o", "/tmp/_audit.bin",
           "-w", "%{http_code}|%{size_download}", url]
    for header in headers or []:
        cmd[1:1] = ["-H", header]
    done = subprocess.run(cmd, capture_output=True)
    code, _, size = done.stdout.decode().strip().partition("|")
    body = b""
    try:
        body = Path("/tmp/_audit.bin").read_bytes()
    except OSError:
        pass
    return done.returncode, code, int(size or 0), body[:120]


def has_json(rc: int, code: str, size: int, head: bytes) -> bool:
    return rc == 0 and code == "200" and size > 200 and head.lstrip().startswith(b"{")


def relay_address(api: str) -> str:
    parts = urllib.parse.urlsplit(api)
    prefix = "cms" if parts.scheme == "http" else "cmsr"
    query = f"?{parts.query}" if parts.query else ""
    return f"{RELAY}/{prefix}/{TOKEN}/{parts.netloc}{parts.path or '/'}{query}"


def with_param(url: str, extra: str) -> str:
    return url + ("&" if "?" in url else "?") + extra


def classify(site: dict, check_poster: bool) -> dict:
    api = site["api"]
    record = {"key": site["key"], "feed": site.get("_feed"), "name": site.get("name", ""),
              "api": api, "route": site.get("_route")}
    rc, code, size, head = curl(with_param(api, "ac=list"), 9)
    record["direct"] = "ok" if has_json(rc, code, size, head) else f"rc{rc}/{code}/{size}"
    rc2, code2, size2, head2 = curl(with_param(relay_address(api), "ac=list"), 20)
    record["relay"] = "ok" if has_json(rc2, code2, size2, head2) else f"rc{rc2}/{code2}/{size2}"

    direct_ok, relay_ok = record["direct"] == "ok", record["relay"] == "ok"
    if direct_ok:
        record["verdict"] = "direct_ok"
    elif relay_ok:
        record["verdict"] = "proxy_only"
    else:
        record["verdict"] = "dead"

    if check_poster and direct_ok:
        record["poster"] = poster_verdict(api, 9)
        if record["poster"] not in ("ok", "no_field", None):
            record["verdict"] = "poster_blocked"
    return record


def poster_verdict(api: str, timeout: int) -> str:
    """首页列表常常不带 `vod_pic`；缺就补一次 `ac=detail`（App 也是这么做的）。"""
    rc, code, size, _ = curl(with_param(api, "ac=list"), timeout)
    body = Path("/tmp/_audit.bin").read_bytes() if rc == 0 else b""
    pictures: list[str] = []
    try:
        listing = json.loads(body)
        pictures = [x["vod_pic"] for x in listing.get("list") or [] if x.get("vod_pic")]
        ids = [str(x["vod_id"]) for x in listing.get("list") or [] if x.get("vod_id") is not None][:8]
    except Exception:
        return "api_bad"
    if not pictures and ids:
        rc2, _, _, _ = curl(with_param(api, "ac=detail&ids=" + ",".join(ids)), timeout + 3)
        if rc2 == 0:
            try:
                detail = json.loads(Path("/tmp/_audit.bin").read_bytes())
                pictures = [x["vod_pic"] for x in detail.get("list") or [] if x.get("vod_pic")]
            except Exception:
                pass
    if not pictures:
        return "no_field"
    origin = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(api))
    pic = str(pictures[0])
    rc3, code3, size3, _ = curl(pic, timeout)
    if rc3 == 0 and code3.startswith("200") and size3 > 0:
        return "ok"
    # 带 Referer 再试一次：区分「图床防盗链」与「本机到不了」。
    rc4, code4, size4, _ = curl(pic, timeout, [f"Referer: {origin}/"])
    if rc4 == 0 and code4.startswith("200") and size4 > 0:
        return "needs_referer"
    return f"blocked:rc{rc3}/{code3 or rc4}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", default=DEFAULT_PACK)
    parser.add_argument("--feeds", nargs="*", help="只看这些组号（00 02 …）")
    parser.add_argument("--posters", action="store_true", help="顺带测封面图")
    parser.add_argument("--json", default=None)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    pack = json.loads(Path(args.pack).read_text())
    sites: list[dict] = []
    for feed in pack["feeds"]:
        key = feed["address"].rsplit("-", 1)[-1]
        if args.feeds and key not in args.feeds:
            continue
        for site in feed["document"]["sites"]:
            # 只有原生 CMS 的 api 是 URL；插件源（type 3）的 api 是类名，这条路测不了。
            if site.get("type") == 1:
                sites.append({**site, "_feed": key})

    print(f"{len(sites)} sources", file=sys.stderr)
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for record in pool.map(lambda s: classify(s, args.posters), sites):
            results.append(record)
            print(f"{record['verdict']:14s} {record['feed']} {record['key']}", file=sys.stderr)

    summary: dict[str, int] = {}
    for record in results:
        summary[record["verdict"]] = summary.get(record["verdict"], 0) + 1
    print("\n== 汇总")
    for verdict, count in sorted(summary.items(), key=lambda kv: -kv[1]):
        print(f"  {count:4d}  {verdict}")
    for verdict in ("proxy_only", "dead", "poster_blocked"):
        picked = [r for r in results if r["verdict"] == verdict]
        if picked:
            print(f"\n-- {verdict}（{len(picked)}）")
            for record in picked:
                print(f"  {record['feed']} {record['key']:28s} {record['name'][:18]:20s} {record['api'][:70]}")
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1))
        print(f"\nwritten {args.json}")


if __name__ == "__main__":
    main()
