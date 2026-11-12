import Foundation

// MARK: - 阶段 1：廉价筛

/// 只问「这个源现在答不答、多快答」，不碰插件、不抓主页、不测视频。
///
/// 判据的取舍
/// ---------
/// 只针对**能直接构造出 HTTP 地址**的源（type 1 / type 4 这类 CMS 接口）做筛。
/// 需要跑 JS/JAR 插件的源无法绕过插件，硬筛会得到「插件没启动所以超时」的假负结论 ——
/// 那比不筛更糟。所以对这些源返回 `.unknown`，由调用方**放行**（当作值得细测），
/// 而不是把它们误判成死源。
///
/// 请求本身用 `Range: bytes=0-2047` 只取 2 KB：
/// 目的不是读内容，是拿到「首字节时间」与「HTTP 状态」。
/// 2048 字节在任何链路上都不构成成本，却能区分「TCP 连不上」「TLS 失败」
/// 「服务器 5xx」「正常应答」四种情况 —— 这正是筛要的粒度。
public enum SourceScreen {

    /// 筛的结论。
    public enum Verdict: String, Sendable {
        /// 应答够快，值得做完整测量。
        case promote
        /// 明确连不上或服务器报错 —— 细测也不会有结果。
        case drop
        /// 应答但很慢（超过 deadline）。
        case slow
        /// 无法筛（插件源、或地址构造不出来）—— 交给完整测量去判。
        case unknown

        /// 这个筛结果要不要交给完整测量。
        ///
        /// ⛔ `.slow` 必须在里面。它是「应答了，但超过 deadline」—— 一个慢而能播的源。
        /// 之前把它排除在外，于是一个真能播的慢源在测速页显示「未测量」，因为筛阶段把它丢了、
        /// 细测根本没跑。筛只该拦掉「肯定不能用」的（`.drop`），不该替细测下结论。
        public var shouldMeasure: Bool {
            switch self {
            case .promote, .unknown, .slow: true
            case .drop: false
            }
        }
    }

    /// 一次筛的结果。带上耗时，让「为什么被判慢」可追。
    public struct Result: Sendable {
        public let verdict: Verdict
        public let milliseconds: Int?
        public let detail: String

        public init(verdict: Verdict, milliseconds: Int? = nil, detail: String = "") {
            self.verdict = verdict
            self.milliseconds = milliseconds
            self.detail = detail
        }
    }

    /// 能否对这个源做廉价筛。只有能直接拼出 HTTP 地址的才行。
    ///
    /// - Parameters:
    ///   - site: 源定义。
    ///   - jarURL: 订阅的 spider 地址；非 nil 且源没有自己的 `api` 时说明它必须跑插件。
    public static func screenable(_ site: Site, jarURL: URL?) -> Bool {
        // 插件源绕不过插件。
        if jarURL != nil, !site.isBuiltIn, site.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        // 内置源（Bilibili 等）有自己的鉴权流程，直接打 API 会被拒 —— 拿不到有意义的结论。
        if site.isBuiltIn { return false }
        // 云端目录 / 脚本运行时同样不是可以直接打的 HTTP 接口。
        if site.isCloudFiles || site.runsInProcess { return false }
        // ⛔ 必须按「http(s) 且有 host」判，不能只判 `URL(string:) != nil`：
        // 相对地址（`./FTY/drpy2.min.js`）、光秃秃的 play 参数（`abc123`）都会被它接受成
        // **相对 URL**，于是 `screen()` 拿它建 `URLRequest` 抛 `NSURLErrorUnsupportedURL`，
        // 落进 catch 一律判 `.drop` —— 好源在筛阶段就被判死，第二轮细测根本轮不到它。
        return ProbePlanTarget.isRequestable(site.api)
    }

    /// 对 API 端点发一次 2 KB 的请求。
    public static func screen(_ site: Site, origin: URL, headers: [String: String] = [:],
                              schedule: ProbeSchedule = .standard,
                              session: URLSession = .shared) async -> Result {
        guard screenable(site, jarURL: nil) else {
            return Result(verdict: .unknown, detail: L10n.text("Needs its plugin; measured in full"))
        }
        // 相对 api 要按订阅的 origin 解析（`WebAddress.resolve`，全仓标准口径）。
        // 直接 `URL(string:)` 得到的是相对 URL，建不出可用的 `URLRequest`。
        guard let url = try? WebAddress.resolve(site.api, relativeTo: origin),
              ProbePlanTarget.isRequestable(url.absoluteString) else {
            // 地址根本不可请求 ≠ 服务器报错。判 `.drop` 会让这类源被静默剔除；
            // 放行到细测阶段，那里有插件解析，能给出真正的答案。
            return Result(verdict: .unknown, detail: L10n.text("Needs its plugin; measured in full"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = schedule.screenTimeout
        // 只要 2 KB：这不是读内容，是量「首字节多久到」。
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1_000)
            guard let http = response as? HTTPURLResponse else {
                return Result(verdict: .unknown, milliseconds: ms, detail: L10n.text("Not an HTTP answer"))
            }
            // 5xx / 403 / 404：细测也救不回来。
            // 401 不判死 —— 有的源对匿名请求回 401，插件带 token 才通。
            if http.statusCode >= 500 || http.statusCode == 403 || http.statusCode == 404 {
                return Result(verdict: .drop, milliseconds: ms, detail: "HTTP \(http.statusCode)")
            }
            if Date().timeIntervalSince(started) > schedule.screenDeadline {
                return Result(verdict: .slow, milliseconds: ms, detail: L10n.text("Answered too slowly"))
            }
            return Result(verdict: .promote, milliseconds: ms, detail: "HTTP \(http.statusCode)")
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return Result(verdict: .unknown, detail: L10n.text("Cancelled"))
            }
            // -1002/-1003 是「这个地址没法当请求发」，不是「服务器不可用」。前者说明
            // 我们还是不知道它死没死，判 `.unknown` 放行；只有真的网络错误才判死。
            let code = (error as? URLError)?.code
            if code == .unsupportedURL || code == .badURL {
                return Result(verdict: .unknown, detail: L10n.text("Needs its plugin; measured in full"))
            }
            return Result(verdict: .drop, detail: error.localizedDescription)
        }
    }
}
