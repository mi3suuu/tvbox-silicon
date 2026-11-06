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
    cmd = ['curl', '-s', '-L', '--max-time', str(timeout), '-r', f'0-{nbytes - 1}']
    for h in (headers or []):
        cmd += ['-H', h]
    cmd.append(url)
    return subprocess.run(cmd, capture_output=True).stdout


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
            base = url.rsplit('/', 1)[0] + '/'
            blob2 = fetch(url, ['User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                                f'Referer: {base}'])
            kind2 = classify(blob2)
            if kind2 in ('hls', 'mp4', 'mpegts', 'isobmff'):
                kind = kind2 + '（需 header）'
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
