import Foundation
import Network

/// 在线播放加速：把一个支持 Range 的直链变成「多连接并发拉取、单连接顺序输出」。
///
/// 为什么要自己做这一层
/// ------------------
/// `AVPlayer` 对一条 http(s) 链接只开**一条**连接顺序读。而很多 CDN 对**单连接限速**
/// （同一 IP 开 8 条能跑满，开 1 条只有 1/8），这正是下载加速器存在的理由 ——
/// `DownloadAccelerator` 里 `DownloadTuning.connections` 那条注释记的就是这件事。
///
/// 播放走的是同一条链路，所以同一个手法成立：**把字节区间切段、多连接并发拉、按序写回**。
/// 但播放不能像下载那样先落盘再播（起播要快），所以这里做成**流式**：
///
///   AVPlayer ──单连接──► 本地回环（本文件） ──N 条并发──► 源站
///
/// 回环服务器收到 `Range: bytes=A-B` 后，把 `[A,B]` 再切成若干段并发拉取，
/// 谁先到就按顺序冲出去 —— 不落盘、不攒整段，首字节仍然是「最快的那条连接」的速度，
/// 稳态则是 N 条之和。
///
/// 明确的边界（不能做的事，写清楚比含糊更好）
/// ----------------------------------------
/// 1. **只对能 `206` 的源生效**。不支持 Range 的源只能顺序读，多连接无从下手，
///    这种情况直接 302/透传给原地址，不做无意义的包装。
/// 2. **HLS 不在这里处理**。m3u8 是「清单 + 一堆分片」，分片本来就是独立的 HTTP 资源，
///    AVPlayer 自己就会并发拉（`httpMaximumConnectionsPerHost`），再包一层只会多一跳。
///    强制走这里反而更慢。
/// 3. **不做转码、不做缓存**。它只改变「同一段字节由几条连接搬」，不改内容，
///    所以画质、音轨、字幕都不受影响。
///
/// 为什么用回环而不是 `AVAssetResourceLoader`
/// --------------------------------------
/// `AVAssetResourceLoaderDelegate` **只拦截非标准 scheme**；`http://` 是系统认识的协议，
/// 根本不会经过 delegate。想接管就必须换成自定义 scheme，但那样 AVPlayer 会当成
/// 未知协议而拒绝播放（它的 loader 只负责「取数据」，不负责「变成可播资产」）。
/// 回环服务器没有这个限制：URL 仍然是标准 http，AVPlayer 完全无感。
public final class PlaybackAccelerator: @unchecked Sendable {
    public static let shared = PlaybackAccelerator()

    /// 一个可加速的会话。
    public struct Session: Sendable {
        /// 交给 AVPlayer 的地址（回环）。
        public let url: URL
        /// 源地址，仅用于日志与排查。
        public let origin: URL
        /// 实际开了几条并发。
        public let lanes: Int
    }

    private let queue = DispatchQueue(label: "tvbox.playback.accelerator", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: Task<UInt16, Error>?
    /// 已登记的源：`token` → (源地址, 请求头)。回环路径里带 token，服务器据此找回源。
    private var routes: [String: Route] = [:]

    private struct Route: Sendable {
        /// 登记时的 token。用它当「探到的总长」的键 —— 一次播放会话一个值。
        let token: String
        let origin: URL
        let headers: [String: String]
        let lanes: Int
    }

    /// token → 已探到的总长。会话级缓存，`release` 时清掉。
    /// 见 `length(for:ranged:)` 的说明：只解决「同一会话重复探」，不跨会话复用。
    private var probedLengths: [String: Int64] = [:]
    /// token → 源站明确不支持 Range（预探的结论）。这条会话的请求直接透传，不再重探。
    private var unranged: Set<String> = []

    /// 是否值得为这个地址启用加速。
    ///
    /// 三个否决条件，每个都有具体理由：
    ///   · 非 http(s)：本地文件、`tvbox-download://` 之类的自造协议不需要也不该被代理。
    ///   · m3u8 / HLS：分片本身就并发，包一层只多一跳。
    ///   · 已经是回环：避免自己代理自己，形成递归。
    public static func canAccelerate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if url.pathExtension.lowercased() == "m3u8" { return false }
        // 清单地址可能没有扩展名（`/live/index` 之类），再看一眼路径关键词。
        let path = url.path.lowercased()
        if path.contains(".m3u8") || path.contains("/hls/") { return false }
        if let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost" { return false }
        return true
    }

    /// 登记一个源，返回可交给 AVPlayer 的回环地址。
    ///
    /// - Parameters:
    ///   - url: 源地址。
    ///   - headers: 播放它需要的请求头（Referer / UA 等，源站常常校验）。
    ///   - lanes: 并发连接数。默认取 `DownloadSettings` 的 `connections`，
    ///     与下载共用同一个用户设置 —— 用户在下载页调过「连接数」，播放也照那个来，
    ///     不需要再学一套旋钮。
    /// - Returns: nil 表示不值得加速（见 `canAccelerate`），调用方继续用原地址。
    /// - Parameter lanes: 并发连接数。调用方从 `DownloadSettings`（`@MainActor`）取好再用 ——
    ///   这里不直接读它，否则非隔离语境引用主 actor 属性编不过。
    public func session(for url: URL, headers: [String: String], lanes: Int) async -> Session? {
        guard Self.canAccelerate(url) else { return nil }
        // ⛔ 并发车道要跟着「当前有几路在播」缩。
        //
        // 每路默认取用户设置的连接数（6～8 条隧道），而代理端口段只有 100 个
        // （`SRCPortPool.proxyRange` = 41500-41599，Loon 规则也只认这一段）。
        // 20 个小窗同时播就是 120～160 条：端口用尽后 `acquire` 返回 nil，
        // 连接退回临时端口 —— 那些端口不在规则段里，Loon 按自己的域名规则判，
        // 于是我们费了半天劲的出口选择在这一段等于失效。
        //
        // 所以按活跃路数均分一个固定预算：1 路仍可拿满 8 条，20 路各 2 条（共 40 条）。
        let active = lock.withLock { routes.count }
        let width = Self.laneAllowance(active: active, requested: lanes)
        // 1 条连接等于没加速 —— 直接不包装，省掉一跳回环。
        guard width > 1 else { return nil }
        if width < lanes {
            Diagnostics.shared.record(.debug, "player",
                "accelerator lanes \(lanes) → \(width) (active=\(active), budget=\(Self.laneBudget))")
        }

        do {
            let base = try await base()
            let token = Self.token()
            let route = Route(token: token, origin: url, headers: headers, lanes: width)
            lock.withLock { routes[token] = route }
            // 登记的那一刻就把总长探掉。
            //
            // AVPlayer 的第一条请求要么是 `bytes=0-1`、要么是直接从 0 开始的区间；两者都要先
            // 知道总长才能切段，不知道就得先等一个 `bytes=0-0` 的往返 —— 那一个往返正好压在
            // 首帧上。这里提前发出去：AVPlayer 此时还在建 item、连回环都还没连上，探针已经在
            // 路上了，等它的请求到达时总长大半已经就位。源站不支持 Range 时顺带记下，
            // 让第一条请求直接透传，也不必再白探一次。
            probe(route) { [weak self] length, ranged in
                guard let self else { return }
                self.lock.withLock {
                    guard self.routes[token] != nil else { return }   // 已经 release，别再塞回去
                    if ranged, let length { self.probedLengths[token] = length }
                    else if !ranged { self.unranged.insert(token) }
                }
            }
            // 把源地址的扩展名带过去：AVPlayer 会根据它判断容器类型，
            // 丢成 `/p/<token>` 会让某些格式认不出来。
            let ext = url.pathExtension
            let name = ext.isEmpty ? token : "\(token).\(ext)"
            let loopback = base.appending(path: name)
            return Session(url: loopback, origin: url, lanes: width)
        } catch {
            Diagnostics.shared.record(.warning, "playback", "accelerator unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// 全局车道预算：同时播 20 路也别把代理端口段挤爆。
    ///
    /// 48 不是随便定的：代理端口段 100 个，留一半余量给接口/海报/清单那些短连接
    /// （它们也走同一个池）。单路时仍给满 8 条，不影响「只有一集在播」的绝大多数场景。
    static let laneBudget = 48

    /// 当前活跃 `active` 路时，新来的这一路最多能拿几条连接。
    ///
    /// 纯函数，便于测试。下限 2：1 条等于没加速（调用方会直接返回 nil，连回环都不走）。
    static func laneAllowance(active: Int, requested: Int) -> Int {
        let fair = max(2, laneBudget / max(1, active + 1))
        return max(1, min(requested, 8, fair))
    }

    /// 释放一个会话。页面离开时调用，避免 `routes` 无限增长。
    public func release(_ session: Session) {
        let token = session.url.deletingPathExtension().lastPathComponent
        lock.withLock {
            routes.removeValue(forKey: token)
            // 总长缓存跟着会话走：同一个 token 不会复活，留着只会长内存。
            probedLengths.removeValue(forKey: token)
            unranged.remove(token)
        }
    }

    // MARK: 服务器

    private func base() async throws -> URL {
        if let running = lock.withLock({ port }).map({ Self.url(for: $0) }) { return running }
        let task = lock.withLock { () -> Task<UInt16, Error> in
            if let starting { return starting }
            let task = Task { try await self.start() }
            starting = task
            return task
        }
        do {
            return Self.url(for: try await task.value)
        } catch {
            lock.withLock { starting = nil }
            throw error
        }
    }

    private static func url(for port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)/")! }

    private func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let settled = Locked(false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    self?.lock.withLock { self?.port = port }
                    guard settled.take() else { return }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard settled.take() else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    /// 读请求头（到 `\r\n\r\n` 为止）。只读头，不动 body —— 播放只有 GET。
    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var head = buffer
            if let data { head.append(data) }
            if error != nil || complete {
                connection.cancel(); return
            }
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                // 头还没读完；限长防止恶意长头把内存吃光。
                if head.count > 32 * 1024 { connection.cancel(); return }
                self.receiveHead(connection, buffer: head)
                return
            }
            let headerText = String(decoding: head[..<end.lowerBound], as: UTF8.self)
            self.handle(headerText, on: connection)
        }
    }

    private func handle(_ headerText: String, on connection: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let target = String(parts[1])
        let name = target.split(separator: "?").first.map(String.init) ?? target
        let token = (name as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "")
        guard let route = lock.withLock({ routes[token] }) else {
            respond(connection, status: "404 Not Found")
            return
        }

        // 把客户端的 Range 原样转给源站；没有 Range 就从头拉。
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        stream(route, range: range, on: connection)
    }

    /// 核心：把请求的区间切段并发拉，按序冲给 AVPlayer。
    ///
    /// 不做「先取全长再分段」那套：播放要的是尽快出画面，等一个 HEAD 往返再开始是多余的。
    /// 直接按「无 Range 就从 0 开始、有 Range 就按它」发 N 条请求，
    /// 每条自己带 `Range`，谁先回来就先冲 —— 顺序由 `expected` 游标保证。
    private func stream(_ route: Route, range: String?, on connection: NWConnection) {
        // 解析 `bytes=A-B` / `bytes=A-`；没有就当作整段。
        var start: Int64 = 0
        var end: Int64?
        if let range, range.lowercased().hasPrefix("bytes=") {
            let spec = range.dropFirst(6)
            let halves = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let first = halves.first, let value = Int64(first) { start = value }
            if halves.count > 1, let value = Int64(halves[1]) { end = value }
        }

        // 捕获成不可变值：闭包在 URLSession 的队列上跑，捕获 `var` 会被
        // `SendableClosureCaptures` 拒绝（同一区间的可变量不允许跨并发域）。
        let lower = start
        let upperBound = end

        // ★ 已知总长就直接分段，不再先探一次头。
        //
        // ⛔ 这是「起播慢」的独立成因之一（RCA H6，已判决）。
        //
        // 上一版**每一个回环请求**都先 `probe(route)` 发一次 `bytes=0-0` 拿总长，
        // 而 AVPlayer 起播时会连续打开多个 Range 请求（清单、首片、以及它在 seek 时的探测）。
        // 每个请求因此多出一个完整 RTT，n 个请求就是 n 个 RTT 串在起播前面。
        // 服务端测速与真机都指向同一个现象：直链播放比走加速器明显更快。
        //
        // 现在总长按 route 缓存（见 `Route.length` / `probedLengths`）：同一会话只探一次，
        // 之后所有请求直接走 `pump`。第一次仍要探（没有总长无法切段），
        // 但那是**整个会话一次**，不是每个请求一次。
        if let known = length(for: route, ranged: nil) {
            let upper = min(upperBound ?? (known - 1), known - 1)
            guard lower <= upper else {
                respond(connection, status: "416 Range Not Satisfiable")
                return
            }
            pump(route, from: lower, to: upper, on: connection)
            return
        }

        // 预探已经说明源站不支持 Range：原样透传，不必再白探一次。
        if lock.withLock({ unranged.contains(route.token) }) {
            redirect(connection, to: route.origin)
            return
        }

        // 不知道总长时分段没有依据：先探一次头，拿到 `Content-Length` 与 `Accept-Ranges`。
        probe(route) { [weak self] length, ranged in
            guard let self else { connection.cancel(); return }
            guard let length, ranged else {
                // 不支持 Range：原样重定向，不做无意义的包装。
                self.redirect(connection, to: route.origin)
                return
            }
            self.rememberLength(length, for: route)
            let upper = min(upperBound ?? (length - 1), length - 1)
            guard lower <= upper else {
                self.respond(connection, status: "416 Range Not Satisfiable")
                return
            }
            self.pump(route, from: lower, to: upper, on: connection)
        }
    }

    /// 已探到的总长缓存：token → 字节数。
    ///
    /// 只在**同一个 route（同一次播放会话）内**复用 —— 源站换文件、CDN 边缘不一致时，
    /// 跨会话复用旧长度会把 Range 算错，那是比慢更糟的错误。`release` 时一并清掉。
    /// `ranged` 参数保留给调用方语义（探针失败与「不支持 Range」都要重新探）。
    private func length(for route: Route, ranged: Bool?) -> Int64? {
        lock.withLock { probedLengths[route.token] }
    }

    private func rememberLength(_ length: Int64, for route: Route) {
        lock.withLock { probedLengths[route.token] = length }
    }

    /// 探一次头拿总长。用 `bytes=0-0` 而不是 HEAD：很多 CDN 的 HEAD 不给 `Content-Length`，
    /// 但 GET 一个字节一定会给 `Content-Range`，那里带着 `/总长`。
    private func probe(_ route: Route, completion: @escaping @Sendable (Int64?, Bool) -> Void) {
        var request = URLRequest(url: route.origin)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in route.headers { request.setValue(value, forHTTPHeaderField: key) }
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse else { completion(nil, false); return }
            let ranged = http.statusCode == 206
            var total: Int64?
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = contentRange.lastIndex(of: "/") {
                total = Int64(contentRange[contentRange.index(after: slash)...])
            }
            if total == nil { total = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) }
            completion(total, ranged)
        }.resume()
    }

    /// 按被加速地址的后缀给 `Content-Type`；认不出才退回二进制流。
    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "m4s": "video/mp4"
        case "m3u8": "application/vnd.apple.mpegurl"
        case "ts": "video/mp2t"
        case "m4a", "aac": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "webm": "video/webm"
        default: "application/octet-stream"
        }
    }

    /// 并发拉 `[from, to]`，按序写给 `connection`。
    private func pump(_ route: Route, from: Int64, to: Int64, on connection: NWConnection) {
        let span = to - from + 1
        // 段大小：太大则尾部一条慢连接拖住整体，太小则往返开销占比高。
        // 2 MB 与下载器的 `chunkMB` 默认值同一量级，且对 4 Mbps 的流够用。
        let chunk: Int64 = 2 << 20
        let lanes = max(1, min(route.lanes, Int((span + chunk - 1) / chunk)))

        // 先回响应头。`200` 而不是 `206`：我们回的是**整个被请求区间**，
        // 而 AVPlayer 已经知道它要的是这一段；再声明 206 会让它二次确认区间，
        // 平白多一次往返。长度写区间长度，客户端据此知道何时收完。
        var head = "HTTP/1.1 200 OK\r\n"
        // ⛔ 不能一律 `application/octet-stream`。
        //
        // 真机证据（20:03-20:07）：
        //   item.status=2 assetURL=http://127.0.0.1:63471/….mp4
        //   CoreMediaErrorDomain -12939 — HTTP response has no Content-Type
        // AVPlayer 拿到 octet-stream 等于「类型不明」，直接判失败；
        // 浏览器能猜，它不猜。按被加速地址的后缀给类型。
        head += "Content-Type: \(Self.mime(for: route.origin))\r\n"
        head += "Content-Length: \(span)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let state = PumpState(nextWrite: from, lanes: lanes)
        for lane in 0..<lanes {
            let laneStart = from + Int64(lane) * chunk
            guard laneStart <= to else { break }
            let laneEnd = min(laneStart + chunk - 1, to)
            fetchLane(route, from: laneStart, to: laneEnd, state: state, connection: connection, tail: to)
        }
    }

    /// 一条分段的拉取。到一段就交给 `PumpState` 按序释放。
    private func fetchLane(_ route: Route, from: Int64, to: Int64, state: PumpState,
                           connection: NWConnection, tail: Int64) {
        var request = URLRequest(url: route.origin)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        for (key, value) in route.headers { request.setValue(value, forHTTPHeaderField: key) }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, error == nil else {
                state.failed()
                connection.cancel()
                return
            }
            // 按序输出：`nextWrite` 之前的段必须等；之后的先攒着。
            let ready = state.deliver(from: from, data: data)
            for payload in ready {
                connection.send(content: payload, completion: .contentProcessed { _ in })
            }
            if state.allArrived {
                // 全部到齐：等最后一批 send 落完再关，避免截断。
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            _ = to; _ = tail
        }.resume()
    }

    private func redirect(_ connection: NWConnection, to url: URL) {
        var head = "HTTP/1.1 302 Found\r\n"
        head += "Location: \(url.absoluteString)\r\n"
        head += "Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(_ connection: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func token() -> String {
        var raw = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 按序释放

/// 把「乱序到达的分段」按起始偏移释放成一条有序字节流。
///
/// 为什么需要它：`lanes` 条连接完成顺序是随机的，而 HTTP 响应体必须是顺序的。
/// 没有这个游标，快的那条先冲出去、慢的后到 —— 播放器收到的是一片乱序字节，
/// 直接解码失败。这正是「多连接加速播放」最容易做错的地方。
private final class PumpState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextWrite: Int64
    private var pending: [Int64: Data] = [:]
    private let lanes: Int
    private var arrived = 0
    private var didFail = false

    init(nextWrite: Int64, lanes: Int) {
        self.nextWrite = nextWrite
        self.lanes = lanes
    }

    /// 交付一段。返回**现在可以按序冲出去**的若干块。
    func deliver(from: Int64, data: Data) -> [Data] {
        lock.withLock {
            arrived += 1
            pending[from] = data
            var out: [Data] = []
            // 只有正好接上游标的那段才放行，放行后继续看下一段是否也到了。
            while let next = pending[nextWrite] {
                pending.removeValue(forKey: nextWrite)
                out.append(next)
                nextWrite += Int64(next.count)
            }
            return out
        }
    }

    func failed() { lock.withLock { didFail = true } }

    var allArrived: Bool {
        lock.withLock { arrived >= lanes || didFail }
    }
}

/// 一个只用来「取一次并置位」的原子布尔。
private final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func take() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}
