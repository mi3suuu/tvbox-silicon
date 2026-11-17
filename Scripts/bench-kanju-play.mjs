#!/usr/bin/env node
// 看剧AI 首播前那段到底把时间花在哪 —— 真网络、真脚本、真签名。
//
//   node Scripts/bench-kanju-play.mjs [关键词] [--repeat 2]
//
// 它加载仓库里那份 `kanju.js`，只把 prelude 提供的 `req / local / joinUrl` 换成同步实现
// （curl，保持脚本原有的阻塞语义）。然后按 App 真实顺序走：
//   search → detail → warm（线路表）→ play（签名地址）
// 并把**每一次子请求**的 URL、耗时、状态码打出来 —— 首播快慢就取决于这张表。
//
// 判定：play 的耗时里，`/v1/playback/resolve/<token>`（线路表）与
// `/v1/playback/resolve-line`（签名）各占多少，`mediaAlive` 的 Range 探测又占多少。

import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const asset = join(here, '..', 'Sources', 'TVCore', 'ScriptAssets', 'js', 'kanju.js');

const calls = [];
let current = '';
/// 网络慢时把脚本自己的超时整体放大，好让测量拿到「到底要多久」而不是「9 秒被砍」。
const SCALE = Math.max(1, Number(process.env.KANJU_TIMEOUT_SCALE || 1));

// ---- prelude：同步 req（脚本按阻塞写） -------------------------------------------
globalThis.req = function req(url, options = {}) {
  const timeout = Math.max(1, Math.ceil(((options.timeout || 9000) * SCALE) / 1000));
  const args = ['-sS', '-i', '--max-time', String(timeout), '-X', options.method || 'GET'];
  for (const [k, v] of Object.entries(options.headers || {})) args.push('-H', `${k}: ${v}`);
  if (options.body != null) args.push('--data-binary', options.body);
  args.push(url);
  const started = Date.now();
  let raw = '';
  try {
    raw = execFileSync('curl', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  } catch (error) {
    const ms = Date.now() - started;
    calls.push({ stage: current, url, ms, code: 0, error: String(error.message || error).slice(0, 80) });
    return { code: 0, headers: {}, content: '' };
  }
  const ms = Date.now() - started;
  const split = raw.indexOf('\r\n\r\n');
  const head = split < 0 ? raw : raw.slice(0, split);
  const content = split < 0 ? '' : raw.slice(split + 4);
  const status = Number((head.match(/^HTTP\/[\d.]+ (\d+)/) || [])[1] || 0);
  const headers = {};
  for (const line of head.split(/\r?\n/).slice(1)) {
    const at = line.indexOf(':');
    if (at < 0) continue;
    const key = line.slice(0, at).trim().toLowerCase();
    const value = line.slice(at + 1).trim();
    headers[key] = headers[key] ? headers[key] + ', ' + value : value;
  }
  calls.push({ stage: current, url, ms, code: status });
  return { code: status, headers, content };
};

globalThis.local = {
  data: {},
  get(g, k) { return this.data[g + ':' + k] ?? ''; },
  set(g, k, v) { this.data[g + ':' + k] = String(v); },
  delete(g, k) { delete this.data[g + ':' + k]; },
};
globalThis.joinUrl = (parent, child) => new URL(child, parent).href;

// ---- 跑 --------------------------------------------------------------------------
const argv = process.argv.slice(2);
const keyword = argv.find((a) => !a.startsWith('--')) || '凡人修仙传';
const repeatIndex = argv.indexOf('--repeat');
const repeat = repeatIndex >= 0 ? Math.max(1, Number(argv[repeatIndex + 1]) || 1) : 1;

const module = await import(pathToFileURL(asset).href);
const kanju = module.default;

function timed(stage, fn) {
  current = stage;
  const before = calls.length;
  const started = Date.now();
  const value = fn();
  const ms = Date.now() - started;
  const sub = calls.slice(before);
  console.log(`\n[${stage}] ${ms} ms  (${sub.length} 次子请求, ${sub.reduce((n, c) => n + c.ms, 0)} ms 串行总和)`);
  for (const c of sub) {
    const path = c.url.replace(/^https:\/\/kanju\.ai/, '');
    console.log(`   ${String(c.ms).padStart(6)} ms  ${String(c.code).padStart(3)}  ${path.slice(0, 110)}${c.error ? '  ' + c.error : ''}`);
  }
  return { value, ms };
}

kanju.init('');
current = 'search';
const found = kanju.search(keyword, false, 1);
const list = (found && found.list) || [];
if (!list.length) {
  console.log(`搜索「${keyword}」没有结果`);
  process.exit(1);
}
const pick = list[0];
console.log(`片名 ${pick.vod_name}  id=${pick.vod_id}`);

for (let round = 1; round <= repeat; round++) {
  console.log(`\n===== 第 ${round} 轮 =====`);
  const detail = timed(`detail#${round}`, () => kanju.detail(pick.vod_id)).value;
  const vod = detail.list[0];
  const flags = String(vod.vod_play_from || '').split('$$$');
  const groups = String(vod.vod_play_url || '').split('$$$');
  console.log(`线路组: ${flags.join(' / ')}   集数: ${groups.map((g) => g.split('#').length).join(' / ')}`);

  for (let i = 0; i < flags.length; i++) {
    const first = (groups[i] || '').split('#')[0] || '';
    const address = first.split('$').pop();
    if (!address) continue;
    // warm 是详情页落地时 App 会调的那一步（只取线路表，不花钱）。
    timed(`warm ${flags[i]}`, () => kanju.warm(flags[i], address));
    const played = timed(`play ${flags[i]}`, () => kanju.play(flags[i], address)).value;
    const summary = played.url
      ? `OK ${String(played.url).slice(0, 80)}`
      : `ERR ${played.errMsg || JSON.stringify(played).slice(0, 120)}`;
    console.log(`   → ${summary}`);
    // 立刻再点一次同一条线：命中缓存应该是个位数毫秒。
    timed(`play ${flags[i]} (again)`, () => kanju.play(flags[i], address));

    // 下一集：这才是稳态。第一集要踩黑名单，之后应当只发一次签名请求。
    const second = (groups[i] || '').split('#')[1] || '';
    const nextAddress = second.split('$').pop();
    if (nextAddress) {
      const next = timed(`play ${flags[i]} 第2集`, () => kanju.play(flags[i], nextAddress)).value;
      console.log(`   → ${next.url ? 'OK ' + String(next.url).slice(0, 60) : 'ERR ' + (next.errMsg || '')}`);
    }
  }
}
