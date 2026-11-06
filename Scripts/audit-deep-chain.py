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
import argparse, importlib.util, json, pathlib, sys, time

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
                    rec['detail'] = {
                        'name': (dv or {}).get('vod_name'),
                        'play_from': (dv or {}).get('vod_play_from'),
                        'episodes': len(((dv or {}).get('vod_play_url') or '').split('#')),
                    }
                    ep_name, ep_key = first_episode(d)
                    if not ep_key:
                        rec['play'] = {'skipped': '详情里没有剧集 key'}
                    else:
                        try:
                            p = session.call({'ac': 'play', 'flag': (dv or {}).get('vod_play_from', '').split('$$$')[0],
                                              'play': ep_key, 'id': v['vod_id']}, 'play')
                            rec['play'] = {'episode': ep_name,
                                           'parse': p.get('parse'),
                                           'url': str(p.get('url'))[:120]}
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
    ok_play = [r for r in results if (r.get('play') or {}).get('url')]
    ok_detail = [r for r in results if (r.get('detail') or {}).get('name')]
    print(f"\n深度链：详情成功 {len(ok_detail)}/{len(results)} ｜ 播放解析成功 {len(ok_play)}/{len(results)}")


if __name__ == '__main__':
    main()
