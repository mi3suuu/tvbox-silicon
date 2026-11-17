import Foundation

/// A pool of local source ports, used to tell Loon which of its rules should carry a request.
///
/// ## Why a source port at all
///
/// Loon has **port rules**, and `SRC-PORT` matches the port a connection came *from* — a property
/// only we control. So a config that starts with
///
/// ```
/// SRC-PORT,41500-41599,Proxy
/// SRC-PORT,41600-41699,DIRECT
/// ```
///
/// turns "did the app want the proxy" into a decision Loon can honour without looking at the
/// hostname. The app dials its proxied connections from the first range and everything else from the
/// second, so both halves of the decision are explicit rather than left to Loon's own rules.
///
/// ## Measured behaviour (LoonKit v8.0, `wifi-access-http-port = 7222`)
///
/// `SRC-PORT` **does** take effect over the LAN proxy port — but only for targets no domain rule
/// matches. Measured by dialling a bare IP (so no `DOMAIN-*` rule could match) at the same host:
///
/// | Dialled from | Egress |
/// |---|---|
/// | outside both ranges | the selected node |
/// | the `DIRECT` range | **direct** (the node was bypassed) |
/// | the `Proxy` range | the selected node |
///
/// Against a domain that *is* listed in the rules, all three ranges behaved identically: **domain
/// rules are consulted before `SRC-PORT`**, which matches Loon's documented order (domain rules
/// first, then IP rules; `SRC-PORT` falls in with the rest). So a site the viewer's own rules
/// already classify cannot be re-routed from here, and the app must not claim otherwise.
///
/// Earlier measurements that read as "SRC-PORT does nothing on the LAN port" were wrong: they all
/// dialled a **domain**, so a domain rule matched first and hid the effect. Any future check of a
/// port/IP rule has to use a target that kind of rule cannot match, or it produces a false negative.
///
/// ## One connection per port
///
/// A TCP source port cannot carry two simultaneous connections: the second `bind` fails with
/// `EADDRINUSE` (measured). So this is a pool with acquire/release, not one fixed port, and a range
/// has to be wide enough for the concurrent connections a player makes. When it runs dry the caller
/// gets `nil` and should fall back to an ephemeral port — a request that goes out on the "wrong"
/// port is still routed by Loon's normal rules, which is no worse than today.
public final class SRCPortPool: @unchecked Sendable {
    public static let shared = SRCPortPool()

    /// Two ranges, because the app has two decisions to express, not one.
    ///
    /// `proxy` is the port range Loon is told to send through the selected line; `direct` is the
    /// range it is told to leave alone. Without the second one a "direct" source would still be
    /// judged by Loon's own rules — which is the thing the viewer is trying to escape. Both are kept
    /// here so the app and the snippet we hand out cannot drift apart.
    public static let proxyRange = 41_500...41_599
    public static let directRange = 41_600...41_699

    public enum Lane: Sendable { case proxy, direct }

    private let lock = NSLock()
    private let ports: [UInt16]
    private var free: [Lane: [UInt16]]
    /// Ports handed out, so `release` can tell a real lease from a stray call.
    private var leased: Set<UInt16> = []

    public init(proxy: ClosedRange<Int> = SRCPortPool.proxyRange,
                direct: ClosedRange<Int> = SRCPortPool.directRange) {
        ports = proxy.compactMap { UInt16(exactly: $0) } + direct.compactMap { UInt16(exactly: $0) }
        free = [.proxy: proxy.compactMap { UInt16(exactly: $0) },
                .direct: direct.compactMap { UInt16(exactly: $0) }]
    }

    /// The whole range, for telling the viewer what to put in Loon.
    public var allPorts: [UInt16] { ports }

    /// A port nobody else in this process is using right now, or nil when that lane is exhausted.
    ///
    /// **最久没用的那个先发**（FIFO），不是刚才用过的那个。这一点不是风格问题：连接每次
    /// 结束都会 `release`，而结束前它刚在这个端口上跑过 —— 如果后进先出，下一次 `acquire`
    /// 拿到的正是那个还没从 `TIME_WAIT` 里出来的端口，绑定失败、再还回去、再拿到同一个，
    /// 一条脏端口就能把之后的所有请求全吃掉（真机 3 分钟 558 次 `NWError 48`）。
    public func acquire(_ lane: Lane = .proxy) -> UInt16? {
        lock.withLock {
            guard var pool = free[lane], !pool.isEmpty else { return nil }
            let port = pool.removeFirst()
            free[lane] = pool
            leased.insert(port)
            return port
        }
    }

    /// Returns a port to the pool. Ignored when it was not leased (or was already returned), so a
    /// double release cannot make the same port appear twice and be handed to two connections.
    public func release(_ port: UInt16) {
        lock.withLock {
            guard leased.remove(port) != nil else { return }
            // Back to the lane it came from: a proxy port returned to the direct lane would let a
            // later connection choose the wrong side of Loon's rules.
            let lane: Lane = Self.proxyRange.contains(Int(port)) ? .proxy : .direct
            free[lane]?.append(port)
        }
    }

    /// How many ports are available, for the settings page and for tests.
    public var available: Int { lock.withLock { (free[.proxy]?.count ?? 0) + (free[.direct]?.count ?? 0) } }

    public var inUse: Int { lock.withLock { leased.count } }
}

/// The `[Rule]` line the viewer pastes into Loon, and why it goes first.
///
/// Loon resolves rules in file order, except that domain rules are tried before IP rules; a
/// `SRC-PORT` rule is neither, so putting it at the very top is what makes it win over the
/// subscription rule sets below. That ordering is the whole point and cannot be traded for
/// something quieter further down the file.
///
/// No `USER-AGENT` rule alongside it: the relay forwards whatever the player sent, so an
/// app-specific user agent never appears on the wire and such a rule would silently match nothing.
public enum LoonSRCPortRule {
    public static var range: String {
        let ports = SRCPortPool.proxyRange
        return "\(ports.lowerBound)-\(ports.upperBound)"
    }

    /// What the viewer adds to the top of `[Rule]`.
    public static var fragment: String {
        """
        # 顾及 · 出口决策交给 App：两段端口各表一边
        # 必须放在 [Rule] 最前面 —— Loon 按文件顺序匹配，且域名类规则会抢在 IP 类规则之前。
        # 注意：域名类规则始终优先于 SRC-PORT，所以已被下方规则集分类的站点仍跟随规则；
        # 不在规则里的站点（大多数）由这两段端口决定去向。
        SRC-PORT,\(range),Proxy
        SRC-PORT,\(directRange),DIRECT
        """
    }

    /// Where the rule stands in a config the viewer actually has.
    ///
    /// Three outcomes, because "present" is not the same as "effective": Loon resolves rules in file
    /// order, so the same line pasted at the bottom of `[Rule]` never wins and the viewer would be
    /// told it works while nothing changes.
    public enum Placement: Equatable, Sendable {
        /// No `SRC-PORT` line for our range at all.
        case missing
        /// Present, but a rule that is consulted first sits above it.
        case tooLow(before: String)
        /// First rule in `[Rule]`: nothing is consulted before it.
        case atTop
        public var isEffective: Bool { self == .atTop }
    }

    /// Whether the config also carries the `DIRECT` line for the other lane.
    ///
    /// Needed separately from the proxy line: a config that only has the proxy range sends
    /// *everything else* through Loon's own rules, and a config carrying the older single wide range
    /// (`41500-41799`) would swallow the direct lane and route it through the proxy — the exact
    /// opposite of what the app asks for.
    public static func hasDirectRule(inConfig text: String) -> Bool {
        var inRule = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inRule = line.lowercased() == "[rule]"
                continue
            }
            guard inRule else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("SRC-PORT"), line.contains(directRange),
               upper.hasSuffix(",DIRECT") { return true }
        }
        return false
    }

    /// A rule left over from before the ranges were split, which now covers the direct lane too.
    public static func hasLegacyWideRange(inConfig text: String) -> Bool {
        var inRule = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inRule = line.lowercased() == "[rule]"
                continue
            }
            guard inRule, line.uppercased().hasPrefix("SRC-PORT") else { continue }
            // A range that starts at our proxy lower bound but ends past our proxy range.
            if line.contains("41500-"), line.contains("41799") { return true }
            if line.contains("41500-41799") { return true }
        }
        return false
    }

    /// Whether a Loon config carries the rule anywhere. Kept for callers that only need existence.
    public static func isInstalled(inConfig text: String) -> Bool {
        placement(inConfig: text) != .missing
    }

    /// Diagnoses the rule against a live config. Read the config every time rather than caching a
    /// copy: the viewer keeps adding subscriptions and switching nodes, and a snapshot of their
    /// config goes stale the moment they do — the rule itself never does, because it matches a port.
    /// The direct range, for the second line of the fragment.
    public static var directRange: String {
        let ports = SRCPortPool.directRange
        return "\(ports.lowerBound)-\(ports.upperBound)"
    }

    public static func placement(inConfig text: String) -> Placement {
        var inRule = false
        var sawOurLine = false
        var firstRule: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inRule = line.lowercased() == "[rule]"
                // A `[Rule]` section further down starts over; stop at the first one that held ours.
                if !inRule && sawOurLine { break }
                continue
            }
            guard inRule else { continue }
            let upper = line.uppercased()
            let ours = upper.hasPrefix("SRC-PORT") && line.contains(range)
            if ours { sawOurLine = true; continue }
            // Only a rule that comes *before* ours can outrank it; one below is irrelevant.
            if !sawOurLine, firstRule == nil { firstRule = line }
        }
        guard sawOurLine else { return .missing }
        // Anything that comes before us and is not ours means we are not first.
        if let firstRule { return .tooLow(before: firstRule) }
        return .atTop
    }
}

// MARK: - 生效性自检

/// 一次「规则到底有没有生效」的实测，而不是靠推断。
///
/// 判据设计是这里最要紧的部分：**必须用域名规则无法命中的目标**。此前的判死实验全部拨的是
/// 域名，而域名规则会抢在 `SRC-PORT` 之前命中，于是三种端口出口一致、看起来「规则无效」——
/// 那是假阴性。用裸 IP 让 `DOMAIN-*` 无从匹配，`SRC-PORT` 才有机会表态。
///
/// 做法是同一目标、分别从代理段与直连段各拨一次，比较两次结果是否不同：
///   - 不同 → 端口规则确实在参与决策
///   - 相同 → 可能被域名规则抢先，或规则未装好（`caveat` 会指出是哪种）
public struct LoonPortRuleProbe: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// 两段出口不同，端口规则生效。
        case effective
        /// 两段出口相同：该目标被更早的规则接管了，端口规则没参与。
        case overridden
        /// 两段都连不出去，无法判定（网络或节点问题），不是规则的错。
        case inconclusive
        public var isEffective: Bool { self == .effective }
    }
    public let outcome: Outcome
    /// 供界面显示的两段结果摘要，例如 "node" / "direct" / "timeout"。
    public let proxyResult: String
    public let directResult: String
}

public extension LoonSRCPortRule {
    /// 自检用的目标：一个裸 IP，使 `DOMAIN-*` 规则无法匹配，`SRC-PORT` 才能决定去向。
    ///
    /// 目标必须同时满足两点，缺一个自检就会误判：
    ///   1. **裸 IP** —— 否则域名规则抢先匹配，测到的只是域名规则的优先级。
    ///   2. **直连不可达、走节点可达** —— 否则两段都能连上，结果一致，会被判成 `overridden`。
    ///
    /// 实测（本机宽带 + LoonKit v8.0）：`1.1.1.1` 直连也通（301），两段无差别，**不合格**；
    /// `104.26.13.205` 直连超时、经 Loon 可达，才是能区分两段的目标。
    static let probeHost = "104.26.13.205"

    /// 从两段端口各拨一次同一目标，比较出口描述。
    ///
    /// `describe` 由调用方提供：把一次连接的观察结果压成一个短标签（出口 IP、超时等）。
    /// 这里只负责「两段是否产生不同结果」这一条判断，不碰网络，便于单测。
    static func evaluate(proxyResult: String, directResult: String) -> LoonPortRuleProbe {
        let failure = { (s: String) in s.hasPrefix("timeout") || s.hasPrefix("fail") }
        if failure(proxyResult) && failure(directResult) {
            return LoonPortRuleProbe(outcome: .inconclusive, proxyResult: proxyResult, directResult: directResult)
        }
        let outcome: LoonPortRuleProbe.Outcome = proxyResult == directResult ? .overridden : .effective
        return LoonPortRuleProbe(outcome: outcome, proxyResult: proxyResult, directResult: directResult)
    }
}
