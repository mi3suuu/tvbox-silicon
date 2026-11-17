import Foundation
import Testing
@testable import TVCore

/// 「这条地址是一条线自己长得像网页」的判据。
///
/// 判错的两种方向都有代价：
///   · 该判的没判 → 播放器拿到 HTML 转圈到超时（实测内置「可播」组 26 条线就是这样）；
///   · 不该判的判了 → 一条好好的 m3u8 被送进 15 秒嗅探，起播从 0.2 秒变 15 秒。
@Suite struct PageAddressTests {

    @Test func platformPagesAreRecognised() {
        #expect(PlaybackChoice.isPageAddress("https://v.youku.com/v_show/id_XNjU4NDYxNTg1Ng==.html"))
        #expect(PlaybackChoice.isPageAddress("https://www.bilibili.com/bangumi/play/ep416234"))
        #expect(PlaybackChoice.isPageAddress("https://v.qq.com/x/cover/abc.html"))
        #expect(PlaybackChoice.isPageAddress("https://www.iqiyi.com/v_19rr7qhfgg.html"))
        #expect(PlaybackChoice.isPageAddress("https://www.mgtv.com/b/1234/5678.html"))
    }

    @Test func cloudPlayPagesAreRecognised() {
        // 云播页：/share/<hash>、/play/<id>
        #expect(PlaybackChoice.isPageAddress("https://vip.ffzy-plays.com/share/fe510a56d595b873d814beaefe60abd9"))
        #expect(PlaybackChoice.isPageAddress("https://hn.bfvvs.com/play/dBB1nZXd"))
        #expect(PlaybackChoice.isPageAddress("https://v.lzcdn27.com/share/845ce31b9cf79c9aad515d0209881a3c"))
    }

    /// 直链媒体永远不算网页 —— 即使路径里有 `/play/`。
    ///
    /// `play.xluuss.com/play/<id>/index.m3u8` 是真实存在的形状，判错就是给每条正常线加 15 秒。
    @Test func directMediaIsNeverAPage() {
        #expect(!PlaybackChoice.isPageAddress("https://play.xluuss.com/play/axkVp9le/index.m3u8"))
        #expect(!PlaybackChoice.isPageAddress("https://g.xlzyd.com:9999/hls/959/20261105/4588854/plist0.ts"))
        #expect(!PlaybackChoice.isPageAddress("https://cdn.example.com/movie.mp4"))
        #expect(!PlaybackChoice.isPageAddress("magnet:?xt=urn:btih:abc"))
    }

    /// 非 HTTP 的地址（插件返回的 `resolve://`、App 自己的 `tvbox-*` scheme）一律不碰。
    @Test func nonHTTPAddressesAreLeftAlone() {
        #expect(!PlaybackChoice.isPageAddress("resolve://ticket-123"))
        #expect(!PlaybackChoice.isPageAddress("tvbox-hongguo://stream"))
        #expect(!PlaybackChoice.isPageAddress(""))
    }
}

/// 「上次选的那档清晰度」要真的记住、真的按名字对回来。
@Suite struct QualityPreferenceTests {
    private let suite = "quality-preference-tests"
    private func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func remembersAndReadsBack() {
        let store = defaults()
        let key = QualityPreference.key(site: "kanju_4k", video: "av_1", flag: "官方4K")
        #expect(QualityPreference.remembered(key, defaults: store) == nil)
        QualityPreference.remember("2160P", for: key, defaults: store)
        #expect(QualityPreference.remembered(key, defaults: store) == "2160P")
        QualityPreference.forget(key, defaults: store)
        #expect(QualityPreference.remembered(key, defaults: store) == nil)
    }

    /// 键必须带线路：同一部剧的不同线路是不同片源，档位名字对不上。
    @Test func keySeparatesLines() {
        #expect(QualityPreference.key(site: "s", video: "v", flag: "A")
                != QualityPreference.key(site: "s", video: "v", flag: "B"))
        #expect(QualityPreference.key(site: "s", video: "v", flag: "A")
                != QualityPreference.key(site: "s2", video: "v", flag: "A"))
    }

    @Test func matchesTheSameQualityByName() {
        let choices = [PlaybackChoice(id: 0, name: "720P", address: "a"),
                       PlaybackChoice(id: 1, name: "1080P", address: "b")]
        let hit = QualityPreference.match(choices, named: "1080P", nameOf: \.name)
        #expect(hit?.address == "b")
        // 那档不在了：返回 nil，调用方重新问一次，而不是静默播另一档。
        #expect(QualityPreference.match(choices, named: "2160P", nameOf: \.name) == nil)
    }
}
