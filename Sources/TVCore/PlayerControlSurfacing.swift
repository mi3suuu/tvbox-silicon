import Foundation

// MARK: - 「直接显示」集合在三种播放布局下的分流（#7b）

/// 原版播放器（`MobilePlayer`）的顶栏/底栏/更多菜单该不该画某个控件。
///
/// ## 为什么需要这一层
///
/// 设置页 `PlayerControlsSettingsView` 明确写着
/// 「This layout applies to the Original and One skins」——
/// 即这套「直接显示」配置对**原版**皮肤生效。而实测：
///
/// ```
/// grep -c "surfaced\|Surfaced" App/MobilePlayer.swift                    → 0
///                              App/OneSkinPlayerChrome.swift             → 11
///                              App/PlayerControlsSettingsView.swift      → 7
/// ```
///
/// 原版播放器**一个读取点都没有**。它的顶栏是纯槽位驱动
/// （`topSlots` 里有什么就画什么，只过 `available()` 这一层内容可用性），
/// 于是「直接显示」的两个集合对它完全无效：
///   · 勾上 → `setSurfaced` 顺手 `surfaceInTopRow` 把控件摆进槽位 ⇒ **看起来生效**
///   · 取消 → 只从集合里删，槽位不动 ⇒ **没有效果**
///
/// 这不是「漏了一处求交」，是整体未接入。
///
/// ## 为什么分成三支而不是「全屏/非全屏」两支
///
/// 播放器布局有三种（`MobilePlayerLayout`），但「直接显示」的语义是按
/// **观看页的状态**定义的（键名就是 `watchSurfaced` / `fullSurfaced`，
/// `watch` 指观看页）。三种布局与两份集合的对应关系**不是**简单的二对二：
///
/// | 布局 | 含义 | 用哪份 |
/// |---|---|---|
/// | `.inline` | 观看页顶部的播放器条 | `watchSurfaced` |
/// | `.pageFullScreen` | 观看页的播放器铺满整屏 | `fullSurfaced` |
/// | `.screen` | **没有观看页**的独立全屏播放器 | **不用**，全部放行 |
///
/// `.screen` 的来源是 `PlayerView.playerLayout`：
/// ```swift
/// guard let watch else { return .screen }
/// return watch.fullScreen ? .pageFullScreen : .inline
/// ```
/// 它没有观看页，`watch`/`full` 这两个语义都不适用。
/// 若让它也走 `fullSurfaced`，因为 `defaultFullSurfaced` 是**空数组**，
/// 独立全屏播放器的顶栏会**整个清空**——那是纯回归，不是修复。
///
/// 所以 `.screen` 显式放行全部，而不是「跳过过滤」：
/// 前者语义自明（将来若要给它 surfaced 语义，改动点唯一），
/// 后者留下「这里是忘了还是故意的」的疑问。
public enum PlayerControlSurfacing {
    /// 播放器布局。与 App 层 `MobilePlayerLayout` 的三个 case 一一对应，
    /// 但**不依赖它**——那份定义在 `App/MobilePlayer.swift`（iOS）与
    /// `App/PlayerSurface.swift`（非 iOS）各有一份，都在 App 层，
    /// 而 App 层没有测试目标。放在这里才能让判据真正可复跑。
    public enum Layout: String, CaseIterable, Sendable {
        case screen
        case inline
        case pageFullScreen
    }

    /// 该布局下允许画出来的控件集合（用 rawValue 表示，避免依赖 App 层枚举）。
    ///
    /// - Parameters:
    ///   - layout: 当前播放器布局。
    ///   - watchSurfaced: 观看页「直接显示」集合的 rawValue。
    ///   - fullSurfaced: 全屏态「直接显示」集合的 rawValue。
    ///   - allControls: 全部控件的 rawValue（`.screen` 放行它们）。
    /// - Returns: 允许集合。`.screen` 返回 `allControls`。
    public static func allowed(
        layout: Layout,
        watchSurfaced: [String],
        fullSurfaced: [String],
        allControls: [String]
    ) -> Set<String> {
        switch layout {
        case .inline: return Set(watchSurfaced)
        case .pageFullScreen: return Set(fullSurfaced)
        case .screen: return Set(allControls)
        }
    }

    /// 过滤一排槽位：`nil`（空槽）保留，非空但不在允许集合里的置 `nil`。
    ///
    /// ⛔ 空槽必须保留成 `nil` 而不是删掉：槽位决定**位置**，
    /// 删掉会让后面的控件整体左移，与「用户拖到第 7 格」的意图矛盾。
    /// 这与 `topSlots` 原本的语义一致（`compactMap` 掉的只是 `nil`）。
    public static func filterSlots(_ slots: [String?], allowed: Set<String>) -> [String?] {
        slots.map { slot in
            guard let slot, allowed.contains(slot) else { return nil }
            return slot
        }
    }

    /// 过滤一个控件列表（用于「更多」菜单）。这个**要真的删**，不是置 `nil`——
    /// 菜单没有位置概念，留着空位只会在列表里出现空隙。
    public static func filterList(_ controls: [String], allowed: Set<String>) -> [String] {
        controls.filter { allowed.contains($0) }
    }
}

// MARK: - 升级迁移（幂等）

/// 把「升级前顶栏里已有的控件」写进两种「直接显示」集合，
/// 让接入 surfacing 前后的视觉**完全一致**。
///
/// ## 为什么必须迁移
///
/// 接入前：原版播放器顶栏 = 槽位全部（用户没勾过任何东西，也一直看着全部按钮）。
/// 接入后：顶栏 = 槽位 ∩ 集合。默认 `watchSurfaced` 只有
/// `[.airPlay, .episodes]`，`fullSurfaced` 是空数组。
///
/// 不迁移的话，从旧版升上来的用户会看到：观看页顶栏从 6 颗变 2 颗、
/// **全屏顶栏一颗不剩**。那不是他们改的配置造成的，是升级造成的——
/// 用户会认为是「更新把功能弄坏了」。
///
/// ## 为什么逐形态写
///
/// 控制栏配置**按三种形态各自分键存储**（折叠外屏 / 展开竖持 / 展开横持，
/// 见 `PlayerControlsLayout.Shape`）。用户的三种形态可能排过三套不同布局，
/// 只迁移一份会让另外两个形态升级后照样塌。
///
/// ## 为什么必须幂等
///
/// 用户可能从任意旧版本升上来，「版本号变了就迁」这种一次性判断不可靠
/// （跨版本升级会跳过中间版本）。这里用**状态判据 + marker 键**：
///   · 只有在集合仍是默认值、且槽位里存在超出默认的控件时才动手；
///   · 动手前检查 marker，做过就不再写。
/// 于是连续启动两次，第二次不写盘。
public enum PlayerControlSurfacingMigration {
    /// marker 键。做过迁移就记一笔，任何形态都共用它——
    /// 因为迁移是一次性的「升级时刻」动作，不是每形态各一次。
    public static let markerKey = "playerControlsSurfacing.migrated.v1"

    /// 一次迁移计算的结果。
    public struct Outcome: Equatable, Sendable {
        /// 该形态是否该写盘（false = 不需要动，保持原样）。
        public let changed: Bool
        /// 迁移后的 watchSurfaced（`changed == false` 时与入参相同）。
        public let watchSurfaced: [String]
        /// 迁移后的 fullSurfaced。
        public let fullSurfaced: [String]
        public init(changed: Bool, watchSurfaced: [String], fullSurfaced: [String]) {
            self.changed = changed
            self.watchSurfaced = watchSurfaced
            self.fullSurfaced = fullSurfaced
        }
    }

    /// 算一个形态要不要迁移、迁成什么。
    ///
    /// - Parameters:
    ///   - topSlots: 该形态顶栏槽位的 rawValue（`nil` = 空槽）。**决定「用户原来看得见什么」**。
    ///   - watchSurfaced: 该形态当前的观看页集合。
    ///   - fullSurfaced: 该形态当前的全屏集合。
    ///   - defaultWatch: 默认观看页集合（用来判断「用户没改过」）。
    ///   - defaultFull: 默认全屏集合。
    ///   - alreadyMigrated: marker 是否已存在。
    /// - Returns: 该形态的处理结果。
    ///
    /// 判据（三条同时成立才动手）：
    ///   1. 还没迁移过（marker 不存在）；
    ///   2. 两个集合**都**还是默认值（用户没自己勾过任何东西）；
    ///   3. 顶栏里存在**不在默认观看页集合里**的控件（说明这些是「靠槽位才看得见」的）。
    ///
    /// 第 2 条是关键：若用户已经手动勾过，说明他理解这套机制，
    /// 迁移会**覆盖他的选择**。这时宁可不动 —— 他自己勾的东西自己认。
    public static func plan(
        topSlots: [String?],
        watchSurfaced: [String],
        fullSurfaced: [String],
        defaultWatch: [String],
        defaultFull: [String],
        alreadyMigrated: Bool
    ) -> Outcome {
        let unchanged = Outcome(changed: false, watchSurfaced: watchSurfaced, fullSurfaced: fullSurfaced)
        guard !alreadyMigrated else { return unchanged }
        guard Set(watchSurfaced) == Set(defaultWatch), Set(fullSurfaced) == Set(defaultFull) else {
            return unchanged
        }

        // 槽位里真实可见的控件（去掉空槽）。
        let visible = topSlots.compactMap { $0 }
        // ⛔ 判据是「顶栏有没有可见控件」，**不是**「有没有超出默认的控件」。
        //
        // 曾写成 `guard !extras.isEmpty`（extras = 不在 defaultWatch 里的）。
        // 后果：standard 配置的顶栏正好就是默认那两颗 [airPlay, episodes]，
        // extras 为空 → 不迁移 → 但 `defaultFullSurfaced` 是**空数组**，
        // 于是这些用户升级后**全屏顶栏照样清空**。
        // 判据必须覆盖「顶栏有东西但全屏集合是空」这一整类，而不是只看差值。
        guard !visible.isEmpty else { return unchanged }

        // 迁移语义：用户升级前看得见的，升级后必须还看得见。
        //   · watchSurfaced ← 顶栏里全部可见控件（合并默认，保持顺序稳定）
        //   · fullSurfaced  ← 顶栏里全部可见控件
        // 为什么两份都写顶栏：原版播放器全屏时顶栏槽位与观看页是**同一份**
        // （`topSlots` 不随布局变化），用户在全屏里看见的就是这些。
        // 只写 watchSurfaced 会让全屏在接入后突然变空。
        var watch = defaultWatch
        for control in visible where !watch.contains(control) { watch.append(control) }
        var full = defaultFull
        for control in visible where !full.contains(control) { full.append(control) }

        // 结果必须真的不一样，否则不写盘（避免无意义 revision 抖动）。
        guard Set(watch) != Set(watchSurfaced) || Set(full) != Set(fullSurfaced) else { return unchanged }
        return Outcome(changed: true, watchSurfaced: watch, fullSurfaced: full)
    }
}
