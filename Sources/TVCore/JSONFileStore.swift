import Foundation

/// A single JSON file persisted outside `UserDefaults`, with the app's shared conventions:
/// a bounded, forgiving read and a silent, atomic write. Callers keep their own fallback
/// values (`[]`, `Self()`, `[:]`) and any post-processing (sorting, filtering), so the
/// storage path and JSON format stay exactly as they were.
public struct JSONFileStore<T: Codable> {
    /// Where the JSON lives.
    public let file: URL
    /// The largest file read back. A larger one is treated as missing, so a corrupted or
    /// bloated save can never exhaust memory. Nil reads any size.
    public let maxBytes: Int?

    public init(file: URL, maxBytes: Int? = nil) {
        self.file = file
        self.maxBytes = maxBytes
    }

    /// The saved value, or nil when the file is missing, over `maxBytes`, or not valid JSON for `T`.
    public func load() -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let maxBytes, data.count > maxBytes { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Encodes and writes atomically, creating the folder first. Returns the error's description
    /// on failure, nil on success; most callers discard it, so a write failure stays silent.
    @discardableResult
    public func save(_ value: T) -> String? {
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
