import Foundation

/// One Loon install on the local network, discovered from its own configuration API.
///
/// Loon exposes its running config at `http://<host>:<port>/loonapi/v1/config/file.conf` while
/// "allow Wi-Fi access" is on. That file names the two LAN proxy ports and whether sharing is on,
/// which is everything needed to add Loon as an outbound proxy without the viewer typing a port.
///
/// ## What Loon will and will not let us decide
///
/// Measured against a live install (LoonKit v8.0, `wifi-access-http-port = 7222`,
/// `wifi-access-socks5-port = 7221`, `mitm-on-wifi-access = true`):
///
/// - **The LAN proxy ports apply the config's rules.** A Chinese host left on the direct line while
///   a foreign host left through the selected node, on both 7222 and 7221. Handing it a bare IP
///   instead of a domain did not change that (`GEOIP,CN` matched the resolved address), five
///   different policy-override headers changed nothing, and every write verb on `/loonapi/v1/...`
///   closes the connection.
/// - **`SRC-PORT` does work there — for targets no domain rule matches.** Dialling a bare IP from
///   the `DIRECT` range sent an otherwise-node-bound request straight out; the same request from the
///   `Proxy` range or from outside both ranges took the node. See `SRCPortPool` for the table.
/// - **Domain rules win over `SRC-PORT`.** Against a domain the config lists, all three ranges
///   behaved identically. Loon documents this order: domain rules first, then IP rules, then the
///   rest. So a site the viewer's own rules already classify cannot be re-routed from the app.
///
/// That last point is the one the UI has to be honest about, which is what `caveat` is for.
public struct LoonPreset: Sendable, Equatable {
    /// The API URL this was read from, kept so the row can show what it points at.
    public let source: URL
    /// The host the proxy ports answer on — Loon's own LAN address, not the API's host:port.
    public let host: String
    public let httpPort: Int
    /// Zero when the config does not share a SOCKS5 port.
    public let socksPort: Int
    /// Whether `allow-wifi-access` is on. Without it the ports are not listening at all.
    public let sharesOnLAN: Bool
    /// Where our `SRC-PORT` rule stands in the config that was read. `missing` and `tooLow` both
    /// mean Loon will not honour the port range, and they need different advice.
    public let portRule: LoonSRCPortRule.Placement
    /// Whether the `DIRECT` line for the other lane is present too.
    public let hasDirectLine: Bool
    /// Whether an older, wider `SRC-PORT` range is still in the config and now covers both lanes.
    public let hasLegacyWideRange: Bool
    /// 我们那条 `SRC-PORT` 规则的三段字段指向哪个策略组；规则不存在时 nil。
    /// 不是 `Proxy` 就说明观看者把它写成了某个地区组 —— 代理源会被钉死在那个地区。
    public let portRuleTarget: String?

    /// The endpoint to add. SOCKS5 is preferred when Loon shares it: it carries UDP and leaves the
    /// request line alone, so nothing about the upstream request is rewritten in transit.
    public var endpoint: CustomProxyEndpoint {
        let port = socksPort > 0 ? socksPort : httpPort
        return CustomProxyEndpoint(name: "Loon", scheme: socksPort > 0 ? .socks5 : .http, host: host, port: port)
    }

    /// What the viewer has to know before relying on it; nil when nothing needs saying.
    public var caveat: String? {
        if !sharesOnLAN {
            return L10n.text("Loon is not sharing its proxy on the local network. Turn on Allow Wi-Fi Access in Loon, then add it again.")
        }
        if hasLegacyWideRange {
            // Checked before `portRule`: the old wide range does not match our narrower proxy range,
            // so placement calls it "missing" and would hide the real problem — that line covers the
            // direct lane too, so "direct" sources would go through the node, the opposite of the ask.
            return L10n.text("Loon still has the older wide SRC-PORT range (up to 41799). It covers the direct ports too, so sources set to direct would go through the node. Replace it with the two lines this page copies.")
        }
        switch portRule {
        case .missing:
            return L10n.text("Loon has no SRC-PORT rule yet, so it decides each site by its own rules — Chinese sources go direct even though you added a proxy. Copy the rule from this page and paste it at the very top of Loon's [Rule] section.")
        case .tooLow(let before):
            return L10n.text("The SRC-PORT rule is in Loon's [Rule] but not first — %@ is matched before it, so it never applies. Move it to the top of that section.", before)
        case .atTop:
            if !hasDirectLine {
                return L10n.text("Only the proxy range is in Loon's rules. Add the second line for the direct range, otherwise those sources still go by Loon's own rules.")
            }
            // The real limit, measured: a domain the config already classifies wins. Saying so is the
            // difference between "this does not work" and "this one site follows Loon's own rule".
            return L10n.text("Both ranges are in place. They decide where a request goes — except for a site Loon's own rules already classify: those follow the rules, because Loon checks them before the port. Sources whose sites are not in your rules (most of them) are fully controlled here.")
        }
        return L10n.text("Loon routes on the port range this app dials from. Turn the App Switch on in Loon's rules if a source should go through the selected line even when Loon would send it direct.")
    }

    // MARK: - Reading Loon

    /// Fetches and parses Loon's config. It answers plain text with no authentication on the LAN.
    public static func load(from apiURL: URL, session: URLSession = .shared) async throws -> LoonPreset {
        guard let host = apiURL.host else { throw TVError.invalidURL }
        let (data, response) = try await session.data(for: URLRequest(url: apiURL, timeoutInterval: 8))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TVError.http(status) }
        return parse(String(decoding: data, as: UTF8.self), host: host, source: apiURL)
    }

    /// Parses the `.conf` text. Split out so it can be tested without a network.
    public static func parse(_ text: String, host: String, source: URL) -> LoonPreset {
        var section = ""
        var general: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            guard section == "general", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            general[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        // The defaults are Loon's own: a config that leaves them out still listens on these.
        let httpPort = Int(general["wifi-access-http-port"] ?? "") ?? 0
        let socksPort = Int(general["wifi-access-socks5-port"] ?? "") ?? 0
        return LoonPreset(source: source, host: host,
                          httpPort: httpPort > 0 ? httpPort : 7222,
                          socksPort: max(0, socksPort),
                          sharesOnLAN: (general["allow-wifi-access"] ?? "").lowercased() == "true",
                          portRule: LoonSRCPortRule.placement(inConfig: text),
                          hasDirectLine: LoonSRCPortRule.hasDirectRule(inConfig: text),
                          hasLegacyWideRange: LoonSRCPortRule.hasLegacyWideRange(inConfig: text),
                          portRuleTarget: LoonSRCPortRule.portRuleTarget(inConfig: text))
    }
}
