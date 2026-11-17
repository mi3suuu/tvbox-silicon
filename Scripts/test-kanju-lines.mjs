#!/usr/bin/env node
// 看剧AI 选线的行为测试（不需要 App、不需要网络）。
//
// 它跑的是**仓库里那份真脚本** `Sources/TVCore/ScriptAssets/js/kanju.js`，
// 只把 `globalThis.req / local / joinUrl` 换成假的 —— 这三个正是 prelude 提供的东西。
//
//   node Scripts/test-kanju-lines.mjs
//
// 覆盖的四件事故（都真实发生过）：
//   A 线路表偶尔回空 → 以前直接当「这集没线路」，用户得切到第二集再切回来
//   B 这一集没有 4K 线 → 以前**悄悄**播放普通线，屏幕上还写着「官方4K」
//   C 播过一次普通线之后，官方线解成功会抛 TypeError（goodProvider 被写成了字符串）
//   D 第一条 4K 线的 CDN 连不上 → 应当换下一条，而不是把死地址交给播放器
//   E 额度用尽 → 说清是额度，不要含糊地叫用户「再试一次」

import { pathToFileURL } from 'node:url';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const asset = join(here, '..', 'Sources', 'TVCore', 'ScriptAssets', 'js', 'kanju.js');

const ordinary = (id, host, weight) => ({
  provider_id: id, provider_name: '普通-' + id, resolve_mode: 'direct',
  url: 'https://' + host + '/' + id + '/index.m3u8', preference_weight: weight,
});
const official = (id, name, ticket, weight) => ({
  provider_id: id, provider_name: name, resolve_mode: 'parse',
  url: 'resolve://' + ticket, preference_weight: weight,
});

let emptyOnce = true;
let quota = false;

const TABLES = {
  tokenA: () => [official('o1', '1080P-官方S', 'tk-1080', 999), ordinary('p1', 'cdn.good', 900)],
  tokenB: () => [official('o1', '1080P-官方S', 'tk-1080', 999), ordinary('p1', 'cdn.good', 900)],
  tokenC: () => [ordinary('p1', 'cdn.good', 900), ordinary('p2', 'cdn.dead', 950)],
  tokenD: () => [official('o1', '1080P-官方S', 'tk-1080', 999)],
  tokenE: () => [official('k1', '4K海外-官方C', 'tk-4k-bad', 996),
                 official('k2', '专享4K-Y', 'tk-4k-good', 995)],
  tokenF: () => [official('k1', '专享4K-Y', 'tk-quota', 995)],
  // 探不出结论（连接超时/被断）的 4K 线：它不是「死」，但要给确认能出字节的那条让位。
  tokenG: () => [official('g1', '4K海外-官方G', 'tk-4k-silent', 996),
                 official('g2', '专享4K-G', 'tk-4k-good2', 995)],
  tokenH: () => [official('h1', '专享4K-H', 'tk-4k-silent2', 995)],
};

const requests = [];

globalThis.local = {
  data: {},
  get(g, k) { return this.data[g + ':' + k] ?? ''; },
  set(g, k, v) { this.data[g + ':' + k] = String(v); },
  delete(g, k) { delete this.data[g + ':' + k]; },
};
globalThis.joinUrl = (parent, child) => new URL(child, parent).href;

const playlist = '#EXTM3U\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nseg2.ts\n';

globalThis.req = (url, options = {}) => {
  const address = String(url);
  requests.push({ url: address, method: options.method || 'GET' });

  const table = /\/v1\/playback\/resolve\/([^?]+)/.exec(address);
  if (table) {
    const token = decodeURIComponent(table[1]);
    if (token === 'tokenA' && emptyOnce) { emptyOnce = false; return { code: 200, headers: {}, content: '{"line_options":[]}' }; }
    const build = TABLES[token];
    return { code: 200, headers: {}, content: JSON.stringify({ line_options: build ? build() : [] }) };
  }
  if (address.includes('/v1/playback/resolve-line')) {
    if (quota) return { code: 402, headers: {}, content: '{"code":"insufficient_tokens"}' };
    let ticket = '';
    try { ticket = JSON.parse(options.body || '{}').ticket || ''; } catch (e) {}
    const signed = {
      'tk-1080': 'https://cdn.good/official.m3u8',
      'tk-4k-bad': 'https://cdn.blocked/4k.m3u8',
      'tk-4k-good': 'https://cdn.good/4k.m3u8',
      'tk-quota': 'https://cdn.good/quota.m3u8',
      'tk-4k-silent': 'https://cdn.silent/4k.m3u8',
      'tk-4k-silent2': 'https://cdn.silent/other.m3u8',
      'tk-4k-good2': 'https://cdn.good/4k2.m3u8',
    }[ticket];
    if (!signed) return { code: 400, headers: {}, content: '{"code":"invalid_public_playback_id"}' };
    return { code: 201, headers: {}, content: JSON.stringify({ line: { url: signed } }) };
  }
  if (address.includes('/v1/users/anonymous')) {
    return { code: 429, headers: {}, content: '{"error":"request_error"}' };
  }
  if (address.includes('cdn.blocked')) return { code: 403, headers: {}, content: '' };
  // code 0 = 没拿到答复（prelude 在连接失败/超时时就是这样），既不是活也不是死。
  if (address.includes('cdn.silent')) return { code: 0, headers: {}, content: '' };
  if (address.includes('cdn.dead')) return { code: 502, headers: {}, content: '' };
  if (address.includes('.m3u8')) return { code: 206, headers: {}, content: playlist };
  if (address.endsWith('seg1.ts') || address.endsWith('seg2.ts')) return { code: 206, headers: {}, content: '\u0000' };
  return { code: 200, headers: {}, content: '{}' };
};

const { default: spider } = await import(pathToFileURL(asset).href);

let failures = 0;
function check(name, ok, detail) {
  console.log((ok ? 'PASS  ' : 'FAIL  ') + name + (detail ? '  — ' + detail : ''));
  if (!ok) failures += 1;
}

// A. 线路表第一次为空，第二次有内容
const beforeA = requests.length;
spider.warm('官方1080', 'p|tokenA');
const tableCalls = requests.slice(beforeA).filter(r => r.url.includes('/v1/playback/resolve/')).length;
check('A 线路表回空时自动重试', tableCalls === 2, '请求了 ' + tableCalls + ' 次');

// B. 这一集没有 4K 线
const no4k = spider.play('官方4K', '4|tokenB');
check('B 没有 4K 线时给出原因', !!no4k.errMsg, JSON.stringify(no4k));
check('B 没有偷偷换成普通线', !no4k.url, JSON.stringify(no4k.url || ''));

// C. 先播普通线，再解官方 1080
const plain = spider.play('普通', 'o|tokenC');
check('C 普通线能播（顺带把 goodOrdinary 记住）', !!plain.url, String(plain.url || ''));
const hd = spider.play('官方1080', 'p|tokenD');
check('C 之后官方线仍能解出（goodProvider 没被写坏）', !!hd.url, JSON.stringify(hd));

// D. 第一条 4K 线签名成功但 CDN 403
const fourK = spider.play('官方4K', '4|tokenE');
check('D 跳过连不上的 4K 线，用下一条', fourK.url === 'https://cdn.good/4k.m3u8', JSON.stringify(fourK));

// D2. 第一条 4K 线探不出结论，第二条确认能出字节
const silent = spider.play('官方4K', '4|tokenG');
check('D2 探不出结论的 4K 线给确认可播的那条让位', silent.url === 'https://cdn.good/4k2.m3u8', JSON.stringify(silent));

// D3. 只有一条、且探不出结论 → 仍然用它（比什么都不给强）
const onlySilent = spider.play('官方4K', '4|tokenH');
check('D3 只剩一条探不出结论的线时仍然交出去', onlySilent.url === 'https://cdn.silent/other.m3u8', JSON.stringify(onlySilent));

// E. 额度用尽
quota = true;
const out = spider.play('官方4K', '4|tokenF');
check('E 额度用尽时说清是额度', /额度/.test(out.errMsg || ''), JSON.stringify(out));
check('E 额度用尽时不退回普通线', !out.url, String(out.url || ''));

console.log(failures ? '\n' + failures + ' 项未通过' : '\n全部通过');
process.exit(failures ? 1 : 0);
