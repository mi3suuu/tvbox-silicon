// 成人聚合 · 端内 JS 源
// 29 个苹果CMS v10 源跑在设备本地 QuickJS 上：统一题材横跨全部站点、
// 搜索按命中相关性排序、播放前先探活（只给能吐 #EXTM3U 的线路）。
// 生成脚本 build_spider.py，不要手改 SRC / CATS。

const SRC = [["155资源", "https://155api.com/api.php/provide/vod"], ["91麻豆", "https://91md.me/api.php/provide/vod"], ["乐播资源", "https://lbapi9.com/api.php/provide/vod"], ["SouAV资源", "https://api.souavzy.vip/api.php/provide/vod"], ["淫水机资源", "https://www.xrbsp.com/api/json.php"], ["奶香香", "https://Naixxzy.com/api.php/provide/vod"], ["白嫖资源", "https://www.kxgav.com/api/json.php"], ["美少女资源", "https://www.msnii.com/api/json.php"], ["JKUN资源", "https://jkunzyapi.com/api.php/provide/vod"], ["老色逼资源", "https://apilsbzy1.com/api.php/provide/vod"], ["香奶儿资源", "https://www.gdlsp.com/api/json.php"], ["辣椒资源", "https://apilj.com/api.php/provide/vod"], ["精品资源", "https://www.jingpinx.com/api.php/provide/vod"], ["性吧资源", "https://xingba111.com/api.php/provide/vod"], ["黄AV资源", "https://www.pgxdy.com/api/json.php"], ["黄色仓库888", "https://hsckzy888.com/api.php/provide/vod"], ["鲨鱼资源", "https://shayuapi.com/api.php/provide/vod"], ["玉兔资源", "https://apiyutu.com/api.php/provide/vod"], ["森林资源", "https://slapibf.com/api.php/provide/vod"], ["森林资源二线", "https://beiyong.slapibf.com/api.php/provide/vod"], ["大奶子", "https://apidanaizi.com/api.php/provide/vod"], ["滴滴资源", "https://api.ddapi.cc/api.php/provide/vod"], ["黄色仓库", "https://hsckzy.xyz/api.php/provide/vod"], ["桃花资源", "https://thzy1.me/api.php/provide/vod"], ["豆豆资源", "https://api.douapi.cc/api.php/provide/vod"], ["黑料资源", "https://www.heiliaozyapi.com/api.php/provide/vod"], ["SouAV资源二线", "https://api.souavzyw.net/api.php/provide/vod"], ["杏吧资源", "https://xingba222.com/api.php/provide/vod"], ["Madouse", "https://madouse.la/api.php/provide/vod"]];
const CATS = [["cn", "国产", "区域", [[0, "10"], [2, "2"], [3, "21"], [5, "20"], [8, "35"], [9, "21"], [11, "1"], [12, "1"], [13, "55"], [15, "1"], [16, "1"], [17, "21"], [18, "22"], [19, "22"], [20, "21"], [21, "20"], [22, "1"], [23, "6"], [24, "47"], [25, "35"], [26, "2"], [27, "55"], [28, "2"]]], ["jp", "日本", "区域", [[3, "23"], [5, "27"], [8, "2"], [9, "36"], [11, "3"], [12, "2"], [13, "54"], [15, "10"], [16, "2"], [17, "36"], [18, "37"], [19, "37"], [21, "23"], [22, "10"], [23, "25"], [24, "53"], [25, "2"], [26, "4"], [27, "54"], [28, "3"]]], ["us", "欧美", "区域", [[0, "27"], [2, "5"], [3, "22"], [5, "34"], [9, "29"], [11, "2"], [12, "3"], [13, "113"], [15, "3"], [16, "23"], [17, "29"], [18, "30"], [19, "30"], [20, "45"], [21, "43"], [22, "3"], [23, "9"], [24, "64"], [26, "3"], [27, "113"], [4, "29"], [6, "35"], [7, "37"], [10, "31"], [14, "31"]]], ["kr", "韩国", "区域", [[0, "34"], [3, "92"], [15, "40"], [16, "27"], [18, "41"], [19, "41"], [20, "44"], [22, "40"], [26, "104"]]], ["hktw", "港台", "区域", [[3, "47"], [16, "28"], [18, "40"], [19, "40"], [20, "30"], [21, "35"], [26, "52"]]], ["sea", "东南亚", "区域", [[12, "41"], [15, "41"], [18, "43"], [19, "43"], [22, "41"]]], ["asia", "亚洲", "区域", [[2, "1"], [18, "24"], [19, "24"]]], ["sub", "中文字幕", "题材", [[0, "6"], [2, "9"], [3, "38"], [5, "29"], [8, "1"], [9, "25"], [11, "20"], [12, "21"], [13, "62"], [16, "20"], [17, "25"], [18, "26"], [19, "26"], [20, "38"], [21, "25"], [24, "78"], [25, "1"], [26, "29"], [27, "62"], [28, "2"]]], ["unc", "无码", "题材", [[0, "1"], [2, "4"], [3, "36"], [5, "28"], [8, "3"], [9, "24"], [11, "3"], [12, "20"], [13, "54"], [15, "10"], [16, "2"], [17, "24"], [18, "24"], [19, "24"], [20, "39"], [21, "23"], [22, "10"], [23, "25"], [24, "71"], [25, "3"], [26, "25"], [27, "54"], [28, "3"]]], ["cen", "有码", "题材", [[3, "37"], [8, "2"], [9, "23"], [17, "23"], [18, "25"], [19, "25"], [21, "24"], [23, "26"], [24, "53"], [25, "2"], [26, "26"], [28, "4"]]], ["wife", "人妻熟女", "题材", [[0, "20"], [2, "6"], [8, "22"], [9, "27"], [13, "63"], [15, "9"], [16, "26"], [17, "27"], [18, "28"], [19, "28"], [20, "46"], [22, "9"], [24, "74"], [25, "22"], [27, "63"]]], ["uni", "制服丝袜", "题材", [[0, "3"], [2, "10"], [9, "33"], [13, "64"], [15, "13"], [16, "25"], [17, "33"], [18, "57"], [19, "57"], [20, "24"], [22, "13"], [24, "63"], [27, "64"], [28, "9"]]], ["big", "巨乳美乳", "题材", [[0, "15"], [2, "8"], [9, "26"], [11, "34"], [13, "70"], [15, "11"], [17, "26"], [18, "27"], [19, "27"], [22, "11"], [24, "59"], [27, "70"], [28, "5"]]], ["loli", "萝莉少女", "题材", [[0, "12"], [1, "29"], [2, "14"], [3, "73"], [8, "21"], [11, "22"], [12, "25"], [13, "95"], [15, "20"], [18, "31"], [19, "31"], [20, "27"], [22, "20"], [23, "22"], [24, "56"], [25, "21"], [26, "84"], [27, "95"], [28, "6"]]], ["rape", "强奸乱伦", "题材", [[0, "16"], [2, "7"], [3, "57"], [5, "32"], [9, "28"], [11, "26"], [12, "10"], [13, "65"], [15, "16"], [17, "28"], [18, "29"], [19, "29"], [20, "43"], [22, "16"], [23, "23"], [24, "62"], [26, "66"], [27, "65"]]], ["self", "自拍偷拍", "题材", [[0, "25"], [2, "3"], [3, "98"], [5, "23"], [8, "29"], [9, "35"], [11, "1"], [12, "8"], [13, "60"], [15, "37"], [16, "24"], [17, "35"], [18, "34"], [19, "34"], [20, "23"], [22, "37"], [24, "61"], [25, "29"], [26, "111"], [27, "60"]]], ["live", "主播网红", "题材", [[0, "35"], [2, "2"], [3, "96"], [5, "21"], [8, "31"], [9, "22"], [12, "15"], [13, "82"], [15, "6"], [16, "21"], [17, "22"], [18, "23"], [19, "23"], [20, "21"], [21, "22"], [22, "6"], [23, "27"], [24, "54"], [25, "31"], [26, "108"], [27, "82"]]], ["tan", "探花嫖妓", "题材", [[3, "33"], [5, "22"], [8, "32"], [9, "65"], [12, "11"], [13, "81"], [15, "8"], [17, "65"], [18, "47"], [19, "47"], [20, "31"], [22, "8"], [23, "24"], [24, "49"], [25, "32"], [26, "15"], [27, "81"]]], ["anime", "动漫里番", "题材", [[0, "7"], [2, "12"], [3, "46"], [5, "47"], [8, "30"], [9, "32"], [11, "21"], [12, "4"], [13, "112"], [15, "5"], [16, "22"], [17, "32"], [18, "33"], [19, "33"], [20, "48"], [21, "39"], [22, "5"], [23, "10"], [24, "70"], [25, "30"], [26, "51"], [27, "112"], [4, "30"], [6, "33"], [7, "38"], [10, "32"], [14, "30"]]], ["ethic", "三级伦理", "题材", [[0, "4"], [2, "13"], [3, "71"], [5, "36"], [8, "33"], [9, "31"], [11, "25"], [13, "61"], [15, "18"], [16, "27"], [17, "31"], [18, "32"], [19, "32"], [20, "44"], [21, "37"], [22, "18"], [24, "68"], [25, "33"], [26, "82"], [27, "61"]]], ["sm", "SM重口", "题材", [[0, "39"], [2, "15"], [3, "83"], [5, "38"], [9, "63"], [11, "24"], [12, "30"], [13, "68"], [15, "21"], [17, "63"], [20, "35"], [21, "45"], [22, "21"], [24, "57"], [26, "94"], [27, "68"]]], ["les", "女同", "题材", [[0, "13"], [2, "11"], [3, "52"], [5, "39"], [12, "29"], [13, "94"], [15, "34"], [18, "60"], [19, "60"], [20, "50"], [21, "46"], [22, "34"], [24, "76"], [26, "57"], [27, "94"]]], ["gay", "男同", "题材", [[3, "51"], [15, "35"], [18, "61"], [19, "61"], [21, "47"], [22, "35"], [24, "80"], [26, "56"]]], ["ts", "人妖TS", "题材", [[3, "53"], [11, "23"], [15, "32"], [20, "49"], [22, "32"], [26, "58"], [6, "31"], [14, "29"]]], ["ai", "AI换脸", "题材", [[0, "5"], [3, "88"], [5, "31"], [9, "60"], [12, "42"], [13, "76"], [15, "29"], [17, "60"], [20, "33"], [22, "29"], [23, "29"], [26, "99"], [27, "76"]]], ["ama", "素人", "题材", [[3, "102"], [8, "36"], [18, "39"], [19, "39"], [23, "28"], [25, "36"], [26, "115"]]], ["out", "野战户外", "题材", [[0, "30"], [3, "86"], [13, "91"], [18, "49"], [19, "49"], [20, "51"], [24, "51"], [26, "97"], [27, "91"]]], ["meme", "吃瓜黑料", "题材", [[0, "36"], [1, "9"], [3, "48"], [5, "24"], [8, "37"], [9, "56"], [11, "18"], [12, "13"], [13, "80"], [15, "31"], [17, "56"], [18, "58"], [19, "58"], [20, "25"], [21, "44"], [22, "31"], [23, "8"], [24, "52"], [25, "37"], [26, "53"], [27, "80"]]], ["group", "多人群交", "题材", [[0, "14"], [13, "75"], [18, "46"], [19, "46"], [20, "40"], [27, "75"]]], ["oral", "口交颜射", "题材", [[11, "36"], [12, "29"], [13, "72"], [15, "22"], [18, "36"], [19, "36"], [22, "22"], [27, "72"]]], ["talk", "影视解说", "题材", [[0, "40"], [3, "80"], [5, "30"], [8, "4"], [13, "78"], [15, "17"], [20, "28"], [21, "28"], [22, "17"], [24, "69"], [25, "4"], [26, "91"], [27, "78"]]], ["madou", "麻豆传媒", "厂牌", [[0, "2"], [1, "1"], [3, "24"], [9, "57"], [17, "57"], [21, "29"], [26, "6"], [28, "1"]]], ["m91", "91制片厂", "厂牌", [[1, "25"], [3, "59"], [18, "47"], [19, "47"], [21, "30"], [26, "70"]]], ["tianmei", "天美传媒", "厂牌", [[1, "3"], [3, "35"], [21, "32"], [26, "20"]]], ["peach", "蜜桃传媒", "厂牌", [[1, "4"], [3, "26"], [21, "31"], [26, "8"]]], ["jingdong", "精东影业", "厂牌", [[1, "7"], [3, "25"], [21, "33"], [26, "7"]]], ["guodong", "果冻传媒", "厂牌", [[3, "27"], [26, "9"]]], ["xingkong", "星空传媒", "厂牌", [[1, "6"], [3, "28"], [21, "34"], [26, "10"]]], ["swag", "SWAG", "厂牌", [[8, "28"], [21, "35"], [25, "28"]]], ["doll", "玩偶姐姐", "厂牌", [[1, "22"], [3, "45"], [26, "50"]]], ["wuya", "乌鸦传媒", "厂牌", [[1, "10"]]], ["rabbit", "兔子先生", "厂牌", [[1, "20"]]], ["xingba", "杏吧原创", "厂牌", [[1, "21"], [3, "60"], [26, "71"]]], ["haijiao", "海角社区", "厂牌", [[1, "8"]]], ["huangjia", "皇家华人", "厂牌", [[1, "5"], [3, "41"], [26, "39"]]], ["tangxin", "糖心传媒", "厂牌", [[1, "27"], [3, "67"], [21, "42"], [26, "78"]]], ["shijie", "性视界", "厂牌", [[1, "30"], [3, "30"], [26, "12"]]], ["hulu", "葫芦影业", "厂牌", [[3, "69"], [21, "41"], [26, "80"]]], ["koukou", "扣扣传媒", "厂牌", [[3, "54"], [26, "62"]]], ["qidian", "起点传媒", "厂牌", [[3, "61"], [26, "72"]]], ["daxiang", "大象传媒", "厂牌", [[1, "24"]]], ["mini", "mini传媒", "厂牌", [[1, "23"]]], ["other", "其他传媒", "厂牌", [[3, "70"], [5, "26"], [8, "35"], [13, "89"], [15, "7"], [18, "59"], [19, "59"], [21, "36"], [22, "7"], [24, "48"], [25, "35"], [26, "81"], [27, "89"]]]];

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const HEAD = {
    'User-Agent': UA,
    Accept: 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9'
};
const CAT_BY_ID = {};
for (const c of CATS) CAT_BY_ID[c[0]] = c;

const origin = u => {
    const m = String(u || '').match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] + '/' : '';
};

const clean = s => String(s == null ? '' : s)
    .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ').trim();

// 去掉空白与标点，用于跨站去重和相关性判断
const key = s => String(s || '').toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, '');

const isImageUrl = u => {
    u = String(u || '').trim();
    if (!/^(https?:)?\/\//i.test(u)) return false;
    return !/\.(m3u8|mp4|m4v|flv|ts)(\?|$)/i.test(u);
};

const picOf = v => {
    let p = String(v.vod_pic || '');
    if (!isImageUrl(p)) p = String(v.vod_pic_thumb || v.vod_pic_slide || p);
    if (p.indexOf('//') === 0) p = 'https:' + p;
    return isImageUrl(p) ? p : '';
};

function getJson(url, timeout) {
    try {
        const r = globalThis.req(url, { headers: headersFor(url), timeout: timeout || 7000 });
        if (!r || r.code >= 400) return null;
        return readJson(r.content);
    } catch (e) {
        return null;
    }
}

function headersFor(url) {
    return Object.assign({ Referer: origin(url) }, HEAD);
}

function readJson(content) {
    if (typeof content !== 'string') return null;
    // 个别采集站会在 JSON 前面垫一段 HTML
    const i = content.indexOf('{');
    if (i < 0) return null;
    try { return JSON.parse(i > 0 ? content.slice(i) : content); } catch (e) { return null; }
}

/**
 * 一次取多个站。新版宿主走 reqAll 原生并行（总耗时 = 最慢那个），
 * 老版本没有 httpAll 就自动退回串行 —— 同一份代码两边都能跑。
 * @param {[number,string][]} pairs [源序号, 查询串]
 */
function fetchBatch(pairs, timeout) {
    const urls = pairs.map(p => SRC[p[0]][1] + '?' + p[1]);
    let resps = null;
    if (typeof globalThis.reqAll === 'function') {
        try {
            resps = globalThis.reqAll(urls.map(u => ({ url: u, headers: headersFor(u) })), { timeout: timeout || 7000 });
        } catch (e) {
            resps = null;
        }
    }
    if (!resps || resps.length !== urls.length) {
        resps = urls.map(u => {
            try { return globalThis.req(u, { headers: headersFor(u), timeout: timeout || 7000 }); }
            catch (e) { return null; }
        });
    }
    const groups = [];
    for (let k = 0; k < pairs.length; k++) {
        const r = resps[k];
        const d = r && r.code && r.code < 400 ? readJson(r.content) : null;
        const list = d && Array.isArray(d.list) ? d.list : [];
        const out = [];
        for (const v of list) if (v && v.vod_name) out.push(toItem(v, pairs[k][0]));
        groups.push(out);
    }
    return groups;
}

function toItem(v, idx) {
    const name = clean(v.vod_name) || clean(v.vod_sub) || '未命名';
    const vid = String(v.vod_id || '') || String(v.vod_en || '') || name;
    return {
        vod_id: idx + '@@' + vid,
        vod_name: name,
        vod_pic: picOf(v),
        vod_remarks: clean(v.vod_remarks)
    };
}

function parseId(id) {
    const s = String(id || '');
    const at = s.indexOf('@@');
    if (at < 0) return null;
    const idx = parseInt(s.slice(0, at), 10);
    if (!(idx >= 0 && idx < SRC.length)) return null;
    return { idx: idx, vid: s.slice(at + 2) };
}


// 各站轮流出一条，避免某个站把整屏占满
function interleave(groups) {
    const out = [];
    let max = 0;
    for (const g of groups) max = Math.max(max, g.length);
    for (let i = 0; i < max; i++) for (const g of groups) if (g[i]) out.push(g[i]);
    return out;
}

function dedupe(items) {
    const seen = {};
    const out = [];
    for (const it of items) {
        const k = key(it.vod_name);
        if (!k || seen[k]) continue;
        seen[k] = 1;
        out.push(it);
    }
    return out;
}

// 采集站的搜索是 LIKE 模糊匹配：搜 SSNI-622 会把 SSNI-682、SSNI-1622 全倒出来。
// 标题里真含关键词的提到前面，有封面的排在无封面前面，其余留作兜底不丢。
function rankByKeyword(items, kw) {
    const k = key(kw);
    const hitPic = [], hitNo = [], restPic = [], restNo = [];
    for (const it of items) {
        const hit = !k || key(it.vod_name).indexOf(k) >= 0;
        const pic = !!it.vod_pic;
        if (hit) (pic ? hitPic : hitNo).push(it);
        else (pic ? restPic : restNo).push(it);
    }
    return hitPic.concat(hitNo, restPic, restNo);
}

function parsePlayLines(playUrl, playFrom) {
    const raw = String(playUrl || '').trim();
    if (!raw) return [];
    const groups = raw.split('$$$');
    const names = String(playFrom || '').split('$$$');
    const out = [];
    for (let g = 0; g < groups.length; g++) {
        let lineName = clean(names[g]) || '线路' + (g + 1);
        if (/^(ck|d)?player$/i.test(lineName)) lineName = '';
        const eps = [];
        for (const seg of groups[g].split('#')) {
            const s = seg.trim();
            if (!s) continue;
            let epName = '';
            let url = s;
            const parts = s.split('$');
            if (parts.length > 1) {
                epName = clean(parts[0]);
                url = parts.slice(1).join('$');
            }
            url = url.trim();
            if (!/^https?:\/\//i.test(url)) continue;
            eps.push({ name: epName, url: url });
        }
        if (eps.length) out.push({ line: lineName || '在线播放', eps: eps });
    }
    // 首条是 m3u8 的线路排前面（有些站第一条是网页中转页，播不了）
    out.sort((a, b) =>
        (/\.m3u8(\?|#|$)/i.test(b.eps[0].url) ? 1 : 0) -
        (/\.m3u8(\?|#|$)/i.test(a.eps[0].url) ? 1 : 0));
    return out;
}

// 探活：既看状态码也看内容，200 + HTML 报错页同样算死。
// hard=true 表示「确定播不了」；超时只算「不知道」，不能拿它拦用户。
function probe(url, ms) {
    try {
        const r = globalThis.req(url, { headers: { 'User-Agent': UA }, timeout: ms || 3000 });
        if (!r || !r.code) return { ok: false, hard: false };
        if (r.code >= 400) return { ok: false, hard: true };
        const text = String(r.content || '');
        if (text.indexOf('#EXTM3U') >= 0) return { ok: true, hard: false };
        // 拿到内容却没有清单头，基本就是落地页/报错页
        return { ok: false, hard: text.length > 0 };
    } catch (e) {
        return { ok: false, hard: false };
    }
}

const HOME_PICKS = [1, 4, 6, 7, 10, 14, 21];
// 有心跳并行后扇出可以放开：一个分类最多横跨 10 个站，
// 总耗时约等于最慢那个（老宿主退回串行时会慢一些）。
const CAT_LIMIT = 10;
const SEARCH_LIMIT = 29;
const CACHE_TTL = 10 * 60 * 1000;
// TTL 只保证「不读到旧数据」，管不住条目数：翻几十页、换十几个关键词，KV 里就会堆下几十份完整列表。
// 给个上限，按写入时间淘汰最旧的。
const CACHE_MAX = 60;

// 均匀取 n 个，保证覆盖到映射表里的不同站点，而不是永远只打前几个
function spread(list, n) {
    if (list.length <= n) return list.slice(0);
    const out = [];
    for (let i = 0; i < n; i++) out.push(list[Math.floor(i * (list.length - 1) / (n - 1))]);
    return out;
}

const cacheGet = k => {
    try {
        const text = globalThis.local.get('adultagg', k);
        if (!text) return null;
        const box = JSON.parse(text);
        if (!box || !box.t || Date.now() - box.t > CACHE_TTL) return null;
        return box.v;
    } catch (e) { return null; }
};

const cacheIndex = () => {
    try {
        const text = globalThis.local.get('adultagg', '__index');
        return text ? JSON.parse(text) : {};
    } catch (e) { return {}; }
};

const cachePut = (k, v) => {
    try { globalThis.local.set('adultagg', k, JSON.stringify({ t: Date.now(), v: v })); } catch (e) { return; }
    try {
        const index = cacheIndex();
        index[k] = Date.now();
        const keys = Object.keys(index);
        if (keys.length > CACHE_MAX) {
            keys.sort((a, b) => index[a] - index[b]);
            for (const old of keys.slice(0, keys.length - CACHE_MAX)) {
                try { globalThis.local.delete('adultagg', old); } catch (e) {}
                delete index[old];
            }
        }
        globalThis.local.set('adultagg', '__index', JSON.stringify(index));
    } catch (e) {}
};

export default {
    home() {
        const hit = cacheGet('home');
        if (hit) return hit;
        const classes = CATS.map(c => ({ type_id: c[0], type_name: c[1] }));
        const groups = fetchBatch(HOME_PICKS.map(i => [i, 'ac=videolist&pg=1']), 7000);
        const out = { class: classes, list: dedupe(interleave(groups)).slice(0, 40) };
        cachePut('home', out);
        return out;
    },

    category(tid, pg) {
        const c = CAT_BY_ID[tid];
        if (!c) return { list: [] };
        const page = parseInt(pg, 10) || 1;
        const ck = 'cat:' + tid + ':' + page;
        const hit = cacheGet(ck);
        if (hit) return hit;
        const groups = fetchBatch(spread(c[3], CAT_LIMIT).map(pair =>
            [pair[0], 'ac=videolist&t=' + encodeURIComponent(pair[1]) + '&pg=' + page]), 7000);
        const out = { list: dedupe(interleave(groups)).slice(0, 60) };
        cachePut(ck, out);
        return out;
    },

    search(wd, quick, pg) {
        const kw = clean(wd);
        if (!kw) return { list: [] };
        const page = parseInt(pg, 10) || 1;
        const ck = 'wd:' + kw.toLowerCase() + ':' + page;
        const hit = cacheGet(ck);
        if (hit) return hit;
        const groups = fetchBatch(spread(SRC.map((_, k) => k), SEARCH_LIMIT).map(i =>
            [i, 'ac=videolist&wd=' + encodeURIComponent(kw) + '&pg=' + page]), 6000);
        const out = { list: rankByKeyword(dedupe(interleave(groups)), kw).slice(0, 80) };
        cachePut(ck, out);
        return out;
    },

    detail(id) {
        const p = parseId(id);
        if (!p) return { list: [] };
        let v = null;
        for (let attempt = 0; attempt < 2 && !v; attempt++) {
            const d = getJson(SRC[p.idx][1] + '?ac=detail&ids=' + encodeURIComponent(p.vid));
            v = d && Array.isArray(d.list) ? d.list[0] : null;
        }
        if (!v) return { list: [] };
        const lines = parsePlayLines(v.vod_play_url, v.vod_play_from);
        return {
            list: [{
                vod_id: id,
                vod_name: clean(v.vod_name) || '未命名',
                vod_pic: picOf(v),
                type_name: clean(v.type_name),
                vod_year: String(v.vod_year || ''),
                vod_area: clean(v.vod_area),
                vod_actor: clean(v.vod_actor),
                vod_director: clean(v.vod_director),
                vod_content: clean(v.vod_content) || clean(v.vod_blurb),
                vod_remarks: clean(v.vod_remarks),
                vod_play_from: lines.map(l => l.line).join('$$$'),
                vod_play_url: lines.map(l => l.eps.map(e => (e.name || '播放') + '$' + e.url).join('#')).join('$$$')
            }]
        };
    },

    play(flag, id) {
        const url = String(id || '');
        const header = { 'User-Agent': UA, Referer: origin(url) };
        // 非 HLS 不探：那会把整个 mp4 拉下来
        if (!/\.m3u8(\?|#|$)/i.test(url)) return { parse: 0, url: url, header: header };

        const first = probe(url, 1500);
        if (first.ok || !first.hard) return { parse: 0, url: url, header: header };

        // 站点 https 常被 SNI 阻断，明确失败时退明文 http 再试一次
        if (url.indexOf('https://') === 0) {
            const plain = 'http://' + url.slice(8);
            if (probe(plain, 1500).ok) {
                return { parse: 0, url: plain, header: { 'User-Agent': UA, Referer: origin(plain) } };
            }
        }
        return { parse: 0, url: url, header: header };
    }
};
