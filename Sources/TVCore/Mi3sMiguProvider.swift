import Foundation

// [mi3s] 二开：Migu 的取流实现。原在上游 `MusicMiguKuwo.swift` 内，
// 上游按「App 不持有任何服务自己的逻辑」把 provider 实现整体移除后，
// 曲库（`MiguMusicCatalog` / `KuwoMusicCatalog`）仍在上游文件里，取流实现搬到这里。
//
// 复核方式：上游若重新引入 provider，优先用上游；确认无等价后保留本文件。

public struct MiguProvider: MusicStreamProvider {
    public let id = MusicProviderID.migu
    public let platforms: Set<MusicPlatform> = [.migu]
    let transport: MusicTransport
    static let timeout: TimeInterval = 8
    static let checkTimeout: TimeInterval = 4
    /// The key the web player's answers are scrambled with.
    static let key = Array("Jk8qzuePiJ1qE3mDYhLQ3T73DtDoAhLP".utf8)
    /// Path and extension of each tier, best first; the answer is always the last.
    static let tiers: [(name: String, path: String, ext: String)] = [
        ("SQ", "歌曲下载/flac", ".flac"), ("HQ", "标清高清/MP3_320_16_Stero", ".mp3"), ("PQ", "标清高清/MP3_128_16_Stero", ".mp3"),
    ]
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        guard let ids = MiguMusicCatalog.ids(songID) else { throw MusicProviderError.noResource }
        let url = MusicHTTP.url("https://c.musicapp.migu.cn/strategy/listen-url/h5/v2.4", [
            ("contentId", ids.content), ("copyrightId", ids.copyright), ("resourceType", "2"), ("netType", "01"),
            ("toneFlag", "PQ"), ("scene", ""), ("lowerQualityContentId", ids.content),
        ])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: [
            "birth": "h5page", "channel": "014X031", "Referer": "https://y.migu.cn/", "location-data": "30.6698676660,104.1229614820",
        ])
        let response = try await MusicHTTP.withTimeout(Self.timeout) { try await transport.send(request, limit: MusicHTTP.jsonLimit) }
        guard (200..<300).contains(response.status) else { throw MusicProviderError.invalidResponse("Migu HTTP \(response.status)") }
        let base = try Self.address(Self.unscramble(response.body))
        // The answer is always PQ; the tiers above it are sibling paths, each confirmed first.
        for tier in Self.tiers(for: quality) {
            guard let better = Self.retone(base, to: tier.name), await exists(better) else { continue }
            return ResolvedMusicStream(url: better, claimedQuality: tier.name, upstream: "migu")
        }
        return ResolvedMusicStream(url: base, claimedQuality: "PQ", upstream: "migu")
    }

    /// The tiers above PQ to try: lossless falls back to 320 kbps, High asks for 320 kbps, and
    /// Standard keeps the 128 kbps answer.
    static func tiers(for quality: MusicAudioQuality) -> [(name: String, path: String, ext: String)] {
        switch quality {
        case .lossless: Array(tiers.dropLast())
        case .high: [tiers[1]]
        case .standard: []
        }
    }

    private func exists(_ url: URL) async -> Bool {
        var head = MusicHTTP.request(url, timeout: Self.checkTimeout)
        head.httpMethod = "HEAD"
        let request = head
        let response = try? await MusicHTTP.withTimeout(Self.checkTimeout) { try await transport.send(request, limit: 0) }
        return response.map { (200..<400).contains($0.status) } ?? false
    }

    /// The web player's answer: "AB CD 01", an offset byte, then JSON with each byte shifted by
    /// the offset less a key byte.
    static func unscramble(_ data: Data) throws -> JSONValue {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xAB, bytes[1] == 0xCD, bytes[2] == 0x01 else {
            throw MusicProviderError.invalidResponse("Migu answer format")
        }
        let offset = Int(bytes[3])
        let plain = bytes.dropFirst(4).enumerated().map { index, byte in
            UInt8((Int(byte) + offset - Int(key[index % key.count]) + 512) % 256)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(plain)) else {
            throw MusicProviderError.invalidResponse("Migu answer not JSON")
        }
        return json
    }

    static func address(_ json: JSONValue) throws -> URL {
        guard json["code"]?.string == "000000" else {
            // A song Migu holds no rights to here answers with a message instead of an address.
            throw MusicProviderError.noResource
        }
        guard var text = json[path: "data", "url"]?.string ?? json[path: "data", "playUrl"]?.string, !text.isEmpty else {
            throw MusicProviderError.noResource
        }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text.replacingOccurrences(of: "+", with: "%2B")), url.host() != nil else {
            throw MusicProviderError.noResource
        }
        return url
    }

    /// The address of another tier of the same file: the tier's folder and extension, without the
    /// 128 kbps answer's signature, which the other tiers do not need.
    static func retone(_ url: URL, to name: String) -> URL? {
        guard let source = tiers.last, let target = tiers.first(where: { $0.name == name }),
              let sourcePath = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let targetPath = target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let bare = url.absoluteString.components(separatedBy: "?")[0]
        guard bare.contains(sourcePath), bare.hasSuffix(source.ext) else { return nil }
        return URL(string: String(bare.replacingOccurrences(of: sourcePath, with: targetPath).dropLast(source.ext.count)) + target.ext)
    }
}
