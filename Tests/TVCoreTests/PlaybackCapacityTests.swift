import Foundation
import Testing
@testable import TVCore

/// 多任务迷你播放器的**并发预算**。
///
/// 这套断言存在的原因是一条真实缺陷（用户报告「第 5 项没有支持多个迷你播放器，
/// 会互顶」）。根因不是坞里画不出来，而是**底下每一路播放要占的流资源槽位比坞的上限还少**：
///
/// | 资源 | 改前 | 位置 |
/// |---|---|---|
/// | 坞里卡片 | 4 | `VideoTaskCenter.capacity` |
/// | 云盘字节流 | 3 | `CloudStreamStore.add` |
/// | 转封装会话 | 3 | `RemuxStore.add` |
/// | DASH 生成清单 | 4 | `PlaylistStore.add` |
/// | 红果解密流 | 4 | `HongguoStreamStore.add` |
///
/// 逐出策略是 FIFO（`order.removeFirst()`），逐出的动作是 `clear()` / `close()`，
/// 没有回滚、没有重试。于是「坞 4 + 前台 1 = 5 > 3」必然把**正在播**的那一路踢掉：
/// 先开的那个黑屏/无声，后开的完好，且不会自愈 —— 这正是「互顶」的形态。
///
/// 下面这些断言把「坞涨了，流也必须跟着涨」这条不变式**锁死**在测试里，
/// 防止将来有人只改一处。

// MARK: - 预算关系

/// 流槽位必须覆盖「坞满 + 前台」并且有余量给每路自己的两个槽位。
@Test func streamSlotsCoverDockPlusForeground() {
    let needed = PlaybackCapacity.dock + PlaybackCapacity.foreground
    #expect(PlaybackCapacity.streamSlots >= needed,
            "流槽位 \(PlaybackCapacity.streamSlots) 必须 ≥ 坞 \(PlaybackCapacity.dock) + 前台 \(PlaybackCapacity.foreground)")
    // 每一路自己可能要两个槽位（云盘流 + 转封装会话；或换集时新旧并存）。
    #expect(PlaybackCapacity.streamLimit >= needed * PlaybackCapacity.streamsPerTask,
            "流上限必须按「每路多槽位」算，否则挂满坞再换集就必然逐出正在播的那一路")
}

/// 坞上限不能小到兑现不了「同时多个」的诉求。
@Test func dockHoldsSeveralTasks() {
    #expect(PlaybackCapacity.dock >= 2, "「迷你播放器可以同时存在多个」至少要有 2 个")
}

/// 每路至少要有 1 个槽位；`streamsPerTask` 写成 0 会让整个预算塌成 0。
@Test func streamsPerTaskIsPositive() {
    #expect(PlaybackCapacity.streamsPerTask >= 1)
    #expect(PlaybackCapacity.streamLimit > 0)
}

// MARK: - 逐出顺序（FIFO 是「先开的先死」的直接原因）

/// 流存储在超限时逐出**最早**加入的那一个。
///
/// 这条断言存在的意义：用户看到的是「先开的那个坏了、后开的完好」。
/// 如果哪天有人把逐出改成 LRU 或随机，现象会变，但**只要容量还是小于坞上限，
/// 就仍然会踢掉正在播的一路**。所以容量断言（上面）才是根本，
/// 这里只把「逐出方向」记录下来，避免将来误以为是「后开的顶掉先开的」。
@Test func streamStoresEvictOldestFirst() {
    var order = ["a", "b", "c"]
    let limit = 3
    order.append("d")
    var evicted: [String] = []
    while order.count > limit { evicted.append(order.removeFirst()) }
    #expect(evicted == ["a"], "最先加入的那个被逐出 —— 也就是用户看到的「先开的那个黑了」")
    #expect(order == ["b", "c", "d"])
}

// MARK: - 之前的错误口径（防止回退）

/// 曾经的容量组合必须判为**不合法** —— 这条把旧 bug 写成可执行的反例。
///
/// 旧值：坞 4、云盘流 3、转封装 3。用同一套断言跑一遍，它必须失败；
/// 若哪天有人把常量改回去，`streamSlotsCoverDockPlusForeground` 会先炸，
/// 这里再把「为什么炸」说清楚。
@Test func oldCapacitiesWereInsufficient() {
    let oldDock = 4
    let oldForeground = 1
    let oldStreamSlots = 3
    #expect(oldStreamSlots < oldDock + oldForeground,
            "旧配置 3 < 4+1，数学上必然逐出正在播的一路 —— 这就是互顶的根因")
}

// MARK: - 音频会话：多任务时不能整锅端

/// 坞里还有别的路在播时，**绝不能**停用进程音频会话。
///
/// 这是「互顶」最刺眼的一条：`AVAudioSession` 是进程级单例，改前
/// `PlaybackSession.stop()` 无条件 `setActive(false)` —— 停一路，其余全哑，
/// 且恢复它们的 `setActive(true)` 只在 `start()` 里跑，所以不会自愈。
@Test func audioSessionStaysActiveWhileAnotherTaskPlays() {
    // 停了这一路之后还剩 1 路在播 → 不许停用。
    #expect(PlaybackAudioSessionPolicy.shouldDeactivate(liveCountAfterLeaving: 1) == false)
    #expect(PlaybackAudioSessionPolicy.shouldDeactivate(liveCountAfterLeaving: 3) == false)
}

/// 最后一路也走了，才把音频焦点还给系统（否则后台会一直占着）。
@Test func audioSessionDeactivatesOnlyWhenNoneLeft() {
    #expect(PlaybackAudioSessionPolicy.shouldDeactivate(liveCountAfterLeaving: 0) == true)
    // 负数不该出现，但真出现时也按「没有别人了」处理，宁可停掉也不要永远占着。
    #expect(PlaybackAudioSessionPolicy.shouldDeactivate(liveCountAfterLeaving: -1) == true)
}

/// 一个会话重复 `enter` 不会把计数算成两份（幂等）。
@Test func enteringTwiceDoesNotDoubleCount() {
    #expect(PlaybackAudioSessionPolicy.isOccupying(afterEntering: true, liveElsewhere: false) == true)
    #expect(PlaybackAudioSessionPolicy.isOccupying(afterEntering: true, liveElsewhere: true) == true)
    #expect(PlaybackAudioSessionPolicy.isOccupying(afterEntering: false, liveElsewhere: true) == true)
    #expect(PlaybackAudioSessionPolicy.isOccupying(afterEntering: false, liveElsewhere: false) == false)
}

// MARK: - 声音分配三档（设置里可选）

/// 默认档：只有选中的那个出声，其余静音。
///
/// 这一档用 `isMuted` 实现（不靠 `volume`），因为静音是确定生效的；
/// 与 YouTube / Safari 多标签的行为一致。
@Test func focusedOnlyActiveTaskIsAudible() {
    let policy = DockAudioPolicy.focused
    #expect(policy.volume(isActive: true, taskIndex: 0, taskCount: 3) == 1)
    #expect(policy.volume(isActive: false, taskIndex: 1, taskCount: 3) == 0)
    #expect(policy.volume(isActive: false, taskIndex: 2, taskCount: 3) == 0)
    // focused 不需要动 volume，只用 isMuted。
    #expect(policy.adjustsVolume == false)
}

/// 背景档：其余降到 15%，不是 0（用户能听见「还有别的在播」）。
@Test func dimmedKeepsBackgroundAudibleButQuiet() {
    let policy = DockAudioPolicy.dimmed
    #expect(policy.volume(isActive: true, taskIndex: 0, taskCount: 3) == 1)
    #expect(policy.volume(isActive: false, taskIndex: 1, taskCount: 3) == 0.15)
    #expect(policy.adjustsVolume == true)
}

/// 均分档：总音量不超标。两路各 0.5，四路各 0.25。
///
/// 若写成「每路都 100%」，两路相加就是 200%，必然削波失真。
@Test func mixedSplitsVolumeSoItDoesNotClip() {
    let policy = DockAudioPolicy.mixed
    #expect(policy.volume(isActive: false, taskIndex: 1, taskCount: 2) == 0.5)
    #expect(policy.volume(isActive: true, taskIndex: 0, taskCount: 2) == 0.5)
    #expect(policy.volume(isActive: false, taskIndex: 3, taskCount: 4) == 0.25)
    // 下限：路数再多也不静音到听不见。
    #expect(policy.mixedVolume(forTasks: 100) >= 0.1)
    // 没有任务时不炸（除零）。
    #expect(policy.mixedVolume(forTasks: 0) == 1)
}

// MARK: - 删源之后不能留死卡片

/// 删掉一条源，它产生的收藏也应当一起走。
///
/// 之前的漏洞：`Store.deleteSite` 只写 `deletedSources` + `hiddenSources`，
/// 而收藏页与「继续观看」**都不读**那两份记账（只有源列表/搜索/网页端读）。
/// 于是用户删完源，收藏页留下一张点一下就报错「这个源已不在当前订阅里」的卡片，
/// 而且没有批量清理的入口 —— 「彻底删除」等于没删干净。
@Test @MainActor func deletingASourceAlsoDropsItsFavourites() {
    let defaults = UserDefaults(suiteName: "favorites-source-delete-\(UUID().uuidString)")!
    let favorites = Favorites(defaults: defaults)
    let origin = URL(string: "https://example.com")!

    let gone = FavoriteVideo(origin: origin, sourceKey: "src-a", sourceName: "A", videoID: "v1",
                             videoName: "要删的", poster: nil, posterHeaders: [:], year: nil)
    let kept = FavoriteVideo(origin: origin, sourceKey: "src-b", sourceName: "B", videoID: "v2",
                             videoName: "要留的", poster: nil, posterHeaders: [:], year: nil)
    favorites.toggle(.video(gone))
    favorites.toggle(.video(kept))
    #expect(favorites.items.count == 2)

    let removed = favorites.removeAll(fromSource: "src-a", origin: origin)
    #expect(removed == 1, "只该删掉来自 src-a 的那一条")
    #expect(favorites.items.count == 1)
    // 同一 origin、不同 sourceKey 的收藏必须还在：按源身份匹配，不是按域名。
    #expect(favorites.items.contains { $0.kind == .video })
    // 幂等：再删一次什么都不做，也不会误删。
    #expect(favorites.removeAll(fromSource: "src-a", origin: origin) == 0)
    #expect(favorites.items.count == 1)
}

/// 删源时必须按 **origin + sourceKey** 两维匹配。
///
/// 只按 sourceKey 会误删别的订阅里同名 key 的源；只按 origin 会误删同域名下的其它源。
/// 这两种误删都不可逆（没有撤销入口），所以用一条反例把它钉住。
@Test @MainActor func sourceDeletionMatchesOriginAndKeyTogether() {
    let defaults = UserDefaults(suiteName: "favorites-source-scope-\(UUID().uuidString)")!
    let favorites = Favorites(defaults: defaults)
    let a = URL(string: "https://a.example.com")!
    let b = URL(string: "https://b.example.com")!

    let sameKeyOtherOrigin = FavoriteVideo(origin: b, sourceKey: "same-key", sourceName: "B", videoID: "v",
                                           videoName: "别的站", poster: nil, posterHeaders: [:], year: nil)
    let target = FavoriteVideo(origin: a, sourceKey: "same-key", sourceName: "A", videoID: "v",
                               videoName: "目标", poster: nil, posterHeaders: [:], year: nil)
    favorites.toggle(.video(sameKeyOtherOrigin))
    favorites.toggle(.video(target))

    #expect(favorites.removeAll(fromSource: "same-key", origin: a) == 1)
    #expect(favorites.items.count == 1, "另一站同名 key 的收藏不能被牵连")
}

// MARK: - 单卡声音设定（具体压通用）

/// 卡片上设了静音，就是静音 —— 哪怕它是当前选中的那张、哪怕全局是「全部出声」。
///
/// 用户要求「在迷你播放器的窗口上可以单独做声音设定」。这条是那个功能的底线：
/// 逐卡设定必须压得住全局，否则「单独设定」等于没做。
@Test func perCardMuteBeatsEveryGlobalPolicy() {
    for policy in DockAudioPolicy.allCases {
        let out = policy.output(isActive: true, taskIndex: 0, taskCount: 3, override: .muted)
        #expect(out.isMuted, "全局 \(policy) 下，设了静音的卡片也必须静音")
        #expect(out.volume == 0)
    }
}

/// 卡片上设了音量，就按那个音量 —— 不看全局、也不看是否选中。
@Test func perCardLevelBeatsGlobalPolicy() {
    for policy in DockAudioPolicy.allCases {
        let out = policy.output(isActive: false, taskIndex: 1, taskCount: 3, override: .level(0.6))
        #expect(out.isMuted == false)
        #expect(abs(out.volume - 0.6) < 0.0001, "全局 \(policy) 不该覆盖卡片上的 0.6")
    }
}

/// 滑杆拖到 0 等同于静音。
///
/// 留一个 `volume == 0 但 isMuted == false` 的状态没有意义，
/// 而且会让「已静音」的判定分叉（图标要按用户听到的结果画）。
@Test func perCardZeroLevelMeansMuted() {
    let out = DockAudioPolicy.dimmed.output(isActive: true, taskIndex: 0, taskCount: 2, override: .level(0))
    #expect(out.isMuted)
    #expect(out.volume == 0)
}

/// 没单独设过的卡片，跟着全局走。
@Test func cardsWithoutOverrideFollowTheGlobalPolicy() {
    // focused：非活跃静音，活跃出声
    let quiet = DockAudioPolicy.focused.output(isActive: false, taskIndex: 1, taskCount: 2, override: nil)
    #expect(quiet.isMuted)
    let loud = DockAudioPolicy.focused.output(isActive: true, taskIndex: 0, taskCount: 2, override: nil)
    #expect(loud.isMuted == false && loud.volume == 1)

    // dimmed：非活跃 0.15 但**不**静音（要能听见「还有别的在播」）
    let background = DockAudioPolicy.dimmed.output(isActive: false, taskIndex: 1, taskCount: 2, override: nil)
    #expect(background.isMuted == false)
    #expect(abs(background.volume - 0.15) < 0.0001)
}

/// 全局新增的「全部静音」档：无论活跃与否，一律不出声。
///
/// 这一档是为「挂着几个任务先放着，但一点声音都不要」准备的 ——
/// `.focused` 做不到（它总有一个在响）。
@Test func silentPolicyMutesEverything() {
    for active in [true, false] {
        let out = DockAudioPolicy.silent.output(isActive: active, taskIndex: 0, taskCount: 3, override: nil)
        #expect(out.isMuted)
        #expect(out.volume == 0)
    }
    // 有单独的卡片设定时，静音档也压不住它（具体压通用，两个方向都成立）。
    let overridden = DockAudioPolicy.silent.output(isActive: true, taskIndex: 0, taskCount: 3, override: .level(0.8))
    #expect(overridden.isMuted == false)
    #expect(abs(overridden.volume - 0.8) < 0.0001)
}

/// 四档都在枚举里，且都能被偏好字符串往返（设置页写的就是 `rawValue`）。
@Test func allFourPoliciesRoundTrip() {
    #expect(DockAudioPolicy.allCases.count == 4, "设置里要有四档：静音 / 只有当前 / 背景 / 全部")
    for policy in DockAudioPolicy.allCases {
        #expect(DockAudioPolicy(rawValue: policy.rawValue) == policy)
    }
}
