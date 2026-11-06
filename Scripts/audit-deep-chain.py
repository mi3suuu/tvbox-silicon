#!/usr/bin/env python3
"""订阅 → 列表 → 详情 → 播放解析 深度审计（补 audit-source-loading.py 只测 home/search 的缺口）。

上游脚本第 3 行自己写了 "No playback or login actions"，所以它证明不了「点进去能不能播」。
这个脚本复用它的 Session（同一套 host 启动逻辑），多跑两阶段：

    detail   {ac: 'detail', ids: <首页第一条的 id>}
    play     {ac: 'play',  flag/play: <详情第一条剧集的 key>}   ← 支持则测，不支持则记 skipped

用法：
    Scripts/audit-deep-chain.py build/audit-snap/yingxia.json --output build/audit-deep
    Scripts/audit-deep-chain.py <snap> --limit 2
"""
import argparse, importlib.util, json, pathlib, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_audit_module():
    spec = importlib.util.spec_from_file_location(
        'audit_source_loading', ROOT / 'Scripts/audit-source-loading.py')
    mod = importlib.util.module_from_spec(spec)
    old, sys.argv = sys.argv, ['audit-source-loading']
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = old
    return mod


def first_video(listing):
    for v in (listing or {}).get('list') or []:
        if v.get('vod_id') is not None:
            return v
    return None


def first_episode(detail):
    """TVBox 的剧集藏在 vod_play_url：`名$key#名$key`，多线路用 $$$ 分隔。"""
    v = (detail or {}).get('list', [{}])[0]
    raw = v.get('vod_play_url') or ''
    if not raw:
        return None, None
    line = raw.split('$$$')[0]
    for part in line.split('#'):
        if '$' in part:
            name, key = part.rsplit('$', 1)
            if key:
                return name, key
    return None, None


def verify_now(url, header, play):
    """在拿到地址的当下就判断它是不是真媒体。返回 {kind, http, note}。"""
    # multi 型（多清晰度）是数组，取第一个可用的
    if isinstance(url, list):
        picked = None
        for item in url:
            cand = item.get('url') if isinstance(item, dict) else item
            if isinstance(cand, str) and cand.startswith(('http://', 'https://')):
                picked = cand
                break
        url = picked
    if not isinstance(url, str) or not url.startswith(('http://', 'https://')):
        return {'kind': 'no-url'}
    if str(url).startswith('http://127.0.0.1:'):
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(url).query)
        inner = (q.get('url') or [None])[0]
        if not inner:
            return {'kind': 'proxy-no-inner'}
        url = inner
    hdrs = dict(header) if isinstance(header, dict) else {}
    if play.get('UA'):
        hdrs['User-Agent'] = play['UA']
    # body 和状态码必须分开取：body 里也有换行，rpartition 会错位（踩过）
    cmd = ['curl', '-s', '-L', '--max-time', '15', '-r', '0-511',
           '-w', '\n---STATUS:%{http_code}---']
    for k, v in hdrs.items():
        cmd += ['-H', f'{k}: {v}']
    out = subprocess.run(cmd + [url], capture_output=True).stdout
    marker = b'\n---STATUS:'
    if marker in out:
        body, _, tail = out.rpartition(marker)
        code = tail.split(b'---')[0].decode(errors='replace')
    else:
        body, code = out, '?'
    return {'kind': classify_media(body), 'http': code}


def classify_media(blob):
    """判响应是不是媒体。顺序很重要：先认二进制魔数，再判文本。
    踩过：先判 `b'<head' in head[:100]` 会把 mp4 的二进制误判成 HTML（avc1/moov 里含这些字节）。"""
    if not blob:
        return 'empty'
    # ① 强魔数先判，二进制优先
    if blob.startswith(b'#EXTM3U'):
        return 'hls'
    if b'ftyp' in blob[:16]:
        return 'mp4'
    if len(blob) > 376 and blob[0] == 0x47 and blob[188] == 0x47:
        return 'mpegts'
    if len(blob) >= 8 and blob[4:8] in (b'ftyp', b'moov', b'mdat', b'styp'):
        return 'isobmff'
    # ISOBMFF 盒子里常见的 box 类型（avc1/avcC/stsd/hdlr/moov 等）
    if any(tag in blob[:512] for tag in (b'avc1', b'avcC', b'moov', b'mdat', b'stsd', b'hdlr', b'stbl')):
        return 'isobmff'
    # ② 再判文本
    head = blob[:200].lstrip().lower()
    if head.startswith(b'<!doctype') or head.startswith(b'<html') or head.startswith(b'<head'):
        return 'html'
    if b'<html' in head[:120] or b'<!doctype' in head[:120]:
        return 'html'
    if len(blob) < 200 and all(32 <= b < 127 or b in (9, 10, 13) for b in blob):
        return 'text-error'
    return 'unknown'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('snapshots', nargs='+')
    ap.add_argument('--output', required=True)
    ap.add_argument('--limit', type=int)
    args = ap.parse_args()

    mod = load_audit_module()
    out = pathlib.Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []

    for path in args.snapshots:
        cfg = json.loads(pathlib.Path(path).read_text())
        sites = [s['raw'] for s in cfg['sites']]
        if args.limit:
            sites = sites[:args.limit]
        for i, site in enumerate(sites):
            ident = f"{pathlib.Path(path).stem}-{i:03d}"
            folder = out / ident
            folder.mkdir(exist_ok=True)
            rec = {'id': ident, 'key': site.get('key'), 'name': site.get('name')}
            # 站点级 header，App 会并入播放请求头（Catalog.swift:421）
            rec['_site_header'] = site.get('header')
            t0 = time.monotonic()
            session = None
            try:
                session = mod.Session(site, cfg, folder)
                rec['initialized'] = True

                home = session.call({'filter': 'true'} if site.get('type') == 4 else {}, 'home')
                rec['home'] = {'videos': len(home.get('list') or [])}
                v = first_video(home)
                if not v:
                    rec['detail'] = {'skipped': 'home 没有可用的 vod_id'}
                else:
                    d = session.call({'ac': 'detail', 'ids': v['vod_id']}, 'detail')
                    dv = first_video(d)
                    raw_play = (dv or {}).get('vod_play_url') or ''
                    rec['detail'] = {
                        # vod_name 可能为 None 或空串（立播 / 比特 实测如此），不能拿它当成功判据
                        'name': (dv or {}).get('vod_name'),
                        'play_from': (dv or {}).get('vod_play_from'),
                        'episodes': len(raw_play.split('#')) if raw_play else 0,
                        'has_play_url': bool(raw_play),
                    }
                    ep_name, ep_key = first_episode(d)
                    if not ep_key:
                        rec['play'] = {'skipped': '详情里没有剧集 key'}
                    else:
                        try:
                            p = session.call({'ac': 'play', 'flag': (dv or {}).get('vod_play_from', '').split('$$$')[0],
                                              'play': ep_key, 'id': v['vod_id']}, 'play')
                            # url 有三种形态，不能一律 str() 截断：
                            #   字符串       —— 单清晰度
                            #   数组         —— 多清晰度 [{'name':'清晰 480P','url':...}, …]（PlaybackResolution.swift 负责挑）
                            #   127.0.0.1:*  —— App 内置代理，审计进程退出后即失效
                            raw_url = p.get('url')
                            if isinstance(raw_url, list):
                                first = raw_url[0] if raw_url else {}
                                kind = 'multi'
                                head = str(first.get('url') if isinstance(first, dict) else first)[:100]
                            elif isinstance(raw_url, str):
                                kind = 'proxy' if raw_url.startswith('http://127.0.0.1:') else 'direct'
                                head = raw_url[:120]
                            else:
                                kind, head = 'none', ''
                            # play 还可能带这些字段，App 侧都要用，审计必须记下来：
                            #   playUrl —— 站点级前缀（Catalog.swift:432/480），拼在最终地址前
                            #   header  —— 请求头，很多源必须带 Referer/UA 才出流
                            #   danmaku —— 弹幕地址
                            hdr = p.get('header')
                            rec['play'] = {'episode': ep_name,
                                           'parse': p.get('parse'),
                                           'kind': kind,
                                           'is_array': isinstance(raw_url, list),
                                           'url': head,
                                           'has_header': bool(hdr),
                                           'header_keys': sorted(hdr) if isinstance(hdr, dict) else [],
                                           'playUrl': p.get('playUrl') or None,
                                           'has_danmaku': bool(p.get('danmaku')),
                                           # 原始值，供 audit-playback-media.py 按 App 逻辑重放
                                           '_header_raw': hdr,
                                           '_ua': p.get('UA') or p.get('ua') or None}
                            # 立刻验媒体：地址可能带时效签名，事后批量校验会失败，所以在这一刻就判。
                            # 注意必须传**完整** raw_url，不能传 head —— head 是截断到 120 字符的展示用值，
                            # 截断后签名不完整，一定 403（踩过，查了三轮才定位）。
                            rec['play']['verified'] = verify_now(raw_url, hdr, p)
                        except Exception as e:
                            rec['play'] = {'error': str(e)[:300]}
            except Exception as e:
                rec['initializationError'] = str(e)[:300]
            finally:
                if session:
                    session.close()
            rec['seconds'] = round(time.monotonic() - t0, 1)
            results.append(rec)
            print(json.dumps(rec, ensure_ascii=False), flush=True)

    (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))

    # 汇总
    # 判据说明：detail 阶段「成功」不等于 vod_name 非空。
    #   立播 实测 vod_name=""，比特 实测 vod_name=None —— 但两者都能取到播放地址。
    #   所以按「拿到了可解析的剧集 key」判定，而不是看标题。
    ok_play = [r for r in results if (r.get('play') or {}).get('url')]
    ok_detail = [r for r in results if 'skipped' not in (r.get('detail') or {})
                 and 'error' not in (r.get('detail') or {})]
    print(f"\n深度链：详情可解析 {len(ok_detail)}/{len(results)} ｜ 播放解析成功 {len(ok_play)}/{len(results)}")
    kinds = {}
    for r in results:
        p = r.get('play') or {}
        if p.get('url'):
            kinds[p.get('kind', '?')] = kinds.get(p.get('kind', '?'), 0) + 1
            print(f"  ✓ {r['key']}: parse={p.get('parse')} [{p.get('kind')}] {str(p.get('url'))[:56]}")
    if kinds:
        print("  形态分布:", kinds)


if __name__ == '__main__':
    main()
