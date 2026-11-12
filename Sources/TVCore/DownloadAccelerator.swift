import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Tuning

/// How a download splits and fetches its bytes.
///
/// Three knobs, the same three One exposes (downloadConnections / downloadChunkMB / downloadParallel):
/// how many HTTP Range requests run at once *inside one file*, how big each Range is, and how many
/// downloads run at once. Total simultaneous sockets = connections x parallel.
public struct DownloadTuning: Sendable, Equatable {
    /// Range requests in flight per file. Per-connection throttling on CDNs is why this is more than one:
    /// a single socket rarely gets more than a few Mbit, while eight sockets saturate the same link.
    public var connections: Int
    /// Bytes per Range request, in MB. Too small wastes round trips; too large leaves one slow socket
    /// holding the tail. 4 MB is the sweet spot for 100 Mbit and above.
    public var chunkMB: Int
    /// Files downloaded at once.
    public var parallel: Int

    public static let standard = DownloadTuning(connections: 8, chunkMB: 4, parallel: 2)

    public init(connections: Int, chunkMB: Int, parallel: Int) {
        self.connections = min(max(connections, 1), 16)
        self.chunkMB = min(max(chunkMB, 1), 32)
        self.parallel = min(max(parallel, 1), 8)
    }

    public var chunk: Int64 { Int64(chunkMB) << 20 }
    /// Sockets this opens across the whole queue.
    public var sockets: Int { connections * parallel }
}

/// The live tuning, readable from the transfer's lane tasks.
/// A reference type so a knob turned mid-download reaches the next range instead of waiting for the
/// next download: raise the connection count and the file in flight opens more lanes immediately.
final class TuningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DownloadTuning
    init(_ tuning: DownloadTuning) { stored = tuning }
    var value: DownloadTuning {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The three settings, persisted under the same key names One uses, so a backup from either reads in the other.
@MainActor @Observable public final class DownloadSettings {
    public static let shared = DownloadSettings()

    public private(set) var tuning: DownloadTuning
    @ObservationIgnored private let defaults: UserDefaults
    /// Called when a knob changes so running downloads can widen or narrow without a restart.
    @ObservationIgnored public var onTuning: (@MainActor (DownloadTuning) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = DownloadTuning(
            connections: defaults.object(forKey: "downloadConnections") as? Int ?? DownloadTuning.standard.connections,
            chunkMB: defaults.object(forKey: "downloadChunkMB") as? Int ?? DownloadTuning.standard.chunkMB,
            // The key this app used before the queue had more than one knob.
            parallel: defaults.object(forKey: "downloadParallel") as? Int
                ?? (defaults.integer(forKey: "downloadsSimultaneous") > 0 ? defaults.integer(forKey: "downloadsSimultaneous") : DownloadTuning.standard.parallel))
        tuning = stored
        if defaults.object(forKey: "downloadConnections") == nil { write(stored) }
    }

    public func set(connections: Int? = nil, chunkMB: Int? = nil, parallel: Int? = nil) {
        let next = DownloadTuning(connections: connections ?? tuning.connections,
                                  chunkMB: chunkMB ?? tuning.chunkMB,
                                  parallel: parallel ?? tuning.parallel)
        guard next != tuning else { return }
        tuning = next
        write(next)
        onTuning?(next)
    }

    private func write(_ value: DownloadTuning) {
        defaults.set(value.connections, forKey: "downloadConnections")
        defaults.set(value.chunkMB, forKey: "downloadChunkMB")
        defaults.set(value.parallel, forKey: "downloadParallel")
        // Kept for the page that still reads it.
        defaults.set(value.parallel, forKey: "downloadsSimultaneous")
    }

    // MARK: - 下载时保持屏幕常亮

    /// 有任务在跑时不自动锁屏。
    ///
    /// One 的同名开关（`keepScreenAwake`，与三个连接参数并排在下载设置里）。
    /// One 的理由写在文案里：「下载时请让 App 留在前台：退到后台，系统只给很短的时间；
    /// 进度会保存，回来自动继续」。锁屏比切后台更快掐断传输，所以这个开关是**必要条件**
    /// 而不是可选优化。
    ///
    /// 键名与 One 一致（`keepScreenAwake`），备份互读。
    /// 默认 **true**：用户点下载就是为了下完，静默失败才是坏默认。
    public var keepScreenAwake: Bool {
        get {
            defaults.object(forKey: "keepScreenAwake") as? Bool ?? true
        }
        set {
            guard newValue != keepScreenAwake else { return }
            defaults.set(newValue, forKey: "keepScreenAwake")
            onKeepAwakeChange?(newValue)
        }
    }

    /// 开关变化时通知界面层（它负责真正去动 `isIdleTimerDisabled`）。
    /// `DownloadSettings` 不 import UIKit：它同时在 macOS/tvOS 上编译。
    @ObservationIgnored public var onKeepAwakeChange: (@MainActor (Bool) -> Void)?
}

// MARK: - Positional writes

/// A file written at arbitrary offsets from several sockets at once.
///
/// pwrite is one syscall that takes the offset as an argument, so lanes never share a file pointer and
/// never take a lock: N connections write N ranges of one file simultaneously. The older
/// FileHandle.seek + write pair needs the kernel\u{2019}s shared offset, which forces every lane through one
/// mutex. That serialisation - not the network - is what makes a naive multi-range downloader slower
/// than a plain single-stream one.
final class PositionalFile: @unchecked Sendable {
    let url: URL
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(_ url: URL) throws {
        self.url = url
        // 0644, create if missing, never truncate: a resumed file keeps its bytes.
        let handle = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard handle >= 0 else { throw PositionalFile.error(errno) }
        fd = handle
    }

    /// Guards against closing twice. closeHandle only marks `closed`; the descriptor itself stays
    /// set, so a deinit that checked `fd >= 0` would close a descriptor number that the kernel may
    /// already have handed to something else — the classic double-close that kills an unrelated socket.
    deinit { if !closed && fd >= 0 { _ = close(fd) } }

    /// Reserves the whole length up front. Two reasons: a full-size file makes the final rename instant
    /// (no copy), and APFS allocates contiguous blocks instead of scattering the writes, which is what
    /// keeps a 4K file from stuttering when it is played back.
    func reserve(_ length: Int64) throws {
        #if canImport(Darwin)
        if length > 0 {
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(length), fst_bytesalloc: 0)
            // Contiguous first; fall back to any allocation rather than failing the download.
            if fcntl(fd, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(fd, F_PREALLOCATE, &store)
            }
        }
        #endif
        guard ftruncate(fd, off_t(length)) == 0 else { throw PositionalFile.error(errno) }
    }

    /// Writes one packet at its offset. Safe from many threads: the offset is an argument, not state.
    func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            var position = off_t(offset)
            while remaining > 0 {
                let written = pwrite(fd, base, remaining, position)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PositionalFile.error(errno)
                }
                guard written > 0 else { throw PositionalFile.error(EIO) }
                remaining -= written
                position += off_t(written)
                base = base.advanced(by: written)
            }
        }
    }

    func truncate(_ length: Int64) throws {
        guard ftruncate(fd, off_t(length)) == 0 else { throw PositionalFile.error(errno) }
    }

    /// Flushes to the platter before the file is renamed: a download that survives a crash must survive
    /// with its bytes, not just its name.
    func flush() {
        #if canImport(Darwin)
        _ = fcntl(fd, F_FULLFSYNC)
        #endif
        _ = fsync(fd)
    }

    func closeHandle() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if fd >= 0 { _ = close(fd) }
        }
    }

    static func error(_ code: Int32) -> Error {
        // A full disk is worth its own message: it is the one failure a person can act on.
        if code == ENOSPC { return TransferError.noSpace(needed: 0, available: 0) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}

// MARK: - Ranges

/// The Range requests a file still needs, handed out one at a time.
///
/// Seeded with chunk-sized ranges but able to split: when the queue has run dry and a lane is about to
/// idle, the range with the most left is cut in half and its second half goes back into the queue. That
/// is what stops the last 10% of a file from crawling behind one throttled socket - the tail always ends
/// up spread over several connections.
final class RangeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Range<Int64>]
    private var claimed: [Int: Range<Int64>] = [:]
    private let minimum: Int64 = 1 << 20             // never split below 1 MB

    init(length: Int64, chunk: Int64, skip: [Range<Int64>] = []) {
        var ranges: [Range<Int64>] = []
        var start: Int64 = 0
        while start < length {
            let end = min(start + chunk, length)
            let range = start..<end
            let covered = skip.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
            if !covered { ranges.append(range) }
            start = end
        }
        pending = ranges
    }

    var isEmpty: Bool { lock.withLock { pending.isEmpty } }
    var depth: Int { lock.withLock { pending.count } }

    /// The next range, or nil when everything is taken.
    func take(lane: Int) -> Range<Int64>? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            let range = pending.removeFirst()
            claimed[lane] = range
            return range
        }
    }

    /// Records that a lane is part-way through its range, so a split can start where it stopped.
    func progress(lane: Int, reached offset: Int64) {
        lock.withLock {
            guard let range = claimed[lane], offset > range.lowerBound, offset < range.upperBound else { return }
            claimed[lane] = offset..<range.upperBound
        }
    }

    func finish(lane: Int) { _ = lock.withLock { claimed.removeValue(forKey: lane) } }

    /// Cuts the largest remaining range in half and puts the second half back in the queue.
    ///
    /// `avoid` is the lane asking. Without it a lane could split its own range and then take the
    /// half back, which looks like progress and is not: it re-requests bytes it already has. Splitting
    /// another lane's range is still allowed when nothing else is available, because a stolen tail is
    /// better than an idle lane.
    @discardableResult
    func split(avoid: Int) -> Bool {
        lock.withLock {
            // Strictly other lanes. An earlier version fell back to the whole pool when no other lane
            // had anything worth cutting, which handed the asker its own range back: the lane then
            // re-requested bytes it had already written, the counters advanced, and the file finished
            // having downloaded the same region twice. Re-downloading is not a slower success, it is
            // wasted bandwidth on the one metric this engine exists to improve.
            guard let largest = claimed
                .filter({ $0.key != avoid && $0.value.count > minimum * 2 })
                .max(by: { $0.value.count < $1.value.count }) else { return false }
            let range = largest.value
            let mid = range.lowerBound + Int64(range.count / 2)
            claimed[largest.key] = range.lowerBound..<mid
            pending.append(mid..<range.upperBound)
            return true
        }
    }
}

// MARK: - Speed

/// Bytes per second, smoothed, plus how many sockets are actually carrying them.
///
/// One reports DownloadSnapshot(speed:activeConnections:) beside the byte counts; the number is what makes
/// an accelerator legible - it is how you tell 8 sockets from 1.
final class SpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var lastBytes: Int64 = 0
    private var smoothed: Double = 0
    private var lanes = 0

    private var highest = 0
    /// The first reading is a baseline, not a rate. A download that resumes with 500 MB already on
    /// disk reports that 500 MB as its byte count; without this the first second divides 500 MB by
    /// one second and the row claims 500 MB/s on a 50 Mbit line. Real hardware cannot exceed the link,
    /// so a number that does is a bug in the meter, and this is where it was.
    private var primed = false

    func laneOpened() {
        lock.withLock {
            lanes += 1
            highest = max(highest, lanes)
        }
    }
    func laneClosed() { lock.withLock { lanes = max(0, lanes - 1) } }
    var activeConnections: Int { lock.withLock { lanes } }
    /// The most sockets this download ever had at once, which is what it was tuned to and what the
    /// summary should say. The live count drops to zero between ranges and after the last one.
    var peakConnections: Int { lock.withLock { highest } }
    var speed: Double { lock.withLock { smoothed } }

    /// Called about once a second by the download ticker.
    func sample(_ bytes: Int64) {
        lock.withLock {
            let now = Date(), elapsed = now.timeIntervalSince(last)
            guard primed else {
                // Baseline only: a resumed file's first count is bytes already on disk, not bytes arrived.
                primed = true; last = now; lastBytes = bytes
                return
            }
            guard elapsed > 0.2 else { return }
            let rate = max(0, Double(bytes - lastBytes) / elapsed)
            // The same 0.6/0.4 blend the queue already uses for its rows: steady enough to read,
            // quick enough to show a stall.
            smoothed = smoothed == 0 ? rate : smoothed * 0.6 + rate * 0.4
            last = now; lastBytes = bytes
        }
    }

    /// The transfer ended: no more bytes will arrive, so the row must not keep showing the rate it had.
    func settle() { lock.withLock { smoothed = 0 } }
}

