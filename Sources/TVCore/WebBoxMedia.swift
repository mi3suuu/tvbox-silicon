import Foundation
import Network

/// WeBox's media pipeline. A plugin may answer `play` with an **in-memory playlist** and a pair of hooks
/// (`media: { request, response }`) instead of a URL: 肉 unwraps an HLS manifest from a PNG payload and
/// rearranges every segment the same way. Nothing can play a string, so this serves one over loopback —
/// the playlist rewritten so each child address comes back here, and each media request answered by the
/// plugin's own hooks (`__webox.mediaFetch`). The player keeps seeing plain http, exactly as it does for
/// `LocalMediaServer`'s downloaded playlists.
public final class WebBoxMediaProxy: @unchecked Sendable {
    static let shared = WebBoxMediaProxy()
    private struct Entry { let manifest: String; let session: ScriptSession }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var listener: NWListener?
    private var base: URL?
    private let queue = DispatchQueue(label: "tvbox.webox.media")

    /// Rewrites a plugin's playlist so it can be played, and answers with the address to hand the player.
    func publish(_ json: String, session: ScriptSession) throws -> String {
        let request = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        guard let token = request["token"]?.string, let manifest = request["manifest"]?.string, !manifest.isEmpty else {
            throw ScriptHostError("invalid media request")
        }
        let base = try start()
        let origin = request["baseUrl"]?.string ?? ""
        let rewritten = Self.rewrite(manifest, origin: origin) { Self.address(base, token, $0) }
        lock.withLock {
            entries[token] = Entry(manifest: rewritten, session: session)
            order.removeAll { $0 == token }
            order.append(token)
            while order.count > 8 { entries.removeValue(forKey: order.removeFirst()) }
        }
        return Self.address(base, token, nil)
    }

    private func entry(_ token: String) -> Entry? { lock.withLock { entries[token] } }

    /// `http://127.0.0.1:<port>/m/<token>` for the playlist itself, `?u=` for everything it points at.
    private static func address(_ base: URL, _ token: String, _ upstream: String?) -> String {
        var text = base.appendingPathComponent("m").appendingPathComponent(token).absoluteString
        guard let upstream, var components = URLComponents(string: text) else { return text }
        components.queryItems = [URLQueryItem(name: "u", value: upstream)]
        text = components.url?.absoluteString ?? text
        return text
    }

    /// Resolves every address in a playlist — segment lines and `URI="…"` attributes alike — through `media`.
    static func rewrite(_ text: String, origin: String, media: (String) -> String) -> String {
        let base = URL(string: origin)
        func absolute(_ value: String) -> String {
            URL(string: value, relativeTo: base)?.absoluteURL.absoluteString ?? value
        }
        return text.components(separatedBy: .newlines).map { line -> String in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return line }
            if !value.hasPrefix("#") { return media(absolute(value)) }
            guard line.contains("URI=\"") else { return line }
            let pattern = try? NSRegularExpression(pattern: #"URI="([^"]+)""#)
            guard let pattern else { return line }
            var result = line
            for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                result = result.replacingCharacters(in: range, with: media(absolute(String(line[range]))))
            }
            return result
        }.joined(separator: "\n")
    }

    private func start() throws -> URL {
        // A suspended iOS app loses its sockets; a listener that is no longer ready is replaced.
        if let base, listener?.state == .ready { return base }
        listener?.cancel(); listener = nil; base = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let found = Box()
        server.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data())
        }
        server.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = server.port { found.value = URL(string: "http://127.0.0.1:\(port.rawValue)/") }
                ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        server.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { server.cancel() }
        guard let address = found.value else { throw TVError.unsupported(L10n.text("The media proxy could not start.")) }
        listener = server
        base = address
        return address
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?
        var value: URL? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { serve(connection, request: bytes) }
            else if error != nil || complete || bytes.count > 16384 { connection.cancel() }
            else { receive(connection, buffer: bytes) }
        }
    }

    private nonisolated static func serve(_ connection: NWConnection, request: Data) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" || fields[0] == "HEAD" else { send(connection, status: 405); return }
        let head = fields[0] == "HEAD"
        guard let components = URLComponents(string: "http://127.0.0.1" + String(fields[1])),
              let token = components.path.split(separator: "/").dropFirst().first.map(String.init),
              let entry = shared.entry(token) else { send(connection, status: 404); return }
        let upstream = components.queryItems?.first { $0.name == "u" }?.value
        guard let upstream, !upstream.isEmpty else {
            let body = Data(entry.manifest.utf8)
            send(connection, status: 200, body: head ? Data() : body, length: body.count, mime: "application/vnd.apple.mpegurl")
            return
        }
        let payload = ["token": token, "url": upstream]
        guard let argument = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: argument, encoding: .utf8) else { send(connection, status: 500); return }
        Task {
            let envelope = await entry.session.evaluate("__webox.mediaFetch(\(text))", within: 40)
            guard let answer = envelope["value"]?.object, let data = answer["body"]?.string,
                  let bytes = Data(base64Encoded: data) else {
                Diagnostics.shared.record(.warning, "webox.media", envelope["error"]?.string ?? "no answer")
                send(connection, status: 502)
                return
            }
            if answer["playlist"]?.bool == true {
                let origin = answer["url"]?.string ?? upstream
                let rewritten = rewrite(String(decoding: bytes, as: UTF8.self), origin: origin) { shared.child(token, $0) }
                let body = Data(rewritten.utf8)
                send(connection, status: 200, body: head ? Data() : body, length: body.count, mime: "application/vnd.apple.mpegurl")
                return
            }
            let mime = answer["mime"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? sniff(bytes)
            send(connection, status: 200, body: head ? Data() : bytes, length: bytes.count, mime: mime)
        }
    }

    private func child(_ token: String, _ upstream: String) -> String {
        guard let base else { return upstream }
        return Self.address(base, token, upstream)
    }

    /// Media that arrives without a content type (肉's slices keep the PNG header off) is named by its magic.
    private nonisolated static func sniff(_ bytes: Data) -> String {
        let head = [UInt8](bytes.prefix(12))
        if head.count >= 4, head[0] == 0x47 { return "video/mp2t" }
        if head.count >= 8, Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return "video/mp4" }
        if head.count >= 3, head[0] == 0xFF, head[1] & 0xF0 == 0xF0 { return "audio/aac" }
        if head.count >= 4, head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 { return "video/webm" }
        return "application/octet-stream"
    }

    private nonisolated static func send(_ connection: NWConnection, status: Int, body: Data = Data(), length: Int? = nil, mime: String = "text/plain") {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed", 500: "Error", 502: "Bad Gateway"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(length ?? body.count)\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
