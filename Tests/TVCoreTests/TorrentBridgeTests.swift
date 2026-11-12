import Foundation
import Testing
@testable import TVCore

/// The JSON the Node bridge answers with, as `POST /add` sends it.
private let answer = """
{"infoHash":"08ada5a7a6183aae1e09d831df6748d566095a10","name":"Sintel","fileName":"Sintel.mp4",
 "fileIndex":5,"length":129241752,"total":129302391,"direct":true,"peers":9,
 "files":[{"index":0,"name":"Sintel.en.srt","length":1514}]}
"""

@Test func theBridgeAnswerDecodes() throws {
    let torrent = try JSONDecoder().decode(TorrentBridge.Torrent.self, from: Data(answer.utf8))
    #expect(torrent.infoHash == "08ada5a7a6183aae1e09d831df6748d566095a10")
    #expect(torrent.fileName == "Sintel.mp4")
    #expect(torrent.fileIndex == 5)
    #expect(torrent.length == 129_241_752)
    #expect(torrent.direct)
    #expect(torrent.peers == 9)
    #expect(torrent.isVideo)
}

@Test func onlyMediaExtensionsCountAsVideo() throws {
    func torrent(_ name: String) throws -> TorrentBridge.Torrent {
        try JSONDecoder().decode(TorrentBridge.Torrent.self,
                                 from: Data(#"{"infoHash":"h","name":"n","fileName":"\#(name)","fileIndex":0,"length":1,"total":1,"direct":false,"peers":0}"#.utf8))
    }
    #expect(try torrent("Show.S01E02.1080p.mkv").isVideo)
    #expect(try torrent("Movie.MP4").isVideo)
    #expect(try torrent("Readme.txt").isVideo == false)
    #expect(try torrent("cover.jpg").isVideo == false)
}

/// The bridge ships in the script assets; a build that drops it cannot join a swarm at all.
@Test func theBridgeScriptShipsWithTheApp() throws {
    let root = try #require(ScriptAssets.root)
    let script = root.appendingPathComponent("torrent/bridge.mjs")
    let bundle = root.appendingPathComponent("torrent/webtorrent.bundle.mjs")
    #expect(FileManager.default.fileExists(atPath: script.path))
    #expect(FileManager.default.fileExists(atPath: bundle.path))
    let text = try String(contentsOf: script, encoding: .utf8)
    // The endpoints the Swift side calls by name.
    for endpoint in ["/add", "/stream/", "/read/", "/stat/", "/health"] {
        #expect(text.contains(endpoint), "bridge.mjs lost \(endpoint)")
    }
    let library = try String(contentsOf: bundle, encoding: .utf8)
    #expect(library.contains("WebTorrent"))
}
