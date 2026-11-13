import Foundation
import Testing
@testable import TVCore

struct DanmakuTests {
    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value > 0 { byte |= 0x80 }; bytes.append(byte) } while value > 0
        return bytes
    }
    private func element(ms: UInt64, mode: UInt64, color: UInt64, text: String) -> [UInt8] {
        let body = [0x10] + varint(ms) + [0x18] + varint(mode) + [0x20] + varint(25) + [0x28] + varint(color)
            + [0x32, 2, 0x61, 0x62] + [0x3A] + varint(UInt64(text.utf8.count)) + Array(text.utf8) + [0x49] + Array(repeating: 0, count: 8)
        return [0x0A] + varint(UInt64(body.count)) + body
    }

    @Test func segmentsParseIntoTimedComments() {
        let data = Data(element(ms: 61_500, mode: 1, color: 0xFF0000, text: "前方高能") + element(ms: 2_000, mode: 5, color: 0xFFFFFF, text: "top")
                        + element(ms: 3_000, mode: 7, color: 0xFFFFFF, text: "[positioned]") + element(ms: 4_000, mode: 4, color: 0, text: "  "))
        let comments = BilibiliDanmaku.parse(data)
        #expect(comments.map(\.text) == ["前方高能", "top"])
        #expect(comments[0].time == 61.5 && comments[0].position == .scroll && comments[0].color == 0xFF0000)
        #expect(comments[1].position == .top)
    }

    /// 拨速度档位时不清屏，但只保住 active 不保碰撞表 ⇒ 新弹幕会挤进已占用的行。
    /// `adopt` 就是补这一步：把屏上已有的 placement 播种进新布局的三张表。
    @Test func adoptingOnScreenPlacementsKeepsNewOnesOutOfTheirLanes() {
        let comment = Danmaku(time: 0, position: .scroll, text: "on screen")
        // 旧布局：屏上已经有一条，占住了 lane 0。
        var old = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        // 第一次落位就是「屏上那条」，直接留用（第二次 place 会落到别的行，不能拿来当它）。
        let resident = old.place(comment, width: 200, at: 0)!
        #expect(resident.lane == 0)

        // 新布局（换速度后）：不 adopt 时它以为满屏是空的，新弹幕落回 lane 0 —— 与屏上那条重叠。
        var without = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 6)
        #expect(without.place(Danmaku(time: 0, position: .scroll, text: "new"), width: 200, at: 0.5)?.lane == 0)

        // adopt 之后，lane 0 被认作已占用，新弹幕挪到下一行。
        var with = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 6)
        with.adopt([resident])
        #expect(with.place(Danmaku(time: 0, position: .scroll, text: "new"), width: 200, at: 0.5)?.lane != 0)
    }

    /// 同一行被 adopt 多条时，留 start 最新的那条：只有它决定下一颗能不能进。
    @Test func adoptingKeepsTheNewestPlacementPerLane() {
        let comment = Danmaku(time: 0, position: .scroll, text: "x")
        var laidOut = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        let early = laidOut.place(comment, width: 100, at: 0)!
        // 手工造一条同 lane、更晚开始的 placement（模拟同一行先后两条）。
        let late = DanmakuLayout.Placement(comment: comment, start: 5, width: 100, lane: early.lane, speed: early.speed)

        var layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        layout.adopt([late, early])   // 顺序故意反着给
        // 若留下的是 early（start 0），`place` 会认为该行早就空了；留下 late 才正确挡住。
        #expect(layout.place(Danmaku(time: 0, position: .scroll, text: "y"), width: 200, at: 5.2) != nil)
        var again = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        again.adopt([late, early])
        // lane 0 被 late 占着，新弹幕应去别的行（或本帧无处可放），总之不能是 lane 0。
        #expect(again.place(Danmaku(time: 0, position: .scroll, text: "y"), width: 200, at: 5.2)?.lane != early.lane)
    }

    /// 越界 lane 必须被丢弃，不许把 place() 的索引假设搞坏。
    @Test func adoptingIgnoresLanesTheNewLayoutDoesNotHave() {
        let comment = Danmaku(time: 0, position: .scroll, text: "x")
        var layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        let outOfRange = DanmakuLayout.Placement(comment: comment, start: 0, width: 100, lane: 99, speed: 100)
        layout.adopt([outOfRange])   // 不该崩，也不该影响正常落位
        #expect(layout.place(comment, width: 200, at: 0)?.lane == 0)
    }

    @Test func layoutKeepsCommentsApartAndDropsWhatDoesNotFit() {
        var layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        #expect(layout.scrollLanes == 4 && layout.fixedLanes == 2)
        let comment = Danmaku(time: 0, position: .scroll, text: "x")
        // Four at once take four lanes; a fifth has none.
        let lanes = (0..<5).map { _ in layout.place(comment, width: 200, at: 0)?.lane }
        #expect(lanes == [0, 1, 2, 3, nil])
        // Once the first has fully entered with a gap, its lane is free again.
        #expect(layout.place(comment, width: 200, at: 3)?.lane == 0)
        // A much longer (faster) comment must not catch the one ahead, so it waits for another lane.
        #expect(layout.place(comment, width: 3000, at: 3.2) == nil)
        // Pinned comments stack in their own rows (on an empty screen, so no scrolling comment is in the way).
        layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        let fixed = Danmaku(time: 0, position: .top, text: "t")
        #expect(layout.place(fixed, width: 100, at: 0)?.lane == 0)
        #expect(layout.place(fixed, width: 100, at: 1)?.lane == 1)
        #expect(layout.place(fixed, width: 100, at: 4.5)?.lane == 0)
    }

    @Test func areaLimitsHowMuchOfThePictureCommentsUse() {
        // A quarter of a 1000-point picture holds five 50-point rows, and top comments stay inside it too.
        let quarter = DanmakuLayout(width: 1000, height: 1000, laneHeight: 50, scrollArea: DanmakuArea.quarter.share)
        #expect(quarter.scrollLanes == 5 && quarter.fixedLanes == 5)
        let whole = DanmakuLayout(width: 1000, height: 1000, laneHeight: 50, scrollArea: DanmakuArea.full.share)
        #expect(whole.scrollLanes == 20 && whole.fixedLanes == 6)
        #expect(DanmakuArea.standard.share == 0.75 && DanmakuArea(rawValue: 50) == .half)
        #expect(DanmakuArea.allCases.map(\.next) == [.half, .threeQuarters, .full, .quarter])
    }

    @Test func styleMenuKeepsTheStoredChoice() {
        #expect(DanmakuStyle.fontSizes(including: 22) == [16, 18, 20, 22, 26, 30, 36])
        // A size or opacity the sheet's slider set between the menu's choices is still listed, so it shows as chosen.
        #expect(DanmakuStyle.fontSizes(including: 24) == [16, 18, 20, 22, 24, 26, 30, 36])
        #expect(DanmakuStyle.opacities(including: 0.85) == [1, 0.85, 0.7, 0.5, 0.3])
        #expect(DanmakuStyle.opacities(including: 0.6) == [1, 0.85, 0.7, 0.6, 0.5, 0.3])
        #expect(DanmakuStyle.textScale(33) == 1.5 && DanmakuStyle.textScale(80) == 36 / 22.0 && DanmakuStyle.textScale(.nan) == 1)
    }

    @Test func topCommentsAndScrollingCommentsDoNotOverlap() {
        var layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        let moving = Danmaku(time: 0, position: .scroll, text: "x")
        let pinned = Danmaku(time: 0, position: .top, text: "t")
        // Lane 0 has a comment that crosses the centre within the next four seconds, so the top comment takes row 1.
        #expect(layout.place(moving, width: 200, at: 0)?.lane == 0)
        #expect(layout.place(pinned, width: 300, at: 1)?.lane == 1)
        // Row 0 is still busy and row 1 holds a pinned comment this one would reach before it goes, so it takes row 2.
        #expect(layout.place(moving, width: 200, at: 1.5)?.lane == 2)
        // Once the first comment is past the centre, row 0 is clear for a top comment again.
        var later = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        _ = later.place(moving, width: 200, at: 0)
        #expect(later.place(pinned, width: 300, at: 7.5)?.lane == 0)
    }
}

struct CastMediaDanmakuTests {
    @Test func castMp4AddressesNameTheirPart() {
        let cast = URL(string: "http://14.17.92.11/upgcxcode/88/70/42500557088/42500557088-1-192.mp4?e=x&ua=tvproj")!
        #expect(DanmakuSource.registerBilibiliMedia(cast) && DanmakuSource.has(cast))
        #expect(!DanmakuSource.registerBilibiliMedia(URL(string: "https://example.com/video.mp4")!))
    }
}
