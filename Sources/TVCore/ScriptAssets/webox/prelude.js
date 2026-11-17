// WeBox plugins on QuickJS. A WeBox plugin is one `WeBox.define({...})` call at its top level; nothing
// in it names a host API, so the plugin file runs unchanged once this module has installed `WeBox`.
//
// Load order (ScriptRuntime.boot): the TVBox prelude, then this module, then the plugin as `api`.
// The TVBox prelude already published `request`, `Buffer`, `URL`, `TextDecoder`, `nativeCrypto`, `local`
// and the timers on globalThis; this module adds `WeBox` and the adapter that presents the plugin's
// list/search/detail/play as the spider `__tvbox.call` expects. Cheerio is imported again because a
// module's imports are its own scope, not the prelude's.
import * as cheerio from 'assets://js/lib/cheerio.min.js';

const host = globalThis.__host;
const nativeCrypto = globalThis.nativeCrypto;
// The TVBox prelude publishes the blocking request as `req`, `_http` and `fetch`; WeBox answers need the
// raw response object, so this layer talks to that function rather than the promise-style `http` helper.
const request = globalThis.req ?? globalThis.fetch;
const local = globalThis.local;
const log = (...values) => host('log', values.map(String).join(' '));

// --- Failures ---------------------------------------------------------------------------------
// Codes match WeBox's own vocabulary so a plugin's messages keep their meaning in the app.
class WeBoxFailure extends Error {
    constructor(code, message, extra) {
        super(String(message == null || message === '' ? code : message));
        this.name = 'WeBoxFailure';
        this.code = String(code || 'FAILED');
        this.extra = extra || null;
    }
}

const fail = (code, message, extra) => { throw new WeBoxFailure(code, message, extra); };

// --- Web Crypto 的最小可用面 ---------------------------------------------------------------
// 站点普遍用 `crypto.getRandomValues` 生成 salt / nonce，并有 `if (!crypto?.getRandomValues)` 的
// 前置检查 —— 没有就直接报「缺少安全随机数能力」。QuickJS 不带 Web Crypto，这里补上它真正用到的两种。
// 随机字节来自原生 `SecRandomCopyBytes`（同一条 `nativeCrypto` 桥），不是 Math.random。
function fillRandom(array) {
    const view = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
    const hex = nativeCrypto({ op: 'random', bytes: view.length }).hex;
    for (let i = 0; i < view.length; i += 1) view[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return array;
}

if (!globalThis.crypto) globalThis.crypto = {};
if (typeof globalThis.crypto.getRandomValues !== 'function') globalThis.crypto.getRandomValues = fillRandom;
if (typeof globalThis.crypto.randomUUID !== 'function') {
    globalThis.crypto.randomUUID = () => {
        const bytes = fillRandom(new Uint8Array(16));
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    };
}

// --- Settings and store -----------------------------------------------------------------------
// Settings live for the whole session: `spider.init` fills them from the source's ext, and `ctx.settings`
// reads the same object, so a plugin sees its configured base URL on every call.
let definition = null;
const settings = {};

function settingFields(def) {
    const fields = (def && def.settings && def.settings.fields) || [];
    return Array.isArray(fields) ? fields : [];
}

function applySettings(def, values) {
    for (const field of settingFields(def)) {
        if (!field || !field.key) continue;
        if ('default' in field) settings[field.key] = field.default;
    }
    if (values && typeof values === 'object' && !Array.isArray(values)) {
        for (const key of Object.keys(values)) if (values[key] != null) settings[key] = values[key];
    }
}

// WeBox's store keeps JSON values, not strings, and survives restarts: `local` writes the session's
// preferences file, which is per source key.
const store = {
    async get(key) {
        const text = local.get('webox', String(key));
        if (text == null || text === '') return null;
        try { return JSON.parse(text); } catch { return text; }
    },
    async set(key, value) { local.set('webox', String(key), JSON.stringify(value == null ? null : value)); },
    async delete(key) { local.delete('webox', String(key)); },
    async keys() { return []; }
};

// --- Binary -----------------------------------------------------------------------------------
const toBytes = value => {
    if (value == null) return new Uint8Array(0);
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (Array.isArray(value)) return Uint8Array.from(value);
    if (typeof value === 'string') return Buffer.from(value, 'utf8');
    return new Uint8Array(0);
};
const copySlice = (bytes, start, length) => {
    const from = Math.max(0, Math.min(bytes.length, Number(start) || 0));
    const to = length == null ? bytes.length : Math.max(from, Math.min(bytes.length, from + (Number(length) || 0)));
    return bytes.slice(from, to);
};

const binary = {
    size: value => toBytes(value).length,
    slice: (value, start, length) => copySlice(toBytes(value), start, length).buffer,
    read: (value, offset, length) => copySlice(toBytes(value), offset, length),
    write: (value, offset, data) => {
        const target = toBytes(value);
        const source = toBytes(data);
        for (let i = 0; i < source.length && offset + i < target.length; i++) target[offset + i] = source[i];
        return target;
    },
    concat: (...parts) => {
        const list = (parts.length === 1 && Array.isArray(parts[0]) ? parts[0] : parts).map(toBytes);
        const out = new Uint8Array(list.reduce((n, b) => n + b.length, 0));
        let at = 0;
        for (const bytes of list) { out.set(bytes, at); at += bytes.length; }
        return out.buffer;
    },
    base64: value => Buffer.from(toBytes(value)).toString('base64'),
    fromBase64: text => copySlice(Buffer.from(String(text || ''), 'base64'), 0).buffer
};

// --- Crypto -----------------------------------------------------------------------------------
// Native AES/hashes (ScriptCrypto.swift). Binary fields go over as XText or X (base64).
const textField = (name, value) => ({ [name + 'Text']: String(value == null ? '' : value) });
const inputField = (value, encoding) => {
    const kind = String(encoding || 'utf8').toLowerCase();
    if (kind === 'base64') return { data: String(value == null ? '' : value) };
    if (kind === 'hex') return { dataHex: String(value == null ? '' : value) };
    return textField('data', value);
};
const crypto = {
    md5: value => nativeCrypto({ op: 'hash', alg: 'md5', ...textField('data', value) }).hex,
    sha1: value => nativeCrypto({ op: 'hash', alg: 'sha1', ...textField('data', value) }).hex,
    sha256: value => nativeCrypto({ op: 'hash', alg: 'sha256', ...textField('data', value) }).hex,
    hmac: (alg, key, value) => nativeCrypto({ op: 'hmac', alg: String(alg || 'sha256'), ...textField('key', key), ...textField('data', value) }).hex,
    base64Encode: value => Buffer.from(toBytes(value)).toString('base64'),
    base64Decode: text => {
        const bytes = Buffer.from(String(text == null ? '' : text), 'base64');
        return Buffer.of(bytes).toString('utf8');
    },
    aesEncrypt(data, key, iv, options = {}) {
        const output = String(options.outputEncoding || 'base64').toLowerCase();
        const result = nativeCrypto({
            op: 'aes', encrypt: true, mode: String(options.mode || 'CBC').toUpperCase(), padding: true,
            ...textField('key', key), ...textField('iv', iv),
            ...inputField(data, options.inputEncoding),
            output: output === 'hex' ? 'hex' : output === 'utf8' || output === 'text' ? 'text' : 'base64'
        });
        return aesAnswer(result, output);
    },
    aesDecrypt(data, key, iv, options = {}) {
        const output = String(options.outputEncoding || 'utf8').toLowerCase();
        const result = nativeCrypto({
            op: 'aes', encrypt: false, mode: String(options.mode || 'CBC').toUpperCase(), padding: true,
            ...textField('key', key), ...textField('iv', iv),
            ...inputField(data, options.inputEncoding),
            output: output === 'hex' ? 'hex' : output === 'utf8' || output === 'text' ? 'text' : 'base64'
        });
        return aesAnswer(result, output);
    },
    // WeBox's RSA is PKCS#1 v1.5 and base64 out; a private key decrypts to text (瓜子's device sign-in).
    rsaEncrypt: (value, key) => nativeCrypto({ op: 'rsa', key: String(key || ''), ...textField('data', value) }).data,
    rsaDecrypt: (value, key) => nativeCrypto({ op: 'rsa', key: String(key || ''), data: String(value || ''), decrypt: true }).text,
    random: bytes => nativeCrypto({ op: 'random', bytes: Number(bytes) || 16 }).hex
};
function aesAnswer(response, output) {
    if (!response) fail('UNSUPPORTED', '加密运算没有返回结果');
    if (output === 'hex') return response.hex;
    if (output === 'text' || output === 'utf8') return response.text;
    return response.data;
}

// --- Context ----------------------------------------------------------------------------------
const origin = value => {
    const text = String(value == null ? '' : value).trim();
    if (!text) fail('CONFIG_REQUIRED', '插件缺少网站地址设置');
    try { return new URL(text).origin; } catch { fail('CONFIG_REQUIRED', '网站地址无效：' + text.slice(0, 120)); }
};
const resolve = (relative, base) => {
    try { return new URL(String(relative == null ? '' : relative).trim(), String(base || '')).href; } catch { return ''; }
};

// WeBox responses carry `status` and `data`; the prelude's carries `code` and `content`.
function answer(response, options) {
    const kind = String(options.responseType || 'text').toLowerCase();
    let data = response.content;
    if (kind === 'json') {
        try { data = JSON.parse(response.content); } catch { data = response.content; }
    // `buffer: 2` already asks the prelude for base64 text, so it is returned as it arrives; encoding it
    // again would corrupt every byte a plugin decodes with atob (肉's PNG-wrapped HLS manifest).
    } else if (kind === 'base64') data = typeof data === 'string' ? data : Buffer.from(toBytes(data)).toString('base64');
    else if (kind === 'buffer' || kind === 'arraybuffer') data = toBytes(response.content).buffer;
    return { status: Number(response.code) || 0, url: response.url || '', headers: response.headers || {}, data, text: typeof data === 'string' ? data : '' };
}

const transport = {
    get: async (address, options = {}) => answer(requestUrl('GET', address, options), options),
    post: async (address, options = {}) => answer(requestUrl('POST', address, options), options),
    request: async (options = {}) => answer(requestUrl(String(options.method || 'GET'), options.url, options), options)
};
function requestUrl(method, address, options = {}) {
    const headers = { ...(options.headers || {}) };
    let body = options.body;
    if (options.json !== undefined) { body = JSON.stringify(options.json); headers['Content-Type'] ||= 'application/json'; }
    else if (options.form !== undefined) { body = new URLSearchParams(options.form).toString(); headers['Content-Type'] ||= 'application/x-www-form-urlencoded'; }
    // `text` is a body handed over already encoded (ONE and 瓜子 sign and encrypt their own form bodies).
    else if (options.text !== undefined) body = String(options.text == null ? '' : options.text);
    let url = String(address);
    // `query` adds parameters without dropping the ones the address already carries.
    if (options.query && typeof options.query === 'object') {
        const extra = new URLSearchParams();
        for (const [name, value] of Object.entries(options.query)) if (value != null) extra.append(name, String(value));
        if ([...extra].length) url += (url.includes('?') ? '&' : '?') + extra.toString();
    }
    const response = request(url, {
        method, headers, body,
        buffer: String(options.responseType || '').toLowerCase() === 'base64' ? 2 : 0,
        timeout: Number(options.timeoutMs) > 0 ? Number(options.timeoutMs) : 20000,
        encoding: options.encoding || 'utf-8',
        // A source may route through a proxy of its own (`ext`: {"proxy":"socks5://127.0.0.1:1080"});
        // sites that answer only some regions need it, and the plugin itself never has to know.
        proxy: options.proxy || settings.proxy || undefined
    });
    // A transport failure has no status; the plugin turns it into its own NETWORK failure.
    if (!response.code) throw Object.assign(new Error('WBX_ERROR: 网络请求失败 ' + String(address).slice(0, 160)), { code: 'NETWORK' });
    return response;
}

const signal = {
    aborted: false,
    reason: null,
    throwIfAborted() {},
    addEventListener() {},
    removeEventListener() {}
};

const html = { load: text => cheerio.load(String(text == null ? '' : text)) };

// Cache is the app's own: a session's answers are already memoised per source, so a plugin's TTL
// request is accepted and only its generation counter is meaningful (it never recycles mid-run).
const cache = { seconds: value => Number(value) || 0, get generation() { return 1; }, get list() { return 0; } };

let requestScope = null;
const context = {
    get settings() { return settings; },
    // WeBox publishes a fixed capability set so a plugin can gate on it before using one
    // (`requires: ['memoryHls']`), and this runtime offers all six: cheerio, native crypto,
    // an in-memory HLS rewrite, media hooks, binary buffers, and WebAssembly through the host.
    get capabilities() {
        return { html: true, crypto: true, memoryHls: true, mediaProcessor: true, binary: true, compute: true };
    },
    get url() { return { origin, resolve, parse: value => { try { return new URL(String(value)); } catch { return null; } } }; },
    get http() { return transport; },
    get html() { return html; },
    get crypto() { return crypto; },
    get binary() { return binary; },
    get store() { return store; },
    get cache() { return cache; },
    get signal() { return signal; },
    // Compute runs the plugin's own code, which may instantiate WebAssembly: QuickJS has no engine, so the
    // host runs it in Node (WebBoxCompute) — the bundled node on the Mac, the embedded one on iPhone/iPad.
    get compute() {
        return {
            async run(request_) {
                const binaries = {};
                for (const [name, value] of Object.entries((request_ && request_.binaries) || {})) {
                    binaries[name] = ArrayBuffer.isView(value) || value instanceof ArrayBuffer
                        ? Buffer.from(value instanceof ArrayBuffer ? new Uint8Array(value) : value).toString('base64')
                        : String(value == null ? '' : value);
                }
                const answer = JSON.parse(host('compute', JSON.stringify({
                    code: String((request_ && request_.code) || ''),
                    input: (request_ && request_.input) == null ? {} : request_.input,
                    binaries,
                    timeoutMs: Number(request_ && request_.timeoutMs) || 10000
                })));
                if (answer && answer.error) fail('UNSUPPORTED', '计算模块运行失败：' + String(answer.error).slice(0, 200));
                return answer ? answer.result : null;
            }
        };
    },
    // WeBox calls this as log(level, message) with a level from debug/info/warn/error; a plugin that
    // passes only a message still reads sensibly.
    log: (level, message) => message === undefined
        ? log('webox', String(level == null ? '' : level))
        : log(String(level || 'info'), String(message)),
    fail,
    get scope() { return requestScope; }
};

// --- Adapter: the plugin's four methods as the TVBox spider -----------------------------------
// vod_play_url carries no media address of its own: an episode is `webox://<content>/<group>/<episode>`,
// and `play` turns that identity into the real address. `#` and `$` separate entries, so they are
// replaced inside names.
const clean = text => String(text == null ? '' : text).replace(/[#$]/g, ' ').replace(/\s+/g, ' ').trim();
const episodeAddress = (content, group, episode) => 'webox://' + [content, group, episode].map(v => encodeURIComponent(String(v))).join('/');
function parseAddress(address) {
    const text = String(address || '');
    if (!text.startsWith('webox://')) return null;
    const parts = text.slice('webox://'.length).split('/').map(part => decodeURIComponent(part));
    return parts.length === 3 ? { content: parts[0], group: parts[1], episode: parts[2] } : null;
}

const vod = item => {
    const fields = { vod_id: String(item.id), vod_name: clean(item.title), vod_remarks: clean(item.subtitle) };
    if (item.poster) fields.vod_pic = String(item.poster);
    if (item.kind) fields.vod_tag = String(item.kind);
    if (item.year) fields.vod_year = String(item.year);
    if (item.summary) fields.vod_content = String(item.summary);
    return fields;
};

function listAnswer(result) {
    const items = (result && Array.isArray(result.items) ? result.items : []).filter(item => item && item.id && item.title);
    return { page: 1, pagecount: result && result.nextCursor ? 2 : 1, limit: items.length, total: items.length, list: items.map(vod) };
}

function definitionOrFail() {
    if (!definition) fail('UNSUPPORTED', '这个插件没有调用 WeBox.define，不是可用的 WeBox 插件');
    return definition;
}

// A plugin pages with an opaque cursor, not a number. Page N is reached by walking the cursor chain
// from page 1; the chain and the answers already fetched are kept for the session, so paging forward
// and back does not re-request or re-walk.
const walks = new Map();
const pages = new Map();
const walkKey = (method, category, query) => method + '\n' + category + '\n' + query;

// The category is the first select filter's value; plugins with no filter get a single entry.
function filterKey(def) {
    const first = (Array.isArray(def.__filters) ? def.__filters : []).find(f => f && f.type === 'select' && f.key);
    return (first && first.key) || 'category';
}

async function page(method, category, query, index) {
    const def = definitionOrFail();
    const key = walkKey(method, category, query);
    const stored = pages.get(key);
    if (stored && stored.has(index)) return stored.get(index);
    const ctx = Object.create(context);
    requestScope = { method, category, query };
    let result;
    try {
        if (method === 'search') result = await def.search(ctx, { query, cursor: index === null ? null : index, refresh: false });
        else result = await def.list(ctx, { filters: category && category !== 'home' ? { [filterKey(def)]: category } : {}, cursor: index === null ? null : index, refresh: false });
    } finally { requestScope = null; }
    result = result && typeof result === 'object' ? result : { items: [], nextCursor: null };
    const kept = pages.get(key) || new Map();
    const number = [...(walks.get(key) || [null])].length;
    kept.set(Number.isInteger(index) ? index : number, result);
    pages.set(key, kept);
    return result;
}

async function walk(method, category, query, pageNumber) {
    const target = Math.max(1, Math.min(200, Number(pageNumber) || 1));
    const key = walkKey(method, category, query);
    let chain = walks.get(key);
    if (!chain) { chain = [null]; walks.set(key, chain); }
    let result = null;
    for (let number = 1; number <= target; number++) {
        const cursor = chain[number - 1];
        if (cursor === null && number > 1) return { items: [], nextCursor: null };
        result = await page(method, category, query, cursor);
        const next = result.nextCursor == null ? null : String(result.nextCursor);
        if (chain.length === number) chain.push(next); else chain[number] = next;
        if (next === null && number < target) return { items: [], nextCursor: null };
    }
    return result || { items: [], nextCursor: null };
}

const spider = {
    async init(extension) {
        let values = {};
        if (extension) {
            if (typeof extension === 'string') { try { values = JSON.parse(extension) || {}; } catch { values = {}; } }
            else if (typeof extension === 'object') values = extension;
        }
        if (values.settings && typeof values.settings === 'object') values = values.settings;
        applySettings(definition, values);
        return { ready: true };
    },
    async home() {
        const def = definitionOrFail();
        let filters = [];
        try { filters = def.filters ? await def.filters(Object.create(context)) : []; } catch { filters = []; }
        def.__filters = Array.isArray(filters) ? filters : [];
        const classes = [{ type_id: 'home', type_name: '首页' }];
        const first = def.__filters.find(f => f && f.type === 'select' && Array.isArray(f.options) && f.options.length);
        if (first) for (const option of first.options) {
            const value = String(option.value == null ? option.label : option.value);
            if (!classes.some(c => c.type_id === value)) classes.push({ type_id: value, type_name: clean(option.label || value) });
        }
        let list = [];
        try {
            const result = await walk('list', classes[0].type_id, '', 1);
            list = listAnswer(result).list;
        } catch (error) { log('webox home list', String(error && error.message || error)); }
        return { class: classes, list };
    },
    async category(typeId, page) {
        const category = String(typeId || 'home');
        return listAnswer(await walk('list', category, '', page));
    },
    async search(keyword, quick, page) {
        const query = String(keyword || '').trim();
        if (!query) return { list: [] };
        return listAnswer(await walk('search', '', query, page));
    },
    async detail(ids) {
        const def = definitionOrFail();
        const id = String(ids == null ? '' : ids).split(',').map(v => v.trim()).filter(Boolean)[0];
        if (!id) fail('NOT_FOUND', '缺少内容标识');
        const ctx = Object.create(context);
        requestScope = { method: 'detail', id };
        let result;
        try { result = await def.detail(ctx, { id }); } finally { requestScope = null; }
        if (!result) fail('NOT_FOUND', '该内容没有详情');
        const groups = (Array.isArray(result.groups) ? result.groups : []).filter(group => group && Array.isArray(group.episodes) && group.episodes.length);
        const content = String(result.id == null ? id : result.id);
        const fields = {
            vod_id: content,
            vod_name: clean(result.title || id),
            vod_play_from: groups.map(group => clean(group.name || group.id)).join('$$$'),
            vod_play_url: groups.map(group => group.episodes
                .map(episode => clean(episode.name || episode.id) + '$' + episodeAddress(content, group.id, episode.id))
                .join('#')).join('$$$')
        };
        if (result.poster) fields.vod_pic = String(result.poster);
        if (result.summary) fields.vod_content = String(result.summary);
        if (result.year) fields.vod_year = String(result.year);
        if (result.kind) fields.vod_tag = String(result.kind);
        return { list: [fields] };
    },
    async play(flag, address) {
        const def = definitionOrFail();
        const reference = parseAddress(address);
        if (!reference) fail('NOT_FOUND', '播放地址无效，请重新打开详情');
        const ctx = Object.create(context);
        requestScope = { method: 'play', ...reference };
        let result;
        // `purpose` is what the player is asking for: a plugin that signs its playback request checks it
        // (4k影视 rejects anything but playback/download). Downloads use the same address here, so this
        // reports playback and the app decides what to do with the stream.
        try { result = await def.play(ctx, { contentId: reference.content, groupId: reference.group, episodeId: reference.episode, purpose: 'playback' }); }
        finally { requestScope = null; }
        const sources = (result && Array.isArray(result.sources) ? result.sources : []).filter(source => source && typeof source.url === 'string' && /^https?:\/\//i.test(source.url));
        if (sources.length) {
            const source = sources[0];
            const headers = { ...(source.headers || {}) };
            const answer = { parse: 0, url: source.url, header: JSON.stringify(headers), playUrl: '' };
            if (source.mime) answer.mime = String(source.mime);
            return answer;
        }
        // A plugin may hand back an HLS manifest it already fetched (肉 unwraps one from a PNG payload), with
        // media hooks that adjust each request and response. The app serves that over loopback and asks the
        // hooks per request, so the player still gets an ordinary http address.
        const inline = (result && Array.isArray(result.sources) ? result.sources : []).find(source => source && typeof source.manifest === 'string');
        if (!inline) fail('UNSUPPORTED', '该线路没有可以直接播放的地址');
        return { parse: 0, url: publishManifest(def, inline, reference), header: '{}', playUrl: '' };
    }
};

// Installed before the plugin loads, so `__tvbox.init` finds a spider even for a plugin that never
// calls `WeBox.define` (it then fails with a message that says exactly that).
globalThis.__JS_SPIDER__ = spider;

// --- Media pipeline ---------------------------------------------------------------------------
// A plugin that answers `play` with a manifest instead of a URL also brings hooks: the app asks them about
// every media request (headers, and the body that comes back). The proxy (WebBoxMedia.swift) calls back
// into this session through `__webox.mediaFetch`, so the plugin's own rules — 肉's Cookie handling and its
// PNG-wrapped segments — apply exactly as they would inside WeBox.
const mediaSessions = new Map();

function publishManifest(def, source, reference) {
    const processor = (source && source.processor) || {};
    const token = 'wxm' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
    mediaSessions.set(token, {
        definition: def,
        headers: { ...((source && source.headers) || {}) },
        processor,
        context: processor.context || {},
        reference
    });
    const address = host('mediaPublish', JSON.stringify({
        token,
        manifest: String(source.manifest),
        baseUrl: String(source.baseUrl || '')
    }));
    if (typeof address !== 'string' || !address) fail('UNSUPPORTED', '媒体代理没有启动，请稍后重试');
    // Only the newest few sessions are worth keeping: a session per episode would grow without bound.
    if (mediaSessions.size > 8) mediaSessions.delete(mediaSessions.keys().next().value);
    return address;
}

globalThis.__webox = {
    async mediaFetch(input) {
        const entry = mediaSessions.get(String((input && input.token) || ''));
        if (!entry) fail('NOT_FOUND', '媒体会话已失效，请重新播放');
        const media = (entry.definition && entry.definition.media) || {};
        const names = entry.processor || {};
        const hook = name => (typeof media[name] === 'function' ? media[name] : null);
        const requestHook = hook(names.request || 'request');
        const responseHook = hook(names.response || 'response');
        const ctx = Object.create(context);
        const scope = entry.context || {};
        const kind = input.kind;
        let headers = { ...entry.headers };
        let target = String(input.url || '');
        if (requestHook) {
            const outcome = await requestHook(ctx, { url: target, headers: { ...headers }, kind, context: scope });
            if (outcome && outcome.headers && typeof outcome.headers === 'object') headers = { ...outcome.headers };
            if (outcome && typeof outcome.url === 'string' && outcome.url) target = outcome.url;
        }
        const raw = request(target, { headers, buffer: 2, timeout: 30000 });
        if (!raw || !raw.code) throw new Error('WBX_ERROR: 媒体请求失败 ' + String(target).slice(0, 160));
        let bytes = toBytes(Buffer.from(String(raw.content == null ? '' : raw.content), 'base64'));
        let mime = '';
        if (responseHook) {
            const outcome = await responseHook(ctx, { body: bytes.slice().buffer, url: raw.url || target, headers, kind, context: scope });
            if (outcome && outcome.body != null) bytes = toBytes(outcome.body);
            if (outcome && outcome.mime) mime = String(outcome.mime);
        }
        const head = bytes.length >= 7 ? new TextDecoder().decode(bytes.subarray(0, 7)) : '';
        return {
            status: Number(raw.code) || 0,
            url: raw.url || target,
            mime,
            playlist: head === '#EXTM3U',
            body: Buffer.from(bytes).toString('base64')
        };
    }
};

globalThis.WeBox = {
    define(plugin) {
        if (!plugin || typeof plugin !== 'object') fail('INVALID_RESPONSE', '插件定义无效');
        const api = String(plugin.api || '');
        if (api && !api.startsWith('1.')) fail('UNSUPPORTED', '插件要求的 WeBox 接口版本 ' + api + ' 尚未支持');
        for (const method of ['list', 'search', 'detail', 'play']) {
            if (plugin[method] != null && typeof plugin[method] !== 'function') fail('INVALID_RESPONSE', '插件方法 ' + method + ' 无效');
        }
        definition = plugin;
        applySettings(plugin, null);
        if (plugin.__filters) plugin.__filters = plugin.__filters;
        log('webox plugin ' + String(plugin.id || plugin.name || '') + ' ' + String(plugin.version || '') + ' loaded');
        return plugin;
    },
    get version() { return '1.1'; }
};
