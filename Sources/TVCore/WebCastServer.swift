import Foundation
import Network

/// What the web UI drives. The app layer (Store) implements this so the web server can list, browse,
/// search and play any source the app can — every subscription the viewer added, plus the built-ins —
/// and control the viewer's own settings, without TVCore depending on SwiftUI.
@MainActor public protocol WebCastDataSource: AnyObject {
    /// The sources to offer, in display order, plus the merged subscription they run against.
    func webCastState() async -> WebCastState
    /// A ready-to-use catalog client for one source, resolved against the merged subscription.
    func webCastClient(for sourceKey: String) async throws -> (CatalogClient, siteName: String)

    // The four lists a viewer also expects to see here: the same data the app shows, filtered by
    // the active environment and the privacy vault exactly as the app filters it. Default
    // implementations below return empty, so a data source need not implement what it has no
    // opinions about — but the app's Store supplies every one of them.
    func webCastLive() async -> [WebCastState.LiveInfo]
    func webCastFavorites() async -> [WebCastState.FavoriteInfo]
    func webCastHistory() async -> [WebCastState.HistoryInfo]
    func webCastDownloads() async -> [WebCastState.DownloadInfo]
}

public extension WebCastDataSource {
    func webCastLive() async -> [WebCastState.LiveInfo] { [] }
    func webCastFavorites() async -> [WebCastState.FavoriteInfo] { [] }
    func webCastHistory() async -> [WebCastState.HistoryInfo] { [] }
    func webCastDownloads() async -> [WebCastState.DownloadInfo] { [] }
}

/// A snapshot the web server hands out: every visible source, and the live settings the web UI edits.
public struct WebCastState: Sendable {
    public struct SourceInfo: Codable, Sendable {
        public let key: String
        public let name: String
        public let runtime: String
        public let hidden: Bool
        public init(key: String, name: String, runtime: String, hidden: Bool) {
            self.key = key; self.name = name; self.runtime = runtime; self.hidden = hidden
        }
    }
    /// A live playlist the viewer can open here, played through the same relay as catalog media.
    public struct LiveInfo: Codable, Sendable {
        public let name: String
        public let url: String
        public let builtIn: Bool
        /// The headers its playlist wants (many live feeds check Referer/UA), as a `ProxyHeaders` id.
        public let headerID: String?
        /// The channel's logo, if the source named one.
        public let logo: String
        public init(name: String, url: String, builtIn: Bool, headerID: String? = nil, logo: String = "") {
            self.name = name; self.url = url; self.builtIn = builtIn
            self.headerID = headerID; self.logo = logo
        }
    }
    /// A saved video, episode or cloud file. `kind` lets the page group them the way the app does.
    public struct FavoriteInfo: Codable, Sendable {
        public let kind: String
        public let videoName: String
        public let sourceName: String
        public let poster: String
        public let episodeName: String
        public let year: String
        public init(kind: String, videoName: String, sourceName: String, poster: String,
                    episodeName: String, year: String) {
            self.kind = kind; self.videoName = videoName; self.sourceName = sourceName
            self.poster = poster; self.episodeName = episodeName; self.year = year
        }
    }
    /// One row of the continue-watching list. `progress` is 0…1, and `episode` may be empty.
    public struct HistoryInfo: Codable, Sendable {
        public let videoName: String
        public let episodeName: String
        public let sourceName: String
        public let poster: String
        public let progress: Double
        public let position: Double
        public let duration: Double
        public let updatedAt: Date
        public let completed: Bool
        public init(videoName: String, episodeName: String, sourceName: String, poster: String,
                    progress: Double, position: Double, duration: Double, updatedAt: Date, completed: Bool) {
            self.videoName = videoName; self.episodeName = episodeName; self.sourceName = sourceName
            self.poster = poster; self.progress = progress; self.position = position
            self.duration = duration; self.updatedAt = updatedAt; self.completed = completed
        }
    }
    /// A download already on the device. Only its state is reported; the file stays on the phone.
    public struct DownloadInfo: Codable, Sendable {
        public let title: String
        public let episode: String
        public let poster: String
        public let status: String
        public let progress: Double
        public let failure: String
        public init(title: String, episode: String, poster: String, status: String,
                    progress: Double, failure: String) {
            self.title = title; self.episode = episode; self.poster = poster
            self.status = status; self.progress = progress; self.failure = failure
        }
    }

    public let sources: [SourceInfo]
    public let enabled: Bool
    public let port: Int
    public init(sources: [SourceInfo], enabled: Bool, port: Int) {
        self.sources = sources; self.enabled = enabled; self.port = port
    }
}

/// The embedded web server. A computer on the same Wi-Fi opens `http://<device-ip>:<port>/`, gets the
/// web UI, and drives the app through the JSON API under the per-launch `token`. Media playback relays
/// through the app's own `LocalProxyServer`, so Referer / headers / HTTPS all work from a browser.
///
/// Reuses the `NWListener` pattern of `LocalMediaServer` and `LocalProxyServer`: a raw TCP listener,
/// hand-rolled HTTP, one response per connection (`Connection: close`).
public actor WebCastServer {
    public static let shared = WebCastServer()
    private let queue = DispatchQueue(label: "tvbox.webcast.server")
    private var listener: NWListener?
    private var port: UInt16?
    /// The web UI's own HTML/JS/CSS, embedded as a resource.
    private let webRoot: URL? = Bundle.module.url(forResource: "WebCast", withExtension: nil)

    public func stop() {
        listener?.cancel(); listener = nil; port = nil
    }

    /// Starts listening on the requested port. `bind 0.0.0.0` so other devices on the Wi-Fi reach it;
    /// `NWParameters.tcp` plus a chosen endpoint. Returns the actual port (the requested one, or an
    /// ephemeral one if it was taken).
    public func start(on requestedPort: Int) async throws -> UInt16 {
        if let port, port == UInt16(requestedPort) { return port }
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // `on:` binds the port while leaving the address unspecified, so NWListener listens on
        // every interface (0.0.0.0) — the whole point of Web Cast, a computer reaches the phone.
        // Setting `requiredLocalEndpoint` instead would confine it to loopback, unreachable off-device.
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(clamping: requestedPort)) ?? .any)
        listener = server
        server.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data())
        }
        let p = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // Guard against a double-resume: the state handler keeps firing for the listener's life.
            let resumed = LockedBox<Bool>(false)
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // On `.ready` the port may not be reported yet; ask the listener again and fall
                    // back to the requested port so the continuation always resolves.
                    let actual = server.port?.rawValue ?? UInt16(clamping: requestedPort)
                    if resumed.swap(true) { return }
                    continuation.resume(returning: actual)
                case .failed(let error):
                    if resumed.swap(true) { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    if resumed.swap(true) { return }
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            server.start(queue: queue)
        }
        port = p
        return p
    }

    /// Set by the app before the server is started; nil until then.
    @MainActor public func attach(_ source: any WebCastDataSource) {
        dataSourceBox = DataSourceBox(source)
    }

    /// The data source, wrapped so it can cross into the server's actor and back. The app sets it once
    /// on the main actor and only ever replaces it there; requests only read it.
    @MainActor private var dataSourceBox: DataSourceBox?

    /// A `@unchecked Sendable` holder for the app's main-actor data source, so the server's request
    /// handlers (which hop off the main actor) can reach it without a sendability error. The value is
    /// written once on the main actor before serving and never mutated afterwards.
    private final class DataSourceBox: @unchecked Sendable {
        let value: any WebCastDataSource
        init(_ value: any WebCastDataSource) { self.value = value }
    }

    // MARK: - HTTP plumbing

    /// Reads one request off the wire on a background queue, then hands it to the main actor, where
    /// the data source lives. Everything after the header is parsed is main-actor work.
    private nonisolated static func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
                let leftover = Data(bytes[headerEnd.upperBound...])
                Task { @MainActor in
                    await route(connection: connection, head: head, body: leftover)
                }
            } else if error != nil || complete || bytes.count > 1 << 20 {
                connection.cancel()
            } else {
                receive(connection, buffer: bytes)
            }
        }
    }

    @MainActor private static func route(connection: NWConnection, head: String, body: Data) async {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { send(connection, status: 400); return }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { send(connection, status: 400); return }
        let method = String(fields[0])
        let target = String(fields[1])

        // Read Content-Length body (for POST settings) if any remains.
        var requestBody = body
        if let lengthHeader = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let length = Int(lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
           requestBody.count < length {
            requestBody.append(await readBody(connection, length: length))
        }

        guard let dataSource = WebCastServer.shared.dataSourceBox?.value else { send(connection, status: 503, json: ["error": "not ready"]); return }
        await Self.dispatch(method: method, target: target, body: requestBody, head: head, connection: connection, dataSource: dataSource)
    }

    private static func readBody(_ connection: NWConnection, length: Int) async -> Data {
        var collected = Data()
        // The body may arrive across several TCP segments; keep receiving until `length` bytes are in,
        // or the connection signals it is done. A single receive is not enough for a POST split by the
        // network stack.
        while collected.count < length {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(length - collected.count, 1)) { data, _, complete, _ in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if complete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            collected.append(chunk)
        }
        return collected
    }

    @MainActor private static func dispatch(method: String, target: String, body: Data, head: String, connection: NWConnection, dataSource: any WebCastDataSource) async {
        // Target: /<route...>?<query>. Split the query off the path first so a route like
        // `/api/<source>/search` isn't seen as `/api/<source>/search?wd=...` (which never matches).
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let route = parts

        // The web UI itself (index.html), its assets, and the login endpoint are always reachable so a
        // browser can load the page and submit the password. Everything else is gated by the login
        // password when one is set, carried as the `X-WebCast-Token` header.
        if route.isEmpty {
            await serveWebFile(connection, path: "index.html")
            return
        }
        if route[0] == "assets" {
            let file = route.dropFirst().joined(separator: "/")
            await serveWebFile(connection, path: "assets/" + file)
            return
        }
        if route[0] == "api", route.count >= 2, route[1] == "login" {
            await handleLogin(target: target, connection: connection, body: body)
            return
        }

        // Gate everything else behind the password (if one is configured). The token can arrive as an
        // `X-WebCast-Token` header (fetch/API calls) or a `?token=` query (plain <img>/<video> tags
        // can't set headers). Header wins when both are present.
        if await requiresAuth() {
            let expected = await WebCastSettings.shared.token
            guard !expected.isEmpty else {
                send(connection, status: 401, json: ["error": "unauthorized"]); return
            }
            let provided = headerValue("X-WebCast-Token", in: head) ?? query(target)["token"]
            guard provided == expected else {
                send(connection, status: 401, json: ["error": "unauthorized"])
                return
            }
        }

        if route[0] == "api" {
            await handleAPI(route: Array(route.dropFirst()), method: method, body: body, target: target, connection: connection, dataSource: dataSource)
            return
        }
        if route[0] == "proxy" {
            await handleProxy(target: target, connection: connection, head: head)
            return
        }
        send(connection, status: 404, json: ["error": "not found"])
    }

    /// Whether the login password is enabled. When off — or when the switch is on but no password is set —
    /// no authentication is applied, so a blank password never locks the viewer out.
    @MainActor private static func requiresAuth() async -> Bool {
        let s = WebCastSettings.shared
        return s.requiresToken && !s.token.isEmpty
    }

    /// `GET /api/login?pwd=...` (or POST with a JSON body) checks the password and returns 200 on match.
    @MainActor private static func handleLogin(target: String, connection: NWConnection, body: Data) async {
        let expected = WebCastSettings.shared.token
        let settings = WebCastSettings.shared
        // No password configured → anything logs in (treats auth as disabled).
        if !settings.requiresToken || expected.isEmpty {
            send(connection, status: 200, json: ["ok": true, "requiresToken": false])
            return
        }
        let q = query(target)
        let candidate: String?
        if let p = q["pwd"] {
            candidate = p
        } else if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let p = obj["pwd"] as? String {
            candidate = p
        } else {
            candidate = nil
        }
        guard let candidate, candidate == expected else {
            send(connection, status: 401, json: ["error": "unauthorized"])
            return
        }
        send(connection, status: 200, json: ["ok": true, "requiresToken": true])
    }

    /// Reads a case-insensitive header value from the raw request head.
    private static func headerValue(_ name: String, in head: String) -> String? {
        let lower = name.lowercased()
        for line in head.components(separatedBy: "\r\n") {
            let idx = line.firstIndex(of: ":") ?? line.endIndex
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == lower else { continue }
            return line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - media proxy

    /// Relays a remote media URL (poster image or stream) so a computer's browser can play it. The
    /// browser asks `/proxy/<encoded-url>`; this fetches the URL here and streams the bytes back,
    /// rewriting m3u8 playlists so their segments also come through the proxy.
    private static func handleProxy(target: String, connection: NWConnection, head: String) async {
        // The URL is everything after `/proxy/` in the path, percent-decoded. A trailing `?token=...`
        // (added by the browser for plain <img>/<video> auth) is our own query, not part of the URL.
        guard let marker = target.range(of: "/proxy/") else { send(connection, status: 400); return }
        let encoded = String(target[marker.upperBound...])
        let urlPart = encoded.split(separator: "?", maxSplits: 1).first.map(String.init) ?? encoded
        guard let urlString = urlPart.removingPercentEncoding, let url = URL(string: urlString) else {
            send(connection, status: 400, json: ["error": "bad proxy url"]); return
        }

        // The app's own playback schemes (`tvbox-cloud`, `tvbox-hongguo`, `tvbox-dash`) are not HTTP:
        // AVPlayer reads them through a resource loader. Serve them here as ordinary ranged responses
        // so the browser plays them too, instead of telling the viewer to go back to the phone.
        if let virtual = await WebCastVirtualStreams.source(for: url) {
            let own = Self.proxyQuery(target)
            await serve(virtual, connection: connection, head: head,
                        headerID: own["h"], token: own["token"])
            return
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            send(connection, status: 400, json: ["error": "bad proxy url"]); return
        }

        // Channel headers the source handed back (a Referer, a signed UA, a referer token) are what
        // makes the CDN serve the file at all. The app plays with them via
        // `AVURLAssetHTTPHeaderFieldsKey`; a browser cannot set them on <video>, so the page passes an
        // opaque `?h=<id>` and the server replays the stored set. Only the id rides in the URL: these
        // headers are long and some carry credentials that must stay off the browser's address bar.
        var headers: [String: String] = ["User-Agent": HTTPClient.userAgent]
        if let id = Self.proxyQuery(target)["h"], let stored = ProxyHeaders.shared.headers(for: id) {
            headers.merge(stored) { _, new in new }
        }
        let incomingRange = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        if let incomingRange { headers["Range"] = incomingRange }
        // Referer: many CDNs refuse requests without one. Only invented when the source named none —
        // overwriting the source's own Referer would break exactly the sources that need one.
        if headers["Referer"] == nil, let scheme = url.scheme, let host = url.host {
            headers["Referer"] = "\(scheme)://\(host)/"
        }

        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        // Chunks go out as they arrive, not after the whole file. `URLSession.data(for:)` waits for
        // the last byte before this connection writes anything, so a 2 GB MKV exhausted memory on
        // the phone and never reached the browser — the difference between "plays on the phone"
        // and "500 from the computer".
        let own = Self.proxyQuery(target)
        let relay = ProxyRelay(connection: connection, isPlaylist: url.pathExtension.lowercased() == "m3u8",
                               base: url, headerID: own["h"], token: own["token"])
        relay.start(request)
    }

    /// The upstream headers a browser needs to treat the relay as the origin: byte ranges and length.
    static func passthrough(_ http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["Content-Range", "Accept-Ranges", "Content-Length"] {
            if let value = http.value(forHTTPHeaderField: key) { out[key] = value }
        }
        return out
    }

    /// Serves one of the app's own scheme addresses. A playlist is answered whole; a file is answered
    /// from the byte range the browser asked for, which is what makes seeking work on a virtual stream.
    private static func serve(_ source: WebCastVirtualStreams.Source, connection: NWConnection,
                              head: String, headerID: String?, token: String?) async {
        let mime = await source.contentType()
        // A playlist has no length: it is a text document, and it must go out **rewritten** so the
        // variants and segments it names come back through us. Sending it verbatim was a dead end —
        // a DASH master names `tvbox-dash://…` variants and CDN segment URLs, neither of which a
        // browser can fetch on its own.
        guard let total = await source.length() else {
            do {
                let raw = try await source.read(at: 0, count: 8 << 20)
                let base = URL(string: "https://localhost/")!
                let body = Self.rewriteM3U8(raw, base: base, headerID: headerID, token: token)
                send(connection, status: 200, body: body, mime: mime, extraHeaders: ["Accept-Ranges": "none"])
            } catch {
                send(connection, status: 502, json: ["error": "\(error.localizedDescription)"])
            }
            return
        }
        let requested = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .flatMap { Self.byteRange($0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces), total: total) }

        // No Range → send the head of the file, capped so one request cannot be made to buffer
        // gigabytes before the browser asks for ranges itself. This is a *partial* answer either way,
        // so it must be 206 with a truthful Content-Range: a 200 here would tell the browser the file
        // ends at the cap, and playback would stop there.
        let range = requested ?? 0..<min(total, 1 << 20)
        do {
            let body = try await source.read(at: range.lowerBound, count: range.count)
            // An empty body means the range resolved past the file, or the stream failed. Answering
            // 206 with `bytes 0--1/total` would be a malformed header the browser cannot parse.
            guard !body.isEmpty else {
                send(connection, status: 416, json: ["error": "requested range not satisfiable"],
                     extraHeaders: ["Content-Range": "bytes */\(total)"])
                return
            }
            send(connection, status: 206, body: body, mime: mime,
                 extraHeaders: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.lowerBound + body.count - 1)/\(total)",
                 ])
        } catch {
            send(connection, status: 502, json: ["error": "\(error.localizedDescription)"])
        }
    }

    /// `bytes=start-end` (or `bytes=start-`, or a suffix `bytes=-n`) mapped onto `total`.
    static func byteRange(_ header: String, total: Int) -> Range<Int>? {
        guard let equals = header.firstIndex(of: "=") else { return nil }
        let spec = header[header.index(after: equals)...].split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            // `bytes=-n`: the last n bytes.
            guard let n = Int(parts[1]), n > 0 else { return nil }
            return max(0, total - n)..<total
        }
        guard let start = Int(parts[0]), start >= 0, start < total else { return nil }
        let end = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? total - 1, total - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    /// `headerID` keeps the source's own headers on every segment we hand back: a playlist's segments
    /// often sit behind the same Referer, so a rewritten child URL without `?h=` fails where the
    /// parent succeeded.
    static func rewriteM3U8(_ data: Data, base: URL, headerID: String? = nil, token: String? = nil) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        // Both of our own query parameters must survive the rewrite. `/proxy` sits behind the login
        // gate, so a segment URL that drops `token` is answered with 401 the moment a viewer has set
        // a password — the first request works (the page added it) and every later one fails.
        var query: [String] = []
        if let headerID { query.append("h=" + headerID) }
        if let token, !token.isEmpty { query.append("token=" + token) }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        let baseDir = base.deletingLastPathComponent()
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(line); continue
            }
            if trimmed.hasPrefix("#") {
                // `#EXT-X-KEY:…,URI="key.bin"` and `#EXT-X-MAP:…,URI="init.mp4"` name real segments
                // inside the tag. Escaping these to us is what makes encrypted and fMP4 playlists play:
                // left alone, the browser asks the CDN directly and the key fetch fails on Referer.
                out.append(rewriteAttributes(in: line, base: baseDir, suffix: suffix)); continue
            }
            // An address that is already absolute is proxied as given. That includes our own virtual
            // schemes (`tvbox-dash://…`): a DASH master lists its variants that way, and appending
            // them to `baseDir` produced `tvbox-dash://tok/tvbox-dash://tok/video-0.m3u8`.
            // Resolve, don't concatenate. `appendingPathComponent` treats the whole string as one
            // file name: a signed segment `seg.ts?sign=abc&t=1` became `seg.ts%3Fsign=abc&t=1` —
            // a *path* containing "?" with an empty query — so the CDN saw a different path and
            // answered 404. It also swallowed the leading slash of a root-relative `/root/x.ts`.
            let full = Self.resolveInPlaylist(trimmed, base: baseDir)
            out.append("/proxy/" + proxyEscape(full) + suffix)
        }
        return out.joined(separator: "\n").data(using: .utf8) ?? data
    }

    /// Rewrites every `URI="…"` attribute value inside a playlist tag to our proxy.
    ///
    /// Both quote styles are handled: the HLS examples all use double quotes, but a single-quoted
    /// `URI='…'` parses fine in players that accept it, and skipping those would leave the key or
    /// init segment pointing at the CDN — which fails on exactly the sources that need a Referer.
    private static func rewriteAttributes(in line: String, base: URL, suffix: String) -> String {
        guard line.contains("URI=") else { return line }
        var out = ""
        var rest = Substring(line)
        while let marker = rest.range(of: "URI=") {
            out += rest[..<marker.upperBound]
            rest = rest[marker.upperBound...]
            guard let quote = rest.first, quote == "\"" || quote == "'" else {
                // `URI=` not followed by a quote: leave the rest untouched rather than guess.
                out += rest
                return out
            }
            // Keep the opening quote in the output. Dropping it left a lone closing quote
            // (`URI=/proxy/…"`), which is not a quoted-string — every AES-128 key and fMP4 init
            // segment would parse as invalid and the playlist would be rejected.
            out.append(quote)
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: quote) else { out += rest; return out }
            let address = String(rest[..<close])
            rest = rest[close...]
            let full = Self.resolveInPlaylist(address, base: base)
            out += "/proxy/" + proxyEscape(full) + suffix
        }
        return out + rest
    }

    /// A playlist reference resolved against the playlist's own address.
    ///
    /// `WebAddress.resolve(_:relativeTo:)` already implements the rules a playlist needs — relative
    /// paths, root-relative `/a/b.ts`, protocol-relative `//cdn/a.ts`, and absolute `scheme://…` —
    /// and it keeps a `?query` where it belongs instead of folding it into the path.
    static func resolveInPlaylist(_ reference: String, base: URL) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        if let url = try? WebAddress.resolve(trimmed, relativeTo: base) { return url.absoluteString }
        // A custom scheme Foundation cannot join (`tvbox-dash://…`) is already absolute.
        return trimmed
    }

    /// Escapes an address for the `/proxy/` path. `.urlQueryAllowed` keeps `&` and `?` literal —
    /// which would split the wrapped address at our own query parser — so `?` and `#` are escaped too.
    private static func proxyEscape(_ address: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&#+")
        return address.addingPercentEncoding(withAllowedCharacters: allowed) ?? address
    }

    /// Our own query on a `/proxy/` request. The wrapped address is percent-escaped, so any `?` inside
    /// it is `%3F` and cannot be mistaken for our separator — the last unescaped `?` starts our query.
    static func proxyQuery(_ target: String) -> [String: String] {
        guard let marker = target.range(of: "/proxy/") else { return [:] }
        let rest = String(target[marker.upperBound...])
        guard let separator = rest.lastIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in rest[rest.index(after: separator)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            out[key] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? "") : ""
        }
        return out
    }


    // MARK: - API

    @MainActor private static func handleAPI(route: [String], method: String, body: Data, target: String, connection: NWConnection, dataSource: any WebCastDataSource) async {
        guard let action = route.first else { send(connection, status: 404); return }

        switch action {
        case "state":
            let state = await dataSource.webCastState()
            send(connection, status: 200, json: stateJSON(state))
        case "sources":
            let state = await dataSource.webCastState()
            send(connection, status: 200, json: ["sources": state.sources.map { ["key": $0.key, "name": $0.name, "runtime": $0.runtime, "hidden": $0.hidden] }])
        case "settings":
            await handleSettings(route: Array(route.dropFirst()), method: method, body: body, connection: connection, dataSource: dataSource)
        // The four lists beside the catalog. They are read-only: the phone stays the place that owns
        // playback history, favorites and downloads, and the page only mirrors what it already has.
        case "live":
            let lives = await dataSource.webCastLive()
            send(connection, status: 200, json: ["list": lives.map { live -> [String: Any] in
                var fields: [String: Any] = ["name": live.name, "url": live.url, "builtIn": live.builtIn,
                                             "logo": live.logo]
                if let id = live.headerID { fields["headerID"] = id }
                return fields
            }])
        case "favorites":
            let items = await dataSource.webCastFavorites()
            send(connection, status: 200, json: ["list": items.map {
                ["kind": $0.kind, "videoName": $0.videoName, "sourceName": $0.sourceName,
                 "poster": $0.poster, "episodeName": $0.episodeName, "year": $0.year]
            }])
        case "history":
            let entries = await dataSource.webCastHistory()
            send(connection, status: 200, json: ["list": entries.map {
                ["videoName": $0.videoName, "episodeName": $0.episodeName, "sourceName": $0.sourceName,
                 "poster": $0.poster, "progress": $0.progress, "position": $0.position,
                 "duration": $0.duration, "updatedAt": $0.updatedAt.timeIntervalSince1970,
                 "completed": $0.completed] as [String: Any]
            }])
        case "downloads":
            let items = await dataSource.webCastDownloads()
            send(connection, status: 200, json: ["list": items.map {
                ["title": $0.title, "episode": $0.episode, "poster": $0.poster,
                 "status": $0.status, "progress": $0.progress, "failure": $0.failure]
            }])
        default:
            // /api/<source>/<home|category|detail|search|play>
            guard route.count >= 2 else { send(connection, status: 404); return }
            await handleCatalog(source: route[0], action: route[1], target: target, body: body, connection: connection, dataSource: dataSource)
        }
    }

    @MainActor private static func handleCatalog(source: String, action: String, target: String, body: Data, connection: NWConnection, dataSource: any WebCastDataSource) async {
        do {
            let (client, _) = try await dataSource.webCastClient(for: source)
            switch action {
            case "home":
                let page = try await client.home()
                send(connection, status: 200, json: ["class": page.categories.map { ["type_id": $0.id, "type_name": $0.name] }])
            case "category":
                let q = query(target)
                let category = q["id"] ?? q["t"] ?? ""
                let pageNum = Int(q["pg"] ?? "1") ?? 1
                let page = try await client.list(category: category, query: "", page: pageNum)
                send(connection, status: 200, json: pageJSON(page))
            case "detail":
                let q = query(target)
                guard let id = q["id"], !id.isEmpty else { send(connection, status: 400, json: ["error": "missing id"]); return }
                let video = try await client.detail(id)
                send(connection, status: 200, json: videoJSON(video))
            case "search":
                let q = query(target)
                let wd = q["wd"] ?? q["q"] ?? ""
                let pageNum = Int(q["pg"] ?? "1") ?? 1
                let page = try await client.list(category: nil, query: wd, page: pageNum)
                send(connection, status: 200, json: pageJSON(page))
            case "play":
                let q = query(target)
                guard let flag = q["flag"], let address = q["address"], !address.isEmpty else {
                    send(connection, status: 400, json: ["error": "missing flag/address"]); return
                }
                // `videoID` is the episode's *video* id, which a type 3 (player-API) source needs as
                // `detailID` before the plugin will answer a play request. The app always has it — its
                // episodes come from a detail page that stamps `videoID` on every one — so dropping it
                // here made the web path the only caller that could ask for playback cold: the plugin
                // answered with no content and the error surfaced as a bare 500.
                let detailID = q["videoID"].flatMap { $0.isEmpty ? nil : $0 }
                let episode = Episode(id: "0", name: q["name"] ?? "Play", address: address,
                                      flag: flag, videoID: detailID)
                let channel = try await client.playback(episode)
                var out: [String: Any] = ["url": channel.url.absoluteString, "name": channel.name]
                // The browser cannot set these on <video>, so hand it an opaque id to replay through
                // `/proxy`. Without this a signed Referer / token UA is lost and the CDN refuses the
                // stream even though the phone plays it with those very headers.
                if let id = ProxyHeaders.shared.store(channel.headers) { out["headerID"] = id }
                // The app plays these beside the video; the page would otherwise have no way to offer
                // them. Each subtitle URL rides our proxy too, so its own headers come along.
                if !channel.subtitles.isEmpty {
                    out["subtitles"] = channel.subtitles.map { track -> [String: String] in
                        ["name": track.name, "url": track.url.absoluteString,
                         "language": track.language, "format": track.format]
                    }
                }
                // Skip marks let the page offer "skip intro" the way the app does.
                if !channel.skips.isEmpty {
                    out["skips"] = channel.skips.map { skip in
                        ["start": skip.start, "end": skip.end, "type": skip.kind.rawValue] as [String: Any]
                    }
                }
                send(connection, status: 200, json: out)
            default:
                send(connection, status: 404, json: ["error": "unknown action"])
            }
        } catch {
            send(connection, status: 500, json: ["error": error.localizedDescription])
        }
    }

    @MainActor private static func handleSettings(route: [String], method: String, body: Data, connection: NWConnection, dataSource: any WebCastDataSource) async {
        // GET /api/settings returns current settings; POST toggles enabled/port/hides a source.
        // (A POST has no sub-path, so `route` is empty — that must NOT be treated as the GET case.)
        if method == "GET" {
            let state = await dataSource.webCastState()
            send(connection, status: 200, json: ["enabled": state.enabled, "port": state.port])
            return
        }
        // The app layer applies mutations; it owns persistence and re-publishes state.
        await MainActor.run {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let enabled = obj["enabled"] as? Bool { WebCastSettings.shared.enabled = enabled }
                if let port = obj["port"] as? Int, (1...65535).contains(port) { WebCastSettings.shared.port = port }
                if let proxyMedia = obj["proxyMedia"] as? Bool { WebCastSettings.shared.proxyMedia = proxyMedia }
                if let hide = obj["hideSource"] as? String { WebCastCommands.shared.hide(hide) }
                if let show = obj["showSource"] as? String { WebCastCommands.shared.show(show) }
                // Re-apply the switch/port so the server restarts to match.
                WebCastCommands.shared.apply()
            }
        }
        let state = await dataSource.webCastState()
        send(connection, status: 200, json: ["enabled": state.enabled, "port": state.port])
    }

    // MARK: - JSON

    @MainActor private static func stateJSON(_ state: WebCastState) -> [String: Any] {
        [
            "enabled": state.enabled,
            "port": state.port,
            "proxyMedia": WebCastSettings.shared.proxyMedia,
            "requiresToken": WebCastSettings.shared.requiresToken && !WebCastSettings.shared.token.isEmpty,
            "sources": state.sources.map { ["key": $0.key, "name": $0.name, "runtime": $0.runtime, "hidden": $0.hidden] },
        ]
    }

    private static func pageJSON(_ page: CatalogPage) -> [String: Any] {
        ["list": page.videos.map(videoJSON), "pagecount": page.pageCount]
    }

    private static func videoJSON(_ video: Video) -> [String: Any] {
        var fields: [String: Any] = [
            "id": video.id,
            "name": video.name,
            "poster": video.poster?.absoluteString ?? "",
            "remarks": video.remarks,
            "synopsis": video.synopsis,
            "year": video.year ?? "",
            "category": video.category ?? "",
            // Carries `videoID` so the web UI can hand it back on `/play`: a type 3 source needs it as
            // `detailID`, and without it the plugin cannot resolve playback. Optional episodes (a plugin
            // that names no video id) omit the key rather than sending an empty string.
            "episodes": video.episodes.map { episode -> [String: Any] in
                var fields: [String: Any] = ["id": episode.id, "name": episode.name,
                                             "address": episode.address, "flag": episode.flag]
                if let videoID = episode.videoID, !videoID.isEmpty { fields["videoID"] = videoID }
                return fields
            },
        ]
        // A poster is fetched by `/proxy` exactly like a stream, and the same CDNs that insist on a
        // Referer for the video insist on it for the artwork. Without this id the image request goes
        // out with a bare User-Agent and the cover shows broken on the computer.
        if let id = ProxyHeaders.shared.store(video.posterHeaders) { fields["posterHeaderID"] = id }
        return fields
    }

    // MARK: - static files

    private static func serveWebFile(_ connection: NWConnection, path: String) async {
        guard let root = await WebCastServer.shared.webRoot else { send(connection, status: 404); return }
        // Reject path traversal; only serve files under the WebCast resource folder.
        guard !path.contains("..") else { send(connection, status: 404); return }
        let file = root.appendingPathComponent(path).standardizedFileURL
        let rootPrefix = root.standardizedFileURL.path
        guard file.path.hasPrefix(rootPrefix), let data = try? Data(contentsOf: file) else {
            send(connection, status: 404); return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js": mime = "application/javascript"
        case "css": mime = "text/css"
        case "svg": mime = "image/svg+xml"
        case "png": mime = "image/png"
        default: mime = "application/octet-stream"
        }
        send(connection, status: 200, body: data, mime: mime)
    }

    // MARK: - response

    private static func query(_ target: String) -> [String: String] {
        guard let q = target.split(separator: "?", maxSplits: 1).last else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            let value = kv.count > 1 ? kv[1].removingPercentEncoding ?? "" : ""
            out[key] = value
        }
        return out
    }

    private static func send(_ connection: NWConnection, status: Int, json: [String: Any],
                             extraHeaders: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        send(connection, status: status, body: data, mime: "application/json; charset=utf-8",
             extraHeaders: extraHeaders)
    }

    private static func send(_ connection: NWConnection, status: Int, body: Data = Data(), mime: String = "text/plain",
                             extraHeaders: [String: String] = [:]) {
        let reason = [200: "OK", 206: "Partial Content", 416: "Range Not Satisfiable", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Server Error", 502: "Bad Gateway", 503: "Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\n"
        // A playlist or error keeps its length; the range headers ride along so a browser can seek.
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Commands the web UI can issue that mutate the app's state. The app layer sets these closures so
/// the web server (in TVCore) can hide/show sources without importing SwiftUI's Store.
@MainActor public final class WebCastCommands {
    public static let shared = WebCastCommands()
    public var hide: (String) -> Void = { _ in }
    public var show: (String) -> Void = { _ in }
    public var apply: () -> Void = {}
}

/// Relays one proxied fetch to one browser connection, passing bytes through as they arrive.
///
/// The old path waited for `URLSession.data(for:)` to finish the entire body before writing the
/// first byte. For a small poster that is invisible; for a 2 GB episode it means the phone buffers
/// the whole file (or gets killed) and the browser gets nothing — which reads as a 500 on the
/// computer and "fine on the phone".
///
/// Back-pressure: `NWConnection.send` is asynchronous, so an unpaced loop runs at network speed into
/// an unbounded pipe. `outstanding` counts unacknowledged sends and reception pauses above the cap.
final class ProxyRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let isPlaylist: Bool
    private let base: URL
    /// The `?h=` id this request carried, replayed onto the playlist's segment URLs.
    private let headerID: String?
    /// The login token this request carried, likewise replayed so segments pass the auth gate.
    private let token: String?
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var playlist = Data()
    private var outstanding = 0
    /// Whether we have called `suspend()` and not yet paired it with a `resume()`.
    private var suspended = false
    /// Whether this response is a playlist, decided once at the response stage.
    private var servingPlaylist = false
    private var finished = false
    /// ~4 MB in flight: enough to keep a LAN saturated, small enough to bound memory.
    private static let outstandingLimit = 64

    init(connection: NWConnection, isPlaylist: Bool, base: URL, headerID: String? = nil, token: String? = nil) {
        self.connection = connection
        self.isPlaylist = isPlaylist
        self.base = base
        self.headerID = headerID
        self.token = token
        // A delegate-held session; invalidated once the body has been relayed.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
        super.init()
    }

    func start(_ request: URLRequest) {
        let task = session.dataTask(with: request)
        task.delegate = self
        lock.lock(); self.task = task; lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(status: 502, json: ["error": "proxy: the source returned no HTTP response"])
            return
        }
        let mime = http.mimeType ?? "application/octet-stream"
        // The playlist decision must be made once and remembered. Judging by extension here and by
        // extension again in `didComplete` while *also* accepting a playlist MIME mean a URL like
        // `get.php?id=1` sending `application/vnd.apple.mpegurl` took the "collect the playlist"
        // path (which sends no headers), then the media path at the end (which sends nothing) —
        // the browser received zero bytes and the server logged no error.
        let playlistResponse = isPlaylist || mime.contains("mpegurl")
        lock.lock(); servingPlaylist = playlistResponse; lock.unlock()
        if playlistResponse {
            // A playlist is small and must be rewritten whole so its segments come back through us.
            lock.lock(); playlist.removeAll(keepingCapacity: true); lock.unlock()
            completionHandler(.allow)
            return
        }
        // Media: relay the status and the range headers, then pump the body as it arrives.
        var head = "HTTP/1.1 \(http.statusCode) \(Self.reason(http.statusCode))\r\nContent-Type: \(mime)\r\n"
        let extra = WebCastServer.passthrough(http)
        // The body is chunked exactly when the upstream named no length; every later write must agree,
        // and the closing `0\r\n\r\n` is owed only in that case.
        let chunked = Int(extra["Content-Length"] ?? "") == nil
        if let raw = extra["Content-Length"], let length = Int(raw) { head += "Content-Length: \(length)\r\n" }
        else { head += "Transfer-Encoding: chunked\r\n" }
        for (key, value) in extra where key != "Content-Length" { head += "\(key): \(value)\r\n" }
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        lock.lock(); pendingChunked = chunked; lock.unlock()
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if lock.withLock({ servingPlaylist }) {
            lock.lock()
            // Bounded: a playlist over 8 MB is not a playlist.
            if playlist.count < 8_000_000 { playlist.append(data) }
            lock.unlock()
            return
        }
        // Count this chunk as in flight. The count must go up on *every* send, because the
        // completion below decrements on every completion — incrementing only when not paused
        // let the counter drift to zero, after which the limit was never reached again and the
        // relay buffered without bound (the exact thing this accounting exists to prevent).
        let inflight: Int = lock.withLock {
            outstanding += 1
            return outstanding
        }
        // Suspend the upstream once when too much is outstanding, and resume once when it drains
        // below half. Two suspends with one resume would park the task forever, so the transition
        // is recorded rather than repeated.
        if inflight > Self.outstandingLimit {
            let shouldSuspend = lock.withLock { () -> Bool in
                guard !suspended else { return false }
                suspended = true
                return true
            }
            if shouldSuspend { dataTask.suspend() }
        }
        let chunked = lock.withLock { pendingChunked }
        var payload = data
        if chunked { payload = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8) }
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let shouldResume: Bool = lock.withLock {
                outstanding = max(0, outstanding - 1)
                // Resume once half the window has drained: resuming at the limit would immediately
                // re-suspend on the next chunk and thrash.
                guard suspended, outstanding <= Self.outstandingLimit / 2 else { return false }
                suspended = false
                return true
            }
            // Resume unconditionally: `suspended` is only ever set right after we called
            // `suspend()`, and checking `dataTask.state` races that transition — reading `.running`
            // in the gap would skip the resume and park the task forever.
            if shouldResume { dataTask.resume() }
        })
    }

    /// Whether the browser connection is chunked (upstream gave no usable length).
    private var pendingChunked = false

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if lock.withLock({ servingPlaylist }) {
            let data = lock.withLock { playlist }
            let body = WebCastServer.rewriteM3U8(data, base: base, headerID: headerID, token: token)
            let http = task.response as? HTTPURLResponse
            finish(status: http?.statusCode ?? 200, body: body,
                   mime: http?.mimeType ?? "application/vnd.apple.mpegurl",
                   extra: http.map(WebCastServer.passthrough) ?? [:])
            return
        }
        // The chunked terminator must reach the browser before the connection is torn down: the
        // previous version issued `send` (async) and cancelled immediately, so the terminator was
        // usually dropped and a chunked response ended without its `0\r\n\r\n`. Cancel from the
        // send's completion instead. Only a task that ended cleanly gets a terminator — after an
        // error the body is incomplete and the browser should see a truncated response, not a
        // clean end, so that it re-requests the range.
        let chunked = lock.withLock { pendingChunked }
        let failed = error != nil
        if failed {
            // A stalled or cancelled upstream ends this connection; the browser retries the range.
            connection.cancel()
        } else if chunked {
            connection.send(content: Data("0\r\n\r\n".utf8),
                            completion: .contentProcessed { [connection] _ in connection.cancel() })
        } else {
            // A Content-Length body needs the same barrier the chunked terminator provides. Network
            // makes no promise that queued sends are written before the connection closes, so
            // cancelling straight away dropped whatever was still outstanding — up to a few MB of
            // tail under back-pressure — and the browser reported ERR_CONTENT_LENGTH_MISMATCH
            // mid-playback. An empty send's completion runs only after the earlier ones have drained.
            connection.send(content: Data(), completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
        session.invalidateAndCancel()
    }

    private func finish(status: Int, body: Data, mime: String, extra: [String: String]) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in extra where key != "Content-Length" { head += "\(key): \(value)\r\n" }
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        // A local, not the property: a capture list may not reach a member without `self.`, and
        // spelling out `self.connection` inside a `@Sendable` completion would capture the whole
        // relay. One binding says exactly what the closure needs.
        let link = connection
        link.send(content: response, completion: .contentProcessed { _ in link.cancel() })
        session.invalidateAndCancel()
    }

    private func finish(status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        finish(status: status, body: body, mime: "application/json; charset=utf-8", extra: [:])
    }

    private static func reason(_ status: Int) -> String {
        [200: "OK", 206: "Partial Content", 416: "Range Not Satisfiable", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
         500: "Server Error", 502: "Bad Gateway", 503: "Unavailable"][status] ?? "Error"
    }
}

/// Short-lived store for the HTTP headers a source's channel carries, keyed by an opaque id so the
/// browser can name them with `?h=<id>` instead of putting a signed Referer in its address bar.
///
/// Bounded and expiring: a playlist can spawn hundreds of segment requests, and an unbounded map
/// keyed by source-returned values is a leak. Entries live long enough for one episode's playback.
public final class ProxyHeaders: @unchecked Sendable {
    public static let shared = ProxyHeaders()
    private struct Entry { let headers: [String: String]; let expires: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// How long an id stays usable. Generous on purpose: a playlist can keep asking for the same
    /// `?h=` for the whole of a long film, and a live playlist re-reads its list every few seconds
    /// while the `h=` in those URLs never changes. A one-hour lifetime made a two-hour film lose its
    /// headers at minute 60 — the CDN then answered 403 and the picture simply stopped, with nothing
    /// in the log. Every hit also pushes the expiry out, so an actively playing stream never lapses.
    private static let lifetime: TimeInterval = 8 * 3600
    private static let limit = 256

    /// Registers a header set and returns its id, or nil when there is nothing to carry.
    public func store(_ headers: [String: String]) -> String? {
        let useful = headers.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard !useful.isEmpty else { return nil }
        let id = UUID().uuidString
        lock.lock()
        let now = Date()
        entries = entries.filter { $0.value.expires > now }
        // Oldest first out once at capacity; the viewer is watching one episode, not a hundred.
        if entries.count >= Self.limit {
            for key in entries.sorted(by: { $0.value.expires < $1.value.expires }).prefix(entries.count - Self.limit + 1).map(\.key) {
                entries.removeValue(forKey: key)
            }
        }
        entries[id] = Entry(headers: useful, expires: now.addingTimeInterval(Self.lifetime))
        lock.unlock()
        return id
    }

    public func headers(for id: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], entry.expires > Date() else { return nil }
        // Sliding expiry: a stream that is still asking for this id keeps it alive.
        entries[id] = Entry(headers: entry.headers, expires: Date().addingTimeInterval(Self.lifetime))
        return entry.headers
    }
}

/// A tiny thread-safe box for one-shot guards across the listener's state callbacks (which can fire
/// on any queue). `swap` returns the previous value so callers can tell who won the race.
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    @discardableResult func swap(_ newValue: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = newValue; return old
    }
}
