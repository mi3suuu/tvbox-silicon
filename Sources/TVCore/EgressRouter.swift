import Foundation

// MARK: - 出口（每请求决策）

/// 一次出网请求属于哪类流量。
///
/// 分类决定两件事：**赛跑时给直连多少领先时间**，以及**按 host 记住的结论能不能互相借用**。
/// 同一台 host 上，接口和封面往往是同一个站，但播放清单常常在另一台 CDN 上 ——
/// 所以「直连能看海报、播放要代理」在按 host 记账时天然分得开。
public enum EgressPurpose: String, Sendable, CaseIterable {
    case catalog
    case image
    case media

    /// 直连先跑多久、代理再起跑。
    ///
    /// 这个值是整套改动的速度关键：直连好的站，代理那条腿**永远不起跑**，代价为零；
    /// 直连被掐的站，最多只等这么久就有一条并行的代理腿在跑，用户感知不到 6–20 秒的挂死。
    var hedgeDelay: Duration {
        switch self {
        case .catalog: .milliseconds(220)
        case .image: .milliseconds(280)
        case .media: .milliseconds(420)
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .catalog: 14
        case .image: 20
        case .media: 12
        }
    }

    /// 决策用的短超时：只用来判断「这条腿能不能通」，不是传完整个文件。
    var probeTimeout: TimeInterval {
        switch self {
        case .catalog: 6
        case .image: 6
        // 播放清单能在 1 秒内响应；给它 4 秒是因为「连上了但被掐住」要等够才能确认，
        // 而这段等待正好与代理腿的起跑重叠，观众感知不到。
        case .media: 4
        }
    }
}

/// 观众对这个源（或这条线路）选的出口。
///
/// 三个态与 UI 上的一致，但语义从「改写地址」变成「允许哪条腿参与」：
/// - `.directOnly`：只走直连（含系统里那层 TUN 代理，由观看者自己的规则分流）；
/// - `.automatic`：直连先跑，跑不动才让代理起跑 —— 默认。
/// - `.preferProxy`：代理与直连同时起跑，谁先给出内容用谁。标成「代理」也不该比直连慢。
public enum EgressPolicy: Sendable, Equatable {
    case directOnly
    case automatic(proxyID: String?)
    case preferProxy(proxyID: String)

    public var proxyID: String? {
        switch self {
        case .directOnly: nil
        case .automatic(let id): id
        case .preferProxy(let id): id
        }
    }

    public var allowsProxy: Bool { proxyID != nil }
}

/// 一条腿：直连，或者经某台代理。
public struct EgressLeg: Sendable, Equatable {
    public enum Kind: String, Sendable { case direct, proxy }
    public var kind: Kind
    public var proxyID: String?

    public static let direct = EgressLeg(kind: .direct, proxyID: nil)
    public static func proxy(_ id: String) -> EgressLeg { EgressLeg(kind: .proxy, proxyID: id) }

    public var isProxy: Bool { kind == .proxy }
    public var label: String { isProxy ? "proxy" : "direct" }
}

// MARK: - 按 host 记账

/// 一台 host 在一类流量上的出口结论。
///
/// ⛔ 这张表存在的理由：出口是**按站**不同的，不是按源、更不是按 app。
/// 同一个源里，接口在国内直连是好的、播放 CDN 必须过节点；换一部剧，两者又反过来。
/// 把结论记在 host 上，第一次撞墙之后同一台 host 的其余几十个请求就不用再撞。
final class HostEgressTable: @unchecked Sendable {
    struct Entry {
        var leg: EgressLeg
        /// 是不是由真实成败得出的结论。默认的 `.direct` 只是「还没试过」，不能当成已知。
        var proven: Bool
        var expires: Date
        var proxyFailures: Int
    }

    /// 学到「必须走代理」之后先信多久。
    ///
    /// 太短：每次播放都先撞一次墙；太长：节点恢复、源站放行之后还在绕远路。
    /// 10 分钟是「一部剧的时间」——期间同 host 的请求全部零代价走对的那条腿。
    private static let proxyTrust: TimeInterval = 600
    /// 学到「直连是好的」之后信多久。比上面长：直连好是常态，反复验证没有收益。
    private static let directTrust: TimeInterval = 1800

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func leg(_ key: String) -> EgressLeg {
        lock.withLock {
            guard let entry = entries[key], entry.expires > Date() else { return .direct }
            return entry.leg
        }
    }

    func isProven(_ key: String) -> Bool {
        lock.withLock {
            guard let entry = entries[key], entry.expires > Date() else { return false }
            return entry.proven
        }
    }

    func record(_ key: String, leg: EgressLeg) {
        let trust = leg.isProxy ? Self.proxyTrust : Self.directTrust
        lock.withLock {
            entries[key] = Entry(leg: leg, proven: true,
                                 expires: Date().addingTimeInterval(trust), proxyFailures: 0)
        }
    }

    /// 记一次失败。代理腿连续失败两次就退回直连 —— 节点挂了/订阅到期时，
    /// 不能把整页内容都赔进去。
    @discardableResult
    func recordFailure(_ key: String, leg: EgressLeg) -> EgressLeg? {
        lock.withLock {
            var entry = entries[key] ?? Entry(leg: .direct, proven: false,
                                              expires: .distantPast, proxyFailures: 0)
            guard leg.isProxy else {
                // 直连失败：交给调用方换成代理腿重试，这里只把旧结论作废。
                entries[key] = Entry(leg: .direct, proven: false, expires: .distantPast,
                                     proxyFailures: entry.proxyFailures)
                return nil
            }
            entry.proxyFailures += 1
            if entry.proxyFailures >= 2 {
                entries[key] = Entry(leg: .direct, proven: false, expires: .distantPast, proxyFailures: 0)
                return .direct
            }
            entries[key] = entry
            return nil
        }
    }

    func forget(host: String? = nil) {
        lock.withLock {
            guard let host else { entries.removeAll(); return }
            // 键是 `host|purpose`：host 在**前面**。
            let prefix = host.lowercased() + "|"
            entries = entries.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    func snapshot() -> [(String, String, Bool)] {
        lock.withLock {
            let now = Date()
            return entries.filter { $0.value.expires > now }
                .map { ($0.key, $0.value.leg.label + ($0.value.leg.proxyID.map { ":" + $0 } ?? ""), $0.value.proven) }
                .sorted { $0.0 < $1.0 }
        }
    }
}

// MARK: - 路由器

/// 出网请求的唯一决策点：**能直连就直连，直连不通才走代理，且不牺牲速度**。
///
/// 做法是「按 host 学习 + 双腿赛跑」：
/// 1. 从没见过的 host：直连先跑，`hedgeDelay` 之后代理并行起跑，谁先给出内容用谁 ——
///    直连好的站代理那条腿根本不起跑，所以常态开销为零；直连被掐的站只多等几百毫秒。
/// 2. 学到结论之后（10/30 分钟）：该走哪条走哪条，不再赛跑，零额外请求。
/// 3. 结论过期：重新赛跑一次，源站/节点恢复了就能自己走回来。
///
/// ⛔ 这里**不承担视频分片**。分片必须留给播放器自己请求（系统栈 → TUN → Loon 的规则），
/// 经本机中继转发时每片一条新 TLS，实测只有 140–190 KB/s，压不住码率。
public final class EgressRouter: @unchecked Sendable {
    public static let shared = EgressRouter()

    private let table = HostEgressTable()
    private let lock = NSLock()
    /// 正在做决策的 host（同一个 host 只允许一个赛跑，避免一页 40 张封面各开一条代理）。
    private var deciding: [String: Date] = [:]

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        // 不用系统代理设置里的 HTTP 代理：那层由 TUN 完成，两条腿都由我们显式选择，
        // 让 URLSession 再套一层会把「直连腿」也变成代理腿，赛跑就没意义了。
        configuration.httpShouldUsePipelining = false
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: 对外

    /// 同步读当前结论：播放器建 asset 时不能 await，只能读已经定下来的那一份。
    public func leg(for url: URL, purpose: EgressPurpose) -> EgressLeg {
        table.leg(Self.key(url, purpose))
    }

    public func isProven(_ url: URL, purpose: EgressPurpose) -> Bool {
        table.isProven(Self.key(url, purpose))
    }

    /// 把一条地址改写到选定的腿上。代理腿在没有中继地址时返回原地址（宁可直连，不要打不开）。
    public func routed(_ url: URL, leg: EgressLeg) -> URL {
        // ⛔ 回环地址一律原样返回。
        //
        // remux 出的 HLS、插件 `/proxy?do=` 的流都在 `127.0.0.1:<port>` 上；再包一层中继
        // 就是「中继把请求发给它自己」，而且 key 是 `host|purpose` —— 所有源的回环媒体
        // 共用 `127.0.0.1|media` 一个格子，一旦记成代理就会把全部 remux 流一起打死。
        guard !Self.isLoopback(url) else { return url }
        // 出口可能刚被观众删掉：表里还留着旧 id 时不要拿它去拼中继地址，
        // 否则每条请求都要先撞一次「代理不存在」再换腿。
        guard leg.isProxy, let id = leg.proxyID,
              CustomProxyStore.shared.endpoints.contains(where: { $0.id == id }),
              let base = LocalProxyServer.shared.baseSync,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return url }
        return LocalProxyServer.proxyURL(base: base, url: url, proxyID: id)
    }

    /// 取数据：按结论选腿，第一次见到该 host 时双腿赛跑。
    public func data(for url: URL, headers: [String: String] = [:],
                     purpose: EgressPurpose, policy: EgressPolicy,
                     range: String? = nil) async throws -> (Data, URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TVError.invalidURL
        }
        // 本机上的流（remux / 插件代理）：不参与出口决策，直连就是回环。
        if Self.isLoopback(url) {
            return try await attempt(url, headers: headers, purpose: purpose, leg: .direct, range: range)
        }
        // 直连源：不给代理任何机会。这是观众显式选的，不该被「自动优化」掉。
        guard let proxyLeg = proxyLeg(for: policy) else {
            return try await attempt(url, headers: headers, purpose: purpose, leg: .direct, range: range)
        }

        let key = Self.key(url, purpose)
        if table.isProven(key) {
            return try await follow(table.leg(key), fallback: proxyLeg, url: url, headers: headers,
                                    purpose: purpose, key: key, range: range)
        }

        // 还没结论。同一个 host 只让一条请求去赛跑，其余先按直连走 ——
        // 它们就算失败也会因为「表里已经写明要走代理」而立刻重试，不会各自开一条代理腿。
        guard beginDecision(key) else {
            do {
                return try await attempt(url, headers: headers, purpose: purpose, leg: .direct, range: range)
            } catch {
                guard Self.isEgressFailure(error), table.isProven(key) else { throw error }
                return try await follow(table.leg(key), fallback: proxyLeg, url: url, headers: headers,
                                        purpose: purpose, key: key, range: range)
            }
        }
        defer { endDecision(key) }
        return try await race(url, headers: headers, purpose: purpose, proxyLeg: proxyLeg,
                              policy: policy, key: key, range: range)
    }

    /// 出发前把这条 host 的结论定下来（只读首包，不取正文）。
    ///
    /// 播放路径上必须先走这一步：`AVPlayerItem` 的地址一旦定下就不容易换，
    /// 与其让它拿着直连地址失败一次再重建，不如先花几百毫秒把腿确认下来。
    ///
    /// ⛔ 这里**不能**用 `data(for:)`：`URLSession.data(for:)` 会把整个响应体读进内存，
    /// 而直链 MP4 的 CDN 常常忽略 `Range` —— 等于在起播路径上把整部片子下一遍。
    /// 用 `bytes(for:)` 只取首字节，拿到就掐掉。
    public func prepare(_ url: URL, purpose: EgressPurpose, policy: EgressPolicy,
                        headers: [String: String] = [:]) async {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        guard !Self.isLoopback(url) else { return }
        let key = Self.key(url, purpose)
        if table.isProven(key) { return }
        guard let proxyLeg = proxyLeg(for: policy) else {
            table.record(key, leg: .direct)
            return
        }
        guard beginDecision(key) else { return }
        defer { endDecision(key) }

        let hedge: Duration = {
            if case .preferProxy = policy { return .zero }
            return purpose.hedgeDelay
        }()
        await withTaskGroup(of: (EgressLeg, Bool).self) { group in
            group.addTask {
                (EgressLeg.direct, await Self.succeeded {
                    try await self.probe(url, headers: headers, purpose: purpose, leg: .direct)
                })
            }
            group.addTask {
                if hedge > .zero { try? await Task.sleep(for: hedge) }
                if Task.isCancelled { return (proxyLeg, false) }
                return (proxyLeg, await Self.succeeded {
                    try await self.probe(url, headers: headers, purpose: purpose, leg: proxyLeg)
                })
            }
            while let (leg, ok) = await group.next() {
                if ok {
                    table.record(key, leg: leg)
                    Diagnostics.shared.record(.debug, "egress", "\(key) → \(leg.label) (preflight)")
                    group.cancelAll()
                    return
                }
            }
            // 两条腿都没答：不留结论，播放器先用直连试，失败了再由 `retryEgress` 翻。
            Diagnostics.shared.record(.warning, "egress",
                "\(key) preflight: neither leg answered; playing direct and letting playback decide")
        }
    }

    /// 只读首包：拿到第一个字节就取消，剩下的不下载。
    private func probe(_ url: URL, headers: [String: String], purpose: EgressPurpose,
                       leg: EgressLeg) async throws {
        let address = routed(url, leg: leg)
        if leg.isProxy, address == url { throw URLError(.cannotConnectToHost) }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: purpose.probeTimeout)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw code == 0 ? URLError(.badServerResponse) : TVError.http(code)
        }
        var iterator = bytes.makeAsyncIterator()
        _ = try await iterator.next()
        bytes.task.cancel()
    }

    private static func succeeded(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true } catch { return false }
    }

    /// 内容不对（拿到的是网页/空列表/解析不了），但连接是通的 —— 这种情况赛跑救不了，
    /// 只能把结论翻到代理再取一次。
    ///
    /// `allowsProxy` 必须由调用方传入：观众把这个源设成「直连」时，翻到代理会直接违背他的选择。
    public func noteBadContent(_ url: URL, purpose: EgressPurpose, allowsProxy: Bool) {
        let key = Self.key(url, purpose)
        guard allowsProxy, table.leg(key).isProxy == false else { return }
        table.recordFailure(key, leg: .direct)
        // 直接记成「必须代理」，下一次 `data` 就走代理腿。
        if let id = CustomProxyStore.shared.fallbackEndpoint?.id {
            table.record(key, leg: .proxy(id))
        }
    }

    /// 代理腿自己也没把画面播出来（不是清单取不到，是取到了却播不动）。
    ///
    /// 记在代理腿名下：连续两次之后 `recordFailure` 会把结论退回直连 —— 节点通了但带宽不够时，
    /// 继续钉在代理上只会让整部剧都播不动。
    public func notePlaybackFailure(_ url: URL, purpose: EgressPurpose) {
        let leg = table.leg(Self.key(url, purpose))
        guard leg.isProxy else { return }
        _ = table.recordFailure(Self.key(url, purpose), leg: leg)
        Diagnostics.shared.record(.info, "egress", "\(Self.key(url, purpose)) failed on the proxy leg")
    }

    /// 播放器已经用直连试过一次并且失败了：不必再赛跑，直接把结论钉到代理上，重开一次。
    ///
    /// 与 `noteBadContent` 分开是因为入口不同：播放失败拿到的是一条「连接断了」的错误，
    /// 不是一段可检查的正文。
    public func forceProxy(_ url: URL, purpose: EgressPurpose, proxyID: String) {
        table.record(Self.key(url, purpose), leg: .proxy(proxyID))
        Diagnostics.shared.record(.info, "egress",
            "\(Self.key(url, purpose)) pinned to proxy after a direct failure")
    }

    /// 代理配置变了（改地址、换端口、删掉）：所有结论作废，否则旧 id 会指向已经不存在的出口。
    public func reset() {
        table.forget()
        lock.withLock { deciding.removeAll() }
    }

    public func snapshot() -> [(String, String, Bool)] { table.snapshot() }

    // MARK: 内部

    private func proxyLeg(for policy: EgressPolicy) -> EgressLeg? {
        if case .directOnly = policy { return nil }
        guard let id = policy.proxyID,
              CustomProxyStore.shared.endpoints.contains(where: { $0.id == id }) else { return nil }
        return .proxy(id)
    }

    /// 本机上正在监听的地址（remux / 插件代理 / 中继自身）。
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
            || host.hasPrefix("127.") || host == "[::1]"
    }

    private func key(_ url: URL, _ purpose: EgressPurpose) -> String { Self.key(url, purpose) }

    static func key(_ url: URL, _ purpose: EgressPurpose) -> String {
        (url.host() ?? url.absoluteString).lowercased() + "|" + purpose.rawValue
    }

    /// 按已知结论走，失败就换另一条腿（这条「换腿」是无条件的 —— 有结论不等于永远对）。
    private func follow(_ leg: EgressLeg, fallback: EgressLeg, url: URL, headers: [String: String],
                        purpose: EgressPurpose, key: String, range: String?) async throws -> (Data, URL) {
        do {
            let result = try await attempt(url, headers: headers, purpose: purpose, leg: leg, range: range)
            table.record(key, leg: leg)
            return result
        } catch {
            guard Self.isEgressFailure(error) else { throw error }
            Diagnostics.shared.record(.info, "egress",
                "\(leg.label) failed on \(key) (\(error.localizedDescription)); trying \(fallback.label)")
            table.recordFailure(key, leg: leg)
            let other = fallback.isProxy ? fallback : .direct
            guard other != leg else { throw error }
            let result = try await attempt(url, headers: headers, purpose: purpose, leg: other, range: range)
            table.record(key, leg: other)
            return result
        }
    }

    /// 双腿赛跑：直连先跑，`hedgeDelay` 后代理起跑，先给出内容的赢。
    private func race(_ url: URL, headers: [String: String], purpose: EgressPurpose,
                      proxyLeg: EgressLeg, policy: EgressPolicy, key: String,
                      range: String?) async throws -> (Data, URL) {
        let hedge: Duration = {
            if case .preferProxy = policy { return .zero }
            return purpose.hedgeDelay
        }()
        Diagnostics.shared.record(.debug, "egress",
            "racing \(key) hedge=\(hedge == .zero ? 0 : Int(purpose.hedgeDelay.milliseconds()))ms")

        let result: (EgressLeg, Data, URL)? = await withTaskGroup(
            of: (EgressLeg, Result<(Data, URL), Error>).self
        ) { group in
            group.addTask {
                (EgressLeg.direct, await Self.capture {
                    try await self.attempt(url, headers: headers, purpose: purpose, leg: .direct, range: range)
                })
            }
            group.addTask {
                if hedge > .zero { try? await Task.sleep(for: hedge) }
                if Task.isCancelled { return (proxyLeg, .failure(CancellationError())) }
                return (proxyLeg, await Self.capture {
                    try await self.attempt(url, headers: headers, purpose: purpose, leg: proxyLeg, range: range)
                })
            }
            var lastError: Error?
            while let (leg, outcome) = await group.next() {
                switch outcome {
                case .success(let value):
                    group.cancelAll()
                    return (leg, value.0, value.1)
                case .failure(let error):
                    if !(error is CancellationError) { lastError = error }
                }
            }
            if let lastError { return nil }
            return nil
        }

        if let result {
            table.record(key, leg: result.0)
            Diagnostics.shared.record(.info, "egress", "\(key) → \(result.0.label) (raced)")
            return (result.1, result.2)
        }
        // 两条腿都没成：不留结论，下一次还会赛跑。
        table.forget(host: url.host())
        throw TVError.unsupported(L10n.text("Neither the direct line nor the proxy could reach %@.", url.host() ?? url.absoluteString))
    }

    private func attempt(_ url: URL, headers: [String: String], purpose: EgressPurpose,
                         leg: EgressLeg, range: String? = nil) async throws -> (Data, URL) {
        let address = routed(url, leg: leg)
        // 代理腿拿不到中继地址（监听器没起来）：这不是「源站不通」，交给调用方换腿。
        if leg.isProxy, address == url {
            throw URLError(.cannotConnectToHost)
        }
        var request = URLRequest(url: address,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: purpose.timeout)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
        // 206/200 都算通；其余按状态码处理，并把「服务器答了但拒绝」也当成这条腿不可用
        // （403/451 在这批源上就是地区封锁，换一条腿通常就通）。
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 || http.statusCode == 451 || http.statusCode >= 500 {
                throw URLError(.badServerResponse)
            }
            throw TVError.http(http.statusCode)
        }
        return (data, url)
    }

    private static func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) }
        catch { return .failure(error) }
    }

    /// 这条失败该不该归咎于「出口」。
    ///
    /// 只有「连接没建立 / 握手中断 / 会话被关」才换腿。源站明确回答的 4xx 是内容问题，
    /// 换腿只会白花一次请求。
    static func isEgressFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
                 .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotLoadFromNetwork,
                 .badServerResponse, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .dataNotAllowed:
                return true
            default: return false
            }
        }
        if let tv = error as? TVError, case .http(let code) = tv { return code == 403 || code == 451 || code >= 500 }
        return false
    }

    private func beginDecision(_ key: String) -> Bool {
        let now = Date()
        return lock.withLock {
            if let started = deciding[key], now.timeIntervalSince(started) < 6 { return false }
            deciding[key] = now
            return true
        }
    }

    private func endDecision(_ key: String) {
        _ = lock.withLock { deciding.removeValue(forKey: key) }
    }
}

private extension Duration {
    func milliseconds() -> Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
