import Foundation

/// A half-open byte span on disk: what one Range request delivered.
struct ByteSpan: Codable, Sendable, Hashable {
    var start: Int64
    var end: Int64
    var count: Int64 { max(0, end - start) }
    func covers(_ other: ByteSpan) -> Bool { start <= other.start && end >= other.end }
    func overlaps(_ other: ByteSpan) -> Bool { start < other.end && other.start < end }
}

/// How one download's media is laid out, saved beside it as `plan.json`: a stopped download
/// reads it back and fetches only what is missing.
struct TransferPlan: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case file, hls, dash }
    /// A file fetched in fixed-size ranges, several at once; `spans` lists the finished ranges.
    struct RemoteFile: Codable, Sendable {
        /// Mirrors, tried in order.
        var urls: [URL]
        var name: String
        var length: Int64?
        /// False when the server ignores ranges: the file then comes in one request and starts over if stopped.
        var ranged: Bool
        /// What earlier runs already wrote. Spans, not chunk numbers: a range can be split in half when
        /// the tail of a file needs more sockets, and a chunk number cannot express "the first 2 MB of it".
        var spans: [ByteSpan] = []
        /// Chunk numbers from plans written before spans existed. Read once, then folded into `spans`.
        var done: Set<Int> = []
        /// Bytes per Range request this file was planned with, so a resumed file keeps its marks valid
        /// even after the person changes the setting.
        var chunk: Int64 = Transfer.chunk
        /// DASH: the initialization section and `sidx` index, which describe the file as HLS byte ranges.
        var initialization: ClosedRange<Int>?
        var index: ClosedRange<Int>?
        var chunks: Int {
            guard ranged, let length, length > 0 else { return 1 }
            return Int((length + chunk - 1) / chunk)
        }
        func range(_ index: Int) -> ClosedRange<Int64> {
            let start = Int64(index) * chunk
            return start...min(start + chunk, length ?? 0) - 1
        }
        /// Bytes already on disk, from spans and from any legacy chunk marks.
        var saved: Int64 {
            guard ranged else { return 0 }
            return finished.reduce(0) { $0 + $1.count }
        }
        /// Everything on disk, as spans. Legacy chunk marks are converted here so the fetch loop only
        /// ever has one thing to trust.
        var finished: [ByteSpan] {
            guard let length else { return spans }
            var all = spans
            for index in done.sorted() where index >= 0 && index < chunks {
                let legacy = range(index)
                all.append(ByteSpan(start: legacy.lowerBound, end: legacy.upperBound + 1))
            }
            return all.filter { $0.start >= 0 && $0.end <= max(0, length) }
        }
        mutating func merge(_ span: ByteSpan) {
            guard span.count > 0 else { return }
            var all = finished.filter { !$0.overlaps(span) }
            var merged = span
            for other in finished where other.overlaps(merged) || other.end == merged.start || other.start == merged.end {
                merged = ByteSpan(start: min(merged.start, other.start), end: max(merged.end, other.end))
            }
            all.removeAll { $0.overlaps(merged) || $0.end == merged.start || $0.start == merged.end }
            all.append(merged)
            all.sort { $0.start < $1.start }
            spans = all
            done = []
        }
        /// Whether every byte of the file is on disk.
        func complete() -> Bool {
            guard let length, length > 0 else { return false }
            guard ranged else { return false }
            let sorted = finished.sorted { $0.start < $1.start }
            var reach: Int64 = 0
            for span in sorted {
                if span.start > reach { return false }
                reach = max(reach, span.end)
            }
            return reach >= length
        }
    }
    /// One HLS segment, key or initialization section, saved whole under `name`.
    struct Part: Codable, Sendable {
        var url: URL
        var range: ClosedRange<Int64>?
        var name: String
        /// MPEG-TS that some hosts disguise behind an image header.
        var transportStream: Bool
    }
    var kind: Kind
    var headers: [String: String]
    var files: [RemoteFile] = []
    var parts: [Part] = []
    /// The local HLS playlist, naming `parts` by their file names.
    var playlist: String?
    var fileExtension: String?
    var quality: Int?
    /// DASH: the master playlist's EXT-X-STREAM-INF attributes.
    var streamInfo: String?
    var label: String?
    var cid: String?
    var duration: Double?
    var expected: Int64? {
        guard kind != .hls else { return nil }
        let lengths = files.map(\.length)
        return lengths.contains(nil) ? nil : lengths.reduce(0) { $0 + ($1 ?? 0) }
    }
}

enum TransferError: LocalizedError, Equatable {
    /// The address answered 401/403/404/410: links from most sources expire, so the episode is resolved again.
    case expired(Int)
    case http(Int)
    case live, protected, notMedia, rangeLost, incomplete, noSpace(needed: Int64, available: Int64)
    var retriable: Bool {
        switch self {
        case .http(let status): status == 429 || status >= 500 || status == 0
        case .incomplete: true
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .expired(let status): L10n.text("The video link stopped working (HTTP %lld) and could not be renewed. Try again later.", status)
        case .http(let status): L10n.text("The server returned HTTP %lld.", status)
        case .live: L10n.text("Live streams can't be cached.")
        case .protected: L10n.text("This video is protected and can't be cached.")
        case .notMedia: L10n.text("This link didn't return a video.")
        case .rangeLost: L10n.text("The server stopped allowing caching to resume. Retry to start again.")
        case .incomplete: L10n.text("The server closed the connection early.")
        case .noSpace(let needed, let available):
            L10n.text("Not enough storage: this needs %@ more, and %@ is free.", Self.size(needed), Self.size(available))
        }
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// What a running transfer reports beyond byte counts.
enum TransferNote: Sendable {
    case prepared(TransferPlan)
    case finishing
}

/// Fetches one download into its folder. Every finished piece is on disk under its final name (or
/// marked in `plan.json`), so cancelling at any point loses at most the pieces in flight.
struct Transfer: Sendable {
    /// Falls back to the settings' defaults; the library passes the person's own knobs.
    static let chunk: Int64 = DownloadTuning.standard.chunk
    static let connections = DownloadTuning.standard.connections
    let folder: URL
    let meter: DownloadMeter
    let session: URLSession
    /// Range requests per file, range size, and the smoothed speed/connection count the UI reads.
    /// Read through `tuning.value` at the point of use, so a knob turned mid-download takes effect on
    /// the next range rather than on the next download.
    let tuning: TuningBox
    let speed: SpeedMeter
    let resolve: @Sendable () async throws -> Channel
    let note: @Sendable (TransferNote) async -> Void

    init(folder: URL, meter: DownloadMeter, session: URLSession, tuning: TuningBox = TuningBox(.standard),
         speed: SpeedMeter = SpeedMeter(), resolve: @escaping @Sendable () async throws -> Channel,
         note: @escaping @Sendable (TransferNote) async -> Void) {
        self.folder = folder; self.meter = meter; self.session = session
        self.tuning = tuning; self.speed = speed; self.resolve = resolve; self.note = note
    }

    private var planFile: URL { folder.appending(path: "plan.json") }

    /// Downloads everything and returns the playable file's path inside the folder.
    func run() async throws -> String {
        try FileManager.default.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: true)
        var plan: TransferPlan
        if let data = try? Data(contentsOf: planFile), let saved = try? JSONDecoder().decode(TransferPlan.self, from: data) { plan = saved }
        else { plan = try await prepare(try await resolve()); try save(plan) }
        var renewals = 0
        while finishedFile(plan) == nil {
            try Task.checkCancellation()
            try begin(plan)
            await note(.prepared(plan))
            let box = PlanBox(plan, file: planFile)
            do {
                try await fetch(box)
                plan = box.plan
                try save(plan)
                break
            } catch TransferError.expired(let status) {
                plan = box.plan
                try? save(plan)
                guard renewals < 2 else { throw TransferError.expired(status) }
                renewals += 1
                Diagnostics.shared.record(.info, "download", "renewing link status=\(status) folder=\(folder.lastPathComponent)")
                plan = try await renew(plan)
                try save(plan)
            } catch {
                try? save(box.plan)
                throw error
            }
        }
        await note(.finishing)
        return try await finish(plan)
    }

    // MARK: Planning

    /// Works out what the resolved address is: DASH, an HLS playlist, or a plain file.
    func prepare(_ channel: Channel) async throws -> TransferPlan {
        if let dash = DashStreams.files(for: channel.url) { return try await prepare(dash) }
        if channel.url.scheme == DashStreams.scheme { throw TVError.unsupported(L10n.text("This playback has expired. Open the video again.")) }
        var headers = channel.headers
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = HTTPClient.userAgent }
        let (head, response) = try await get([channel.url], headers: headers, range: 0...65_535, limit: 65_536, counts: false)
        let base = response.url ?? channel.url
        if Self.isPlaylist(head) {
            var text = String(decoding: head, as: UTF8.self)
            if Self.total(response).map({ $0 > Int64(head.count) }) ?? (head.count >= 65_536) {
                text = String(decoding: try await get([channel.url], headers: headers, counts: false).0, as: UTF8.self)
            }
            return try await prepareHLS(text, base: base, headers: headers)
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/html") || mime.hasPrefix("application/json") { throw TransferError.notMedia }
        let ranged = response.statusCode == 206
        let length = ranged ? Self.total(response) : (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        let file = TransferPlan.RemoteFile(urls: [base], name: "media.part", length: length,
                                          ranged: ranged && length != nil, chunk: tuning.value.chunk)
        return TransferPlan(kind: .file, headers: headers, files: [file], fileExtension: Self.fileExtension(base, mime: mime, head: head))
    }

    private func prepare(_ dash: DashFiles) async throws -> TransferPlan {
        var files: [TransferPlan.RemoteFile] = []
        let halves = [("video.m4s", dash.video, dash.videoInitialization, dash.videoIndex), ("audio.m4s", dash.audio, dash.audioInitialization, dash.audioIndex)]
        for (name, urls, initialization, index) in halves where !urls.isEmpty {
            let (_, response) = try await get(urls, headers: dash.headers, range: 0...0, limit: 1, counts: false)
            guard response.statusCode == 206, let length = Self.total(response) else { throw TransferError.rangeLost }
            // Keep the mirror that answered first.
            let first = response.url.flatMap { answered in urls.first { $0.host() == answered.host() } }
            files.append(.init(urls: first.map { [$0] + urls.filter { $0 != first } } ?? urls, name: name, length: length, ranged: true,
                               chunk: tuning.value.chunk, initialization: initialization, index: index))
        }
        return TransferPlan(kind: .dash, headers: dash.headers, files: files, quality: dash.quality,
                            streamInfo: dash.streamInfo, label: dash.label, cid: dash.cid, duration: dash.duration)
    }

    private func prepareHLS(_ playlist: String, base: URL, headers: [String: String]) async throws -> TransferPlan {
        var text = playlist, base = base, label: String?
        // A master playlist: take the best variant (by bandwidth), which may itself be a master.
        for _ in 0..<3 {
            guard let best = HLS.variants(text, base: base).max(by: { $0.bandwidth < $1.bandwidth }) else { break }
            label = best.height.map { "\($0)P" } ?? label
            let (data, response) = try await get([best.url], headers: headers, counts: false)
            guard Self.isPlaylist(data) else { throw TransferError.notMedia }
            text = String(decoding: data, as: UTF8.self); base = response.url ?? best.url
        }
        let local = try HLS.localize(text, base: base)
        return TransferPlan(kind: .hls, headers: headers, parts: local.parts, playlist: local.playlist, label: label)
    }

    /// Resolves the episode again after its links expired and carries the progress over when the
    /// media is the same (same sizes, same segment count); otherwise starts it over.
    private func renew(_ old: TransferPlan) async throws -> TransferPlan {
        let channel = try await resolve()
        var plan: TransferPlan
        if old.kind == .dash, let dash = DashStreams.files(for: channel.url, quality: old.quality) { plan = try await prepare(dash) }
        else { plan = try await prepare(channel) }
        if plan.kind == old.kind {
            switch plan.kind {
            case .file, .dash:
                if plan.files.count == old.files.count, zip(plan.files, old.files).allSatisfy({ $0.length == $1.length && $0.ranged && $1.ranged }) {
                    // Spans carry over, not chunk numbers: a renewed link may be split differently.
                    for index in plan.files.indices {
                        plan.files[index].spans = old.files[index].finished
                        plan.files[index].chunk = old.files[index].chunk
                        plan.files[index].done = []
                    }
                    return plan
                }
            case .hls:
                if plan.parts.count == old.parts.count, plan.playlist == old.playlist { return plan }
            }
        }
        Diagnostics.shared.record(.info, "download", "renewed media differs; starting over folder=\(folder.lastPathComponent)")
        try? FileManager.default.removeItem(at: folder.appending(path: "parts"))
        try FileManager.default.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: true)
        return plan
    }

    /// A file download already moved into place (or rewrapped): the app quit while it was finishing.
    private func finishedFile(_ plan: TransferPlan) -> String? {
        guard plan.kind == .file, !FileManager.default.fileExists(atPath: folder.appending(path: "parts").appending(path: plan.files[0].name).path) else { return nil }
        return ["media." + (plan.fileExtension ?? "mp4"), DownloadLibrary.rewrappedName].first { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    private func save(_ plan: TransferPlan) throws {
        try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
    }

    /// Counts what is already on disk and checks there is room for the rest.
    private func begin(_ plan: TransferPlan) throws {
        let saved: Int64, done: Int, total: Int
        switch plan.kind {
        case .file, .dash:
            saved = plan.files.reduce(0) { $0 + $1.saved }
            // Counted in ranges rather than spans so a split range does not inflate the total.
            done = plan.files.reduce(0) { total, file in
                guard file.ranged, let length = file.length, length > 0 else { return total }
                return total + min(file.chunks, Int(file.saved / max(1, file.chunk)))
            }
            total = plan.files.reduce(0) { $0 + $1.chunks }
        case .hls:
            let present = plan.parts.compactMap { part -> Int64? in
                (try? folder.appending(path: part.name).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            }
            saved = present.reduce(0, +); done = present.count; total = plan.parts.count
        }
        meter.reset(received: saved, parts: done, total: total, expected: plan.expected)
        if let expected = plan.expected, let free = DownloadLibrary.availableCapacity(at: folder) {
            let needed = expected - saved
            if needed > free { throw TransferError.noSpace(needed: needed, available: free) }
        }
    }

    // MARK: Fetching

    private func fetch(_ box: PlanBox) async throws {
        let plan = box.plan
        switch plan.kind {
        case .file, .dash:
            for index in plan.files.indices { try await fetch(file: index, box: box) }
        case .hls:
            // Segments are small and independent, so the same lane count that fetches ranges works here;
            // each one still arrives in one request because a segment is its own file.
            let pending = plan.parts.filter { !FileManager.default.fileExists(atPath: folder.appending(path: $0.name).path) }
            let queue = WorkQueue(pending)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<min(tuning.value.connections, pending.count) {
                    group.addTask {
                        while let part = queue.next() {
                            try Task.checkCancellation()
                            var (data, _) = try await get([part.url], headers: plan.headers, range: part.range)
                            if part.transportStream { data = MediaPayload.transportStream(data) }
                            let target = folder.appending(path: part.name)
                            try Self.writing { try data.write(to: target, options: .atomic) }
                            meter.finishedPart()
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    /// Fetches one file with several Range requests at once.
    ///
    /// This is the whole acceleration: the speed of one download is not the speed of one socket, it is
    /// the sum of `connections` sockets. Every packet is written the moment it lands, at its own offset,
    /// with `pwrite` — no shared file pointer, no lock, no full-chunk buffers. A lane that runs dry takes
    /// half of the largest range still in flight, which is what keeps the tail of the file at full speed
    /// instead of finishing on whichever socket happened to be slowest.
    private func fetch(file index: Int, box: PlanBox) async throws {
        let file = box.plan.files[index], headers = box.plan.headers
        let target = folder.appending(path: "parts").appending(path: file.name)
        guard file.ranged, let length = file.length, length > 0 else {
            // No ranges: one request, appended as it arrives, and it starts over if stopped.
            try? FileManager.default.removeItem(at: target)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let writer = try FileWriter(target)
            let before = meter.received
            do {
                _ = try await get(file.urls, headers: headers, sink: { data in try writer.append(data) })
            } catch {
                meter.add(before - meter.received)
                throw error
            }
            try writer.close()
            box.markWhole(index)
            meter.finishedPart()
            return
        }
        if !FileManager.default.fileExists(atPath: target.path) {
            // A fresh file: earlier spans would point at bytes that are not there.
            box.reset(index)
        }
        let sink = try PositionalFile(target)
        defer { sink.closeHandle() }
        // Preallocate before the ranges land: contiguous blocks, and a rename that costs nothing.
        try sink.reserve(length)

        let already = box.plan.files[index].finished
        let queue = RangeQueue(length: length, chunk: file.chunk, skip: already.map { Int64($0.start)..<Int64($0.end) })
        // One lane per pending range, capped by the connection count. A single-lane server still gets one.
        let lanes = min(tuning.value.connections, max(1, queue.depth))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<lanes {
                group.addTask {
                    speed.laneOpened()
                    defer { speed.laneClosed() }
                    try await self.pump(lane: lane, index: index, length: length, queue: queue, box: box, sink: sink, headers: headers)
                }
            }
            try await group.waitForAll()
        }
        sink.flush()
        box.saveNow()
        // Nothing is renamed until every byte is on disk: a half file that plays would be worse than
        // a download that says it failed. Two exemptions, both about servers that cannot be measured
        // byte by byte: an unranged file has already returned above (one stream, no spans), and a
        // file whose length the server never told us cannot be proved complete by arithmetic — the
        // only honest test for it is the byte count the request reported, checked by the caller.
        if box.plan.files[index].ranged, box.plan.files[index].length ?? 0 > 0 {
            guard box.plan.files[index].complete() else { throw TransferError.incomplete }
        }
    }

    /// One lane: take a range, stream it to its offsets, and when the queue is empty steal half of the
    /// largest range still in flight rather than idling.
    private func pump(lane: Int, index: Int, length: Int64, queue: RangeQueue, box: PlanBox,
                      sink: PositionalFile, headers: [String: String]) async throws {
        while true {
            try Task.checkCancellation()
            guard let range = queue.take(lane: lane) else {
                // Nothing queued: split the biggest range still running, or stop this lane.
                guard queue.split(avoid: lane) else { return }
                continue
            }
            let cursor = LaneCursor(range.lowerBound)
            // One retry owner, not two.
            //
            // This used to hold its own attempt loop *and* call `get`, which retries three times per
            // mirror: a server that answered 503 twice had the same range requested four times for one
            // megabyte, measured. `get` already covers mirrors and transient failures, so the lane's job
            // is only to ask again when `get` came back having delivered less than the range — a
            // condition `get` cannot see, because it finishes when the connection finishes.
            var shortfalls = 0
            var attempt = 0
            while cursor.value < range.upperBound {
                do {
                    let urls = box.plan.files[index].urls
                    let start = cursor.value
                    _ = try await get(urls, headers: headers, range: start...(range.upperBound - 1), counts: true, sink: { data in
                        // Written where it belongs the moment it arrives: no chunk-sized buffer is held
                        // while the rest of the range downloads.
                        // Clamped to this lane's range. A server that answers with more than asked
                        // (a proxy that ignores the end of the Range, a mirror that serves the whole
                        // file) would otherwise run the cursor past `range.upperBound` and write over
                        // the bytes the neighbouring lane is delivering — two lanes, one region, and a
                        // file that plays as corruption with no error anywhere.
                        let room = range.upperBound - cursor.value
                        let slice = data.count > room ? data.prefix(Int(room)) : data
                        try sink.write(slice, at: cursor.value)
                        cursor.advance(by: Int64(slice.count))
                        // A split from here on starts where this lane actually got to.
                        queue.progress(lane: lane, reached: cursor.value)
                    })
                } catch is CancellationError {
                    queue.finish(lane: lane)
                    throw CancellationError()
                } catch {
                    // The lane retries too, and it must: \`get\` gives a mirror three attempts, so a server
                    // that answers 503 four times straight is already past its budget by the time the
                    // error surfaces here. Dropping this loop made exactly that case fail — measured, a
                    // five-503 server went from "recovers in 12 s" to "always fails". What it does not do
                    // is retry blindly: the budget is small and the wait grows, so the common case (\`get\`
                    // handled it) never reaches this line.
                    guard Self.worthRetrying(error), attempt < 2, cursor.value < range.upperBound else {
                        queue.finish(lane: lane)
                        throw error
                    }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(800 * attempt))
                    continue
                }
                // A connection can end cleanly without delivering the whole range (a proxy closing
                // mid-body, a mirror that truncates). \`get\` cannot see that — it finishes when the
                // connection finishes — so the lane checks and asks again from where it stopped. Each
                // byte is still written exactly once, because the request starts at the cursor.
                if cursor.value < range.upperBound {
                    shortfalls += 1
                    guard shortfalls <= 2 else {
                        queue.finish(lane: lane)
                        throw TransferError.incomplete
                    }
                }
            }
            // One span per delivered range, merged into the plan and written to disk every few seconds.
            box.merge(index, span: ByteSpan(start: range.lowerBound, end: range.upperBound))
            meter.finishedPart()
            queue.finish(lane: lane)
        }
    }

    /// A dropped connection or a 5xx is worth another run at the same offsets; a 403 or a lost range support is not.
    static func worthRetrying(_ error: Error) -> Bool {
        if let transfer = error as? TransferError { return transfer.retriable }
        if error is CancellationError { return false }
        if let url = error as? URLError {
            return [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse].contains(url.code)
        }
        return error is POSIXError || (error as NSError).domain == NSPOSIXErrorDomain
    }

    /// Fetches one address (trying mirrors, retrying network failures with a pause) into memory, or into `sink`.
    /// Throws `expired` only when every mirror refused, since renewing the link is then the way on.
    func get(_ urls: [URL], headers: [String: String], range: ClosedRange<Int64>? = nil, limit: Int? = nil,
             counts: Bool = true, sink: (@Sendable (Data) throws -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        var failure: Error = TransferError.http(0)
        // Mirrors first, attempts second.
        //
        // The loops used to be the other way round: attempt 1 tried mirror A, B, C; attempt 2 tried A
        // again. With three attempts and one mirror that is three requests; with three mirrors the
        // first attempt already walks all three, so the repeat buys nothing and costs a full round of
        // duplicates. Swapping the order means the retry round runs only when every mirror has already
        // failed once, which is exactly when waiting is the right move.
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2 * attempt)) }
            var refused = 0
            for url in urls {
                do { return try await once(url, headers: headers, range: range, limit: limit, counts: counts, sink: sink) }
                catch let error as TransferError {
                    failure = error
                    if case .expired = error { refused += 1; continue }
                    // [mi3s] 二开：`.incomplete` 不重试 —— 流式 body 已写了半份，重试会写第二遍损坏文件
                    // A streamed body is appended to the file as it arrives. `.incomplete` means part
                    // of it is already on disk, so retrying here would write the whole file a second
                    // time and corrupt it. Fail and let the download start over cleanly.
                    if sink != nil, case .incomplete = error { throw error }
                    if !error.retriable { throw error }
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                     .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse].contains(error.code) {
                    failure = error
                    // A mid-stream network drop leaves a partial streamed file; retrying would append
                    // a second copy rather than resume. Fail and start the request over.
                    if sink != nil { throw error }
                } catch { throw error }
            }
            if refused == urls.count { throw failure }
        }
        throw failure
    }

    private func once(_ url: URL, headers: [String: String], range: ClosedRange<Int64>?, limit: Int?, counts: Bool,
                      sink: (@Sendable (Data) throws -> Void)?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        let collector = Collector(limit: limit)
        let meter = counts ? meter : nil
        let receiver = Receiver(accept: { response in
            switch response.statusCode {
            case 206: nil
            // A probe accepts the whole file; a range request answered with it can't be resumed from there.
            case 200..<300: range == nil || limit != nil ? nil : TransferError.rangeLost
            case 401, 403, 404, 410: TransferError.expired(response.statusCode)
            default: TransferError.http(response.statusCode)
            }
        }, sink: { data in
            if let sink { try sink(data) } else { collector.append(data) }
            meter?.add(Int64(data.count)); collector.count(data.count)
            return !collector.full
        })
        do {
            let response = try await receiver.run(session.dataTask(with: request))
            return (collector.data, response)
        } catch {
            meter?.add(-collector.received)
            throw error
        }
    }

    // MARK: Finishing

    private func finish(_ plan: TransferPlan) async throws -> String {
        let parts = folder.appending(path: "parts")
        switch plan.kind {
        case .file:
            if let name = finishedFile(plan) {
                try? FileManager.default.removeItem(at: parts)
                return await DownloadLibrary.rewrap(name, in: folder)
            }
            let name = "media." + (plan.fileExtension ?? "mp4")
            try? FileManager.default.removeItem(at: folder.appending(path: name))
            try FileManager.default.moveItem(at: parts.appending(path: plan.files[0].name), to: folder.appending(path: name))
            try? FileManager.default.removeItem(at: parts)
            return await DownloadLibrary.rewrap(name, in: folder)
        case .hls:
            try Self.writing { try Data((plan.playlist ?? "").utf8).write(to: folder.appending(path: "index.m3u8"), options: .atomic) }
            return "index.m3u8"
        case .dash:
            // The halves stay as downloaded and play as HLS byte ranges, as they stream: re-muxing HEVC
            // into MP4 tags it `hev1`, which AVPlayer only plays inside HLS.
            var master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
            for (position, file) in plan.files.enumerated() {
                guard let initialization = file.initialization, let range = file.index else { throw TransferError.notMedia }
                let handle = try FileHandle(forReadingFrom: parts.appending(path: file.name))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(range.lowerBound))
                let sidx = try handle.read(upToCount: range.count) ?? Data()
                let index = try SegmentIndex(sidx: sidx, at: range.lowerBound, initialization: initialization, url: URL(string: "parts/" + file.name)!)
                let name = position == 0 ? "video.m3u8" : "audio.m3u8"
                try Self.writing { try Data(DashStreams.media(index).utf8).write(to: folder.appending(path: name), options: .atomic) }
                if position == 1 { master.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"") }
            }
            master += ["#EXT-X-STREAM-INF:" + (plan.streamInfo ?? "BANDWIDTH=1"), "video.m3u8"]
            try Self.writing { try Data((master.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "index.m3u8"), options: .atomic) }
            return "index.m3u8"
        }
    }

    // MARK: Helpers

    static func isPlaylist(_ data: Data) -> Bool {
        String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("#EXTM3U")
    }
    /// The full length from `Content-Range: bytes a-b/total`.
    static func total(_ response: HTTPURLResponse) -> Int64? {
        (response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int64($0) }
    }
    static func fileExtension(_ url: URL, mime: String, head: Data = Data()) -> String {
        // The first bytes win over the name: cloud drives serve 4K MP4s named .mp3 from CDN addresses without one.
        let bytes = [UInt8](head.prefix(12))
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return bytes[8...11] == [0x71, 0x74, 0x20, 0x20] ? "mov" : "mp4" }
        if bytes.count >= 4, bytes[0...3] == [0x1A, 0x45, 0xDF, 0xA3] { return "mkv" }
        // Songs: music hosts often serve FLAC and MP3 from addresses without an extension.
        if bytes.count >= 4, bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] { return "flac" }
        if bytes.count >= 3, bytes[0...2] == [0x49, 0x44, 0x33] { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "aac" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "mp3" }
        let known = ["mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "mp3", "m4a", "aac", "flac"]
        let named = url.pathExtension.lowercased()
        if known.contains(named) { return named }
        switch mime {
        case "video/x-matroska": return "mkv"
        case "video/webm": return "webm"
        case "video/mp2t": return "ts"
        case "video/x-flv": return "flv"
        case "audio/mpeg": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        default: return "mp4"
        }
    }
    /// Turns a full disk into a clear message.
    static func writing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
                throw TransferError.noSpace(needed: 0, available: DownloadLibrary.availableCapacity(at: URL.temporaryDirectory) ?? 0)
            }
            throw error
        }
    }
}

/// HLS playlists: picking a variant, and rewriting a media playlist to local files.
enum HLS {
    struct Variant { let bandwidth: Int; let height: Int?; let url: URL }

    static func variants(_ text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pending: [String: String]?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))) }
            else if let fields = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    let height = fields["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) }
                    result.append(Variant(bandwidth: Int(fields["BANDWIDTH"] ?? "") ?? 0, height: height, url: url))
                }
                pending = nil
            }
        }
        return result
    }

    /// The playlist with every key, initialization section and segment pointed at a file under `parts/`,
    /// and those files' remote addresses. Byte ranges become whole files.
    static func localize(_ text: String, base: URL) throws -> (playlist: String, parts: [TransferPlan.Part]) {
        guard text.contains("#EXT-X-ENDLIST") else { throw TransferError.live }
        var lines: [String] = [], parts: [TransferPlan.Part] = []
        var named: [String: String] = [:]
        var pendingRange: (length: Int64, offset: Int64?)?
        var ends: [URL: Int64] = [:]
        var segments = 0
        func resolve(_ value: String) throws -> URL {
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TransferError.protected }
            return url
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-KEY:") {
                let fields = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                guard let method = fields["METHOD"], method != "NONE" else { lines.append(line); continue }
                // AES-128 keys are plain files; SAMPLE-AES and FairPlay need a key server at play time.
                guard method == "AES-128", let uri = fields["URI"] else { throw TransferError.protected }
                let url = try resolve(uri)
                let name = named[url.absoluteString] ?? {
                    let name = "parts/key-\(named.count).key"
                    parts.append(.init(url: url, range: nil, name: name, transportStream: false))
                    return name
                }()
                named[url.absoluteString] = name
                lines.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(name)\""))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let fields = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = fields["URI"] else { continue }
                let url = try resolve(uri)
                let range = fields["BYTERANGE"].flatMap(byteRange).map { value -> ClosedRange<Int64> in
                    let start = value.offset ?? 0
                    return start...start + value.length - 1
                }
                let key = url.absoluteString + (range.map { "#\($0)" } ?? "")
                let name = named[key] ?? {
                    let name = "parts/init-\(named.count).\(segmentExtension(url, fallback: "mp4"))"
                    parts.append(.init(url: url, range: range, name: name, transportStream: false))
                    return name
                }()
                named[key] = name
                lines.append("#EXT-X-MAP:URI=\"\(name)\"")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#") {
                lines.append(line)
            } else {
                let url = try resolve(line)
                var range: ClosedRange<Int64>?
                if let pending = pendingRange {
                    let start = pending.offset ?? ends[url] ?? 0
                    range = start...start + pending.length - 1
                    ends[url] = start + pending.length
                }
                pendingRange = nil
                let fileExtension = segmentExtension(url, fallback: "ts")
                let name = String(format: "parts/%05d.", segments) + fileExtension
                segments += 1
                parts.append(.init(url: url, range: range, name: name, transportStream: fileExtension == "ts"))
                lines.append(name)
            }
        }
        guard segments > 0 else { throw TransferError.notMedia }
        return (lines.joined(separator: "\n") + "\n", parts)
    }

    /// Segment files keep a real media extension; disguised ones (.png, .jpg, none) are MPEG-TS.
    private static func segmentExtension(_ url: URL, fallback: String) -> String {
        let value = url.pathExtension.lowercased()
        return ["ts", "m4s", "mp4", "m4a", "m4v", "aac", "mp3", "cmfv", "cmfa", "vtt", "webvtt"].contains(value) ? value : fallback
    }
    /// `length[@offset]`, from EXT-X-BYTERANGE or a BYTERANGE attribute.
    private static func byteRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let fields = text.split(separator: "@")
        guard let length = fields.first.flatMap({ Int64($0) }), length > 0 else { return nil }
        return (length, fields.count > 1 ? Int64(fields[1]) : nil)
    }
    /// An attribute list (`KEY=value,KEY="quoted, value"`).
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: /([A-Z0-9-]+)=("[^"]*"|[^,]*)/) {
            var value = String(match.2)
            if value.hasPrefix("\"") { value = String(value.dropFirst().dropLast()) }
            result[String(match.1)] = value
        }
        return result
    }
}

/// Byte and piece counts for one running download, read by the library once a second.
final class DownloadMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0, parts = 0, total = 0, expectedBytes: Int64?
    var received: Int64 { lock.withLock { bytes } }
    var snapshot: (received: Int64, parts: Int, total: Int, expected: Int64?) { lock.withLock { (bytes, parts, total, expectedBytes) } }
    func add(_ count: Int64) { lock.withLock { bytes += count } }
    func finishedPart() { lock.withLock { parts += 1 } }
    func reset(received: Int64, parts: Int, total: Int, expected: Int64?) {
        lock.withLock { bytes = received; self.parts = parts; self.total = total; expectedBytes = expected }
    }
}

/// One lane's read cursor into its range, advanced inside the packet sink and read by the retry loop.
/// A reference type because the sink runs on the session's delegate queue, not on this task.
final class LaneCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var position: Int64
    init(_ start: Int64) { position = start }
    var value: Int64 { lock.withLock { position } }
    func advance(by count: Int64) { lock.withLock { position += count } }
}

/// The plan with finished ranges marked as they land, written to disk every few seconds.
final class PlanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TransferPlan
    private let file: URL
    private var saved = Date()
    init(_ plan: TransferPlan, file: URL) { value = plan; self.file = file }
    var plan: TransferPlan { lock.withLock { value } }
    /// Records a delivered range. Written to disk at most every few seconds: one fsync per range would
    /// cost more than the download.
    func merge(_ file: Int, span: ByteSpan) {
        let snapshot: TransferPlan? = lock.withLock {
            value.files[file].merge(span)
            guard Date().timeIntervalSince(saved) > 3 else { return nil }
            saved = Date()
            return value
        }
        if let snapshot { try? JSONEncoder().encode(snapshot).write(to: self.file, options: .atomic) }
    }
    /// The whole file is in place; the marks must be on disk before it is renamed, or a crash between
    /// the two would leave a finished-looking file the plan calls unfinished.
    func saveNow() {
        let snapshot = lock.withLock { saved = Date(); return value }
        try? JSONEncoder().encode(snapshot).write(to: self.file, options: .atomic)
    }
    func markWhole(_ file: Int) {
        lock.withLock {
            guard let length = value.files[file].length else { return }
            value.files[file].spans = [ByteSpan(start: 0, end: length)]
            value.files[file].done = []
        }
    }
    func reset(_ file: Int) { lock.withLock { value.files[file].spans = []; value.files[file].done = [] } }
}

final class WorkQueue<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item]
    private var position = 0
    init(_ items: [Item]) { self.items = items }
    func next() -> Item? {
        lock.withLock {
            guard position < items.count else { return nil }
            defer { position += 1 }
            return items[position]
        }
    }
}

/// Writes ranges into one file from several connections.
final class FileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init(_ url: URL) throws { handle = try FileHandle(forWritingTo: url) }
    func truncate(_ length: Int64) throws {
        try lock.withLock {
            if try handle.seekToEnd() != UInt64(length) { try handle.truncate(atOffset: UInt64(length)) }
        }
    }
    func write(_ data: Data, at offset: UInt64) throws {
        try Transfer.writing { try lock.withLock { try handle.seek(toOffset: offset); try handle.write(contentsOf: data) } }
    }
    func append(_ data: Data) throws {
        try Transfer.writing { try lock.withLock { try handle.seekToEnd(); try handle.write(contentsOf: data) } }
    }
    func close() throws { try lock.withLock { try handle.close() } }
}

/// A response body gathered in memory, up to an optional limit.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var counted: Int64 = 0
    private let limit: Int?
    init(limit: Int?) { self.limit = limit }
    var data: Data { lock.withLock { limit.map { Data(buffer.prefix($0)) } ?? buffer } }
    var received: Int64 { lock.withLock { counted } }
    var full: Bool { lock.withLock { limit.map { buffer.count >= $0 } ?? false } }
    func append(_ data: Data) { lock.withLock { buffer.append(data) } }
    func count(_ bytes: Int) { lock.withLock { counted += Int64(bytes) } }
}

/// Runs one data task, handing its body to `sink` as it arrives (progress counts every packet,
/// not whole responses). `sink` returns false to stop early with what it has.
final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let accept: @Sendable (HTTPURLResponse) -> Error?
    private let sink: @Sendable (Data) throws -> Bool
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var stoppedEarly = false
    init(accept: @escaping @Sendable (HTTPURLResponse) -> Error?, sink: @escaping @Sendable (Data) throws -> Bool) {
        self.accept = accept; self.sink = sink
    }

    func run(_ task: URLSessionDataTask) async throws -> HTTPURLResponse {
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { failure = TransferError.http(0) }; completionHandler(.cancel); return
        }
        let refusal = accept(http)
        lock.withLock { self.response = http; failure = refusal }
        completionHandler(refusal == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            if try !sink(data) { lock.withLock { stoppedEarly = true }; dataTask.cancel() }
        } catch {
            lock.withLock { failure = error }; dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, response, failure, early) = lock.withLock { () -> (CheckedContinuation<HTTPURLResponse, Error>?, HTTPURLResponse?, Error?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, self.response, self.failure, stoppedEarly)
        }
        if early, let response { continuation?.resume(returning: response) }
        else if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if let response {
            let expected = response.expectedContentLength
            // Compressed bodies arrive decoded, so only plain ones can be checked against their length.
            if response.value(forHTTPHeaderField: "Content-Encoding") == nil, expected > 0, task.countOfBytesReceived < expected { continuation?.resume(throwing: TransferError.incomplete) }
            else { continuation?.resume(returning: response) }
        } else { continuation?.resume(throwing: TransferError.http(0)) }
    }
}
