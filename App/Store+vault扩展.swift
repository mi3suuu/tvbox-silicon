import Foundation
import TVCore

// MARK: - 隐私保险库：App 级生命周期接线

/// The vault's app-lifecycle leg, kept out of `Store.swift` so the main class stays as the fusion
/// rule requires. Everything here is a method or a computed property — no stored state — which is
/// why an extension is enough.
extension Store {

    /// Relocks the vault when the app leaves the foreground.
    ///
    /// An unlock is for the moment it was given. Handing the phone to someone else with the app
    /// still open would otherwise leave every hidden source and every hidden subscription one tap
    /// away, for as long as `unlockDuration` lasts. Locking on background makes the window the
    /// viewer actually used the only one that is open.
    ///
    /// A no-op when no passcode is set: `lock()` returns early unless something is unlocked, and a
    /// vault without a passcode hides nothing in the first place. The guard here is only about
    /// skipping the write, so a plain install does not touch defaults on every backgrounding.
    func relockVaultOnBackground() {
        guard vault.hasPasscode else { return }
        vault.lock()
        saveVault()
    }

    /// Whether the vault currently hides anything at all — a passcode plus at least one hidden
    /// item. Settings uses this instead of `hasPasscode` alone where "is the vault doing work" is
    /// the question rather than "is a passcode set".
    var vaultHidesAnything: Bool { vault.hasPasscode && vault.hasHiddenItems }
}
