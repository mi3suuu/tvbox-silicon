import Foundation

/// The app's hardcoded network identities, gathered in one place: the User-Agent strings each
/// service presents, the Xunlei Android client version its sign-in impersonates, and the music
/// resolver's fixed host. Keeping them here makes version bumps and endpoint audits a one-file
/// change instead of a hunt through every provider.
enum Endpoints {
    // MARK: User-Agent

    /// The desktop Chrome Douyin's sign-in page and account check expect.
    static let douyinWebUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// The desktop Chrome Quark Drive's web API expects.
    static let quarkUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    /// 115's own browser; a download link opens only with the User-Agent that asked for it.
    static let pan115UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 115Browser/27.0.5.7"

    /// The desktop browser the live platforms' web APIs expect.
    static let liveDesktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// The mobile Safari some live platforms answer differently for.
    static let liveMobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // MARK: Xunlei client

    /// The Android app version the Xunlei sign-in impersonates (the identity the wexfnw bundles use).
    static let xunleiClientVersion = "25.0.6.30"

    /// The `downloadprovider-<version>` auth identity the bundles store.
    static let xunleiAuthVersion = "downloadprovider-25.0.6.30"

    // MARK: Music resolver

    /// HYW's public-benefit QQ resolver endpoint, pinned by IP.
    static let hywMusicBaseURL = "https://103.79.184.97/api/music/url"
}
