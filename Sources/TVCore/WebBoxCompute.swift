import Foundation

/// `ctx.compute.run`: a plugin's own code plus the binaries it instantiates, run with a real WebAssembly
/// engine. QuickJS has none, and 4k影视 signs its play requests inside a wasm-bindgen module, so this one
/// capability runs in Node: the Mac host's bundled node, a node on PATH (the probe), or — on iPhone, iPad
/// and Apple TV, where no process can be started — the embedded Node the CatPawOpen sources already use.
///
/// The answer is the text Node returned: `{"result": ...}` or `{"error": "..."}`.
enum WebBoxCompute {
    static func run(_ json: String) throws -> String {
        guard let data = json.data(using: .utf8) else { throw ScriptHostError("invalid compute request") }
        let limit = Double((try? JSONDecoder().decode([String: JSONValue].self, from: data))?["timeoutMs"]?.int ?? 10000) / 1000
        // ⛔ `Process` 在 iOS/tvOS 上**不存在**（不是运行时不可用，是编译期没有这个类型）。
        // 所以「有 node 就跑子进程」这条支路必须整段用平台守卫包住，
        // 不能只把 fallback 分支放进 #if —— 否则 iOS 目标在编译 `Process()` 时就报错。
        #if os(macOS)
        if let node = node() { return try execute(node, request: data, limit: limit) }
        throw ScriptHostError("node is missing, so this plugin's WebAssembly module can't run")
        #else
        // iPhone / iPad / Apple TV 起不了子进程，一律走内嵌 Node。
        return try embedded(data, limit: limit)
        #endif
    }

    #if os(macOS)
    /// The Mac app ships Node beside its other hosts (`Scripts/build-script-host.sh`); a build without it
    /// (the probe, a developer's copy) uses the node on PATH.
    private static func node() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("ScriptHost/node")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        for folder in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    #endif

    /// 两个平台都要用它（macOS 走子进程、iOS 走内嵌 Node），
    /// 所以必须在平台守卫**外面** —— 上一版把它框进 `#if os(macOS)`，
    /// iOS 编译时这里就找不到 `runner`（实测报 cannot find 'runner' in scope）。
    private static var runner: URL? { ScriptAssets.root?.appendingPathComponent("webox/compute.mjs") }

    /// One node run per computation: the module is a few dozen kilobytes and the call is once per episode.
    #if os(macOS)
    /// 只在 macOS 编译：`Process` 在 iOS/tvOS 上**不存在**（编译期就没有这个类型）。
    private static func execute(_ node: URL, request: Data, limit: Double) throws -> String {
        guard let runner, FileManager.default.fileExists(atPath: runner.path) else { throw ScriptHostError("the compute runner is missing from this build") }
        let process = Process()
        process.executableURL = node
        process.arguments = ["--no-warnings", runner.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw ScriptHostError("node could not start: \(error.localizedDescription)") }
        input.fileHandleForWriting.write(request)
        try? input.fileHandleForWriting.close()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit + 5, execute: watchdog)
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        let noise = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard !answer.isEmpty, let text = String(data: answer, encoding: .utf8) else {
            let reason = String(decoding: noise, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScriptHostError(reason.isEmpty ? "the compute module returned nothing" : String(reason.suffix(300)))
        }
        return text
    }
    #endif

    #if os(iOS) || os(tvOS)
    /// Node can't start twice in a process, so the embedded one answers: it imports the same runner.
    private static func embedded(_ request: Data, limit: Double) throws -> String {
        guard EmbeddedNodeHost.available else { throw ScriptHostError("this build has no Node, so the plugin's WebAssembly module can't run") }
        guard let runner else { throw ScriptHostError("the compute runner is missing from this build") }
        let slot = Answer()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { slot.store(.success(try await EmbeddedNodeHost.shared.compute(request, runner: runner.path))) }
            catch { slot.store(.failure(error)) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + limit + 10) == .timedOut { throw ScriptHostError("the compute module did not answer in time") }
        switch slot.value {
        case .success(let text): return text
        case .failure(let error): throw ScriptHostError(error.localizedDescription)
        case nil: throw ScriptHostError("the compute module returned nothing")
        }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<String, Error>?
        func store(_ result: Result<String, Error>) { lock.withLock { stored = result } }
        var value: Result<String, Error>? { lock.withLock { stored } }
    }
    #endif
}
