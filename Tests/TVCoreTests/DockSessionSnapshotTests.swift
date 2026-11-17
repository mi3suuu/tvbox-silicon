import Foundation
import Testing
@testable import TVCore

/// 「记住上次的窗口」的判据。
///
/// 用户要求：历史播放窗口、坐标、各窗口进度都要记住，下次进 App 一键恢复。
@Suite("DockSessionSnapshot")
struct DockSessionSnapshotTests {

    private func ctx(_ episode: String) -> PlaybackHistoryContext {
        PlaybackHistoryContext(origin: URL(string: "https://a.test")!, sourceKey: "k",
                               sourceName: "s", videoID: "v1", videoName: "剧",
                               episodeID: episode, episodeName: "第\(episode)集", episodeFlag: "f")
    }

    private func snap(_ ep: String, at: Date, pos: Double = 10) -> DockSessionSnapshot {
        DockSessionSnapshot(context: ctx(ep), position: pos, duration: 100,
                            scale: 1, offset: CGSize(width: -20, height: -30), savedAt: at)
    }

    /// 同一集只留最新一条（防止反复进出把同一集堆成好几份）。
    @Test func theSameEpisodeKeepsOnlyTheNewest() {
        let now = Date()
        let old = snap("e1", at: now.addingTimeInterval(-100), pos: 5)
        let new = snap("e1", at: now, pos: 50)
        let out = DockSessionStore.normalized([old, new], now: now)
        #expect(out.count == 1)
        #expect(out.first?.position == 50, "应保留最新那条的进度")
    }

    /// 过期的快照不再恢复（直链/会话早失效了）。
    @Test func staleSnapshotsAreDropped() {
        let now = Date()
        let fresh = snap("e1", at: now)
        let stale = snap("e2", at: now.addingTimeInterval(-DockSessionStore.maxAge - 60))
        let out = DockSessionStore.normalized([fresh, stale], now: now)
        #expect(out.count == 1)
        #expect(out.first?.context.episodeID == "e1")
    }

    /// 条数不超过坞容量。
    @Test func theSnapshotNeverExceedsTheDockCapacity() {
        let now = Date()
        let many = (0..<20).map { snap("e\($0)", at: now.addingTimeInterval(Double($0))) }
        #expect(DockSessionStore.normalized(many, now: now).count == PlaybackSessionCapacityForTest.dock)
    }

    /// 编解码往返不丢坐标与进度。
    @Test func encodeDecodeKeepsPositionAndOffset() {
        let now = Date()
        let items = [snap("e1", at: now, pos: 42.5)]
        let data = DockSessionStore.encode(items)
        #expect(data != nil)
        let back = DockSessionStore.decode(data!)
        #expect(back.count == 1)
        #expect(back.first?.position == 42.5)
        #expect(back.first?.offset == CGSize(width: -20, height: -30))
    }

    /// 损坏数据不能崩，也不能返回半个列表。
    @Test func corruptDataDecodesToNothing() {
        #expect(DockSessionStore.decode(Data("not json".utf8)).isEmpty)
        #expect(DockSessionStore.decode(Data()).isEmpty)
    }

    /// 恢复时坐标必须钳回可视区 —— 上次横屏摆的，这次竖屏可能整个在屏外。
    @Test func restoringClampsOffsetsBackOnScreen() {
        let now = Date()
        var far = snap("e1", at: now)
        far.offsetX = -5000
        far.offsetY = -5000
        let out = DockSessionStore.clamped([far],
                                           containers: [CGSize(width: 466, height: 678)],
                                           card: CGSize(width: 200, height: 150))
        let o = out[0].offset
        #expect(o.width > -5000, "恢复时必须钳回可视区，否则窗口找不回来")
        #expect(o.height > -5000)
    }
}

/// 只读 `PlaybackCapacity.dock` 的别名，避免测试里写死。
private enum PlaybackSessionCapacityForTest {
    static var dock: Int { PlaybackCapacity.dock }
}
