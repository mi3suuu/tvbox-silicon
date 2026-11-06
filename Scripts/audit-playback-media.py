#!/usr/bin/env python3
"""验证 play 返回的地址是否真的是媒体（而不只是 HTTP 200）。

为什么必须有这一步：
    HTTP 200 完全可能是 HTML 网页、`need sign info` 之类的错误页。
    只看状态码会把「拿到了网页」当成「能播放」。
    2026-11-06 实测：17 个「解析成功」里只有 4 个是真的媒体流。

判据（看响应前若干字节）：
    HLS     以 `#EXTM3U` 开头
    MP4/ISOBMFF  前 12 字节含 `ftyp`
    其他二进制   前 4 字节是 size box 且含非常见文本
    HTML/错误页  其余一律判否

用法：
    Scripts/audit-playback-media.py build/audit-deep/results.json
    Scripts/audit-playback-media.py results.json --headers   # 也试带 UA/Referer
"""
import argparse, json, pathlib, subprocess, sys

MAGIC_TS = (b'\x47',)  # 188-byte MPEG-TS 包以 0x47 起头


def fetch(url, headers=None, timeout=12, nbytes=512):
    """headers 可以是 list['k: v'] 或 dict。App 侧（Catalog.swift:421-431）会合并三处：
    site.raw['header']、play 返回的 result['header']（dict 或 JSON 字符串）、result['UA']。
    这里接受 dict，就是照抄 App 的合并结果。"""
    cmd = ['curl', '-s', '-L', '--max-time', str(timeout), '-r', f'0-{nbytes - 1}']
    items = headers.items() if isinstance(headers, dict) else [(None, h) for h in (headers or [])]
    for k, v in items:
        cmd += ['-H', f'{k}: {v}' if k else str(v)]
    cmd.append(url)
    return subprocess.run(cmd, capture_output=True).stdout


def replay_headers(rec):
    """按 App 的三处合并逻辑拼出请求头。"""
    hdrs = {}
    site = rec.get('_site_header')
    if isinstance(site, dict):
        hdrs.update({k: v for k, v in site.items() if isinstance(v, str)})
    pl = rec.get('play') or {}
    ph = pl.get('_header_raw')
    if isinstance(ph, dict):
        hdrs.update({k: v for k, v in ph.items() if isinstance(v, str)})
    elif isinstance(ph, str):
        try:
            parsed = json.loads(ph)
            if isinstance(parsed, dict):
                hdrs.update({k: v for k, v in parsed.items() if isinstance(v, str)})
        except Exception:
            pass
    if pl.get('_ua'):
        hdrs['User-Agent'] = pl['_ua']
    return hdrs


def classify(blob):
    if not blob:
        return 'empty'
    if blob.startswith(b'#EXTM3U'):
        return 'hls'
    if b'ftyp' in blob[:16]:
        return 'mp4'
    head = blob[:200].lstrip().lower()
    if head.startswith(b'<!doctype') or head.startswith(b'<html') or b'<head' in head[:100]:
        return 'html'
    # 明确的错误文本（很短且无二进制）
    if len(blob) < 200 and all(32 <= b < 127 or b in (9, 10, 13) for b in blob):
        return 'text-error: ' + blob[:40].decode('utf-8', 'replace').strip()
    # MPEG-TS：多个 188 字节包都以 0x47 起始
    if len(blob) > 376 and blob[0] == 0x47 and blob[188] == 0x47:
        return 'mpegts'
    if len(blob) >= 8 and blob[4:8] in (b'ftyp', b'moov', b'mdat', b'styp'):
        return 'isobmff'
    return 'unknown:' + blob[:24].hex()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('results', nargs='+')
    ap.add_argument('--headers', action='store_true', help='同时试带 UA/Referer')
    args = ap.parse_args()

    rows = []
    for p in args.results:
        rows += json.loads(pathlib.Path(p).read_text())

    playable, notplayable = [], []
    for r in rows:
        pl = r.get('play') or {}
        url = pl.get('url')
        if not url or not str(url).startswith(('http://', 'https://')):
            continue
        if str(url).startswith('http://127.0.0.1:'):
            # 插件代理：进程已退出，只能解出内层地址来判
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(url).query)
            inner = (q.get('url') or [None])[0]
            if not inner:
                notplayable.append((r['key'], 'proxy-no-inner', ''))
                continue
            url = inner
        blob = fetch(url)
        kind = classify(blob)
        if args.headers and kind not in ('hls', 'mp4', 'mpegts', 'isobmff'):
            # ① 先按 App 的真实合并逻辑重放（site.header + play.header + UA）
            app_hdrs = replay_headers(r)
            if app_hdrs:
                k2 = classify(fetch(url, app_hdrs))
                if k2.startswith(('hls', 'mp4', 'mpegts', 'isobmff')):
                    kind = k2 + '（需 App header）'
            # ② 再用通用 UA+Referer 兜底
            if not kind.startswith(('hls', 'mp4', 'mpegts', 'isobmff')):
                base = url.rsplit('/', 1)[0] + '/'
                k3 = classify(fetch(url, ['User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                                          f'Referer: {base}']))
                if k3.startswith(('hls', 'mp4', 'mpegts', 'isobmff')):
                    kind = k3 + '（需 UA+Referer）'
        ok = kind.startswith(('hls', 'mp4', 'mpegts', 'isobmff'))
        (playable if ok else notplayable).append((r['key'], kind, url[:60]))

    print(f"真·可播 {len(playable)} / 有地址 {len(playable) + len(notplayable)}\n")
    if playable:
        print("可播：")
        for k, kind, u in playable:
            print(f"  ✓ {str(k)[:14]:<14} {kind:<18} {u}")
    if notplayable:
        print("\n有地址但不是媒体：")
        for k, kind, u in notplayable:
            print(f"  ✗ {str(k)[:14]:<14} {kind:<40} {u}")
    return 0 if playable else 1


if __name__ == '__main__':
    sys.exit(main())
