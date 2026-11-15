// 看剧AI（kanju.ai）· 映匣端内 JS 源
//
// 它自己那一套"官方线路"是服务端现签：客户端只拿 ticket，播放前再 POST /v1/playback/resolve-line
// 换一条带 x-expires 的签名地址（字节云 bytetos/byteimg，约 1 小时）。所以这里也照它的流程走：
//   详情 → 每集一个 token → 播放时 resolve 出线路表 → 按 fl(normal/官方/4K) 选一条 → 换地址
//
// 三个线路组（vod_play_from）：
//   普通      第三方采集站 m3u8，免费，直连，权重 750–920
//   官方1080  站方签名 mp4/m3u8，吃词元（大多 3 万/集，official-v 6 万），剧集前 3 集免费
//   官方4K    bytevod-lv5「专享4K-Y」，同样吃词元
//
// ext 可选：{"prefer":"official"|"4k"|"ordinary"} 只影响默认线路组的排序（默认普通在前，先省词元）。
// 签名密钥是它前端 bundle 里硬编码的那把，规则 HEAD 可见：HMAC-SHA256(METHOD\npath?query\nts\nnonce)。

const HOST = 'https://kanju.ai';
const SKEY = '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

// ---- SHA-256 / HMAC，纯 JS 实现：不赌运行时有 crypto --------------------------------
const K256 = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];
const rotr = (x, n) => ((x >>> n) | (x << (32 - n))) >>> 0;

function utf8(s) {
    const out = [];
    for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        else if (c >= 0xd800 && c < 0xdc00) {
            c = 0x10000 + ((c - 0xd800) << 10) + (s.charCodeAt(++i) - 0xdc00);
            out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
}

function sha256(bytes) {
    const len = bytes.length;
    const size = (((len + 9) + 63) >> 6) << 6;
    const buf = new Uint8Array(size);
    buf.set(bytes);
    buf[len] = 0x80;
    const view = new DataView(buf.buffer);
    const bits = len * 8;
    view.setUint32(size - 8, Math.floor(bits / 4294967296));
    view.setUint32(size - 4, bits >>> 0);

    const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const W = new Uint32Array(64);
    for (let off = 0; off < size; off += 64) {
        for (let i = 0; i < 16; i++) W[i] = view.getUint32(off + i * 4);
        for (let i = 16; i < 64; i++) {
            const a = W[i - 15], b = W[i - 2];
            const s0 = (rotr(a, 7) ^ rotr(a, 18) ^ (a >>> 3)) >>> 0;
            const s1 = (rotr(b, 17) ^ rotr(b, 19) ^ (b >>> 10)) >>> 0;
            W[i] = (W[i - 16] + s0 + W[i - 7] + s1) >>> 0;
        }
        let [a, b, c, d, e, f, g, h] = H;
        for (let i = 0; i < 64; i++) {
            const S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
            const ch = ((e & f) ^ (~e & g)) >>> 0;
            const t1 = (h + S1 + ch + K256[i] + W[i]) >>> 0;
            const S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
            const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
            const t2 = (S0 + maj) >>> 0;
            h = g; g = f; f = e; e = (d + t1) >>> 0;
            d = c; c = b; b = a; a = (t1 + t2) >>> 0;
        }
        H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
        H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    return new Uint8Array(H.flatMap(v => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255]));
}

const hex = bytes => Array.from(bytes, b => ('0' + b.toString(16)).slice(-2)).join('');

function hmacSha256Hex(key, message) {
    let k = utf8(key);
    if (k.length > 64) k = sha256(k);
    const pad = new Uint8Array(64);
    pad.set(k);
    const inner = new Uint8Array(64 + message.length);
    const outer = new Uint8Array(64 + 32);
    for (let i = 0; i < 64; i++) { inner[i] = pad[i] ^ 0x36; outer[i] = pad[i] ^ 0x5c; }
    inner.set(message, 64);
    outer.set(sha256(inner), 64);
    return hex(sha256(outer));
}

// ---- 它的签名与调用 ---------------------------------------------------------------
function nonce32() {
    let s = '';
    while (s.length < 32) s += Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0');
    return s.slice(0, 32);
}

function sign(method, path, ts, nonce) {
    return hmacSha256Hex(SKEY, utf8(method + '\n' + path + '\n' + ts + '\n' + nonce));
}

// 站点一进来就发一张访客身份，额度按这张身份记。
//
// 额度见底时换一张新身份（用户要求）。服务端实测：**带旧 cookie 再 POST
// `/v1/users/anonymous` 会下发另一个 session 值**（不是续用旧身份），新身份
// `used_tokens=0 / limit_tokens=900000`，立刻解官方票照样 201。所以"换身份"只需
// 丢掉旧 cookie 再建号，不必清任何服务端状态，也没有登出接口要用。
//
// 每次重置都要它重新计一份 CDN 账单，无节制刷会被风控掐掉整条链路（连正常看都看不了），
// 所以设每日上限：超了就安静走普通线，不再换。
let authCookie = '';

function storedCookie() {
    try { return String(local.get('kanju', 'guest') || ''); } catch (e) { return ''; }
}

function saveCookie(value) {
    authCookie = value;
    try { local.set('kanju', 'guest', value); } catch (e) {}
}

function cookieFromHeaders(headers) {
    const raw = headers || {};
    const all = raw['set-cookie'] ?? raw['Set-Cookie'] ?? '';
    const entries = Array.isArray(all) ? all : [String(all)];
    // 它建号时一次发 5 条：前几条是清空用的 `ai_movie_session=`（空值），最后一条才是真会话。
    // 所以不能"取第一条"，要把每条都切开，只看名字像会话且值非空的。
    for (const entry of entries) {
        for (const token of String(entry).split(/[;,]+\s*/)) {
            const m = /^([A-Za-z0-9_-]+)=(.+)$/.exec(token.trim());
            if (!m) continue;
            const name = m[1], value = m[2].trim();
            if (!value) continue;
            if (/session|token|guest|auth|sid/i.test(name)) return name + '=' + value;
        }
    }
    return '';
}

/// 和 call 一样，但把状态码与正文一起还回来。额度不足 / 票失效要按 body 里的 code 区分，
/// 而 call 在 code>=400 时直接返回 null，把原因丢了。
function callWithStatus(path, options) {
    const method = (options && options.method) || 'GET';
    const body = options && options.body;
    const ts = String(Date.now());
    const n = nonce32();
    const headers = {
        'User-Agent': UA,
        'Accept': 'application/json',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': HOST + '/',
        'x-ai-movie-timestamp': ts,
        'x-ai-movie-nonce': n,
        'x-ai-movie-signature': sign(method, path, ts, n)
    };
    if (authCookie) headers['Cookie'] = authCookie;
    if (body != null) headers['Content-Type'] = 'application/json';
    let r;
    try {
        r = globalThis.req(HOST + path, {
            method: method, headers: headers, body: body == null ? null : JSON.stringify(body),
            timeout: (options && options.timeout) || 9000
        });
    } catch (e) { return { code: 0, json: null, text: String(e) }; }
    if (r && r.headers) {
        const fresh = cookieFromHeaders(r.headers);
        if (fresh && fresh !== authCookie) saveCookie(fresh);
    }
    if (!r) return { code: 0, json: null, text: '' };
    let json = null;
    try { json = JSON.parse(r.content); } catch (e) {}
    return { code: r.code || 0, json: json, text: String((r.content || '')).slice(0, 400) };
}

function call(path, options) {
    const method = (options && options.method) || 'GET';
    const body = options && options.body;
    const ts = String(Date.now());
    const n = nonce32();
    const headers = {
        'User-Agent': UA,
        'Accept': 'application/json',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': HOST + '/',
        'x-ai-movie-timestamp': ts,
        'x-ai-movie-nonce': n,
        'x-ai-movie-signature': sign(method, path, ts, n)
    };
    if (authCookie) headers['Cookie'] = authCookie;
    if (body != null) headers['Content-Type'] = 'application/json';
    let r;
    try {
        r = globalThis.req(HOST + path, {
            method: method, headers: headers, body: body == null ? null : JSON.stringify(body),
            timeout: (options && options.timeout) || 9000
        });
    } catch (e) { return null; }
    if (r && r.headers) {
        const fresh = cookieFromHeaders(r.headers);
        if (fresh && fresh !== authCookie) saveCookie(fresh);
    }
    if (!r || r.code >= 400) return null;
    try { return JSON.parse(r.content); } catch (e) { return null; }
}

/// 这张身份还剩几集官方额度；读不到（无会话/接口变了）返回 null，不瞎猜。
///
/// 十分钟：这个数字只影响「要不要白撞一次解票」和简介里的提示，而多读一次就是多一个
/// 往返 —— 每次打开详情都读，等于把详情页的等待翻倍。解票成功时本地先减一（见
/// `resolveOfficial`），所以显示不会因为这个 TTL 变得离谱。
let remainCache = null, remainAt = 0;
function remainingEpisodes(refresh) {
    const now = Date.now();
    if (!refresh && remainCache !== null && now - remainAt < 600000) return remainCache;
    // 额度只有带身份才读得到（无 cookie 是 401 "User session is required."），
    // 所以到这里才建号——这也是懒建号的落点：谁真要额度，谁才付这一次往返。
    if (!ensureSession()) return null;
    const data = call('/v1/users/me/quota', { timeout: 6000 });
    if (!data || data.remaining_tokens == null) return null;
    remainCache = Math.floor(Number(data.remaining_tokens) / 30000);
    remainAt = now;
    return remainCache;
}

/// 建号接口自己有频率限制：实测连着建十几次之后，签名请求也被回
/// 429 `{"error":"request_error","message":"请求太频繁，请稍后再试"}`，
/// 且**不带签名**的裸 POST 会直接 401（不是 429）。
/// 所以撞到 429 要退避，不能继续每集都试——那会把整条链路一起撞死。
let createCooldownUntil = 0;

function ensureSession(force) {
    if (!force) {
        if (authCookie) return true;
        const saved = storedCookie();
        if (saved) { authCookie = saved; return true; }
    }
    if (Date.now() < createCooldownUntil) return false;
    // force 时先把旧 cookie 清空，让服务端按"新游客"发一张身份。
    // 但**失败要还原**：一次没换成的重置不该连带毁掉手里那张还能用的身份——
    // 否则后面连额度都读不到，等于把"换号失败"放大成"连原有身份也没了"。
    const previous = authCookie || storedCookie();
    if (force) { authCookie = ''; saveCookie(''); }
    const answer = callWithStatus('/v1/users/anonymous', { method: 'POST', body: {}, timeout: 8000 });
    if (answer.code === 429) {
        // 退避 10 分钟：这段时间内不再建号，播放照走普通线。
        createCooldownUntil = Date.now() + 600000;
        if (previous) saveCookie(previous);
        return false;
    }
    if (!authCookie && previous) saveCookie(previous);
    return !!authCookie;
}

// ---- 额度耗尽 → 换新游客身份（每日配额，防被风控） ---------------------------------
// day 存"这一天重置过几次"，跨自然日归零。上限 3 次：够看完 900k÷30k≈30 集再多一两轮，
// 又不至于把同一出口 IP 的建号频率推到象是爬虫。
const RESETS_PER_DAY = 3;
let resetCache = null;

function dayKey() {
    const d = new Date();
    return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
}

function resetCount() {
    try {
        const raw = String(local.get('kanju', 'resets') || '');
        if (!raw) return 0;
        const parts = raw.split('|');
        if (parts[0] !== dayKey()) return 0;
        return parseInt(parts[1], 10) || 0;
    } catch (e) { return 0; }
}

function bumpResetCount() {
    try { local.set('kanju', 'resets', dayKey() + '|' + (resetCount() + 1)); } catch (e) {}
}

/// 换一张全新游客身份。返回 true 表示后续请求会用新身份。
function resetGuest() {
    if (resetCache === false) return false;
    if (Date.now() < createCooldownUntil) return false;   // 正在限流退避，别白耗一次配额
    if (resetCount() >= RESETS_PER_DAY) {
        resetCache = false;      // 本轮进程里不再重复尝试
        return false;
    }
    remainCache = null; remainAt = 0;
    const ok = ensureSession(true);
    // 只有真换成了才记一次：被限流打回不该占掉当天额度。
    if (ok) { bumpResetCount(); resetCache = true; }
    return ok;
}

const enc = s => encodeURIComponent(String(s == null ? '' : s));
const clean = s => String(s == null ? '' : s).replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();

// ---- 卡片 → 映匣字段 -------------------------------------------------------------
function toVod(card) {
    if (!card || !card.id) return null;
    const genres = card.genres || [];
    return {
        vod_id: card.id,
        vod_name: clean(card.title) || '未命名',
        vod_pic: String(card.poster_url || ''),
        vod_remarks: [clean(card.remarks || ''), reasonOf(card),
                       card.playback_count ? card.playback_count + ' 次播放' : ''].filter(Boolean).join(' · '),
        type_name: genres.slice(0, 3).join('/'),
        vod_year: String(card.year || ''),
        vod_area: clean(card.area || ''),
        vod_lang: clean(card.language || ''),
        vod_actor: (card.actors || []).slice(0, 4).join(','),
        vod_director: (card.directors || [])[0] || '',
        vod_content: clean(card.description || '') || genres.slice(0, 8).join(' / ')
    };
}

function flatten(sections) {
    const out = [], seen = {};
    for (const section of sections || []) {
        for (const card of section.cards || []) {
            if (!card || !card.id || seen[card.id]) continue;
            seen[card.id] = 1;
            const vod = toVod(card);
            if (vod) out.push(vod);
        }
    }
    return out;
}

const KIND = { series: '电视剧', movie: '电影', anime: '动漫', variety: '综艺' };

// ---- 推荐货架（照它自己的分发来） --------------------------------------------------
// 它首页不是一堆片子，而是 8 个货架：大家都在看 / 韩剧在追 / 日剧上新 / 美剧续看 / 国产新剧 /
// 高分电影 / 电影热播 / 院线热映。每个货架由它服务端按 (热度, 榜单快照, 个性化) 排好序、
// 还带 reasons 说明为什么推（"热门韩剧" "center_trending_day" …）。
// 这里**原样保留货架与其顺序**：一个货架 = 一个分类，标题用它的标题，顺序用它的顺序。
// 自己重排只会把它算好的推荐稀释掉。
function loadFeed(ttlSeconds) {
    const now = Math.floor(Date.now() / 1000);
    if (cache.feed && now - (cache.feedAt || 0) < (ttlSeconds || 180)) return cache.feed;
    const feed = call('/v1/feed/home', { timeout: 12000 });
    if (feed && feed.sections && feed.sections.length) {
        cache.feed = feed.sections;
        cache.feedAt = now;
    }
    return cache.feed || [];
}

/// 它给每条卡片的推荐理由：优先取中文标签（"热门韩剧"），没有就用榜单位次。
function reasonOf(card) {
    for (const reason of card.reasons || []) {
        const text = clean(reason);
        if (/[\u4e00-\u9fff]/.test(text) && text.indexOf('hot_list:') !== 0) return text;
    }
    if (card.rank_position != null) return '第 ' + (card.rank_position + 1) + ' 名';
    return '';
}

function classes() {
    const list = [];
    const sections = loadFeed();
    for (const section of sections) {
        const title = clean(section.title);
        if (!title || !section.id) continue;
        list.push({ type_id: 'feed:' + section.id, type_name: title });
    }
    list.push({ type_id: 'all', type_name: '全部推荐' });
    for (const key of Object.keys(KIND)) list.push({ type_id: key, type_name: KIND[key] });
    return list;
}

// ---- 线路挑选 -------------------------------------------------------------------
const isOfficial = line => line.resolve_mode === 'parse' || line.resolve_required === true;
const is4K = line => /4k/i.test(String(line.provider_id) + ' ' + String(line.provider_name));

/// 它的分发规则照抄：官方线按 `preference_weight`（990–1000）降序，`default_priority` 是它自己
/// 标的"默认线路"。上面再叠两点我们自己的经验：上次解成功的那家优先（同片各集线路常常同源），
/// 以及"解不出来就换下一条"由调用方逐条走——首页权重最高那条在某些集次会给图片或空地址。
///
/// ⚠️ 这两条经验必须**硬过**它的权重，不能是加分项。权重都在 990~1000 之间，加个 +2 等于没加：
/// 实测一集要连撞三条线（bytevod-lv2、official-v 都给图），三次签名就是三个往返，
/// 用户眼里的「首次播放要等很久」正是这一段。
let goodProvider = { p: '', 4: '' };
/// 最近解不出来的厂：失败一次压一档，成功就清零。按片维度不知道，但同一条线连续失败的
/// 片子往往就是那几部，压下去比每次重撞三次合算。
const badProvider = {};

function readGoodProviders() {
    try {
        goodProvider.p = String(local.get('kanju', 'good1080') || '');
        goodProvider['4'] = String(local.get('kanju', 'good4k') || '');
    } catch (e) {}
}
readGoodProviders();

function providerScore(id, weight, want4K) {
    const good = id === (want4K ? goodProvider['4'] : goodProvider.p);
    const bad = Math.min(badProvider[id] || 0, 4);
    return (good && id ? 1e6 : 0) + (weight || 0) - bad * 400;
}

function rankScore(line, want4K) {
    return providerScore(line.provider_id, line.preference_weight || 0, want4K) + (line.default_priority ? 1 : 0);
}

function rankOfficial(lines, want4K) {
    return lines
        .filter(l => isOfficial(l) && (want4K ? is4K(l) : true))
        .slice()
        .sort((a, b) => rankScore(b, want4K) - rankScore(a, want4K));
}

function bestOfficial(lines, want4K) {
    return rankOfficial(lines, want4K)[0] || null;
}

function bestOrdinary(lines) {
    const pool = lines.filter(l => l.resolve_mode === 'direct' && /^https?:/i.test(String(l.url || '')));
    return pool.slice().sort((a, b) => rankScore(b, false) - rankScore(a, false))[0] || null;
}

// ---- 线路健康度：把"这个 provider 在这个网络上给过死链/图片"记下来 -------------------
// 实测一部剧 33 条线（官方 10 + 普通 23），普通只有 17 条真能出分片，其中多条首个
// Range 请求要 1–4 秒；官方里 official-v 稳定返回图片地址（当视频放必黑屏）。
// 每次都从权重最高的那条开始试 = 每次都要踩同样的坑，所以按 provider 记一份短时黑名单：
// 死了/给图片就记 30 分钟，下次直接跳过。goodProvider 反过来记"这家最近成功过"。
const BAD_TTL = 1800;

function badMap() {
    try {
        const raw = String(local.get('kanju', 'bad') || '');
        return raw ? JSON.parse(raw) : {};
    } catch (e) { return {}; }
}

function isBad(pid) {
    if (!pid) return false;
    const map = badMap();
    const until = map[pid];
    return until != null && until > Math.floor(Date.now() / 1000);
}

function markBad(pid) {
    if (!pid) return;
    try {
        const map = badMap();
        map[pid] = Math.floor(Date.now() / 1000) + BAD_TTL;
        local.set('kanju', 'bad', JSON.stringify(map));
    } catch (e) {}
}

function markGood(pid) {
    if (!pid) return;
    goodProvider = pid;
    try {
        const map = badMap();
        if (map[pid] != null) { delete map[pid]; local.set('kanju', 'bad', JSON.stringify(map)); }
    } catch (e) {}
}

/// 一条普通线到底能不能播。三种结论要分开，不能都算"死"：
///   'ok'      拿到 #EXTM3U（master 或 media 都算；实测 master 只有 97–134 字节却完全正常）
///   'dead'    服务器明确答复了但它不是 playlist（4xx/5xx 或 200 却不是 #EXTM3U）——这类记黑名单
///   'unknown' 超时/连接中断/没拿到答复——**不记黑名单**：实测 360 资源要 7.5s 才出分片，
///             把它当死线记 30 分钟，等于因为一次慢就废掉一条能播的线。
function lineAlive(url) {
    let r;
    try {
        r = globalThis.req(String(url), {
            method: 'GET',
            headers: { 'User-Agent': UA, 'Range': 'bytes=0-4095' },
            timeout: 9000
        });
    } catch (e) { return 'unknown'; }
    if (!r) return 'unknown';
    const text = String(r.content || '');
    if (text.indexOf('#EXTM3U') >= 0) return 'ok';
    // code 0 = 连接失败/超时（prelude 在 failed 时不给 4xx），答复都没拿到就不知道它活不活。
    if (!r.code) return 'unknown';
    return 'dead';
}

// 官方线路的 ticket 在 url 里（resolve://<ticket>），个别版本放在 resolve_ticket
function ticketOf(line) {
    const direct = String(line.resolve_ticket || '').trim();
    if (direct) return direct;
    const url = String(line.url || '').trim();
    return url.indexOf('resolve://') === 0 ? url.slice(10) : '';
}

// 解票回来的地址有时不是媒体：官方线里的 official-v / bytevod-lv2 在部分集次返回的是
// veImageX 的图片处理地址（...jpg~tplv-...image.image）。当视频放当然黑屏，这里直接判掉。
function looksLikeMedia(url) {
    const s = String(url).toLowerCase();
    // .jpg~tplv-… 这种后缀不是以 .jpg 结尾，所以原后缀后面允许跟 ~ ? # 任一分隔符。
    if (/\.(jpe?g|png|gif|webp|bmp|svg|ico)(?:[~?#]|$)/.test(s)) return false;
    if (/~tplv-[^/?#]*image/.test(s)) return false;
    return true;
}

/// 这一次解成了，下一集先试这家（写进 local，重启也记得）。
function noteGood(line, want4K) {
    const id = String(line.provider_id || '');
    if (!id) return;
    badProvider[id] = 0;
    const key = want4K ? '4' : 'p';
    if (goodProvider[key] === id) return;
    goodProvider[key] = id;
    try { local.set('kanju', want4K ? 'good4k' : 'good1080', id); } catch (e) {}
}

/// 这一次没解成（图片地址、空地址、接口报错）：压一档，排在别家后面，别再每次从它开始撞。
/// **额度不足不算这条线的错**，不能压它——压了下次还会省下它，但那是白省的，
/// 真正要换的是身份（见 grantNewGuest）。
function noteBad(line) {
    const id = String(line.provider_id || '');
    if (id) badProvider[id] = (badProvider[id] || 0) + 1;
}

/// 解一条官方票。返回 { url } 成功，或 { reason } 说明为什么没成——
/// reason 分两类，处理方式完全不同：
///   'quota'  额度不足：换身份再来，**不能**把这条线记成坏的（它本身没坏）
///   'line'   给图片 / 空地址 / 票失效：这家在这个网络上是坏的，压一档
function resolveOfficial(line, want4K) {
    const ticket = ticketOf(line);
    if (!ticket) { noteBad(line); return { reason: 'line' }; }
    const answer = callWithStatus('/v1/playback/resolve-line', {
        method: 'POST', body: { ticket: ticket }, timeout: 12000
    });
    const fresh = answer.json && answer.json.line;
    if (!fresh) {
        const text = (answer.text || '') + ' ' + JSON.stringify(answer.json || {});
        // 额度不足：402，或 body 里带 insufficient/token 之类标记。
        if (answer.code === 402 || /insufficient|not_enough|token_exhaust|词元不足|额度不足/i.test(text)) {
            return { reason: 'quota' };
        }
        noteBad(line);
        return { reason: 'line' };
    }
    const url = String(fresh.url || '');
    if (!/^https?:/i.test(url) || !looksLikeMedia(url)) { noteBad(line); return { reason: 'line' }; }
    noteGood(line, want4K);
    // 解票扣词元：本地先减一，免得为了显示「还剩几集」再问一次服务端。
    if (remainCache != null && remainCache > 0) remainCache -= 1;
    return { url: url };
}

// 签名地址自带 x-expires（约 1 小时）。缓存到过期前 3 分钟，重播/来回切线路就不用再解一次票
// ——对方按次扣词元，这类重复请求对双方都是白花。
const addressCache = {};

function expiryOf(url) {
    const m = /[?&]x-expires=(\d{9,13})/.exec(url);
    if (!m) return 0;
    const value = Number(m[1]);
    return value > 1e12 ? Math.floor(value / 1000) : value;
}

function cachedAddress(key) {
    const hit = addressCache[key];
    if (!hit) return '';
    if (hit.until - 180 > Math.floor(Date.now() / 1000)) return hit.url;
    delete addressCache[key];
    return '';
}

function rememberAddress(key, url) {
    const expires = expiryOf(url) || Math.floor(Date.now() / 1000) + 3000;
    addressCache[key] = { url: url, until: expires };
    return url;
}

/// 普通线路：跳过黑名单，先挑一条**实测能出 playlist** 的。
/// 不做全量探测——那要 17 条各拉一次、最慢 7 秒；只在候选里沿权重往下试，
/// 试到能出的就用，顺手把死的记进黑名单，下次直接从活的开始。
function pickOrdinary(lines) {
    const pool = lines
        .filter(l => l.resolve_mode === 'direct' && /^https?:/i.test(String(l.url || '')))
        .slice()
        .sort((a, b) => rankScore(b, false) - rankScore(a, false));
    let tried = 0;
    let firstUnknown = null;
    for (const line of pool) {
        if (isBad(line.provider_id)) continue;
        // 最多实测 3 条：普通线多数第一个就通，试太多反而比直接播更慢。
        if (tried >= 3) break;
        tried++;
        const verdict = lineAlive(line.url);
        if (verdict === 'ok') { markGood(line.provider_id); return line; }
        // 只把"服务器明确说它不是 playlist"记坏；超时的不记，但也不再排在前面试。
        if (verdict === 'dead') markBad(line.provider_id);
        else if (!firstUnknown) firstUnknown = line;
    }
    if (firstUnknown) return firstUnknown;
    // 全都试过或都在黑名单里：交回权重最高那条，让播放器自己试一次，总比不给地址强。
    return pool[0] || null;
}

/// 一集的分集 token → 它的线路表。**同一个 token 只问一次。**
///
/// 三条线路组（普通 / 官方1080 / 官方4K）是同一集的三条路，线路表却是同一份：以前每个
/// 组各取一次 `/v1/playback/resolve/<token>`，三条组一起用就是三个往返、三倍等待。
/// 表里也没有会过期的签名地址，缓存十分钟是安全的（换集就是换 token，不会读到别人）。
const lineCache = {};
const lineOrder = [];
const LINE_TTL = 600000;

function linesOf(episodeToken) {
    const hit = lineCache[episodeToken];
    if (hit && hit.until > Date.now()) return hit.lines;
    const data = call('/v1/playback/resolve/' + enc(episodeToken), { timeout: 10000 });
    const lines = (data && data.line_options) || [];
    if (!lines.length) return [];
    lineCache[episodeToken] = { lines: lines, until: Date.now() + LINE_TTL };
    lineOrder.push(episodeToken);
    // 看一晚上也就几十集：留 40 集，多出来的按先后丢，免得越积越大。
    while (lineOrder.length > 40) delete lineCache[lineOrder.shift()];
    return lines;
}

/// 分集地址是 `<线路组>|<token>`（`detail` 里拼的）。`warm` 与 `play` 都要拆它。
function tokenOf(id) {
    const raw = String(id || '');
    const cut = raw.indexOf('|');
    return cut > 0 ? raw.slice(cut + 1) : raw;
}

function playAddress(mode, episodeToken) {
    const key = mode + '|' + episodeToken;
    const hit = cachedAddress(key);
    if (hit) return hit;

    const lines = linesOf(episodeToken);
    if (!lines.length) return '';

    if (mode === 'o') {
        const normal = pickOrdinary(lines);
        if (normal) return rememberAddress(key, String(normal.url));
        const fallback = rankOfficial(lines, false)[0];
        const out = fallback ? resolveOfficial(fallback, false) : { reason: 'line' };
        return out.url ? rememberAddress(key, out.url) : '';
    }
    // 一条解不出来就换下一条：权重最高的那条在某些集次会给图片或空地址，不能就此放弃整个官方档。
    const want4K = mode === '4';
    // 额度预检**只在已经有身份时**才做。play 这条路不为读额度单独建号：
    //   · resolve-line 实测不带 cookie 也返回 201，额度不足才回 402；
    //   · 主动建号会让"每日重置上限"形同虚设（没身份时的建号绕过了计数判定）；
    //   · 少一次往返，首播更快。
    // 额度真见底由下面 resolveOfficial 拿到 402 后换身份；这里只是"上次读数就是 0"时的省路。
    // 判据是"本地是否已存过一张身份"（storedCookie），不是内存里的 authCookie——
    // 后者在懒建号下第一次播放时必然是空的，用它当门等于永不预检。
    if ((authCookie || storedCookie()) && remainingEpisodes(false) === 0) {
        if (resetGuest()) {
            remainCache = null; remainAt = 0;
        } else {
            const spent = pickOrdinary(lines);
            return spent ? rememberAddress(key, String(spent.url)) : '';
        }
    }
    const ranked = rankOfficial(lines, want4K).filter(l => !isBad(l.provider_id));
    let quotaHits = 0;
    for (const line of ranked) {
        let out = resolveOfficial(line, want4K);
        // 额度不足：换身份后再试**同一条**。只换一次，避免一次播放里连开多个号。
        if (out.reason === 'quota' && quotaHits === 0) {
            quotaHits++;
            if (resetGuest()) {
                remainCache = null; remainAt = 0;
                out = resolveOfficial(line, want4K);
            }
        }
        if (out.url) return rememberAddress(key, out.url);
        // 额度不足不是这条线的错，别压档（noteBad 已在 resolveOfficial 里只对 'line' 调）。
        // 解不出来就记一笔：这条线的名字与它给的票，是下次换线的依据（也方便排查「点开是黑的」）。
        console.log('kanju: line failed ' + String(line.provider_id || '') + ' ' + String(line.provider_name || ''));
    }
    // 词元不够 / 官方解析全部失败：退回普通线路，别让用户点开就是黑的
    const normal = pickOrdinary(lines);
    return normal ? rememberAddress(key, String(normal.url)) : '';
}

// ---- 偏好（ext） ------------------------------------------------------------------
// 默认官方优先：这条路子画质与稳定度都比采集站强，代价是每集 3 万词元。
// 想让官方额度留给真正的"卡"剧，就把它改成 {"prefer":"ordinary"}。
function preferOf(ext) {
    try {
        if (ext) {
            const parsed = typeof ext === 'string' ? JSON.parse(ext) : ext;
            if (parsed && parsed.cookie) saveCookie(String(parsed.cookie));
            const value = parsed && parsed.prefer ? String(parsed.prefer) : '';
            if (value === 'official' || value === '4k' || value === 'ordinary') return value;
        }
    } catch (e) {}
    return 'official';
}

function preference(prefer) {
    const groups = [
        { flag: '普通', mode: 'o' },
        { flag: '官方1080', mode: 'p' },
        { flag: '官方4K', mode: '4' }
    ];
    const first = prefer === 'official' ? 'p' : (prefer === '4k' ? '4' : 'o');
    return groups.sort((a, b) => (a.mode === first ? -1 : b.mode === first ? 1 : 0));
}

let extPreference = 'ordinary';
const cache = {};

export default {
    init(ext) {
        extPreference = preferOf(ext);
        // 这里**不建号**。实测 feed / catalog / playback-resolve / resolve-line 四类接口
        // 不带任何 cookie 都返回 200/201，只有 /v1/users/me/quota 要身份（401
        // "User session is required."）。所以建号（约 0.8–3.3 秒）不该压在打开列表页这条
        // 路上：等真要读额度、真要解官方票时再建，普通线首播根本不经过身份。
    },

    home() {
        // 首页给第一个货架：那是它自己排在最前的「大家都在看」，不是我们拍脑袋挑的。
        const sections = loadFeed();
        const list = sections.length ? flatten([sections[0]]) : [];
        return { class: classes(), list: list.slice(0, 60) };
    },

    category(tid, pg) {
        const page = parseInt(pg, 10) || 1;
        const id = String(tid || '');
        // 全部推荐：8 个货架摊平，按货架先后去重，保留它原来的推荐顺序。
        if (id === 'all') {
            return { list: flatten(loadFeed()).slice(0, 120), page: 1, pagecount: 1 };
        }
        // 单个货架：12 条，不再分页——货架本身就是它算好的固定推荐。
        if (id.indexOf('feed:') === 0) {
            const wanted = id.slice(5);
            const section = loadFeed().filter(s => s.id === wanted)[0];
            const cards = (section && section.cards) || [];
            return { list: cards.map(toVod).filter(Boolean), page: 1, pagecount: 1 };
        }
        const data = call('/v1/browse/catalog?kind=' + enc(id) + '&page=' + page);
        const cards = (data && data.cards) || [];
        return { list: cards.map(toVod).filter(Boolean), page: page, pagecount: cards.length >= 20 ? page + 1 : page };
    },

    search(wd, quick, pg) {
        const keyword = clean(wd);
        if (!keyword) return { list: [] };
        const page = parseInt(pg, 10) || 1;
        const data = call('/v1/browse/catalog?q=' + enc(keyword) + '&page=' + page, { timeout: 12000 });
        const cards = (data && data.cards) || [];
        return { list: cards.map(toVod).filter(Boolean), page: page, pagecount: cards.length >= 20 ? page + 1 : page };
    },

    detail(id) {
        const data = call('/v1/catalog/' + enc(id));
        const vod = data && toVod(data);
        if (!vod) return { list: [] };
        vod.vod_content = clean(data.description || '') || vod.vod_content;
        vod.vod_remarks = clean(data.episode_progress_text || data.remarks || '');

        const episodes = data.episodes || [];
        const groups = preference(extPreference);
        const from = [], urls = [];
        for (const group of groups) {
            const items = episodes.map(ep => {
                // 站点这套接口有两种分集写法：老的 display_name/episode_number，新的 title/number。
                const label = ep.display_name || ep.title || ep.name;
                const number = ep.number != null ? ep.number : ep.episode_number;
                const name = clean(label || ('第' + number + '集')) || '播放';
                return name + '$' + group.mode + '|' + String(ep.token || '');
            }).filter(s => s.indexOf('|') > 0 && s.split('|')[1]);
            if (!items.length) continue;
            from.push(group.flag);
            urls.push(items.slice(0, 500).join('#'));
        }
        vod.vod_play_from = from.join('$$$');
        vod.vod_play_url = urls.join('$$$');
        // 把这张身份的官方余额写在简介末尾，用户点开就知道还能看几集，不用等弹窗。
        if (extPreference !== 'ordinary') {
            const left = remainingEpisodes(false);
            if (left != null) {
                const note = left > 0 ? '官方额度余 ' + left + ' 集' : '官方额度已用尽，本片走普通线路';
                vod.vod_remarks = (vod.vod_remarks ? vod.vod_remarks + ' · ' : '') + note;
            }
        }
        return { list: [vod] };
    },

    /// 只预热便宜的那一半：这一集的线路表（`/v1/playback/resolve/<token>`，不扣词元）。
    ///
    /// 映匣在详情页落地后调它一次（`{"warm": 地址, "flag": 线路}`，见 prelude 的 warm 分支）：
    /// 用户从「看简介」到「点播放」之间隔着一两秒，这段空档正好用来问线路表，于是点播放时
    /// 只剩下一次签名请求。真去解签名地址是要扣词元的，那一步不替用户提前花。
    warm(flag, id) {
        const token = tokenOf(id);
        if (token) linesOf(token);
        return {};
    },

    play(flag, id) {
        const raw = String(id || '');
        const cut = raw.indexOf('|');
        const mode = cut > 0 ? raw.slice(0, cut) : 'o';
        const token = tokenOf(raw);
        const url = playAddress(mode, token);
        if (!url) return { parse: 1, url: HOST + '/', header: { 'User-Agent': UA } };
        return { parse: 0, url: url, header: { 'User-Agent': UA, 'Referer': HOST + '/' } };
    }
};
