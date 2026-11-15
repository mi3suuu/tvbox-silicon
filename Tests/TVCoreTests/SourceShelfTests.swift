import Foundation
import Testing
@testable import TVCore

/// 组内二级书架：一个 4K 分组 168 个源，按形态分成磁力/网盘/蓝光/弹幕几层。
@Suite struct SourceShelfTests {

    private func site(_ name: String, api: String = "https://example.com/api.php/provide/vod") -> Site {
        Site(key: name, name: name, type: 3, api: api, raw: ["key": .string(name), "name": .string(name)])
    }

    @Test func namesDecideTheShelf() {
        #expect(SourceShelf.shelf(for: site("🧲┃磁力┃4k")) == .magnet)
        #expect(SourceShelf.shelf(for: site("🧡蓝光┃影视")) == .bluRay)
        // 裸「4K」不算蓝光：这整组名字里几乎都有它，认它等于没分层。
        #expect(SourceShelf.shelf(for: site("💥┃布雷┃4K")) == .other)
        #expect(SourceShelf.shelf(for: site("🍿┃嗑剧┃4K弹幕")) == .danmaku)
        #expect(SourceShelf.shelf(for: site("🤟┃盘搜┃4K")) == .cloud)
        #expect(SourceShelf.shelf(for: site("🍉漫短┃小红")) == .shortDrama)
        #expect(SourceShelf.shelf(for: site("🤡共和┃动漫")) == .anime)
        #expect(SourceShelf.shelf(for: site("👼宝宝┃儿歌")) == .kids)
        #expect(SourceShelf.shelf(for: site("💃跳舞┃教学")) != .music)   // 教学不是音乐
        #expect(SourceShelf.shelf(for: site("🎼KTV┃音乐")) == .music)
        #expect(SourceShelf.shelf(for: site("88｜看球")) == .sport)
        #expect(SourceShelf.shelf(for: site("🎮一直播┃直播")) == .live)
        #expect(SourceShelf.shelf(for: site("韩圈｜APP")) == .apps)
        #expect(SourceShelf.shelf(for: site("无名小站")) == .other)
    }

    /// 「4K弹幕」是弹幕站，不是蓝光站：具体的那一类先命中。
    @Test func theMoreSpecificShelfWins() {
        #expect(SourceShelf.shelf(for: site("👽玩偶哥哥┃4K弹幕·饭太硬")) == .danmaku)
        #expect(SourceShelf.shelf(for: site("🚀盘搜💖4K|弹幕")) == .danmaku)
        #expect(SourceShelf.shelf(for: site("🧲新6V┃磁力")) == .magnet)
    }

    /// 小分组不分层：十几张卡本来就看得完，多一层只是多一次点击。
    @Test func smallGroupsStayFlat() {
        let small = (0..<10).map { site("磁力站\($0)") } + (0..<5).map { site("蓝光站\($0)") }
        #expect(SourceShelf.shelves(for: small).isEmpty)
    }

    /// 分不出两类时也不分：只有一层命中，等于给整组加了个标题。
    @Test func oneShelfIsNoShelf() {
        let onlyBluRay = (0..<40).map { site("蓝光站\($0)") }
        #expect(SourceShelf.shelves(for: onlyBluRay).isEmpty)
    }

    /// 真分得出来时，按书架大小排，且一个源都不丢。
    @Test func bigGroupsSplitIntoShelves() throws {
        var sites: [Site] = []
        sites += (0..<30).map { site("蓝光站\($0)") }
        sites += (0..<20).map { site("磁力站\($0)") }
        sites += (0..<12).map { site("盘搜\($0)") }
        sites += (0..<2).map { site("杂项\($0)") }     // <3 的并入「其他」
        let shelves = SourceShelf.shelves(for: sites)
        #expect(shelves.count == 4)
        #expect(shelves.reduce(0) { $0 + $1.sites.count } == sites.count)
        // 最大的书架在前，「其他」垫底。
        #expect(shelves.first?.shelf == .bluRay)
        #expect(shelves.last?.shelf == .other)
        #expect(shelves.last?.sites.count == 2)
    }

    /// 三个源能拼成一层时就不该被并进「其他」—— 阈值是「至少 3 个」。
    @Test func aShelfOfThreeStays() throws {
        var sites: [Site] = (0..<30).map { site("蓝光站\($0)") }
        sites += (0..<3).map { site("磁力站\($0)") }
        let shelves = SourceShelf.shelves(for: sites)
        #expect(shelves.contains { $0.shelf == .magnet })
    }
}
