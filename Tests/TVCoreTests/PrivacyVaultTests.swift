import Foundation
import Testing
@testable import TVCore

private let one = URL(string: "https://one.example/a.json")!
private let two = URL(string: "https://two.example/b.json")!

private func source(_ key: String, origin: URL? = nil) -> Site {
    var site = Site(key: key, name: key, type: 1, api: "https://api.example/" + key, raw: ["key": .string(key)])
    if let origin { site.provenance = SourceProvenance(origin: origin, spider: nil) }
    return site
}

/// A vault with a passcode already set, for the tests that are about hiding rather than about the
/// passcode. Six digits is `PrivacyVault.minimumLength`: four was brute-forceable from a copied
/// preferences file, and the tests used to encode the old rule.
private func unlockedVault(_ passcode: String = "123456", now: Date = Date()) throws -> PrivacyVault {
    var vault = PrivacyVault(rounds: 10)
    try vault.setPasscode(passcode, now: now)
    return vault
}

/// The bug behind "turning off A also turned off B": a hide used to be recorded by source key
/// alone, and public subscriptions reuse keys constantly.
@Test func hidingASourceLeavesItsNamesakeInAnotherSubscription() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["csp_AppYsV2"], origin: one, now: now)
    // Hiding shows its effect once the vault closes: while it is open its owner sees everything.
    vault.lock()

    #expect(!vault.permits(sourceKey: "csp_AppYsV2", origin: one, now: now))
    #expect(vault.permits(sourceKey: "csp_AppYsV2", origin: two, now: now))
    #expect(vault.permits(sourceKey: "somethingElse", origin: one, now: now))
}

@Test func lockingHidesAndUnlockingBringsBack() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    #expect(vault.permits(sourceKey: "a", origin: one, now: now))

    vault.lock()
    #expect(!vault.permits(sourceKey: "a", origin: one, now: now))

    let opened = vault.unlock("123456", now: now)
    #expect(opened)
    #expect(vault.permits(sourceKey: "a", origin: one, now: now))
}

/// A hidden subscription must not take the built-in sources with it. Built-in sources carry no
/// origin, and the filter used to fall back to the merged subscription's — which is the first
/// subscription's — so hiding that one emptied the built-in group.
@Test func aHiddenSubscriptionDoesNotHideBuiltInSources() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    let builtIn = source("bilibili")
    try vault.hide(subscription: one, sourceKeys: ["a"], now: now)
    vault.lock()

    #expect(!vault.permits(site: source("a", origin: one), fallback: one, now: now))
    #expect(vault.permits(site: builtIn, fallback: one, now: now))
}

@Test func aHiddenSubscriptionHidesItsOwnSources() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(subscription: one, sourceKeys: [], now: now)
    vault.lock()
    #expect(vault.isHidden(subscription: one))
    #expect(!vault.permits(subscription: one, now: now))
    #expect(vault.permits(subscription: two, now: now))
    // Every source of that feed goes with it, through the site-level question the lists ask.
    #expect(!vault.permits(site: source("a", origin: one), fallback: one, now: now))
    #expect(vault.permits(site: source("a", origin: two), fallback: two, now: now))
}

/// Reading a switch asks "is this hidden", not "may this be seen": a locked vault would otherwise
/// draw every switch as off and look as though everything were hidden.
@Test func aSwitchReadsItsOwnPositionWhateverTheLock() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    vault.lock()

    #expect(vault.isHidden(sourceKey: "a", origin: one))
    #expect(!vault.isHidden(sourceKey: "b", origin: one))
    #expect(!vault.isHidden(sourceKey: "a", origin: two))
}

/// Builds before the identity carried an origin saved bare keys. Those still hide after the update,
/// otherwise an existing vault would silently empty itself.
@Test func bareKeysFromAnOlderVaultStillHide() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["keep"], origin: two, now: now)

    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(vault)) as? [String: Any])
    json["hiddenSources"] = (json["hiddenSources"] as? [String] ?? []) + ["legacyKey"]
    let migrated = try JSONDecoder().decode(PrivacyVault.self, from: try JSONSerialization.data(withJSONObject: json))

    var reopened = migrated
    // A decoded vault always starts locked.
    #expect(!reopened.permits(sourceKey: "legacyKey", origin: one, now: now))
    #expect(!reopened.permits(sourceKey: "keep", origin: two, now: now))
    #expect(reopened.permits(sourceKey: "keep", origin: one, now: now))

    let opened = reopened.unlock("123456", now: now)
    #expect(opened)
    #expect(reopened.permits(sourceKey: "legacyKey", origin: one, now: now))
}

/// Cached source rows compare `revision`; without a bump, hiding something would change nothing on
/// screen until the app restarted.
@Test func everyVisibilityChangeBumpsTheRevision() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    let start = vault.revision
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    #expect(vault.revision > start)
    let hidden = vault.revision
    vault.lock()
    #expect(vault.revision > hidden)
    let locked = vault.revision
    let opened = vault.unlock("123456", now: now)
    #expect(opened)
    #expect(vault.revision > locked)
}

/// Without a passcode nothing is hidden, even if a previous vault left a list behind.
@Test func withoutAPasscodeNothingIsHidden() throws {
    var vault = try unlockedVault()
    try vault.hide(sourceKeys: ["a"], origin: one)
    try vault.removePasscode()
    #expect(vault.permits(sourceKey: "a", origin: one))
    #expect(vault.permits(sourceKey: "a", origin: one))
}

/// The Sources page filters through this: a hidden source's history row and favourite go with it.
@Test func historyAndFavouritesFollowTheSourceIdentity() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    vault.lock()

    let context = PlaybackHistoryContext(origin: one, sourceKey: "a", sourceName: "A", videoID: "1", videoName: "V",
                                         episodeID: "e", episodeName: "E", episodeFlag: "line")
    #expect(!vault.permits(PlaybackHistoryEntry(context: context, position: 1, duration: 2, updatedAt: now), now: now))
    #expect(vault.visibleHistory([PlaybackHistoryEntry(context: context, position: 1, duration: 2, updatedAt: now)], now: now).isEmpty)
}

/// The download list and its "More" count share one choke point, so a hidden source's downloads
/// cannot leak through either, and a download saved before its source carried an origin stays
/// visible — the vault can only hide what it can name.
@Test func downloadsFollowTheSourceIdentity() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    vault.lock()

    func download(_ key: String, origin: URL?) -> DownloadItem {
        let site = source(key, origin: origin)
        let src = DownloadSource(site: site, videoID: "v", episode: Episode(id: "e", name: "E", address: "x", flag: "line"))
        return DownloadItem(id: key, title: key, episode: "E", poster: nil, posterHeaders: [:], source: src,
                            created: now, status: .completed, failure: nil, kind: nil, quality: nil)
    }

    let hidden = download("a", origin: one)
    let visibleOtherSource = download("b", origin: one)
    let namesakeElsewhere = download("a", origin: two)
    // Saved before the source carried an origin: the vault cannot name it, so it stays visible.
    let noOrigin = download("a", origin: nil)

    let visible = vault.visibleDownloads([hidden, visibleOtherSource, namesakeElsewhere, noOrigin], now: now)
    #expect(visible.count == 3)
    #expect(!visible.contains(hidden))
    #expect(visible.contains(visibleOtherSource))
    #expect(visible.contains(namesakeElsewhere))
    #expect(visible.contains(noOrigin))
}


@Test func aPasscodeShorterThanTheMinimumIsRefused() {
    var vault = PrivacyVault(rounds: 10)
    #expect(throws: PrivacyVault.PasscodeError.tooShort) {
        try vault.setPasscode("1234")
    }
    #expect(!vault.hasPasscode)
    #expect(throws: Never.self) {
        try vault.setPasscode(String(repeating: "1", count: PrivacyVault.minimumLength))
    }
    #expect(vault.hasPasscode)
}

@Test func theUnlockWindowHasADeadlineThePageCanWaitFor() throws {
    // A page that closes itself when the unlock lapses needs the deadline, not just a yes/no.
    let start = Date()
    var vault = PrivacyVault(rounds: 10, unlockDuration: 300)
    #expect(vault.unlockExpiresAt == nil)
    try vault.setPasscode("123456", now: start)
    #expect(vault.unlockExpiresAt == start.addingTimeInterval(300))
    vault.lock()
    #expect(vault.unlockExpiresAt == nil)
}

/// Auto-advance, the Next button, and every recommendation path re-check `permitsPlayback` at the
/// moment of advance. An unlock that lapsed mid-title must not let the next episode (or a follow-up
/// season) of a hidden source play on in the locked state. This pins the rule those choke points
/// rely on: hidden source → false, hidden subscription → false, and an unlock restores it.
@Test func permitsPlaybackCoversTheAdvanceChokePoints() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    vault.lock()

    // A source hidden by key is refused.
    #expect(!vault.permitsPlayback(sourceKey: "a", origin: one, now: now))
    // A namesake in another subscription still plays.
    #expect(vault.permitsPlayback(sourceKey: "a", origin: two, now: now))

    // A whole hidden subscription also refuses every source it contributed.
    var vault2 = try unlockedVault(now: now)
    try vault2.hide(subscription: two, sourceKeys: ["s"], now: now)
    vault2.lock()
    #expect(!vault2.permitsPlayback(sourceKey: "s", origin: two, now: now))
    #expect(vault2.permitsPlayback(sourceKey: "s", origin: one, now: now))

    // Unlocking restores playback.
    let opened = vault.unlock("123456", now: now)
    #expect(opened)
    #expect(vault.permitsPlayback(sourceKey: "a", origin: one, now: now))
}
