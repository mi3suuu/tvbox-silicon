import Foundation

/// Plays a magnet link.
///
/// A magnet is not a media address: someone has to join the swarm, ask for the pieces the player is
/// about to read, and hand them over as bytes. That runs in a Node process (`ScriptAssets/torrent/
/// bridge.mjs`, WebTorrent bundled into one file), because the swarm work — DHT, trackers, peer wire —
/// has no business on the main thread and no place in the app binary.
///
/// The bridge answers on a loopback port with a per-launch token:
///
/// - an MP4 is played straight from `…/stream/<hash>/<index>`, which speaks HTTP Range like any CDN,
///   so the player seeks before the file is finished;
/// - anything else (MKV, AVI, TS…) goes through `Remux` with `TorrentRemuxSource`, which reads arbitrary
///   slices from `…/read/<hash>/<index>` and turns the file into HLS the way a downloaded MKV is.
///
/// WebTorrent is TCP-only here (`utp-native` is a native addon we do not ship), which is what most
/// clients seed on anyway.
#if os(macOS)
public actor TorrentBridge {
    public static let shared = TorrentBridge()

    /// Node, the bridge script and a platform that can start one. iOS and tvOS cannot: the embedded
    /// runtime is nodejs-mobile, single-instance and already owned by CatPaw Open sources.
    public static let available: Bool = {
        #if os(macOS)
        return executable != nil && script != nil
        #else
        return false
        #endif
    }()

    /// What the bridge found in the swarm: the file to play and how big it is.
    public struct Torrent: Codable, Sendable, Equatable {
        public var infoHash: String
        public var name: String
        public var fileName: String
        public var fileIndex: Int
        public var length: Int64
        public var total: Int64
        /// True for MP4/MOV: playable as it is, without the repackager in the middle.
        public var direct: Bool
        public var peers: Int

        public var isVideo: Bool {
            ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts", "mpg", "mpeg", "vob"]
                .contains((fileName as NSString).pathExtension.lowercased())
        }
    }

    private struct Handshake: Decodable { var port: Int; var token: String }
    private struct AddRequest: Encodable { var magnet: String; var wait: Int }

    private var process: Process?
    private var base: URL?
    private var token = ""
    private var starting: Task<URL, Error>?

    // MARK: - Process

    /// The app's own Node on the Mac, else the one a developer has installed.
    static var executable: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("ScriptHost/node")) }
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/node"), URL(fileURLWithPath: "/usr/local/bin/node")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The bridge ships inside TVCore's script assets, so it needs no build step in the app target.
    static var script: URL? {
        if let root = ScriptAssets.root {
            let file = root.appendingPathComponent("torrent/bridge.mjs")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        // A checkout that runs the CLI from its build directory without the resource bundle.
        let beside = Bundle.main.resourceURL?.appendingPathComponent("torrent/bridge.mjs")
        return beside.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static var store: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tvbox.yingxia/Torrents", isDirectory: true)
    }

    private func start() async throws -> URL {
        if let base { return base }
        if let starting { return try await starting.value }
        let task = Task<URL, Error> { try await launch() }
        starting = task
        defer { starting = nil }
        let url = try await task.value
        base = url
        return url
    }

    private func launch() async throws -> URL {
        guard Self.available, let executable = Self.executable, let script = Self.script else {
            throw TVError.unsupported(L10n.text("Torrent playback needs the Mac app: iPhone, iPad and Apple TV have no Node process to spare."))
        }
        let launchToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try FileManager.default.createDirectory(at: Self.store, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-warnings", script.path, "--root", Self.store.path, "--token", launchToken, "--port", "0"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        do { try process.run() } catch { throw TVError.unsupported("node could not start: \(error.localizedDescription)") }

        // The first line on stdout is the handshake: the port it listens on.
        let reading = Task.detached { () -> Handshake? in
            var buffer = Data()
            let handle = output.fileHandleForReading
            while buffer.count < 4096 {
                let piece = handle.availableData
                if piece.isEmpty { break }
                buffer.append(piece)
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    return try? JSONDecoder().decode(Handshake.self, from: line)
                }
            }
            return nil
        }
        let handshake = await withTaskGroup(of: Handshake?.self) { group in
            group.addTask { await reading.value }
            group.addTask { try? await Task.sleep(for: .seconds(12)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let handshake, let url = URL(string: "http://127.0.0.1:\(handshake.port)/") else {
            process.terminate()
            let detail = errors.fileHandleForReading.readDataToEndOfFile()
            throw TVError.unsupported("torrent bridge did not start: " + (String(decoding: detail.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        // Keep the pipes drained, or a chatty torrent fills the buffer and the process stalls.
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        output.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.forget() }
        }
        self.process = process
        self.token = handshake.token
        Diagnostics.shared.record(.info, "torrent", "bridge listening on \(url.absoluteString) pid=\(process.processIdentifier)")
        return url
    }

    private func forget() {
        process = nil
        base = nil
        starting = nil
    }

    // MARK: - Calls

    private func url(_ path: String, query: [String: String] = [:]) async throws -> URL {
        let base = try await start()
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { throw TVError.invalidURL }
        return url
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 200
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// Joins the swarm and returns the file to play. `wait` bounds the metadata exchange: a dead torrent
    /// (or one whose trackers this network cannot reach) answers nothing, and the player should say so.
    public func open(_ magnet: String, wait seconds: TimeInterval = 60) async throws -> Torrent {
        let target = try await url("add")
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = seconds + 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AddRequest(magnet: magnet, wait: Int(seconds)))
        let started = ContinuousClock.now
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.unsupported("torrent bridge gave no answer") }
        guard http.statusCode == 200 else {
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            if text.contains("no peers") { throw TVError.unsupported(L10n.text("No peer answered for this magnet. The torrent may be dead, or this network blocks BitTorrent.")) }
            throw TVError.unsupported("torrent bridge: HTTP \(http.statusCode) \(text)")
        }
        let torrent = try JSONDecoder().decode(Torrent.self, from: data)
        Diagnostics.shared.record(.info, "torrent", "joined \(torrent.infoHash) peers=\(torrent.peers) file=\(torrent.fileName) \(torrent.length)B in \(started.duration(to: .now))")
        return torrent
    }

    /// An address the player can open: HTTP Range over the swarm.
    public func streamURL(_ torrent: Torrent) async throws -> URL {
        try await url("stream/\(torrent.infoHash)/\(torrent.fileIndex)")
    }

    /// Bytes `[offset, offset+count)`, waiting for the pieces that carry them. Used by the repackager.
    public func read(_ torrent: Torrent, at offset: Int64, count: Int) async throws -> Data {
        let target = try await url("read/\(torrent.infoHash)/\(torrent.fileIndex)",
                                   query: ["offset": String(offset), "count": String(count)])
        let (data, response) = try await Self.session.data(for: URLRequest(url: target))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TVError.unsupported("the torrent stopped sending bytes")
        }
        return data
    }

    /// An HLS address for a file AVPlayer cannot open as it is (MKV, AVI, TS…): the repackager reads it
    /// through this bridge while the swarm is still sending.
    public func remuxURL(_ torrent: Torrent) async throws -> URL {
        try await Remux.open(TorrentRemuxSource(torrent: torrent))
    }

    public func stop(_ torrent: Torrent) async {
        guard let target = try? await url("torrent/\(torrent.infoHash)") else { return }
        var request = URLRequest(url: target)
        request.httpMethod = "DELETE"
        _ = try? await Self.session.data(for: request)
    }
}

/// Reads a torrent's chosen file through the bridge, so `Remux` can turn an MKV into HLS while it
/// is still downloading. FFmpeg reads the index at the end of a Matroska file and comes back to the
/// start, which the bridge answers by asking WebTorrent for exactly those pieces.
struct TorrentRemuxSource: RemuxSource {
    let torrent: TorrentBridge.Torrent
    var length: Int64 { torrent.length }
    var transfer: (received: Int64, host: String?)? { nil }

    func read(at offset: Int64, count: Int) async throws -> Data {
        try await TorrentBridge.shared.read(torrent, at: offset, count: count)
    }

    func close() async {}
}

#else
/// iPhone, iPad and Apple TV have no second Node process to spare: nodejs-mobile is a single instance
/// already owned by CatPaw Open sources, so a magnet cannot be joined there yet. The app says so
/// instead of failing silently, and the Mac build plays it.
public actor TorrentBridge {
    public static let shared = TorrentBridge()
    public static let available = false

    public struct Torrent: Codable, Sendable, Equatable {
        public var infoHash = ""
        public var name = ""
        public var fileName = ""
        public var fileIndex = 0
        public var length: Int64 = 0
        public var total: Int64 = 0
        public var direct = false
        public var peers = 0
        public var isVideo: Bool { false }
    }

    private var unavailable: Error {
        TVError.unsupported(L10n.text("Torrent playback needs the Mac app: iPhone, iPad and Apple TV have no Node process to spare."))
    }

    public func open(_ magnet: String, wait seconds: TimeInterval = 60) async throws -> Torrent { throw unavailable }
    public func streamURL(_ torrent: Torrent) async throws -> URL { throw unavailable }
    public func read(_ torrent: Torrent, at offset: Int64, count: Int) async throws -> Data { throw unavailable }
    public func remuxURL(_ torrent: Torrent) async throws -> URL { throw unavailable }
    public func stop(_ torrent: Torrent) async {}
}
#endif
