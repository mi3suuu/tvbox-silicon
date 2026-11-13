import SwiftUI
import Network
import TVCore

/// Configures the viewer's own HTTP/HTTPS/SOCKS5 proxy endpoints and, per source, which one to use.
/// This is separate from the built-in relay (`SourceRelay`): those endpoints are the user's own
/// egress, where the built-in relay is a fixed public server.

struct ProxySettingsView: View {
    @Environment(Store.self) private var store
    @State private var editing: CustomProxyEndpoint?
    @State private var adding = false
    @State private var addingLoon = false
    @State private var loonAddress = ""
    @State private var loonError: String?
    @State private var loonLoading = false
    @State private var loonPreset: LoonPreset?
    @State private var ruleCopied = false
    @State private var checking = false
    @State private var probe: LoonPortRuleProbe?

    var body: some View {
        let endpoints = store.customProxy.store.endpoints
        SettingsPage(title: L10n.text("Outbound Proxy"), symbol: "network") {
            SettingsGroup(footer: L10n.text("Proxies carry the sources you route through them; a source without a route goes direct.")) {
                if endpoints.isEmpty {
                    SettingsRow(symbol: "network", tint: .secondary, title: L10n.text("No proxies yet"))
                }
                ForEach(endpoints) { endpoint in
                    // A row that opens the editor for that endpoint: `SettingsLinkRow` pushes a
                    // subpage, which an edit sheet is not.
                    Button { editing = endpoint } label: {
                        FormLabel(symbol: "network", tint: Brand.indigo, title: endpoint.name,
                                  subtitle: "\(endpoint.scheme.title) · \(endpoint.host):\(endpoint.port)")
                    }
                    .formRowButton()
                }
                SettingsActionRow(title: L10n.text("Add Proxy")) { adding = true }
            }
            SettingsGroup(title: L10n.text("From Loon"),
                          footer: L10n.text("Loon shares its proxy on the local network while Allow Wi-Fi Access is on. Point this at its configuration page and the proxy ports are filled in for you.")) {
                SettingsActionRow(title: loonLoading ? L10n.text("Reading…") : L10n.text("Add Loon")) {
                    addingLoon = true
                    loonPreset = nil
                    loonError = nil
                }
                if let preset = loonPreset {
                    SettingsRow(symbol: "checkmark.circle", tint: .green,
                                title: L10n.text("Found %@", "\(preset.host):\(preset.endpoint.port)"))
                    if let caveat = preset.caveat {
                        SettingsRow(symbol: "exclamationmark.triangle", tint: .orange, title: caveat)
                    }
                }
                // 让 Loon 按「我们指定的端口」而不是「它自己判的域名」决定走不走节点。
                // 一行规则，与订阅数量无关：它匹配的是源端口，不看域名，所以以后新增订阅、
                // 换节点、更新远程规则集都不需要再动它。
                SettingsActionRow(title: ruleCopied ? L10n.text("Rule Copied") : L10n.text("Copy Loon Rule")) {
                    copyLoonRule()
                }
                SettingsRow(symbol: "arrow.triangle.branch", tint: .secondary, title: L10n.text("Proxy %@", LoonSRCPortRule.range),
                            subtitle: L10n.text("Dialled for sources you route through a proxy."))
                SettingsRow(symbol: "arrow.right", tint: .secondary, title: L10n.text("Direct %@", LoonSRCPortRule.directRange),
                            subtitle: L10n.text("Dialled for everything else, so Loon leaves it alone."))
                SettingsActionRow(title: checking ? L10n.text("Checking…") : L10n.text("Check It Works")) {
                    runSelfCheck()
                }
                if let probe {
                    switch probe.outcome {
                    case .effective:
                        SettingsRow(symbol: "checkmark.seal", tint: .green,
                                    title: L10n.text("The port ranges decide where a request goes"),
                                    subtitle: L10n.text("Proxy %@ · Direct %@", probe.proxyResult, probe.directResult))
                    case .overridden:
                        SettingsRow(symbol: "exclamationmark.triangle", tint: .orange,
                                    title: L10n.text("Both ranges went the same way — Loon's own rules decided"),
                                    subtitle: L10n.text("Proxy %@ · Direct %@", probe.proxyResult, probe.directResult))
                    case .inconclusive:
                        SettingsRow(symbol: "questionmark.circle", tint: .secondary,
                                    title: L10n.text("Could not tell — neither range reached the test address"),
                                    subtitle: L10n.text("Proxy %@ · Direct %@", probe.proxyResult, probe.directResult))
                    }
                }
                if let preset = loonPreset {
                    // 每次读的都是 Loon 当前的真实配置，所以「装没装、位置对不对」永远是新的。
                    switch preset.portRule {
                    case .atTop:
                        SettingsRow(symbol: "checkmark.seal", tint: .green, title: L10n.text("Rule is in place"))
                    case .tooLow(let before):
                        SettingsRow(symbol: "arrow.up.to.line", tint: .orange,
                                    title: L10n.text("Rule is below %@ — move it to the top", before))
                    case .missing:
                        SettingsRow(symbol: "plus.circle", tint: .secondary, title: L10n.text("Rule not installed yet"))
                    }
                }
            }
        }
        .sheet(item: $editing) { endpoint in
            CustomProxyEndpointEditor(endpoint: endpoint)
        }
        .sheet(isPresented: $adding) {
            CustomProxyEndpointEditor(endpoint: nil)
        }
        .sheet(isPresented: $addingLoon) {
            LoonImportSheet(preset: $loonPreset, error: $loonError, loading: $loonLoading)
        }
    }

    /// Puts the rule fragment on the pasteboard, since the only place it can be installed is
    /// Loon's own config editor (its HTTP API is read-only — every write verb closes the socket).
    /// 实测端口规则到底有没有参与决策，而不是靠推断。
    ///
    /// 必须拨裸 IP：域名规则会抢在 SRC-PORT 之前命中，用域名测会得到「规则无效」的假阴性。
    private func runSelfCheck() {
        // 自检不依赖端点：它验的是「端口段是否在影响去向」，与用哪个代理无关。
        guard loonPreset != nil else { return }
        checking = true
        probe = nil
        Task {
            async let proxy = Self.describeEgress(lane: .proxy)
            async let direct = Self.describeEgress(lane: .direct)
            let result = LoonSRCPortRule.evaluate(proxyResult: await proxy, directResult: await direct)
            await MainActor.run { probe = result; checking = false }
        }
    }

    /// 从指定端口段拨一次自检目标，把观察结果压成一个短标签。
    ///
    /// 必须真的从那个端口发出去：`SRC-PORT` 判的是 TCP 源端口，`URLSession` 不给绑定端口的机会，
    /// 所以这里直接开一条 `NWConnection` 并设置 `requiredLocalEndpoint`。目标用裸 IP，
    /// 域名规则便无法抢先匹配——那正是判据成立的前提。
    ///
    /// 刻意**不**经过代理端点：自检要问的是「Loon 是否按这个源端口分流」，而走 Loon 的 CONNECT
    /// 会让 Loon 重建连接、源端口就没了。所以这里是从本机直接拨目标，让 TUN 层看到真实端口。
    private static func describeEgress(lane: SRCPortPool.Lane) async -> String {
        guard let port = SRCPortPool.shared.acquire(lane) else { return "fail(no free port)" }
        defer { SRCPortPool.shared.release(port) }

        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(host: .init(LoonSRCPortRule.probeHost), port: 80, using: params)

        return await withCheckedContinuation { continuation in
            let answered = LockedFlag()
            func finish(_ value: String) {
                guard answered.swap() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 发一个最小请求：能拿到响应说明这条路径通；对端是 HTTP，回什么都行。
                    let request = "HEAD / HTTP/1.1\r\nHost: \(LoonSRCPortRule.probeHost)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if error != nil { finish("timeout"); return }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, error in
                            if error != nil { finish("timeout") }
                            else if let data, !data.isEmpty {
                                let head = String(decoding: data, as: UTF8.self)
                                finish(head.hasPrefix("HTTP/") ? "reachable" : "odd reply")
                            } else { finish("timeout") }
                        }
                    })
                case .failed: finish("fail")
                case .waiting: finish("timeout")
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            // 兜底：不能无限等，否则界面一直转圈。
            DispatchQueue.global().asyncAfter(deadline: .now() + 9) { finish("timeout") }
        }
    }

    private func copyLoonRule() {
        // 三个平台各不相同，不能两分支：
        //   · iOS   → UIPasteboard
        //   · macOS → NSPasteboard（AppKit）
        //   · tvOS  → 两者都不可用（UIPasteboard 标 unavailable，NSPasteboard 属 AppKit 不编入）
        // 原来写的是 `#if os(iOS) || os(tvOS)` → UIPasteboard，tvOS 编译不过。
        #if os(iOS)
        UIPasteboard.general.string = LoonSRCPortRule.fragment
        ruleCopied = true
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LoonSRCPortRule.fragment, forType: .string)
        ruleCopied = true
        #else
        // tvOS 没有系统粘贴板：电视端无法把规则文本交给外部剪贴板。
        // 置 false，让按钮保持「Copy Loon Rule」原文，不谎报已复制。
        ruleCopied = false
        #endif
    }
}

/// 只答一次的开关：`NWConnection` 的状态回调会持续触发，重复 resume 会崩。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func swap() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Asks for Loon's config address, reads it, and adds the endpoint it names.
private struct LoonImportSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var preset: LoonPreset?
    @Binding var error: String?
    @Binding var loading: Bool

    @State private var address = "http://192.168.124.55:7222/loonapi/v1/config/file.conf"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("Address"), text: $address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text(L10n.text("Loon Configuration"))
                } footer: {
                    Text(L10n.text("Open Loon, turn on Allow Wi-Fi Access, and paste the address shown there. Loon's own address is used for the proxy, not this URL's port."))
                }
                if let preset {
                    Section(L10n.text("Found")) {
                        LabeledContent(L10n.text("Host"), value: preset.host)
                        LabeledContent(L10n.text("Scheme"), value: preset.endpoint.scheme.title)
                        LabeledContent(L10n.text("Port"), value: String(preset.endpoint.port))
                        if let caveat = preset.caveat {
                            Text(caveat).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(L10n.text("Add Loon"), action: add).disabled(preset == nil || loading)
                }
            }
            .navigationTitle(L10n.text("Add Loon"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Read"), action: read).disabled(loading)
                }
            }
        }
    }

    private func read() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = L10n.text("Enter a valid HTTP or HTTPS URL."); return
        }
        loading = true
        error = nil
        Task {
            do {
                let found = try await LoonPreset.load(from: url)
                await MainActor.run {
                    preset = found
                    loading = false
                    if !found.sharesOnLAN { error = found.caveat }
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func add() {
        guard let preset else { return }
        store.customProxy.store.upsert(preset.endpoint)
        store.customProxy.touch()
        store.cloudSync?.changed("cloudBackup")
        // Start the relay now: the viewer is about to expect a route to work.
        LocalProxyServer.shared.ensureStarted()
        dismiss()
    }
}

/// Adds or edits one proxy endpoint: its name, scheme (HTTP / HTTPS / SOCKS5), host, port, and
/// optional username and password.
private struct CustomProxyEndpointEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let endpoint: CustomProxyEndpoint?

    @State private var name = ""
    @State private var scheme: CustomProxyEndpoint.Scheme = .http
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmsRemoval = false

    /// A port is usable only inside the range a `UInt16` can name. `Int(port) != nil` alone let 0
    /// and 70000 be saved, and the endpoint then silently had no address at all — a proxy row that
    /// could never dial and never said why.
    private var validPort: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(value) else { return nil }
        return value
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Name")) {
                    TextField(L10n.text("Name"), text: $name)
                }
                Section(L10n.text("Scheme")) {
                    Picker(L10n.text("Scheme"), selection: $scheme) {
                        ForEach(CustomProxyEndpoint.Scheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(L10n.text("Address")) {
                    TextField(L10n.text("Host"), text: $host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField(L10n.text("Port"), text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Section(L10n.text("Authentication (optional)")) {
                    TextField(L10n.text("Username"), text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField(L10n.text("Password"), text: $password)
                }
                Section {
                    Button(L10n.text("Save"), action: save)
                        .disabled(trimmedHost.isEmpty || validPort == nil)
                }
                if endpoint != nil {
                    Section {
                        Button(L10n.text("Remove"), role: .destructive) { confirmsRemoval = true }
                    }
                }
            }
            .navigationTitle(endpoint == nil ? L10n.text("Add Proxy") : L10n.text("Edit Proxy"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
            }
            .confirmationDialog(L10n.text("Remove Proxy"), isPresented: $confirmsRemoval) {
                Button(L10n.text("Remove"), role: .destructive) {
                    if let endpoint { store.customProxy.store.removeEndpoint(id: endpoint.id); store.customProxy.touch() }
                    store.cloudSync?.changed("cloudBackup")
                    dismiss()
                }
            }
            .onAppear {
                name = endpoint?.name ?? ""
                scheme = endpoint?.scheme ?? .http
                host = endpoint?.host ?? ""
                port = endpoint.map { String($0.port) } ?? ""
                username = endpoint?.username ?? ""
                password = endpoint?.password ?? ""
            }
        }
    }

    private func save() {
        guard let validPort else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = CustomProxyEndpoint(id: endpoint?.id ?? UUID().uuidString,
                                  name: trimmedName.isEmpty ? "\(scheme.title) \(trimmedHost):\(validPort)" : trimmedName,
                                  scheme: scheme, host: trimmedHost, port: validPort,
                                  username: username, password: password)
        store.customProxy.store.upsert(value)
        store.customProxy.touch()
        store.cloudSync?.changed("cloudBackup")
        LocalProxyServer.shared.ensureStarted()
        dismiss()
    }
}
