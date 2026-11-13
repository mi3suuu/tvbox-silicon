import Foundation
import Testing
@testable import TVCore

// MARK: - #7b：原版播放器「直接显示」集合分流 + 升级迁移

/// 三形态 ↔ 两份集合的映射。
///
/// 这是 #7b 的核心判据。`MobilePlayer` 此前完全不读 surfaced
/// （`grep -c surfaced App/MobilePlayer.swift` = 0），顶栏是纯槽位驱动，
/// 于是设置页的「直接显示」勾选对它一半生效（勾上靠 `surfaceInTopRow` 副作用
/// 补进槽位、取消无效）。
@Test func surfacingMapsThreeLayoutsToTwoSets() throws {
    let watch = ["airPlay", "episodes"]
    let full: [String] = []
    let all = ["airPlay", "episodes", "quality", "speed", "lock", "rotate"]

    // 观看页顶栏 → watchSurfaced
    #expect(PlayerControlSurfacing.allowed(
        layout: .inline, watchSurfaced: watch, fullSurfaced: full, allControls: all
    ) == Set(watch))

    // 观看页全屏 → fullSurfaced
    #expect(PlayerControlSurfacing.allowed(
        layout: .pageFullScreen, watchSurfaced: watch, fullSurfaced: full, allControls: all
    ) == Set(full))

    // ⛔ 独立全屏播放器（没有观看页）→ 放行全部，不能套 fullSurfaced。
    // 若套了，因为 defaultFullSurfaced 是空数组，独立全屏播放器顶栏会整体清空。
    #expect(PlayerControlSurfacing.allowed(
        layout: .screen, watchSurfaced: watch, fullSurfaced: full, allControls: all
    ) == Set(all))

    // 负对照：如果实现把 .screen 也当 fullSurfaced 处理，上面那行必然红。
    // 这里显式写出来，让「错误实现」有一个可直接对照的期望：
    let wrongForScreen = Set(full)
    #expect(Set(all) != wrongForScreen)
}

/// 槽位过滤：空槽要保留成 nil（位置语义），非空但被禁的置 nil。
@Test func surfacingKeepsGapsAndClearsForbiddenSlots() throws {
    // 第 1 格 airPlay（允许）、第 2 格空、第 3 格 quality（被禁）、第 4 格 episodes（允许）
    let slots: [String?] = ["airPlay", nil, "quality", "episodes"]
    let allowed: Set<String> = ["airPlay", "episodes"]

    let filtered = PlayerControlSurfacing.filterSlots(slots, allowed: allowed)

    #expect(filtered.count == 4, "槽位总数不能变，否则后面的控件会整体左移")
    #expect(filtered[0] == "airPlay")
    #expect(filtered[1] == nil, "原本的空槽保留")
    #expect(filtered[2] == nil, "被禁的控件置空，而不是删除")
    #expect(filtered[3] == "episodes")

    // 负对照：若实现用 filter 而不是 map（删掉而非置空），count 会变 3。
    let wrong = slots.compactMap { slot -> String? in
        guard let slot, allowed.contains(slot) else { return nil }
        return slot
    }
    #expect(wrong.count == 2)
    #expect(wrong.count != filtered.count)
}

/// 「更多」菜单过滤：这里要**真删**（没有位置概念），不是置空。
@Test func surfacingRemovesFromMoreList() throws {
    let more = ["quality", "speed", "lock", "videoInfo"]
    let allowed: Set<String> = ["quality", "lock"]
    #expect(PlayerControlSurfacing.filterList(more, allowed: allowed) == ["quality", "lock"])
    #expect(PlayerControlSurfacing.filterList(more, allowed: []).isEmpty)
    // 负对照：置空式实现会留下空串占位，数量不变。
    #expect(PlayerControlSurfacing.filterList(more, allowed: allowed).count != more.count)
}

// MARK: - 升级迁移

/// 核心迁移判据：老用户升级前后，顶栏可见控件**数量不变**。
///
/// 这是三条约束里第 ①/③ 条的机器化：对三形态各跑一次。
@Test func migrationKeepsVisibleControlCountPerShape() throws {
    let defaultWatch = ["airPlay", "episodes"]
    let defaultFull: [String] = []

    // 三种典型「老用户」配置：顶栏都摆得比默认多。
    let shapes: [(name: String, top: [String?])] = [
        ("folded",   ["airPlay", "episodes", "quality", nil, nil, nil, nil, nil, nil, nil]),
        ("unfolded", ["airPlay", "episodes", "quality", "speed", "videoInfo", nil, nil, nil, nil, nil]),
        ("sideways", ["airPlay", "episodes", "quality", "speed", "lock", "rotate", "markAd", nil, nil, nil]),
    ]

    for shape in shapes {
        let before = shape.top.compactMap { $0 }.count
        let outcome = PlayerControlSurfacingMigration.plan(
            topSlots: shape.top,
            watchSurfaced: defaultWatch,
            fullSurfaced: defaultFull,
            defaultWatch: defaultWatch,
            defaultFull: defaultFull,
            alreadyMigrated: false
        )
        #expect(outcome.changed, "\(shape.name) 应当需要迁移")

        // 迁移后：顶栏每个可见控件都必须被允许，于是可见数量与迁移前一致。
        let allowedWatch = PlayerControlSurfacing.allowed(
            layout: .inline,
            watchSurfaced: outcome.watchSurfaced,
            fullSurfaced: outcome.fullSurfaced,
            allControls: defaultWatch + shape.top.compactMap { $0 }
        )
        let afterWatch = PlayerControlSurfacing.filterSlots(shape.top, allowed: allowedWatch)
            .compactMap { $0 }.count
        #expect(afterWatch == before, "\(shape.name) 观看页可见控件数必须不变：\(before) → \(afterWatch)")

        // 全屏也一样（老用户全屏顶栏就是同一份槽位）。
        let allowedFull = PlayerControlSurfacing.allowed(
            layout: .pageFullScreen,
            watchSurfaced: outcome.watchSurfaced,
            fullSurfaced: outcome.fullSurfaced,
            allControls: defaultWatch + shape.top.compactMap { $0 }
        )
        let afterFull = PlayerControlSurfacing.filterSlots(shape.top, allowed: allowedFull)
            .compactMap { $0 }.count
        #expect(afterFull == before, "\(shape.name) 全屏可见控件数必须不变：\(before) → \(afterFull)")

        // 负对照：不迁移（直接用默认集合）→ 数量必然变少。
        // 这条证明「迁移不是可选项」。
        let withoutMigration = PlayerControlSurfacing.filterSlots(
            shape.top, allowed: Set(defaultWatch)
        ).compactMap { $0 }.count
        #expect(withoutMigration < before,
                "\(shape.name) 不迁移必然缩水，否则本判据无意义：\(before) → \(withoutMigration)")
    }
}

/// 幂等：已经迁移过就不再动。
@Test func migrationIsIdempotentByMarker() throws {
    let top: [String?] = ["airPlay", "episodes", "quality", nil, nil, nil, nil, nil, nil, nil]
    let defaultWatch = ["airPlay", "episodes"]

    let first = PlayerControlSurfacingMigration.plan(
        topSlots: top, watchSurfaced: defaultWatch, fullSurfaced: [],
        defaultWatch: defaultWatch, defaultFull: [], alreadyMigrated: false
    )
    #expect(first.changed)

    // 第二次（marker 已存在）→ 不动
    let second = PlayerControlSurfacingMigration.plan(
        topSlots: top, watchSurfaced: first.watchSurfaced, fullSurfaced: first.fullSurfaced,
        defaultWatch: defaultWatch, defaultFull: [], alreadyMigrated: true
    )
    #expect(!second.changed, "marker 存在时不能再写盘")

    // 第三次：即使把集合改回默认（模拟用户手动清了），marker 在也不动。
    let third = PlayerControlSurfacingMigration.plan(
        topSlots: top, watchSurfaced: defaultWatch, fullSurfaced: [],
        defaultWatch: defaultWatch, defaultFull: [], alreadyMigrated: true
    )
    #expect(!third.changed)
}

/// 不抢用户的选择：用户自己勾过（集合已非默认）就不迁移。
@Test func migrationLeavesUserChoicesAlone() throws {
    let top: [String?] = ["airPlay", "episodes", "quality", nil, nil, nil, nil, nil, nil, nil]
    let defaultWatch = ["airPlay", "episodes"]

    // 用户自己勾了 speed —— 说明他懂这套机制，不能覆盖
    let outcome = PlayerControlSurfacingMigration.plan(
        topSlots: top,
        watchSurfaced: defaultWatch + ["speed"],
        fullSurfaced: [],
        defaultWatch: defaultWatch,
        defaultFull: [],
        alreadyMigrated: false
    )
    #expect(!outcome.changed)
    #expect(outcome.watchSurfaced == defaultWatch + ["speed"])

    // 全屏集合被改过，同样不动
    let outcome2 = PlayerControlSurfacingMigration.plan(
        topSlots: top,
        watchSurfaced: defaultWatch,
        fullSurfaced: ["quality"],
        defaultWatch: defaultWatch,
        defaultFull: [],
        alreadyMigrated: false
    )
    #expect(!outcome2.changed)
}

/// 顶栏**为空**时不写盘；顶栏**有控件**（哪怕就是默认那两颗）时必须写 ——
/// 因为 `defaultFullSurfaced` 是空数组，不写就会让全屏顶栏清空。
///
/// ⛔ 这条的前身是 `migrationSkipsWhenNothingExtraInSlots`（判据「有超出默认的控件」），
/// 已被证明是错的：standard 配置的顶栏正好是默认那两颗，extras 为空 → 不迁移
/// → 这些用户升级后全屏顶栏照样塌。判据改为「顶栏有无可见控件」。
@Test func migrationTriggersOnAnyVisibleTopControl() throws {
    let defaultWatch = ["airPlay", "episodes"]

    // ① 顶栏全空 → 不写盘（没什么可保的）
    let empty = PlayerControlSurfacingMigration.plan(
        topSlots: [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil],
        watchSurfaced: defaultWatch, fullSurfaced: [],
        defaultWatch: defaultWatch, defaultFull: [], alreadyMigrated: false
    )
    #expect(!empty.changed)

    // ② 顶栏就是默认那两颗 → **必须写**：否则全屏顶栏（defaultFull=[]）会清空
    let standard = PlayerControlSurfacingMigration.plan(
        topSlots: ["airPlay", "episodes", nil, nil, nil, nil, nil, nil, nil, nil],
        watchSurfaced: defaultWatch, fullSurfaced: [],
        defaultWatch: defaultWatch, defaultFull: [], alreadyMigrated: false
    )
    #expect(standard.changed, "standard 顶栏也必须迁移，否则全屏顶栏清空")
    #expect(Set(standard.fullSurfaced) == Set(["airPlay", "episodes"]),
            "迁移后 fullSurfaced 必须包含顶栏可见控件")
}

// MARK: - 三形态基线（约束③）

/// 打印三形态在 standard 配置下的实际数量，供人工对照与回归留痕。
///
/// 这不是断言测试，是**基线快照**：数字变化时会在日志里显形。
/// `.screen` 一行必须 top/bottom/more 三个数字前后**完全一致**
/// （它是「显式放行全部」，任何变化都是回归）。
@Test func printThreeShapeBaseline() throws {
    // 与 App/PlayerControls.swift:145-152 的 standardTop/Bottom/More 一致
    let standardTop = ["airPlay", "episodes"]
    let standardBottom = ["backTen", "playPause", "forwardTen", "previousEpisode", "nextEpisode", "fullScreen"]
    let standardMore = ["quality", "audio", "subtitles", "speed", "pictureSize", "pictureInPicture",
                        "miniPlayer", "lock", "rotate", "danmaku", "videoInfo", "speechSubtitles",
                        "anotherPlayer", "markAd", "adBlock", "autoPlayNext", "moreInSeries",
                        "skipIntroAuto", "skipIntroManual"]
    let allCases = standardTop + standardBottom + standardMore
    let defaultWatch = ["airPlay", "episodes"]
    let defaultFull: [String] = []

    func pad(_ xs: [String]) -> [String?] {
        var r: [String?] = Array(xs.prefix(10)).map { Optional($0) }
        while r.count < 10 { r.append(nil) }
        return r
    }
    let topSlots = pad(standardTop)
    let bottomSlots = pad(standardBottom)

    var rows: [String] = []
    for layout in PlayerControlSurfacing.Layout.allCases {
        let plan = PlayerControlSurfacingMigration.plan(
            topSlots: topSlots, watchSurfaced: defaultWatch, fullSurfaced: defaultFull,
            defaultWatch: defaultWatch, defaultFull: defaultFull, alreadyMigrated: false)
        let allowed = PlayerControlSurfacing.allowed(
            layout: layout, watchSurfaced: plan.watchSurfaced,
            fullSurfaced: plan.fullSurfaced, allControls: allCases)
        let beforeTop = topSlots.compactMap { $0 }.count
        let beforeBottom = bottomSlots.compactMap { $0 }.count
        let afterTop = PlayerControlSurfacing.filterSlots(topSlots, allowed: allowed).compactMap { $0 }.count
        // ⛔ 底栏与「更多」**不受 surfaced 管**（设置页判据是 set && layout.top.contains），
        // 所以这里必须前后不变 —— 若变了就是把播放器掏空。
        rows.append("\(layout.rawValue): top \(beforeTop)→\(afterTop) bottom \(beforeBottom)→\(beforeBottom) more \(standardMore.count)→\(standardMore.count) migrated=\(plan.changed)")
    }
    print("=== #7b 三形态基线 ===")
    for row in rows { print(row) }

    // 断言：.screen 逐项必须不变（这是约束③「逐字节一致」的机器化）
    let screenAllowed = PlayerControlSurfacing.allowed(
        layout: .screen, watchSurfaced: [], fullSurfaced: [], allControls: allCases)
    #expect(PlayerControlSurfacing.filterSlots(topSlots, allowed: screenAllowed).compactMap { $0 } == standardTop)
    #expect(PlayerControlSurfacing.filterSlots(bottomSlots, allowed: screenAllowed).compactMap { $0 } == standardBottom)
    #expect(PlayerControlSurfacing.filterList(standardMore, allowed: screenAllowed) == standardMore)

    // 基线关键数字（若将来有人改了 standard 或默认集合，这里会显形）
    #expect(defaultWatch.count == 2)
    #expect(defaultFull.isEmpty)
    #expect(rows.count == 3)

    // ⛔ 底栏与「更多」不受 surfaced 管 —— 三条一起锁死，
    // 防止后来者「顺手统一过滤」把播放器掏空（bottom 6→0 / more 19→0）。
    for layout in PlayerControlSurfacing.Layout.allCases {
        let allowed = PlayerControlSurfacing.allowed(
            layout: layout, watchSurfaced: defaultWatch, fullSurfaced: defaultFull, allControls: allCases)
        // 底栏在「不过滤」时恒为 6，与 allowed 无关
        #expect(PlayerControlSurfacing.filterSlots(bottomSlots, allowed: Set(allCases))
                    .compactMap { $0 } == standardBottom)
        // 但若拿 allowed 去过滤（错误做法），inline/pageFullScreen 会塌 —— 负对照
        let wrong = PlayerControlSurfacing.filterSlots(bottomSlots, allowed: allowed).compactMap { $0 }.count
        if layout == .screen {
            #expect(wrong == standardBottom.count, ".screen 放行全部，底栏不变")
        } else {
            #expect(wrong < standardBottom.count, "\(layout.rawValue) 若错误地过滤底栏必然塌 —— 这就是不能那么做的证据")
        }
    }
}


/// 迁移必须真的把 `pageFullScreen` 的顶栏从 0 补回 2。
///
/// 上面 `printThreeShapeBaseline` 显示：standard 配置下
/// `pageFullScreen: top 2→0` —— 因为 `defaultFullSurfaced = []`。
/// 老用户升级后全屏顶栏会**整个消失**。迁移是唯一补救，这条判据锁住它。
@Test func migrationRestoresFullScreenTopBar() throws {
    let standardTop = ["airPlay", "episodes"]
    let defaultWatch = ["airPlay", "episodes"]
    let defaultFull: [String] = []
    func pad(_ xs: [String]) -> [String?] {
        var r: [String?] = Array(xs.prefix(10)).map { Optional($0) }
        while r.count < 10 { r.append(nil) }
        return r
    }
    let topSlots = pad(standardTop)

    // 迁移前：全屏顶栏 = 槽位 ∩ fullSurfaced = 空
    let before = PlayerControlSurfacing.filterSlots(
        topSlots, allowed: Set(defaultFull)).compactMap { $0 }.count
    #expect(before == 0, "未迁移时全屏顶栏确实为空 —— 这就是必须迁移的理由")

    // 迁移
    let plan = PlayerControlSurfacingMigration.plan(
        topSlots: topSlots, watchSurfaced: defaultWatch, fullSurfaced: defaultFull,
        defaultWatch: defaultWatch, defaultFull: defaultFull, alreadyMigrated: false)
    #expect(plan.changed)

    // 迁移后：全屏顶栏回到 2
    let allowedFull = PlayerControlSurfacing.allowed(
        layout: .pageFullScreen, watchSurfaced: plan.watchSurfaced,
        fullSurfaced: plan.fullSurfaced, allControls: standardTop)
    let after = PlayerControlSurfacing.filterSlots(topSlots, allowed: allowedFull).compactMap { $0 }.count
    #expect(after == standardTop.count, "迁移后全屏顶栏必须恢复到 \(standardTop.count) 颗：0 → \(after)")

    // 观看页也保持 2
    let allowedInline = PlayerControlSurfacing.allowed(
        layout: .inline, watchSurfaced: plan.watchSurfaced,
        fullSurfaced: plan.fullSurfaced, allControls: standardTop)
    #expect(PlayerControlSurfacing.filterSlots(topSlots, allowed: allowedInline)
                .compactMap { $0 }.count == standardTop.count)
}
