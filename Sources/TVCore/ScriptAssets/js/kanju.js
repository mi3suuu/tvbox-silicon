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

// 站点一进来就发一张访客身份，额度按这张身份记。这里照它的做法只建**一个**并长期沿用
// （存进 local，重启也不换）——换身份就能重置额度，那是绕它的计量，不做。
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
let remainCache = null, remainAt = 0;
function remainingEpisodes(refresh) {
    const now = Date.now();
    if (!refresh && remainCache !== null && now - remainAt < 120000) return remainCache;
    const data = call('/v1/users/me/quota', { timeout: 6000 });
    if (!data || data.remaining_tokens == null) return null;
    remainCache = Math.floor(Number(data.remaining_tokens) / 30000);
    remainAt = now;
    return remainCache;
}

function ensureSession() {
    if (authCookie) return true;
    const saved = storedCookie();
    if (saved) { authCookie = saved; return true; }
    call('/v1/users/anonymous', { method: 'POST', body: {}, timeout: 8000 });
    return !!authCookie;
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
let goodProvider = '';

function rankScore(line) {
    return (line.preference_weight || 0)
        + (line.default_priority ? 1 : 0)
        + (goodProvider && line.provider_id === goodProvider ? 2 : 0);
}

function rankOfficial(lines, want4K) {
    return lines
        .filter(l => isOfficial(l) && (want4K ? is4K(l) : true))
        .slice()
        .sort((a, b) => rankScore(b) - rankScore(a));
}

function bestOfficial(lines, want4K) {
    return rankOfficial(lines, want4K)[0] || null;
}

function bestOrdinary(lines) {
    const pool = lines.filter(l => l.resolve_mode === 'direct' && /^https?:/i.test(String(l.url || '')));
    return pool.slice().sort((a, b) => rankScore(b) - rankScore(a))[0] || null;
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

function resolveOfficial(line) {
    const ticket = ticketOf(line);
    if (!ticket) return '';
    const answer = call('/v1/playback/resolve-line', { method: 'POST', body: { ticket: ticket }, timeout: 12000 });
    const fresh = answer && answer.line;
    if (!fresh) return '';
    const url = String(fresh.url || '');
    if (!/^https?:/i.test(url) || !looksLikeMedia(url)) return '';
    goodProvider = line.provider_id;   // 下一集先试这家
    return url;
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

function playAddress(mode, episodeToken) {
    const key = mode + '|' + episodeToken;
    const hit = cachedAddress(key);
    if (hit) return hit;

    const data = call('/v1/playback/resolve/' + enc(episodeToken), { timeout: 10000 });
    const lines = (data && data.line_options) || [];
    if (!lines.length) return '';

    if (mode === 'o') {
        const normal = bestOrdinary(lines);
        if (normal) return rememberAddress(key, String(normal.url));
        const fallback = bestOfficial(lines, false);
        const url = fallback ? resolveOfficial(fallback) : '';
        return url ? rememberAddress(key, url) : '';
    }
    // 一条解不出来就换下一条：权重最高的那条在某些集次会给图片或空地址，不能就此放弃整个官方档。
    const want4K = mode === '4';
    // 余额读得到且已经见底：别再拿一次必然失败的解票去撞，直接用普通线。
    if (remainingEpisodes(false) === 0) {
        const spent = bestOrdinary(lines);
        return spent ? rememberAddress(key, String(spent.url)) : '';
    }
    const ranked = rankOfficial(lines, want4K);
    for (const line of ranked) {
        const url = resolveOfficial(line);
        if (url) return rememberAddress(key, url);
    }
    // 词元不够 / 官方解析全部失败：退回普通线路，别让用户点开就是黑的
    const normal = bestOrdinary(lines);
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
        ensureSession();
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

    play(flag, id) {
        const raw = String(id || '');
        const cut = raw.indexOf('|');
        const mode = cut > 0 ? raw.slice(0, cut) : 'o';
        const token = cut > 0 ? raw.slice(cut + 1) : raw;
        const url = playAddress(mode, token);
        if (!url) return { parse: 1, url: HOST + '/', header: { 'User-Agent': UA } };
        return { parse: 0, url: url, header: { 'User-Agent': UA, 'Referer': HOST + '/' } };
    }
};
