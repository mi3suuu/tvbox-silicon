import Foundation

// MARK: - What a sweep should measure

/// Which sources a sweep visits, and what it may skip because a recent reading is still good.
///
/// The old sweep re-probed every source every time, which on a 400-source library is minutes of
/// traffic to learn what it already knew. A plan makes the choice explicit: the caller says which
/// sources it is looking at (a group, a filter, the whole list) and how old a reading may be before
/// it counts as stale, and the plan returns the work to do.
public struct SourceProbePlan: Sendable {
    /// One source to probe, with the key its reading is filed under.
    public struct Entry: Sendable, Hashable {
        public let sourceKey: String
        public let name: String
        /// The API address the probe hits, already routed.
        public let url: URL
        public let headers: [String: String]
    }

    public enum Reason: String, Sendable {
        /// Nothing measured yet.
        case neverMeasured
        /// The last reading is older than the plan's tolerance.
        case stale
        /// The caller asked for this one by name.
        case requested
    }

    /// Sources to probe, with why each is in the list.
    public var work: [(entry: Entry, reason: Reason)] = []
    /// Sources left alone, and how long ago they were measured: the page says "12 skipped, measured
    /// 3 minutes ago" rather than silently doing less than the button promises.
    public var skipped: Int = 0
    /// The oldest reading among the skipped ones, for the same line.
    public var oldestSkipped: Date?

    public init() {}

    public var isEmpty: Bool { work.isEmpty }
}
