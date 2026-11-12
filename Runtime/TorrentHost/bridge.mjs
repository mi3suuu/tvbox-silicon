// Torrent bridge for Yingxia: a magnet becomes a byte stream the app can play.
//
// One node process per app run. It keeps a WebTorrent client, and answers on a loopback port with a
// per-launch token:
//
//   POST /add              {"magnet":"…","wait":60}  → metadata, the video file to play, its length
//   GET  /stream/<hash>/<i>  Range: bytes=…          → 206 with exactly that slice (for MP4, which AVPlayer
//                                                      opens straight from this URL)
//   GET  /read/<hash>/<i>?offset=&count=              → raw bytes (for the repackager, which reads MKV/AVI
//                                                      at arbitrary offsets and turns it into HLS)
//   GET  /stat/<hash>                                 → progress, peers, speed
//   DELETE /torrent/<hash>                            → stop and forget
//
// WebTorrent fetches pieces on demand for the range being read, so a seek works before the file is done.

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import WebTorrent from './webtorrent.bundle.mjs'

const args = process.argv.slice(2)
const option = (name, fallback) => {
  const index = args.indexOf('--' + name)
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback
}
const root = path.resolve(option('root', path.join(process.cwd(), 'torrents')))
const token = option('token', '')
const port = Number(option('port', '0'))
fs.mkdirSync(root, { recursive: true })

const client = new WebTorrent({ maxConns: 80, dht: true, tracker: true })
client.on('error', (error) => log('client error ' + (error?.message || error)))

/** infoHash → { torrent, picked, added } */
const torrents = new Map()
/** infoHash → the metadata wait in flight, so two players asking at once share it. */
const waiting = new Map()

const log = (...values) => process.stderr.write('[torrent] ' + values.join(' ') + '\n')
const json = (res, code, body) => {
  const data = Buffer.from(JSON.stringify(body))
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': data.length })
  res.end(data)
}

/// 源站给的 tracker 常有半数是死的，DHT 也要时间。补几个长期在线的公共 tracker。
const TRACKERS = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://open.stealth.si:80/announce',
]

const DIRECT = new Set(['mp4', 'm4v', 'mov'])
const VIDEO = new Set(['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'flv', 'wmv', 'asf', 'rmvb', 'ts', 'm2ts', 'mpg', 'mpeg', 'vob'])
const extension = (name) => (name.split('.').pop() || '').toLowerCase()

/** The file worth playing: a direct-playable MP4 first, else the biggest video, else the biggest file. */
function pick(files) {
  const scored = files.filter((file) => VIDEO.has(extension(file.name)))
  const direct = scored.filter((file) => DIRECT.has(extension(file.name))).sort((a, b) => b.length - a.length)
  if (direct.length) return direct[0]
  if (scored.length) return scored.sort((a, b) => b.length - a.length)[0]
  return files.slice().sort((a, b) => b.length - a.length)[0]
}

function add(magnet, waitSeconds) {
  return new Promise((resolve, reject) => {
    const existing = [...torrents.values()].find((entry) => entry.torrent.magnetURI === magnet)
    if (existing) return resolve(existing)
    if (waiting.has(magnet)) return waiting.get(magnet).then(resolve, reject)
    const task = new Promise((done, fail) => {
      let settled = false
      const timer = setTimeout(() => {
        if (settled) return
        settled = true
        try { client.remove(magnet, { destroyStore: false }) } catch {}
        fail(Object.assign(new Error('no peers answered in ' + waitSeconds + 's'), { status: 504 }))
      }, (waitSeconds || 60) * 1000)
      client.add(magnet, { path: root, announce: TRACKERS }, (torrent) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        try { torrent.deselect(0, torrent.pieces.length - 1, false) } catch {}
        const file = pick(torrent.files)
        const entry = { torrent, file, added: Date.now() }
        torrents.set(torrent.infoHash, entry)
        for (const tracker of TRACKERS) { try { torrent.addTracker(tracker) } catch {} }
        log('added', torrent.infoHash, torrent.files.length, 'files;', file.name, file.length, 'bytes')
        done(entry)
      })
      client.once('error', (error) => {
        if (settled) return
        settled = true; clearTimeout(timer); fail(error)
      })
    }).finally(() => waiting.delete(magnet))
    waiting.set(magnet, task)
    task.then(resolve, reject)
  })
}

function describe(entry) {
  const { torrent, file } = entry
  const extensionName = extension(file.name)
  return {
    infoHash: torrent.infoHash,
    name: torrent.name,
    fileName: file.name,
    fileIndex: torrent.files.indexOf(file),
    length: file.length,
    total: torrent.length,
    direct: DIRECT.has(extensionName),
    peers: torrent.numPeers,
    files: torrent.files.map((item, index) => ({ index, name: item.name, length: item.length })),
  }
}

/** Bytes `[offset, offset+count)` of the picked file, waiting for the pieces that carry them. */
function read(entry, offset, count) {
  return new Promise((resolve, reject) => {
    const { file } = entry
    if (offset >= file.length) return resolve(Buffer.alloc(0))
    const end = Math.min(offset + Math.max(count, 1), file.length) - 1
    const chunks = []
    let size = 0
    const stream = file.createReadStream({ start: offset, end })
    const fail = (error) => { stream.destroy(); reject(error) }
    stream.on('data', (chunk) => { chunks.push(chunk); size += chunk.length })
    stream.on('end', () => resolve(Buffer.concat(chunks, size)))
    stream.on('error', fail)
  })
}

async function body(req) {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  const text = Buffer.concat(chunks).toString('utf8')
  return text ? JSON.parse(text) : {}
}

const TYPES = { mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime', mkv: 'video/x-matroska', webm: 'video/webm', avi: 'video/x-msvideo', ts: 'video/mp2t' }

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1')
    if (url.pathname === '/health') return json(res, 200, { ok: true, torrents: torrents.size, root })
    const supplied = url.searchParams.get('token') || req.headers['x-torrent-token'] || ''
    if (token && supplied !== token) return json(res, 403, { error: 'token' })

    if (req.method === 'POST' && url.pathname === '/add') {
      const input = await body(req)
      if (!input.magnet || !/^magnet:\?/i.test(input.magnet)) return json(res, 400, { error: 'magnet required' })
      const entry = await add(input.magnet, Math.min(Math.max(Number(input.wait) || 60, 10), 180))
      return json(res, 200, describe(entry))
    }

    if (url.pathname.startsWith('/torrent/') && req.method === 'DELETE') {
      const target = url.pathname.split('/').pop().toLowerCase()
      const entry = torrents.get(target)
      if (entry) { torrents.delete(target); entry.torrent.destroy({ destroyStore: true }) }
      return json(res, 200, { ok: true })
    }
    let kind, hash, index = 0
    const byFile = url.pathname.match(/^\/(stream|read)\/([0-9a-f]{40})\/(\d+)$/i)
    const byStat = url.pathname.match(/^\/stat\/([0-9a-f]{40})$/i)
    if (byFile) { kind = byFile[1].toLowerCase(); hash = byFile[2].toLowerCase(); index = Number(byFile[3]) }
    else if (byStat) { kind = 'stat'; hash = byStat[1].toLowerCase() }
    else return json(res, 404, { error: 'unknown ' + url.pathname })

    const entry = torrents.get(hash)
    if (!entry) return json(res, 404, { error: 'torrent not added' })

    if (kind === 'stat') {
      const { torrent, file } = entry
      return json(res, 200, {
        infoHash: hash, name: torrent.name, peers: torrent.numPeers,
        downloaded: torrent.downloaded, uploaded: torrent.uploaded,
        progress: torrent.progress, length: file.length,
        speed: torrent.downloadSpeed, ratio: torrent.ratio,
      })
    }

    // The repackager reads arbitrary slices; it names both ends itself.
    if (kind === 'read' && req.method !== 'HEAD') {
      const offset = Math.max(Number(url.searchParams.get('offset') || 0), 0)
      const count = Math.min(Math.max(Number(url.searchParams.get('count') || 65536), 1), 8 << 20)
      const data = await read(entry, offset, count)
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': data.length })
      return res.end(data)
    }

    // AVPlayer opens an MP4 from here: it sends Range and expects 206.
    const file = entry.file
    const type = TYPES[extension(file.name)] || 'application/octet-stream'
    const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '')
    if (req.method === 'HEAD') {
      res.writeHead(200, { 'content-type': type, 'content-length': file.length, 'accept-ranges': 'bytes' })
      return res.end()
    }
    if (range) {
      const start = range[1] ? Number(range[1]) : 0
      const end = range[2] ? Math.min(Number(range[2]), file.length - 1) : file.length - 1
      const data = await read(entry, start, end - start + 1)
      res.writeHead(206, {
        'content-type': type, 'content-length': data.length, 'accept-ranges': 'bytes',
        'content-range': `bytes ${start}-${start + data.length - 1}/${file.length}`,
      })
      return res.end(data)
    }
    res.writeHead(200, { 'content-type': type, 'content-length': file.length, 'accept-ranges': 'bytes' })
    return res.end(await read(entry, 0, file.length))
  } catch (error) {
    log('request failed', error?.stack || error)
    if (!res.headersSent) json(res, 500, { error: String(error?.message || error) })
    else res.destroy()
  }
})
server.timeout = 0
server.keepAliveTimeout = 0
server.listen(port, '127.0.0.1', () => {
  process.stdout.write(JSON.stringify({ port: server.address().port, token, root }) + '\n')
})

for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { try { client.destroy() } catch {} ; process.exit(0) })
