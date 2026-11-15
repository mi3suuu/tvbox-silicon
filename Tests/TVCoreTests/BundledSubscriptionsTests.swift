import Foundation
import Testing
@testable import TVCore

/// A feed the app carries itself must answer without a host: no DNS, no refresh error, and the
/// plugin it names has to be the one bundled in `ScriptAssets`.
@Test func bundledKanjuNeedsNoAddress() throws {
    let document = try #require(BundledSubscriptions.document(for: BundledSubscriptions.kanjuAddress))
    #expect(document.sites.count == 3)
    #expect(document.origin.absoluteString == "builtin://kanju")
    #expect(document.lives.isEmpty)
    // Every entry runs the bundled plugin, and nothing points at a host.
    for site in document.sites {
        #expect(site.type == 3)
        #expect(site.api == "assets://js/kanju.js")
        #expect(site.raw["api"]?.string == "assets://js/kanju.js")
    }
    #expect(document.sites.map(\.key) == ["kanju_o", "kanju_4k", "kanju_s"])
    // The default spends tokens (official first); the third entry is the one that does not.
    #expect(document.sites[0].raw["ext"] == nil)
    #expect(document.sites[1].raw["ext"]?.string == #"{"prefer":"4k"}"#)
    #expect(document.sites[2].raw["ext"]?.string == #"{"prefer":"ordinary"}"#)
    // The script resolves to the bundle, not to anything relative to the pseudo-origin.
    #expect(try document.sites[0].scriptURL(origin: document.origin).absoluteString == "assets://js/kanju.js")
}

@Test func ordinaryAddressesAreNotBundled() {
    #expect(BundledSubscriptions.isBundled(BundledSubscriptions.kanjuAddress))
    #expect(BundledSubscriptions.isBundled("BUILTIN://kanju"))
    #expect(!BundledSubscriptions.isBundled("https://example.com/a.json"))
    #expect(BundledSubscriptions.document(for: "https://example.com/a.json") == nil)
    // An unknown builtin name is a miss, not a crash: the old address just shows as a failed refresh.
    #expect(BundledSubscriptions.document(for: "builtin://nothing") == nil)
}

/// The route pack rides in `ScriptAssets/builtin/route.json`; it must decode into the same groups
/// the exporter wrote, with each group keeping its own default routing and on/off state.
@Test func bundledRoutePackKeepsItsGroups() throws {
    let addresses = BundledSubscriptions.addresses
    #expect(addresses.first == BundledSubscriptions.kanjuAddress)
    #expect(addresses.count > 20)

    let direct = try #require(BundledSubscriptions.document(for: "builtin://yingxia-route-00"))
    #expect(direct.origin.absoluteString == "builtin://yingxia-route-00")
    #expect(!direct.sites.isEmpty)
    // Verdicts travel with the sources, so the source list can still show why a line is routed.
    #expect(direct.sites.contains { $0.raw["_probe"] != nil })

    let proxyEntry = try #require(BundledSubscriptions.entry(for: "builtin://yingxia-route-02"))
    #expect(proxyEntry.routing == .proxy)
    #expect(proxyEntry.name.contains("中转"))

    // The dead group ships switched off.
    let dead = try #require(BundledSubscriptions.entry(for: "builtin://yingxia-route-11"))
    #expect(dead.enabled == false)

    let total = addresses.compactMap { BundledSubscriptions.document(for: $0) }
        .reduce(0) { $0 + $1.sites.count + $1.lives.count }
    #expect(total > 900)
}

/// The pack that ships to users says `builtin://kanju`, so importing it lands on the same entry the
/// fresh-install seed uses instead of creating a second, unreachable one.
@Test func kanjuConfigUsesTheBundledAddress() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TVCore/ScriptAssets/js/kanju.js")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(BundledSubscriptions.kanju().sites.count == 3)
}
