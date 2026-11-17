//
//  VideoTasks.swift
//  映匣 / Mi3s
//
//  「多任务播放」—— 应用内可以同时挂着**多个**迷你播放器。
//
//  为什么不能继续只用一个 `store.playing`
//  --------------------------------
//  上游（以及本仓此前的二开）把「在播的那一集」写成一个单值 `store.playing`，配一个
//  单槽会话 `activeSession`。那套结构只能表达「一集在前台播、缩成小窗后仍只有它」。
//  用户这次的要求是另一件事：
//
//    · 长按海报「直接迷你播放器打开播放」，并且**不影响已有的已打开迷你播放器**；
//    · 迷你播放器可以同时存在多个，随时选择回到哪一个。
//
//  单值状态在结构上无法表达「同时两集在跑」，所以这里引入 `VideoTaskCenter`：
//  每个迷你播放器 = 一个 `VideoTask`（自己的 `PlaybackSession`、自己的频道，以及
//  「点一下回到那一集的选集页」所需的视频/源句柄）。
//
//  与 `store.playing` 的分工（**这条不搞清楚会互相踩**）
//  --------------------------------
//  · `store.playing` / `store.playbackSession(for:)` 仍然是**前台**那一集（观看页、
//    全屏播放器）。前台只能有一个，这是 iOS 的呈现现实。
//  · `VideoTaskCenter.tasks` 是**坞里**的那些。坞里可以有很多个。
//  · 两者互斥：一集要么在前台、要么在坞里。`promote` 把坞里的挪到前台，
//    `dock` 把前台的挪进坞里 —— 都只在各自那一侧增删，绝不两边同时存在，
//    否则返回时会出现「同一集被停两次」或「同一集被恢复成两集」。
//
//  音频
//  --------------------------------
//  多个 `AVPlayer` 同时出画面是允许的，但**同时出声音是噪音**。坞里只有正在被操作的
//  那一个（`activeTaskID`，默认最近加入的）出声，其余一律 `isMuted = true`。
//  用户点了别的卡片，它就变成出声的那一个。
//

import AVKit
import SwiftUI
import TVCore

// MARK: - 一次播放任务

/// 坞里的一个迷你播放器：一集正在播的视频，连同「回到它」所需的全部句柄。
@MainActor @Observable final class VideoTask: Identifiable {
    let id = UUID()
    /// 正在播的这一集。
    private(set) var channel: Channel
    /// 它自己的播放会话。坞里的任务**不走** `store.playbackSession(for:)`：
    /// 那个单槽是前台专用的，混用会互相顶掉。
    let session: PlaybackSession
    /// 点卡片回到选集页要用的视频与源。云文件 / 直播这类没有详情页的留空，
    /// 点卡片时退回全屏播放器。
    let video: Video?
    let client: CatalogClient?
    /// 这一路自己的「当前作品」。
    ///
    /// ⛔ 必须自带，不能读 `store.playbackCatalog`。
    ///
    /// 那个是 **Store 上的单值**：坞里再起播第二部剧时 `remember()` 会把它整个覆盖掉。
    /// 于是第一部剧那张卡片的自动连播（`nextEpisode(after:)` → `catalog(for:)` 按 scope
    /// 比对返回 nil）就再也找不到下一集 —— 表现为「坞里只有一个任务时能自动连播，
    /// 挂上第二个之后第一个就停在最后一集不动了」。
    ///
    /// 这也是「互顶」的一种：不是画面被抢，是**功能被抢**。
    /// 自动连播换了下一集时随之更新（见 `move(to:episode:)`）。
    private(set) var catalog: PlaybackCatalog?
    /// 云文件目录（只有从「文件」页起播的任务才有）。
    ///
    /// ⛔ 必须随任务携带，不能读 `store.filesFolder` —— 那是单值，坞里同时播两个
    /// 不同目录里的文件时，它只指向最后开始的那一个，另一个的「下一集」就会算不出来
    /// （或算到别人的目录里去）。`Store.file(_:from:in:)` 有三重比对兜底，
    /// 拿错目录只会返回 nil，不会串片。
    private(set) var filesFolder: CloudFilesFolder?
    /// **这一张卡片自己的声音设定**；nil = 跟随设置里的全局档位。
    ///
    /// 用户要求「在迷你播放器的窗口上可以单独做声音设定」：坞里挂着几个任务时，
    /// 可能只想要其中一个大声、另一个彻底静音、第三个跟全局走。
    /// 全局那三档（静音/只有当前/背景/均分）是「一把尺子」，做不到逐卡控制。
    ///
    /// 存成可选而不是给个默认值：**「没设过」与「设成跟随」是两件事** ——
    /// 用户没动过这一张时，改全局设置应当立刻生效；一旦他在卡片上动过，
    /// 就不该被全局设置覆盖。
    var audioOverride: DockTaskAudio?
    /// 加进坞的时刻，用来排序（新的在前）。
    let createdAt = Date()

    init(channel: Channel, session: PlaybackSession, video: Video?, client: CatalogClient?,
         catalog: PlaybackCatalog? = nil, filesFolder: CloudFilesFolder? = nil) {
        self.channel = channel
        self.session = session
        self.video = video
        self.client = client
        self.catalog = catalog
        self.filesFolder = filesFolder
    }

    /// 自动连播换了下一集：频道与作品目录一起前进，会话不变（同一个 `AVPlayer`，只换 item）。
    ///
    /// `catalog` 也要更新：跨集后 `scope` 已变（`PlaybackHistoryContext.id` 按集算），
    /// 不更新就会拿旧 scope 去比对，`nextEpisode` 依然返回 nil。
    func move(to channel: Channel, catalog: PlaybackCatalog? = nil) {
        self.channel = channel
        if let catalog { self.catalog = catalog }
    }

    /// 卡片第一行：作品名。
    var title: String { channel.historyContext?.videoName ?? channel.name }
    /// 卡片第二行：集名；单集片与作品同名时留空，免得两行一模一样。
    var subtitle: String {
        guard let context = channel.historyContext else { return "" }
        return context.episodeName == context.videoName ? "" : context.episodeName
    }

    /// 从**本任务自己的**作品目录算下一集。
    ///
    /// 与 `Store.nextEpisode(after:)` 的差别只有一处：那个读 Store 上的单值
    /// `playbackCatalog`，坞里存在第二个任务时它已被覆盖，`catalog(for:)` 按 scope
    /// 比对会返回 nil，于是这一路永远没有下一集。这里读任务自带的目录，彼此独立。
    var nextEpisode: Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog?.playlist.next(after: context)
    }

    /// 这一路在云文件目录里的下一集（`offset` = ±1）。
    ///
    /// 目录由任务自己带着 —— 坞里两个不同目录的文件各算各的，不会串。
    /// 这不是个复制的清单遍历：三重比对（`drive.key` / `folder.id` / 文件名都在同一个
    /// context 里）保证拿错目录只会返回 nil，绝不会播到别的目录里的片子。
    func cloudFileStep(_ offset: Int) -> Channel? {
        guard let context = channel.historyContext, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        let file = folder.files[index + offset]
        return CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name,
                                  subtitles: folder.subtitles)
    }

    /// 一次播放的作品目录 scope（与 `PlaybackHistoryContext.id` 同一算法）。
    ///
    /// 必须与 `Channel.historyContext.id` 逐字相同，否则 `playlist.next(after:)`
    /// 找不到当前集、`catalog(for:)` 也按 scope 比对失败。
    static func scope(for channel: Channel, video: Video, client: CatalogClient) -> String {
        EpisodeSkipSettings.scope(origin: client.origin, source: client.site.sourceKey, video: video.id)
    }

    /// 两个任务是不是「同一部剧的同一集」。
    ///
    /// 按 `historyContext`（作品 scope + 集 id）判，**不按 URL**：换线路后同一集的
    /// `url` 会变，但作品与集都没变 —— 那种情况该就地激活，不该留两张卡。
    /// 云文件 / 直播 / 手填地址没有 `historyContext`，只能退回按 `Channel` 整体比较
    /// （它们的 URL 就是身份，同一地址重复挂确实应该合并）。
    func isSameEpisode(as other: VideoTask) -> Bool {
        if let mine = channel.historyContext, let theirs = other.channel.historyContext {
            return mine.id == theirs.id && mine.episodeID == theirs.episodeID
        }
        return channel == other.channel
    }

    var isPaused: Bool { session.paused }
    var isLoading: Bool { session.loading }
    /// 这个窗口**当前摆在哪**（相对右下角锚点）。
    ///
    /// 由摆放层在拖动/缩放结束时写回 —— 坞自己不知道卡片位置（那是视图层的事），
    /// 但存档时必须知道，否则「记住坐标」无从谈起。
    var lastKnownOffset: CGSize = .zero

    /// 它是**因为超出解码预算**被暂停的，而不是用户按的暂停。
    ///
    /// ⛔ 没有这一笔，20 个窗就是「点一下切过去，停在一帧上」：
    ///    `applyMuting` 把超预算的 `rate = 0`，用户再点回来时它在预算内了，
    ///    但**没有人会替他把播放续上**（他并没按过暂停，可 `rate` 已经是 0）。
    ///    有了它，回到预算内就续播；用户自己按的暂停不会被误续。
    var parkedWhilePlaying = false

    /// 海报地址（管理器列表的缩略图）。云文件/直播没有作品，返回 nil 由调用方兜底。
    var posterURL: URL? { video?.poster }
    var posterHeaders: [String: String] { video?.posterHeaders ?? [:] }

    /// 卡片画面比例取**实际画面**：唯一真源仍是 `presentationSize`，
    /// 但必须读 `session.presentationAspect` 这个**可观察镜像**。
    ///
    /// ⛔ 原来直接读 `session.player.currentItem?.presentationSize` —— 那是普通属性，
    /// 不是 SwiftUI 可观察源：源比例就绪后卡片**不会重算**，一直按回退值 16/9 排版。
    /// 竖屏源（9:16）于是被排成扁条，画面 `resizeAspect` 居中 ⇒ 左右留白，
    /// 正是用户报的「竖屏源小窗缩到最小右侧有白边」。
    /// 镜像由 `PlaybackSession.updateSkipping(_:)` 每采样 tick 同步。
    var aspectRatio: CGFloat {
        let r = DockCardAspect.resolved(session.presentationAspect)
        #if DEBUG
        // 探针（真机判据）：卡片实际拿去算高度用的比例，与它读到的镜像值。
        // #16 的缺陷形态是「取数方式两种」——`fraction` 读 @Observable（会刷新），
        // `aspectRatio` 过去读 `AVPlayerItem.presentationSize`（普通属性、不刷新），
        // 于是竖源永远停在回退 16/9、卡片按横比例量高，右侧留白。
        // 真机验收：竖源（nat=1080x1920）时 resolved 必须 ≈0.5625 而不是 1.7778；
        // 且换集期间不得跳回 fallback（`from()` 返回 nil 时保留上次好值）。
        oneSkinLog("DOCKASPECT mirrored=\(String(format: "%.4f", session.presentationAspect)) "
            + "resolved=\(String(format: "%.4f", r)) fallback=\(r == DockCardAspect.fallback)")
        #endif
        return r
    }

    /// 播放进度（0…1），卡片底边那条细线用。
    var fraction: Double {
        guard session.duration > 0 else { return 0 }
        return min(max(session.position / session.duration, 0), 1)
    }
}

// MARK: - 坞

/// 所有迷你播放器。作为 `Store` 主类的一个 stored property 存在
/// （Swift 的 extension 不能加存储属性，见项目铁律第一条）。
@MainActor @Observable final class VideoTaskCenter {
    /// 坞里的播放器，新的在前。
    private(set) var tasks: [VideoTask] = []
    /// 正在出声的那一个。`nil` 表示坞是空的。
    private(set) var activeTaskID: UUID?

    /// 坞里最多挂几个。
    ///
    /// 取值统一到 `PlaybackCapacity.dock`（Sources/TVCore/PlaybackCapacity.swift）。
    /// 原先是这里的字面量 4，而底层各路流存储各自写死 3/4 个槽位，两边没有任何联动 ——
    /// 「坞 4 + 前台 1 = 5」必然逐出**正在播**的那一路，正是用户报的「互顶」。
    /// 现在上限只有一个真源，流槽位由它推导（= (坞 + 前台) × 2）。
    static var capacity: Int { PlaybackCapacity.dock }

    var hasTasks: Bool { !tasks.isEmpty }
    var activeTask: VideoTask? { tasks.first { $0.id == activeTaskID } }

    // MARK: 收起与管理器
    //
    // 用户报的现象：「进入播放页迷你小窗就消失了，误触也没了」。
    //
    // 根因不是「消失」本身（进观看页必须让位，否则两层视频叠在一起），
    // 而是**隐藏之后没有任何入口能把它叫回来**：卡片 opacity 归零之后，
    // 屏幕上再没有东西能证明「这里还有几集在播」。
    //
    // 现在拆成两件事（判定在 `TVCore/DockVisibility.swift`）：
    //   · `collapsed` / 被前台盖住 → 不画**卡片**
    //   · 只要有任务 → 永远画**管理入口**（收起/展开 + 打开管理器）
    /// 用户手动把坞收起了（不是被前台盖住）。
    var collapsed = false

    /// 坞管理器（悬浮列表）是否打开。
    var showsManager = false

    /// 当前的可见性判定输入。
    var visibilityState: DockVisibility.State {
        DockVisibility.State(taskCount: tasks.count, coveredByForeground: false, collapsed: collapsed)
    }

    /// 卡片画不画。被前台盖住那一项由 `RootView` 传进来（它才知道观看页在不在）。
    func showsCards(coveredByForeground: Bool) -> Bool {
        DockVisibility.showsCards(.init(taskCount: tasks.count,
                                        coveredByForeground: coveredByForeground,
                                        collapsed: collapsed))
    }

    func showsHandle(coveredByForeground: Bool) -> Bool {
        DockVisibility.showsHandle(.init(taskCount: tasks.count,
                                         coveredByForeground: coveredByForeground,
                                         collapsed: collapsed))
    }

    func badge(coveredByForeground: Bool) -> String? {
        DockVisibility.badge(.init(taskCount: tasks.count,
                                   coveredByForeground: coveredByForeground,
                                   collapsed: collapsed))
    }

    func handleShowsHiddenContent(coveredByForeground: Bool) -> Bool {
        DockVisibility.handleShowsHiddenContent(.init(taskCount: tasks.count,
                                                      coveredByForeground: coveredByForeground,
                                                      collapsed: collapsed))
    }

    /// 收起 / 展开。收起时卡片不画，入口仍在。
    func toggleCollapsed() { collapsed.toggle() }

    /// 请求把坞里所有卡片的位置与缩放复位。
    ///
    /// ⛔ 为什么需要「复位」这个动作，而不只是钳位：
    ///    钳位只约束**之后**的拖动。已经拖出去的卡片，它的偏移还存在
    ///    `perCardOffset` 里，重启前一直是个坏值。而且用户也可能把卡片
    ///    缩到极小（0.6）再也点不准。给一个「一键归位」比任何边界算法都可靠 ——
    ///    它是**用户可执行的自救**，不依赖我们猜得对。
    var resetRequest = 0

    func resetCardPlacement() { resetRequest &+= 1 }

    /// 最近一次因为「超过容量」被逐出的标题。
    ///
    /// UI 读它弹一句「已收起《X》—— 同时最多 8 个」。
    /// ⛔ 必须让用户知道：静默消失与「自己弄丢了」在体感上没有区别。
    var lastEvictedTitle: String?

    // MARK: 上次的窗口（持久化，跨启动一键恢复）

    /// 上次退出前开着的那些小窗。恢复过一次就清空，避免反复弹。
    ///
    /// ⛔ **不自动恢复**。用户要的是「可以一键恢复」——
    ///    自动恢复会在每次冷启动都起 4–8 路流，既费流量又吵；
    ///    一键恢复把决定权留给用户，也符合「坞是临时工作区」的直觉。
    private(set) var resumable: [DockSessionSnapshot] = []

    /// 窗口摆放（位置/缩放）—— 与播放列表分开存，因为它的变化频率高得多。
    private static let dockStorageKey = "dockTasks.snapshot"
    /// 窗口摆放（按 episode scope 索引），拖动/缩放结束时写。
    private static let placementKey = "dockTasks.placement"

    /// 扫一遍当前坞，生成快照并落盘。坞的内容或进度变化时调用（节流在外面做）。
    func saveSnapshot() {
        let items: [DockSessionSnapshot] = tasks.compactMap { task -> DockSessionSnapshot? in
            guard let context = task.channel.historyContext else { return nil }
            let placement = Self.loadPlacement()[Self.placementID(context)]
            return DockSessionSnapshot(
                context: context,
                position: task.session.position,
                duration: task.session.duration,
                scale: placement?.scale ?? 1,
                offset: placement?.offset ?? task.lastKnownOffset,
                savedAt: Date())
        }
        if let data = DockSessionStore.encode(items) {
            UserDefaults.standard.set(data, forKey: Self.dockStorageKey)
        }
    }

    /// 读上次的快照（App 启动时调一次，供管理器显示「恢复上次」）。
    func loadResumable() {
        guard let data = UserDefaults.standard.data(forKey: Self.dockStorageKey) else {
            resumable = []; return
        }
        let saved = DockSessionStore.decode(data)
        // 已经在坞里的不再算「可恢复」。
        let live = Set(tasks.compactMap { t in
            t.channel.historyContext.map { $0.id + "|" + $0.episodeID }
        })
        resumable = saved.filter { !live.contains($0.context.id + "|" + $0.context.episodeID) }
    }

    /// 恢复完成后清掉，避免同一个「恢复」动作被点两次。
    func consumeResumable() { resumable = [] }

    // MARK: 从管理器把窗口「拖出来」

    /// 管理器里一次拖放请求：把某一集摆到屏幕上的某一点。
    ///
    /// ## 为什么是「摆位」而不是「新建」
    ///
    /// 坞里的卡片**一直都在**（管理器只是同一批任务的列表视图，
    /// `showsManager` 只控制那个浮层画不画）。所以「拖出来」不是新建一个窗口，
    /// 而是**把这扇已经存在的窗挪到手指松开的位置** ——
    /// 用户说的「拖拽出来的就是真身」，落点就在这里：
    /// 同一个 `VideoTask`、同一个 `AVPlayer`，不重新解析、不重新缓冲。
    struct DropRequest: Equatable {
        public let id: UUID
        /// 落点（相对坞容器的坐标）。`nil` = 位置未知，退回当前存档坐标。
        public let point: CGPoint?
    }

    /// 待处理的拖放请求。坞视图消费后清空。
    var dropRequest: DropRequest?

    /// 把某一集摆到 `point`。
    func requestDrop(_ id: UUID, at point: CGPoint?) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        dropRequest = DropRequest(id: id, point: point)
        // 拖出来之后它就是用户在主操作的那一个。
        activate(id)
    }

    func consumeDrop() { dropRequest = nil }

    /// 刚落下的位置（视图层消费后清掉）。键是任务 id。
    ///
    /// ⛔ 必须经过一次「中心 → 视图」的传递：位置住在视图的 `@State` 里
    ///    （拖动时不该让整坞失效），中心不能直接写它。
    var pendingDropOffset: [UUID: CGSize] = [:]

    // MARK: 排布模式与图层顺序

    /// 当前排布方式：自由摆放 / 锁定整理。
    ///
    /// 用户要求：「多个窗口需要支持平铺处理」，同时「锁定整理可以保留，
    /// 得把视窗统一」—— 锁定态下所有卡同一个尺寸、位置由 `DockLayout` 算，
    /// 不接受拖动（拖也拖不动，那才叫锁定）。
    var layoutMode: DockLayoutMode = .free

    /// 锁定态：位置与尺寸都由网格决定。
    var isLayoutLocked: Bool { layoutMode == .tiled }

    func toggleLayoutLock() {
        layoutMode = isLayoutLocked ? .free : .tiled
    }

    /// 「整理一次」请求。
    ///
    /// 与锁定整理的分工（用户 2026-11-17 明确要求两个都要）：
    ///   · **单次整理** —— 把多张卡摆成互不重叠的平铺网格、尺寸统一成格子大小，
    ///     摆完**立刻回到自由模式**，用户可以接着拖、接着捏。整理是动作，不是状态；
    ///   · **锁定整理** —— 同一个网格，但位置与尺寸一直由布局决定，随手拖动无效。
    ///
    /// 网格的几何只有坞视图知道（容器尺寸、安全区），所以这里只发一个计数，
    /// 由 `VideoTaskDock` 消费（`onChange(of: tidyRequest)`）。
    var tidyRequest = 0
    func tidy() { tidyRequest &+= 1 }

    /// 把某张卡提到最前（z-order 最高）。
    ///
    /// 坞是按 `tasks` 数组顺序渲染的，**越靠前越在上层**（`zIndex` 由倒序给出，
    /// 见 `VideoTaskDock`）。所以「提到最前」= 挪到数组首位。
    ///
    /// ⛔ 这条以前只从管理器的「上移一层」按钮进，用户的原话是
    ///    「调整图层顺序应该单击即响应，点击则挪到最前，而不是在面板里复杂操作」。
    ///    现在轻点卡片走的是 `activate`，它内部就是这一步 —— 没有中间步骤。
    func bringToFront(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), i != 0 else { return }
        tasks.insert(tasks.remove(at: i), at: 0)
        activeTaskID = id
        saveSnapshot()
    }

    /// 把某张卡往后压一层（z-order 降低）。
    ///
    /// 供「图层顺序」面板用：逐层下调比「一步到底」更可控。
    func sendBackward(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), i < tasks.count - 1 else { return }
        let t = tasks.remove(at: i)
        tasks.insert(t, at: i + 1)
        saveSnapshot()
    }

    /// 把某张卡挪到指定层（0 = 最前）。
    ///
    /// 管理器里拖动行排序时用这个 —— 一次就到位，不逐层挪。
    func moveToLayer(_ id: UUID, _ index: Int) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(index, 0), tasks.count - 1)
        guard i != clamped else { return }
        let t = tasks.remove(at: i)
        tasks.insert(t, at: clamped)
        if clamped == 0 { activeTaskID = id }
        saveSnapshot()
    }

    /// 一键恢复上次的所有小窗。
    ///
    /// 每条快照都走**和「长按海报播小窗」完全一样**的路径（`start(video:client:)`）：
    /// 重新解析 → 建会话 → 入坞。所以这里不重复写解析逻辑，只负责
    /// ① 把作品拿回来 ② 把进度与窗口坐标贴回去。
    ///
    /// ⛔ 逐条 `await` 而不是并发：8 路同时解析会把源站的并发限制打满，
    ///    而且用户看到的是「一个一个回来」，比「一起转圈」更可信。
    @MainActor
    func restore(_ items: [DockSessionSnapshot], store: Store) async {
        for item in items {
            let entry = PlaybackHistoryEntry(context: item.context,
                                             position: item.position,
                                             duration: item.duration,
                                             updatedAt: item.savedAt,
                                             environment: nil)
            guard let client = store.historyClient(entry) else { continue }
            let video = entry.listVideo
            await start(video: video, client: client, store: store)
            // 起播后把进度与坐标贴回去。
            if let task = tasks.first(where: { t in
                guard let c = t.channel.historyContext else { return false }
                return c.id == item.context.id && c.episodeID == item.context.episodeID
            }) {
                if item.position > 0 { task.session.seek(to: item.position) }
                task.lastKnownOffset = item.offset
                perCardScaleHint[task.id] = CGFloat(item.scale)
            }
        }
        consumeResumable()
    }

    /// 恢复时要用的缩放值（视图层读它作为初值，避免依赖跨层状态）。
    var perCardScaleHint: [UUID: CGFloat] = [:]

    // MARK: 窗口摆放（按 episode scope 存）

    /// 摆放记录的 id：同一集换了线路也算同一个窗口。
    private static func placementID(_ context: PlaybackHistoryContext) -> String {
        context.id + "|" + context.episodeID
    }

    struct Placement: Codable {
        var scale: Double
        var offsetX: Double
        var offsetY: Double
        var offset: CGSize { CGSize(width: offsetX, height: offsetY) }
    }

    static func loadPlacement() -> [String: Placement] {
        guard let data = UserDefaults.standard.data(forKey: placementKey),
              let map = try? JSONDecoder().decode([String: Placement].self, from: data) else { return [:] }
        return map
    }

    static func savePlacement(_ id: String, scale: CGFloat, offset: CGSize) {
        var map = loadPlacement()
        map[id] = Placement(scale: Double(scale), offsetX: Double(offset.width), offsetY: Double(offset.height))
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: placementKey)
        }
    }

    // MARK: 增删

    /// 放一个任务进坞。**不碰前台** —— 这是「不影响已有的已打开迷你播放器」的落点。
    @discardableResult
    func add(_ task: VideoTask) -> VideoTask {
        // 同一集已经在坞里：不重复挂，激活并返回。长按同一个海报两次很常见。
        //
        // ⛔ 去重键不是 `Channel == Channel`。那个比较含 `url`（`Channel.id` 就是
        // `group|name|url`），而**同一集换一条线路 url 就变了** —— 于是「第一集看的是
        // 高清线，换到流畅线再长按一次」会在坞里留下两张其实同一集的卡片。
        // 正确的键是「哪一部剧的哪一集」：`historyContext.id`（scope）+ `episodeID`。
        // 云文件 / 直播没有 `historyContext`，退回按 `Channel` 整体比较。
        if let existing = tasks.first(where: { $0.isSameEpisode(as: task) }) {
            activate(existing.id)
            task.session.stop()
            return existing
        }
        tasks.insert(task, at: 0)
        activate(task.id)
        if let evicted = trim() {
            lastEvictedTitle = evicted
        }
        return task
    }

    func remove(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: index)
        task.session.stop()
        if activeTaskID == id { activeTaskID = tasks.first?.id }
        applyMuting()
    }

    func removeAll() {
        for task in tasks { task.session.stop() }
        tasks.removeAll()
        activeTaskID = nil
    }

    /// 把**某一集**从坞里摘掉（若有）。
    ///
    /// 与 `removeAll()` 的区别：那个清空整个坞，这个只摘这一集，别的卡片不受影响。
    /// 供「退出键 = 彻底退出那个视频」用（`Store.quitPlayback`）——
    /// 用户点了退出，那一集就不该留在坞里继续播。
    func removeAll(of channel: Channel) {
        let doomed = tasks.filter { $0.channel == channel }
        guard !doomed.isEmpty else { return }
        for task in doomed {
            if activeTaskID == task.id { activeTaskID = nil }
            tasks.removeAll { $0.id == task.id }
            task.session.stop()
        }
        if activeTaskID == nil { activeTaskID = tasks.first?.id }
        applyMuting()
    }

    /// 点卡片：这一个开始出声，其余静音。
    func activate(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        activeTaskID = id
        // 提到队首：`applyMuting` 用 `prefix(decoding)` 决定谁在解码，
        // 不置顶的话「刚点的那一路」仍可能排在预算之外而拿不到解码。
        if index != 0 {
            tasks.insert(tasks.remove(at: index), at: 0)
            // 图层顺序也是用户摆出来的状态。以前只有 `bringToFront`（管理器按钮）会落快照，
            // 轻点换层不落 —— 于是重启后顺序回到旧样子，用户会以为「点了没记住」。
            saveSnapshot()
        }
        applyMuting()
    }

    /// 超过容量时逐出**最久没被切到**的那一个。
    ///
    /// ⛔ 原来这里是**静默**逐出：用户点了第 9 个小窗，最早那个无声消失，
    ///    他只会觉得「小窗自己没了」。现在逐出时把标题记下来，由调用方提示。
    ///    这是用户列出的「可能把迷你小窗弄丢的途径」之一 —— 丢可以，但必须说。
    @discardableResult
    private func trim() -> String? {
        var evicted: String?
        while tasks.count > Self.capacity {
            let dropped = tasks.removeLast()
            dropped.session.stop()
            evicted = dropped.title
        }
        if let active = activeTaskID, !tasks.contains(where: { $0.id == active }) {
            activeTaskID = tasks.first?.id
        }
        applyMuting()
        return evicted
    }

    /// 按设置里的策略分配声音（`DockAudioPolicy`）。
    ///
    /// 三种策略都在这里落地，**只有这一处**改音量/静音 —— 分散到各个调用点必然走散。
    ///
    /// `focused`（默认）用 `isMuted`：静音是确定生效的，不依赖 `volume`。
    /// `dimmed` / `mixed` 用 `volume`，同时确保非活跃的不被上一轮的 `isMuted` 卡住。
    /// 按「卡片自己的设定 → 全局档位」算出每一张该出的声，**只有这一处**改音量/静音。
    ///
    /// 分散到各个调用点必然走散 —— 之前就是这样：策略从「只有当前」切到「背景」时，
    /// 上一轮留下的 `isMuted` 没被还原，那几路会永远静音（用户改了设置却听不到变化）。
    /// 所以这里每轮都把 `isMuted` 与 `volume` **一起重算**，不依赖上一次的状态。
    ///
    /// 逐卡设定优先于全局：见 `DockAudioPolicy.output(isActive:taskIndex:taskCount:override:)`。
    func applyMuting() {
        let policy = DockAudioPolicy.current
        let count = tasks.count
        // 解码预算：`PlaybackCapacity.decoding`（按机型 4–8 路），其余**挂起**。
        //
        // ⛔ 2026-11-17：卡片上限涨到 20，但「解码 = 卡片」在 20 时**做不到** ——
        //    iOS 同时能开的视频解码会话有硬上限，超了不是卡，是有些窗永远黑屏。
        //    所以 20 张卡里只有最近点过的那 `decoding` 路在解，其余：
        //      · `rate = 0`（不再解码，省解码器与带宽）；
        //      · 画面层让出 `AVPlayer`（`DockPlayerLayer` 按 `suspended` 置 nil），
        //        卡片下露出海报 + 「已挂起」角标 —— 用户看到的是一部挂着的剧，不是黑玻璃。
        //
        // ⛔ 只暂停**正在播**的，不动本来就已经暂停的：
        //    用户手动暂停的那一路不该被我们「恢复」成播放。
        //    所以挂起时记一笔「它本来在播」，回到预算内再替用户续上。
        let decoding = DockDecodingBudget.decodeSet(order: tasks.map(\.id),
                                                    budget: PlaybackCapacity.decoding)
        // 前台增强要靠这个数决定让不让路（见 `EnhancementBudget`）。
        PlaybackLoad.shared.setDockDecoding(decoding.count)
        for (index, task) in tasks.enumerated() {
            let overBudget = !decoding.contains(task.id)
            if overBudget {
                if task.session.player.rate != 0 {
                    task.parkedWhilePlaying = true
                    task.session.player.rate = 0
                }
            } else if task.parkedWhilePlaying {
                // 回到预算内：用户刚点了它，就该接着放（而不是停在一帧上等他自己按播放）。
                task.parkedWhilePlaying = false
                task.session.player.play()
            }
            let output = policy.output(isActive: task.id == activeTaskID,
                                       taskIndex: index, taskCount: count,
                                       override: task.audioOverride)
            let player = task.session.player
            player.isMuted = output.isMuted
            // ⛔ 不要用 `player.volume` 做用户音量滑块。
            //
            // Apple 在 SDK 头文件 `AVPlayer.h` 里写得很直接：
            //   「iOS note: Do not use this property to implement a volume slider
            //     for media playback. … This property is most useful on iOS to control
            //     the volume of the AVPlayer relative to other audio output,
            //     not for volume control by end users.」
            // 而 `isMuted` 的注释是「Only affects audio muting for the player instance」——
            // 两条不同通道，这正是实测「静音生效、音量不生效」的原因。
            //
            // 真要按用户值改音量只能走 `AVAudioMix`：
            // `AVMutableAudioMixInputParameters.setVolume(_:at:)` 是**解码后的增益**，
            // 不受系统音量耦合影响。见 `DockTask.audioMix`。
            task.session.player.volume = 1
            task.session.applyAudioGain(output.volume)
        }
    }

    /// 单独设定某一张卡片的声音；`nil` = 恢复跟随全局档位。
    ///
    /// 改完立刻重算 —— 否则用户拖完滑杆要等下一次「切活跃卡片」才听得到变化。
    func setAudio(_ audio: DockTaskAudio?, for id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        task.audioOverride = audio
        applyMuting()
    }

    // MARK: 起播

    /// 直接以迷你播放器打开一部作品（长按海报的「迷你播放器播放」）。
    ///
    /// 与「进详情页再点播放」只差一点：**它不动前台**。前台可能正有一集在看，
    /// 这个新任务只在坞里起播，用户回到那一集时它是完好的。
    ///
    /// 起哪一集：看过就接上次那集，没看过就第一集 —— 与详情页「继续播放」同一取舍，
    /// 免得同一部剧两个入口从不同集开始。
    func start(video: Video, client: CatalogClient, store: Store) async {
        // ⛔ 列表页的海报只有 id / 名字 / 封面，`episodes` 一定是空数组 ——
        //    `vod_play_url` 只在 `ac=detail` 的响应里。原来直接拿它选集：
        //    `startingEpisode` 找不到任何一集 → 弹一句「没有可播放的剧集」→
        //    **迷你播放器永远起不来**。用户看到的就是「长按海报点小窗没反应」，
        //    而同一部剧点进详情页再播放是正常的（那条路会先取详情）。
        //    这里补上同一步：空选集就先向源要详情（走 MediaCache，点进过详情页时
        //    通常一次网络都不用发）。
        var video = video
        if video.episodes.isEmpty {
            guard let detail = try? await client.detail(video.id, cached: true),
                  !detail.episodes.isEmpty else {
                store.notice = L10n.text("This title has no episodes to play.")
                return
            }
            // 详情常常没有封面（`vod_pic` 只在列表里给），保留海报页那张。
            video = detail.keepingPoster(video.poster, headers: video.posterHeaders)
        }
        guard let episode = startingEpisode(video, client: client, store: store) else {
            store.notice = L10n.text("This title has no episodes to play.")
            return
        }
        do {
            let resolved = try await client.playback(episode)
            guard !Task.isCancelled else { return }
            let channel = store.catalogChannel(resolved, video: video, episode: episode, client: client)
            let session = PlaybackSession()
            // 坞卡片按**自己的宽度**限解码分辨率（480p/720p 两档就够）。
            // 卡片最宽 320pt、@3x ≈ 960px，所以永远不需要超过 1080p。
            // ⛔ 这不是可选的画质取舍：8 路同时解码时，单路解 4K 会直接把解码器拖死。
            session.preferredMaximumResolution = DockDecodeResolution.preferredMaximumResolution(
                forCardWidth: 320, scale: 3)
            session.history = store.playbackHistory
            session.skipDefaults = store.playbackDefaults
            session.player.isMuted = true
            // ⛔ 作品目录随任务携带，不读 `store.playbackCatalog`（那是单值，会被
            // 坞里后来起的另一部剧覆盖，见 `VideoTask.catalog` 的注释）。
            let catalog = PlaybackCatalog(video: video, client: client,
                                          scope: VideoTask.scope(for: channel, video: video, client: client))
            let task = add(VideoTask(channel: channel, session: session, video: video, client: client, catalog: catalog))
            // 已经在坞里（同一集挂过一次）：上面那次 `add` 已经把它激活，会话收掉了，这里不再起。
            guard task.session === session else { return }
            startCatalogPlayback(session, channel: channel, store: store)
            // 自动连播在坞里也照旧：换集只换频道，会话（同一个 AVPlayer）不变。
            //
            // ⛔ 下一集**从本任务自己的目录算**，不走 `store.nextEpisode` ——
            // 那条路依赖 Store 上的单值 `playbackCatalog` / `filesFolder`，坞里多任务时
            // 会被别的剧/别的目录覆盖，于是只有「坞里唯一一个任务」时才连播得动，
            // 这正是用户说的互顶（功能被抢，不是画面被抢）。
            session.onPlaybackEnded = { [weak store, weak session, weak task] in
                guard let store, let session, let task, store.autoPlayNext else { return }
                // 云文件目录：同一目录里的下一个文件，直接起播（不用向源解析地址）。
                if let nextFile = task.cloudFileStep(1) {
                    task.move(to: nextFile)
                    session.start(nextFile)
                    return
                }
                // 点播源：下一集要向源重新解析地址。
                // `client` 从**任务**取，不从闭包捕获时的参数取 —— 换源后任务上的
                // client 才是当前有效的那一个（`sourceReassignment` 会换掉它）。
                guard let video = task.video, let source = task.client, let next = task.nextEpisode else { return }
                Task { @MainActor in
                    guard let nextResolved = try? await source.playback(next) else { return }
                    let nextChannel = store.catalogChannel(nextResolved, video: video, episode: next, client: source)
                    task.move(to: nextChannel,
                              catalog: PlaybackCatalog(video: video, client: source,
                                                       scope: VideoTask.scope(for: nextChannel, video: video, client: source)))
                    session.start(nextChannel)
                }
            }
            applyMuting()
        } catch {
            guard !(error is CancellationError) else { return }
            Diagnostics.shared.failure("tasks", "dock play \(client.reportContext) episode=\(episode.flag)", error)
            store.error = L10n.text("Unable to play this title: %@", error.localizedDescription)
        }
    }

    /// 长按海报起播用哪一集：上次看到的那一集，否则第一集。
    private func startingEpisode(_ video: Video, client: CatalogClient, store: Store) -> Episode? {
        let scope = EpisodeSkipSettings.scope(origin: client.origin, source: client.site.sourceKey, video: video.id)
        let watched = store.visibleHistory.first { $0.context.id == scope && !$0.completed }
        if let watched, let episode = watched.context.episode(in: video.episodes) { return episode }
        return video.episodes.first
    }

    // MARK: 与前台之间搬家

    /// 前台那一集收进坞（观看页「返回上一层」/ 小窗键）。
    ///
    /// `session` 是前台正在用的那一个：**原样搬进坞**，不重建。重建会重新取流、
    /// 从零加载，用户看到的是「返回一下，进度条跳回开头」。
    @discardableResult
    func dock(channel: Channel, session: PlaybackSession, store: Store) -> VideoTask {
        // 作品目录随任务带走。`store.catalog(for:)` **按 scope 比对**，只在「它就是当前
        // 这一集的作品」时给得出东西 —— 正好是我们需要的。
        //
        // ⛔ 取不到就留空，**绝不回退到 `store.playbackCatalog`**：那个单值此刻可能
        // 属于坞里另一部剧（坞里起播第二部剧时 `remember()` 会覆盖它）。拿错目录的后果
        // 比没有目录严重得多 —— 这一路会在剧终时自动连播到**另一部剧**的下一集。
        let catalog = store.catalog(for: channel)
        return add(VideoTask(channel: channel, session: session,
                             video: catalog?.video, client: catalog?.client, catalog: catalog,
                             filesFolder: store.filesFolder))
    }

    /// 坞里的那一个回到前台，返回它的视频/源句柄；没有详情页的（云文件、直播）返回 nil，
    /// 调用方据此退回全屏播放器。
    ///
    /// 会话**原样交回**前台（`store.adoptSession`），不新建 —— 否则回到选集页会重新起播。
    @discardableResult
    func take(_ id: UUID, store: Store) -> (video: Video, client: CatalogClient)? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let task = tasks[index]
        tasks.remove(at: index)
        if activeTaskID == id { activeTaskID = tasks.first?.id }
        applyMuting()

        // ⛔ 摘掉坞期间挂上的自动连播回调，交给前台重新接。
        //
        // 坞里那段 `onPlaybackEnded` 是闭包捕获了**坞那一侧**的状态（`task` / `client`），
        // 它会在剧终时把 `task.move(to:)` 与 `session.start()` 又跑一遍 —— 而这一集此刻
        // 已经回到前台、由观看页的 `startCatalogPlayback` 管。两套回调同时挂着，
        // 集末会**各起一次**，表现为「最后两集来回跳」。
        // 观看页拿到会话后会自己 `startCatalogPlayback` 重绑这一组回调。
        task.session.onPlaybackEnded = nil
        // 回到前台就是唯一的那一路：静音与音量都要还原。
        // 只清 `isMuted` 不清 `volume` 的话，`.dimmed` / `.mixed` 策略下
        // 回到选集页的那一集音量会停在 0.15 或均分值（用户觉得「声音变小了」）。
        //
        // ⛔ 「卡片上单独设过静音」也必须在这里清掉。
        // 那是**坞里那张卡片**的设定，不是「这一集永久静音」——
        // 用户点回选集页是明确要去看它，结果发现没声音，只会认为播放器坏了。
        // 覆盖值随任务一起丢弃（任务已从坞里摘除），所以只清播放器状态即可。
        task.session.player.isMuted = false
        task.session.player.volume = 1

        // 会话原样交回前台：`adoptSession` 只写那一对槽，不新建会话。
        store.adoptSession(task.session, for: task.channel)
        // ⛔ 先决定「回到哪一页」，再置 `playing`。反了就会闪一下全屏播放器。
        //
        // `store.playing` 的 didSet 会在「不在任何观看页作用域里」时把
        // `presentingPlayer = true`（见 `Store.playing` 的注释）—— 那是给
        // 「从设置页深链起播」这类路径用的兜底。坞里点卡片时：
        //   · 有详情页 → 调用方紧接着会压选集页，届时 `isWatchPageMounted` /
        //     `watchPageScopes` 才登记；didSet 那一刻还不在，于是会先把全屏播放器弹出来，
        //     下一帧再被选集页盖掉 —— 用户看到的是「点卡片闪一下播放器」。
        // 所以在赋 `playing` **之前**就把标记摆好。
        store.isWatchPageMounted = true
        store.presentingPlayer = false
        guard let video = task.video, let client = task.client else {
            // 没有详情页（云文件 / 直播）：退回全屏播放器，这是它唯一合理的去处。
            // 解掉上面那道标记，否则 `playing` 的 didSet 会以为观看页挂着、不肯弹播放器。
            store.isWatchPageMounted = false
            store.playing = task.channel
            store.presentingPlayer = true
            return nil
        }
        store.playing = task.channel
        return (video, client)
    }
}

// MARK: - 左滑返回的信号

/// 「这次返回是左滑手势」的全局信号。
///
/// 用户对选集页的返回有两种语义，必须分开（要求 4）：
///   · 返回键 / 程序化 dismiss → **关掉音频**；
///   · 左滑返回 → 画面收进迷你播放器，**继续播**。
///
/// 系统的手势 pop 不会调用 `dismiss()`，页面只在 `onDisappear` 里被动得知「我走了」，
/// 拿不到原因。所以在手势开始那一刻留一个短时标记，`onDisappear` 读它区分这两条路。
/// 用时间窗而不是布尔：布尔会被「手势取消」留下脏值，下一次正常返回就会被误判成左滑。
@MainActor enum SwipeBack {
    private static var pendingUntil = Date.distantPast
    /// 700 ms：够覆盖一次 pop 过渡（约 350 ms）加上系统延迟，又短到不会串到下一次返回。
    static func begin() { pendingUntil = Date().addingTimeInterval(0.7) }
    static var isPending: Bool { Date() < pendingUntil }
    /// QA / 诊断用：确认手势确实被识别到。
    static var lastBeginAt: Date?

    /// 全局左滑返回的总闸。选集页在全屏时关掉它 —— 全屏里左滑该由播放器自己处理，
    /// 而不是把整页弹走。由 `VideoDetailView` 在自己的全屏状态变化里写。
    static var blocked = false
}

#if os(iOS)
// MARK: - 全局左滑返回

/// 给**每一个被压栈的页面**装上左滑返回。
///
/// 为什么不能只靠系统那条手势：系统自带的边缘 pop 只在**导航栏可见**时生效，
/// 而本仓大量页面为了沉浸式版式把导航栏隐藏了（`HomeView`、`DiscoverDetailView`、
/// `SiteView`…）。那些页面一旦被压栈，左滑就完全没反应 ——
/// 用户说的「全局需要支持左滑返回」正是这件事。
///
/// 实现取舍（走过弯路，写下来免得再踩）：
///
///  · ❌ 先试的是「接管 `interactivePopGestureRecognizer` 的 delegate」。这条路有两个死结：
///    ① 系统在每次 push / pop 后会把 delegate 收回，而 UIKit **没有**公开的
///       「didShow」通知可以挂（`UINavigationController.h` 里只有 delegate 方法，
///       没有任何 Navigation 通知），重新接管只能靠 `updateUIViewController` 的偶然调用；
///    ② 与选集页那份 `EdgeSwipeBack` 装的是同一个手势，两份 representable 抢 delegate，
///       后接管的赢，行为变成「看谁后刷新」。
///  · ✅ 现在走「自建一条屏幕左缘手势」，**只在导航栏隐藏时启用**：
///    导航栏可见时系统那条本来就好用，此时我们的手势一律不识别 ——
///    这样两者永不重叠，也就不可能出现「一次滑动 pop 两层」。
///
/// 这个判据（`isNavigationBarHidden`）同时解决了两件事：
///  · 全屏播放器把整页变成沉浸态时，它的 top VC 把导航栏藏了 → 但我们有 `SwipeBack.blocked`；
///  · 设置里的子栈（导航栏可见）→ 交回系统，不重复接管。
struct GlobalSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.refresh() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var edge: UIScreenEdgePanGestureRecognizer?
        /// 这一条手势是不是**从本页面内部起手**的。
        ///
        /// ⛔ 判据不能读 `SwipeBack.isPending`（700ms 时间窗）。
        ///
        /// 那个时间窗是给「选集页区分返回/左滑」用的，语义是「刚刚发生过左滑」。
        /// 拿它当「这条手势合法吗」的门，会产生一个很硬的手感缺陷：
        /// **慢慢拖动超过 0.7 秒，松手时窗口已过期 → 永远不 pop**。
        /// 用户拖到一半屏宽、松手，页面纹丝不动。
        ///
        /// 正确做法：`gestureRecognizerShouldBegin` 通过时记下这条手势自己，
        /// `handle` 里比对是不是同一条。手势取消/重新起手都会换新实例，天然不会串。
        private weak var tracking: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            arm()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // ⛔ 不要在这里 disarm。
            //
            // 手势是装在整个 `nav.view` 上的，服务的是**这个导航栈**。
            // 每次 pop / push 各页的 representable 都会经历 viewWillDisappear，
            // 若那时摘掉，手势就在每次返回后被上一条路径带走 ——
            // 真机日志实测到成对出现：
            //   `Swipe arm SKIP navigationController==nil`  ← 被摘之后又在新页 arm，此时还没入栈
            //   `Swipe arm OK stack=2`                      ← viewDidAppear 时补上
            // 于是「返回一层后，下一次左滑失效」。
            //
            // 戴在 `nav.view` 上就该由 `nav` 的生命周期管：
            // 只有「整个栈真被扔掉」时才摘（`navigationController == nil` 且没有父）。
            if isMovingFromParent, navigationController == nil { disarm() }
        }

        func refresh() {
            // `updateUIViewController` 可能发生在入栈**之前**（SwiftUI 先建视图再交给 nav），
            // 那时 `navigationController` 还是 nil。`viewDidAppear` 会补一次，
            // 但若那一帧 SwiftUI 没再更新，就再没有补的机会。
            // 这里排一次下一 runloop 的重试，覆盖「入栈稍晚于第一帧」的时序。
            arm()
            if edge == nil {
                DispatchQueue.main.async { [weak self] in self?.arm() }
            }
        }

        private func arm() {
            // 探针：验证「左滑返回」到底有没有装上手势。
            // 用户报「没生效」，而旧实现挂在 NavigationStack 外层时 nav 恒为 nil，
            // 这条日志能一眼看出是「没装上」还是「装上了但不响应」。
            guard let nav = navigationController else {
                #if DEBUG
                oneSkinLog("Swipe arm SKIP navigationController==nil（挂错层级）")
                #endif
                return
            }
            #if DEBUG
            oneSkinLog("Swipe arm OK stack=\(nav.viewControllers.count)")
            #endif
            if let edge, edge.view === nav.view { return }
            disarm()
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.edges = .left
            recognizer.delegate = self
            nav.view.addGestureRecognizer(recognizer)
            edge = recognizer
        }

        private func disarm() {
            if let edge { edge.view?.removeGestureRecognizer(edge) }
            edge = nil
        }

        @objc private func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            #if DEBUG
            oneSkinLog("Swipe handle state=\(recognizer.state.rawValue) tx=\(Int(recognizer.translation(in: recognizer.view).x))")
            #endif
            guard let nav = navigationController, nav.viewControllers.count > 1 else { return }
            let width = nav.view.bounds.width
            guard width > 1 else { return }
            let travelled = max(0, recognizer.translation(in: nav.view).x)
            switch recognizer.state {
            case .ended:
                // 走过屏宽 30%，或者甩得够快 —— 与系统手势的手感对齐。
                let fast = recognizer.velocity(in: nav.view).x > 800
                // ⛔ 只认「这条手势是本次起手的」。不用时间窗（慢拖会被误杀）。
                guard tracking === recognizer else { return }
                tracking = nil
                // 通知选集页「这次返回来自左滑」，供它区分「退出/收进小窗」。
                SwipeBack.begin()
                SwipeBack.lastBeginAt = Date()
                if travelled > width * 0.3 || fast {
                    nav.popViewController(animated: true)
                }
            case .cancelled, .failed:
                // 手势被取消：清掉跟踪，且**不**置 `SwipeBack` 标记 ——
                // 否则一次半途而废的滑动会让紧随其后的正常返回被误判成左滑。
                if tracking === recognizer { tracking = nil }
            default:
                break
            }
        }

        /// 只在「系统那条用不上」时启用：导航栏被隐藏，且栈里不止一页，且没被全屏禁用。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard !SwipeBack.blocked,
                  let nav = navigationController,
                  nav.viewControllers.count > 1,
                  nav.isNavigationBarHidden else { return false }
            // 记下这条手势实例：`handle` 里比对它，用来判断「这次手势是合法的起手」。
            // 不用 `SwipeBack` 的时间窗 —— 那会误杀慢速拖动（见 `tracking` 的注释）。
            tracking = gestureRecognizer
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // 左滑优先于页面内的横向拖动（选集行、横向卡片流），否则边缘起手会被它们吃掉。
            other is UIPanGestureRecognizer
        }
    }
}

extension View {
    /// 在被压栈的区域根上挂一次，即覆盖该栈内所有页面。
    func globalSwipeBack() -> some View {
        background { GlobalSwipeBack().frame(width: 0, height: 0) }
    }
}
#endif

// MARK: - 海报长按（点播源 / 订阅源内）

/// 长按海报的两个动作：**直接以迷你播放器播放**、**下载**。
///
/// 为什么做成一个修饰器挂在卡片上而不是进详情页：
/// 用户要的是「不离开当前列表」——点进去再返回会丢掉列表位置与滚动状态。
/// 长按菜单天然满足这一点，而且两个动作都不动前台（要求 6 明确「不影响已有的已打开
/// 迷你播放器」）。
///
/// 平台差异（**这条曾经是个真 bug**）：
///
/// 坞（`VideoTaskDock`）与 `dockForeground()` 全部包在 `#if os(iOS)` 里。
/// 而本修饰器原来只在 tvOS 分支掉，macOS 走 `#else` 会**显示**「Play in Mini Player」菜单 ——
/// 点了会在后台起一路 AVPlayer，但 macOS 上没有坞、没有卡片、没有关闭入口。
/// 用户得到的是「有声音、找不到界面、关不掉」的幽灵播放，比不给菜单糟得多。
///
/// 所以现在**只有 iOS 挂这个菜单**（下载仍走详情页/设置里的既有路径，macOS 本来就有）。
struct CatalogPosterMenu: ViewModifier {
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// 正在为下载准备选集列表（要先去源上取详情）。
    @State private var preparing = false
    /// 取到详情后要弹的下载抽屉。
    @State private var plan: DownloadPlan?

    /// 下载抽屉要的数据。单独一个 `Identifiable` 是因为 `.sheet(item:)` 需要它。
    struct DownloadPlan: Identifiable {
        let id = UUID()
        let episodes: [Episode]
        let flag: String
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.contextMenu {
            Button {
                // 迷你播放器播放：坞里起播，前台那一集不受影响（要求 6）。
                Task { await store.videoTasks.start(video: video, client: client, store: store) }
            } label: {
                Label(L10n.text("Play in Mini Player"), systemImage: "rectangle.inset.bottomright.filled")
            }
            Button {
                Task { await prepareDownload() }
            } label: {
                Label(L10n.text("Download"), systemImage: "arrow.down.circle")
            }
            .disabled(preparing)
        }
        // 下载要整部剧的选集列表，只能先问源要详情（走缓存，通常一次就够）。
        .sheet(item: $plan) { plan in
            DownloadPicker(video: video, site: client.site, flag: plan.flag, episodes: plan.episodes,
                           origin: client.origin) { count in
                guard count > 0 else { return }
                store.notice = L10n.text("Queued %@", String(count))
            }
        }
        #else
        // macOS / tvOS：没有坞，就不给这个菜单（见类型注释里那段幽灵播放的成因）。
        content
        #endif
    }

    private func prepareDownload() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            // `cached: true`：列表页刚拉过的详情就在 MediaCache 里，别再打一次源。
            let detail = try await client.detail(video.id, cached: true)
            guard !detail.episodes.isEmpty else {
                store.notice = L10n.text("This title has no episodes to download.")
                return
            }
            // 用第一条线路，与详情页下载抽屉的默认一致。
            plan = DownloadPlan(episodes: detail.episodes, flag: detail.episodes.first?.flag ?? "")
        } catch {
            Diagnostics.shared.failure("tasks", "poster download detail \(client.reportContext) video=\(video.id)", error)
            store.error = L10n.text("Unable to load this title's episodes: %@", error.localizedDescription)
        }
    }
}

extension View {
    /// 点播源 / 订阅源里的海报：长按给出「迷你播放器播放」「下载」。
    func catalogPosterMenu(_ video: Video, client: CatalogClient) -> some View {
        modifier(CatalogPosterMenu(video: video, client: client))
    }
}

#if os(iOS)
// MARK: - 坞的界面

/// 坞里一张卡片的画面层。
///
/// 与 `PlayerLayerView` 的区别只有画中画那一段：只有**正在出声的那一张**（`pip != nil`）
/// 才把自己这块 layer 交给画中画控制器，其余一律不登记。
///
/// ⛔ 不能让每张卡片各挂一个 `PictureInPicture`。`PictureInPicture.current` 是**全局静态**
/// 的，退场裁决（`PlaybackExit` / `RootView` 的 `pipPossible`）靠它回答「现在浮着没有」。
/// 坞里挂三张卡片就三份控制器抢那一个静态量，前台的退场裁决会读到别人的控制器，
/// 于是「上滑回主界面该浮窗」变成对着一张坞卡片的 layer 去 `startPictureInPicture`。
/// 所以坞共用一个实例，只交接给当前活跃的那一张 —— 用户离开 App 时，浮起来的是
/// 他刚才在操作的那一个，语义正确。
/// 视频层的 `Equatable` 包装：让 `updateUIView` 只在真正需要时被调用。
///
/// 用包装视图而不是给 `VideoTaskCard` 加 `Equatable` —— 后者在 Swift 6 下会
/// 跨 actor 隔离报错（`view` 是 `@MainActor` 的），而包装视图天然只在主 actor 里比较。
private struct DockVideoLayerBox: View, Equatable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let pip: PictureInPicture?
    let coveredByForeground: Bool
    /// 超出解码预算被挂起：画面层必须**让出** `AVPlayer`。
    ///
    /// 这不只是省解码器：`AVPlayerLayer` 一旦持续绑着一个被 `rate = 0` 的 player，
    /// 它会把最后一帧冻在那儿 —— 20 个窗就是 20 块冻住的画面，
    /// 用户分不清「挂起」和「卡死」。让出去之后露出下面的海报，语义就对了。
    let suspended: Bool
    let width: CGFloat
    let height: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // 只比较影响画面的五项 + 尺寸。`player` 是引用，比对象身份即可。
        lhs.player === rhs.player
            && lhs.gravity == rhs.gravity
            && lhs.pip === rhs.pip
            && lhs.coveredByForeground == rhs.coveredByForeground
            && lhs.suspended == rhs.suspended
            && lhs.width == rhs.width
            && lhs.height == rhs.height
    }

    var body: some View {
        DockPlayerLayer(player: player, gravity: gravity, pip: pip,
                        coveredByForeground: coveredByForeground, suspended: suspended)
    }
}

private struct DockPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    /// 只有活跃卡片有；其余为 nil。
    let pip: PictureInPicture?
    /// 前台观看页（或全屏播放器）正在演 —— 这时坞里的画面必须完全让出 player。
    var coveredByForeground: Bool = false
    /// 超出解码预算被挂起 —— 同上，必须让出。
    var suspended: Bool = false

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        pip?.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.videoGravity = gravity
        // 卡片刚变成活跃：把控制器的 contentSource 指到这块新 layer。
        // `attach` 内部就是这么做的（改指向、不重建控制器），见 `PictureInPicture.attach`。
        if let pip { pip.attach(view.playerLayer) }
        // ⛔ 这块 layer 什么时候**必须让出 player**。
        //
        // `AVPlayer` 同一时刻只把像素给**一个** `AVPlayerLayer`。谁最后绑上谁拿到画面，
        // 前一块的 `videoRect` 就变成 0×0 —— 表现就是「那块区域只剩底下的海报虚化」。
        //
        // 真机日志实证（`fixedLayer` 行）：
        //   展开横屏 split 下 `view=523x294 layer=523x294 videoRect=0x0`，
        //   而同一路视频在坞卡片尺寸下曾报 `videoRect=165x294` 正常。
        //   根因就是这里：坞卡片一直绑着 player，把前台观看页那块 layer 饿死成 0×0。
        //
        // 所以「让出」有两个来源，缺一不可：
        //   ① 浮窗（PiP）起着 —— 画面归系统那一层（原有逻辑）；
        //   ② **前台观看页正在演** —— 画面归页面上那块 layer（用户报的「只见海报」）。
        //      这时坞里挂着但看不见，绑着 player 只会抢画面。
        let yieldsToPiP = !(pip?.shouldRender(view.playerLayer) ?? true)
        let yieldsToForeground = coveredByForeground
        let target: AVPlayer? = (yieldsToPiP || yieldsToForeground || suspended) ? nil : player
        if view.playerLayer.player !== target { view.playerLayer.player = target }
    }
}

/// 坞里的**一张**卡片：画面 + 名字 + 播放/关闭，点一下回那一集的选集页。
struct VideoTaskCard: View {
    @Environment(Store.self) private var store
    let task: VideoTask
    let width: CGFloat
    let gravity: AVLayerVideoGravity
    /// 它是不是正在出声的那一张（其余静音，卡片描边亮起以示区别）。
    let isActive: Bool
    /// 坞共用的画中画控制器；只交给活跃的那一张。
    /// 只有活跃卡片拿得到（PiP 控制器共用一个实例，见 `DockPlayerLayer` 的说明）。
    let pip: PictureInPicture?
    /// 前台观看页在演 —— 这张卡的画面必须让出 `AVPlayer`（见 `DockPlayerLayer.updateUIView`）。
    var coveredByForeground: Bool = false
    /// **这张卡自己**的缩放。坞里多张卡各有一份，不共享 ——
    /// 用户要求「每个窗口单独调整大小」，用坞级一个 `scale` 只会整体变大变小。
    var ownScale: CGFloat = 1
    /// 这张卡捏合时回报新的 scale（由坞写回 `perCardScale[task.id]`）。
    var onScaleChange: ((CGFloat) -> Void)? = nil
    /// 这一张在坞里的**位置**与**总数**（`applyMuting` 用的是同一对值）。
    ///
    /// ⛔ 这两个数必须与 `VideoTasks.applyMuting()` 传给
    /// `DockAudioPolicy.output(isActive:taskIndex:taskCount:override:)` 的**完全一致**。
    /// 曾经这里写死 `taskIndex: 0, taskCount: 1` —— 于是卡片按「坞里只有我一路」算音量，
    /// 而实际出声按真实路数算：
    ///   · `.mixed` 下活跃那路实际是 `1/n`，卡片却显示满格；
    ///   · `.dimmed` / `.focused` 的活跃判断也按「唯一那张」算，图标随之失真。
    /// 用户看到的就是「这一张图标是静音，得按 + 才出声」——
    /// **图标说的和听到的不是一回事**，因为两处口径分叉。
    var taskIndex: Int = 0
    var taskCount: Int = 1

    /// 这一张是否**超出解码预算被挂起**。
    ///
    /// 判据只在 `DockDecodingBudget` 一处（`isSuspended(index:budget:)`）：
    /// 卡片位置与 `tasks` 同序，`applyMuting` 用的也是同一个预算，
    /// 所以「卡片显示挂起」与「player 真的被 rate=0」不会分叉。
    private var isSuspended: Bool {
        DockDecodingBudget.isSuspended(index: taskIndex, budget: PlaybackCapacity.decoding)
    }

    /// 画面区容器。拖动已上移到摆放层（`DockPlacedCard`），这里只负责命中形状。
    @ViewBuilder private func dragSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            // 让画面区（除底部进度条热区外）成为实心命中区域。
            .contentShape(DockDragShape(bottomInset: dockProgressHitHeight))
            // ★ 搬窗口的手势挂在**画面区**，与本卡的进度条、tap **同层**。
            //
            // ⛔ 这是本问题（拖不动 / 松手才跳 / 进度条拖不动）的最终解。
            //    前几版试过的三种位置都不行，原因各不相同：
            //      ① 挂在整张卡（`simultaneousGesture`）→ 覆盖进度条热区，
            //         拖进度时窗口跟着跑。
            //      ② 挂在摆放层 `.gesture` → 被本卡 tap 的 `simultaneousGesture`
            //         抢先，父层收不到触摸 ⇒ **松手才跳**。
            //      ③ 挂在摆放层 `simultaneousGesture` → 与进度条并行识别，
            //         拖进度时窗口也动 ⇒ **进度条很难拖**。
            //
            //    挂在这里（画面区内部）就对了：
            //      · 与进度条**同层**，进度条的 `highPriorityGesture` 是它的邻居，
            //        热区内进度条赢（`.gesture` 优先级低于 `highPriorityGesture`）；
            //      · 画面区没有别的竞争手势，拖动逐帧收到 ⇒ 跟手；
            //      · 位移写本卡的 `livePan`（`@GestureState`），
            //        父层拖动期间**完全不重算** ⇒ 不抖。
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($livePan) { value, state, transaction in
                        transaction.animation = nil
                        state = value.translation
                    }
                    .onEnded { value in
                        onPanEnded?(value.translation)
                    }
            )
    }

    /// 捏合的**瞬时**倍率：只影响画面，松手时才算进 `ownScale`。
    ///
    /// ⛔ 原来直接把 `MagnificationGesture.value` 写回 `ownScale`。那个 value 是
    /// 「相对**本次起手**的倍率」，不是绝对缩放 —— 已经捏到 1.6 的卡再捏一下，
    /// 它又从 1 起算，`ownScale` 立刻跳回 1.0，每捏一次都「弹回原大小」。
    @GestureState private var pinch: CGFloat = 1
    /// 由 `DockPlacedCard` 传进来的**瞬时**倍率。
    ///
    /// ⛔ 与上面那个 `@GestureState pinch` 并存但**不重复计算**：
    ///    `@GestureState` 只在本卡自己持有手势时有效；手势已经移到摆放层之后，
    ///    这里拿到的是摆放层算出的值。两者相乘会让捏合量翻倍。
    ///
    ///    所以：手势还在本卡上时（`pinch` 生效）就不再用 `externalPinch`。
    ///    现在手势统一在摆放层，本卡只读 `externalPinch`，`pinch` 恒为 1，
    ///    乘上去无害，但保留它是为了不破坏既有单卡手势路径。
    var externalPinch: CGFloat = 1

    /// 位置与尺寸被布局锁死（锁定整理）。
    ///
    /// 锁定时**所有卡同一个宽**（`DockLayout.packedTiles` 给的格子宽），
    /// 捏合不生效、拖动也不生效 —— 「锁定」得是真的锁住，
    /// 而不是「拖一下再弹回去」（那比拖不动还难受）。
    var isLayoutLocked: Bool = false

    /// 拖动允许的位移区间（相对起手位置）。`nil` = 不限制。
    ///
    /// ⛔ 逐帧钳位，不是松手才钳。
    ///    只钳「松手结果」的话，拖动过程中窗口照样整块跑到屏幕外（手指跟着它走），
    ///    松手再弹回来 —— 用户看到的是「能拖出去」。要求是**任何位置都不许出屏**。
    var panBounds: CGRect? = nil

    /// 画面区被拖动时上报的**累计位移**。摆放层据此落定最终位置。
    ///
    /// ⛔ 只在 `onEnded` 里上报，拖动过程**不报** ——
    ///    拖动中的逐帧位移由本卡自己的 `@GestureState livePan` 承担，
    ///    这样父层（摆放层）在拖动期间完全不用重算，卡片树也就不会重建。
    var onPanEnded: ((CGSize) -> Void)? = nil
    /// 双击 = 伪全屏置顶 / 再双击还原（用户 2026-11-17）。
    ///
    /// 与单击**并行**识别（两条 `simultaneousGesture`），不用 `.exclusively`：
    /// 后者会让单击等双击超时 ≈0.3s 才生效（见 `:1660` 注释记的那个坑）。
    /// 双击时单击也会触发一次 `activate` —— 无害，`activate` 只改 tasks 顺序（= zIndex），
    /// 不碰伪全屏状态，而伪全屏切换是幂等的（只切一个 id）。
    ///
    /// ⚠️ 参数顺序：`onPanEnded` 之后、`initialEpisodeIndex` 之前。
    ///    Swift 的成员初始化按声明顺序，写在前面会让调用点报
    ///    「argument 'onPanEnded' must precede argument 'onDoubleTap'」。
    var onDoubleTap: (() -> Void)? = nil
    /// 拖动中每帧的位移（不含基准），由摆放层在拖动开始时告知基准。
    var panBase: CGSize = .zero

    /// 拖动中的实时位移。
    ///
    /// ⛔ `@GestureState`：手势进行中**不触发依赖重算**，只让布局拿新值。
    ///    这正是「跟手又不抖」需要的；`@State` 每帧写入会重建卡片树。
    @GestureState private var livePan: CGSize?

    // MARK: - 进度拖动（底部细线与标题栏共用同一份状态）

    /// 手指拖到的进度（0…1）。nil = 没在拖，按播放进度画。
    ///
    /// ⛔ **一份状态，两处入口**。底部细线是 `DockProgressBar`，标题栏是那段
    ///    `VStack`；两者都调 `scrub(_:)`，都读这里的值。
    ///    分开各存一份的后果正是用户报的「没有真正进度条调整的样式」——
    ///    拖标题栏时底部线一动不动、也没有读数泡。
    @State private var scrubFraction: Double?
    /// 节流器。用类实例而不是 `@State` 结构体：写它不进 SwiftUI 依赖图，
    /// 拖动每帧改时间戳不会引起卡片重建（`DragAnchor` 同一理由）。
    private final class ScrubClock { var throttle = DockScrubThrottle() }
    @State private var scrubClock = ScrubClock()

    /// 这一帧进度条该画到哪。
    private var shownFraction: Double { scrubFraction ?? task.fraction }
    /// 有没有手指正在抓进度。
    private var isScrubbing: Bool { scrubFraction != nil }
    /// 直播没有可拖的时间轴。
    private var canScrub: Bool {
        task.session.duration > 0 && !task.session.isLive
    }

    /// 拖动进度：`x` 是手指在控件内的横坐标，`width` 是控件宽，`ended` = 松手。
    ///
    /// ## 三件事，缺一件就是用户报的「拖了没用」
    /// 1. **拖动中真的发 seek**（大容差 + 先取消排队）——只改本地变量不发 seek，
    ///    画面一帧都不会动，「画面不会进行移动」说的就是这一格。
    /// 2. **节流**，不是每帧都发：`onChanged` 每秒几十次，全发出去 AVPlayer 排队积压，
    ///    画面越来越落后，比不发还糟（这就是 `previewSeek` 当初为前台修的病）。
    /// 3. **松手发零容差精确 seek**，并立刻把进度交回播放器。
    private func scrub(_ x: CGFloat, width: CGFloat, ended: Bool) {
        guard canScrub else { return }
        let f = DockScrub.fraction(x: x, width: width)
        let duration = task.session.duration

        if ended {
            scrubClock.throttle.reset()
            scrubFraction = f
            if let target = DockScrub.seconds(fraction: f, duration: duration) {
                task.session.seek(to: target)
            }
            // 松手后先保留一小会儿再交回播放器：`session.position` 已经做了乐观更新，
            // 但换集/换线路时可能晚一点，这一手让线不会闪回旧值。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                scrubFraction = nil
            }
            return
        }

        scrubFraction = f
        guard let target = DockScrub.seconds(fraction: f, duration: duration),
              scrubClock.throttle.due(now: Date()) else { return }
        task.session.previewSeek(to: target)
    }

    /// 有手指正在抓进度条/标题栏。
    ///
    /// ⛔ **这是本卡搬窗口顺滑的关键。**
    ///
    /// 进度条与标题栏都用 `DragGesture(minimumDistance: 0)` + `highPriorityGesture`：
    /// 手指一落下就立即激活（这是「按住就能调进度」所必需的）。
    /// 但 `highPriorityGesture` **只在本视图层级内生效** —— 它无法阻止
    /// **父层**（`dragSurface` 的搬窗口手势）同时被识别。
    ///
    /// 后果：手指按在进度条/标题栏上时，搬窗口那一路也在跑，
    /// 每一帧都在算 `dragOffset` → 整卡 body 失效 → 画面跟着抖。
    /// 用户感受到的就是「加了进度条/标题栏拖动之后，窗口移动不顺滑了」。
    ///
    /// 所以搬窗口那一路必须**主动让路**：只要进度手势活着，它就整段不响应。



    /// 拖动中的位移，钳进 `panBounds`。
    private var clampedLivePan: CGSize {
        guard let pan = livePan else { return .zero }
        guard let b = panBounds else { return pan }
        return CGSize(width: min(max(pan.width, b.minX), b.maxX),
                      height: min(max(pan.height, b.minY), b.maxY))
    }

    private var scaledWidth: CGFloat {
        // 锁定整理时忽略捏合：尺寸由网格统一，手指捏了也不动。
        width * ownScale * (isLayoutLocked ? 1 : pinch * externalPinch)
    }
    private var height: CGFloat { scaledWidth / task.aspectRatio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ★ 「可拖动区」= 只有**画面**这一块。
            //
            // 用户报：「进度条部分 和下方白条标题栏 部分不应该拖动小窗位置，
            // 它要用于进度条，否则进度条不好拖拽调整」。
            //
            // 原来拖动手势挂在**整张卡**上（`DockPlacedCard` 对 `card` 整体挂手势），
            // 于是手指落在底部 22pt 的进度条热区、或下方标题栏上时，
            // 拖动会先被父层吃掉 —— 进度条那个 `DragGesture` 根本拿不到触摸。
            //
            // 现在把画面单独包成一层，拖动只认它：
            //   · 画面区 → 拖动窗口（这里就是「抓着画面搬窗口」的直觉）
            //   · 进度条 → 只调进度，不搬窗口（它有 22pt 热区，够按）
            //   · 标题栏 → 既不搬窗口也不调进度，只接轻点/双击
            dragSurface {
            // ⛔ 视频层用 `EquatableView` 包住，只在这些值真正变化时才更新 UIKit 层。
            //
            // 这是「拖动/缩放卡顿」的第二处修法。`DockPlayerLayer` 是
            // `UIViewRepresentable`，它的 `updateUIView` 每次都会重设 `videoGravity`、
            // 重跑 `pip.attach`、重新布局 AVPlayerLayer。拖动时这些值一个字都没变，
            // 但原来每帧都会走一遍 —— 8 张卡一起就是明显的掉帧。
            //
            // `DockVideoLayerBox` 自己实现 `Equatable`，比较的就是真正影响画面的四项。
            DockVideoLayerBox(player: task.session.player,
                              gravity: gravity,
                              pip: isActive ? pip : nil,
                              coveredByForeground: coveredByForeground,
                              suspended: isSuspended,
                              width: scaledWidth, height: height)
                .equatable()
                .frame(width: scaledWidth, height: height)
                .clipped()
                .overlay {
                    // 加载中：黑底 + 转圈，别让用户对着一张纯黑卡片判断「是不是卡死了」。
                    if task.isLoading {
                        ZStack { Color.black; ProgressView().tint(.white) }
                    }
                }
                .overlay {
                    // 超出解码预算被挂起：画面层已让出 player，这里补一张海报 + 角标。
                    //
                    // ⛔ 为什么必须补海报：20 个窗里只有 8 路在解，其余 12 路如果只有
                    //    一块 `Color.black`，用户看到的是「12 个窗全废了」——
                    //    而真实状态是「挂着的剧，点一下就接上」。差别全在这张图上。
                    if isSuspended {
                        ZStack {
                            if let url = task.posterURL {
                                PosterImage(url: url, headers: task.posterHeaders)
                                    .opacity(0.55)
                            } else {
                                Color.black
                            }
                            VStack(spacing: 6) {
                                Image(systemName: "pause.circle")
                                    .font(.system(size: 18, weight: .semibold))
                                Text(L10n.text("Parked"))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 左上角一组：播放/暂停 + 这一张的声音。
                    //
                    // 声音键放在这里（画面内、与暂停并排）而不是卡片外沿，是有意的：
                    // 它是**高频的临时操作**（切一下声音），不是破坏性的；
                    // 外沿那颗（右上）是销毁任务，两者必须在位置上分开。
                    HStack(spacing: 6) {
                        Button {
                            // ⛔ 挂起的那一张，这颗键的语义是「**激活它**」，不是「播放它」。
                            //
                            // 直接 `togglePlayback()` 会绕过解码预算：12 个挂起窗各按一下，
                            // 就真的有 20 路在解码 —— 又回到了「黑屏 + 抢解码器」那个状态，
                            // 而且这次是我们自己放进去的。激活会把它提到队列最前，
                            // 由 `applyMuting` 重新分配预算并续播。
                            if isSuspended { store.videoTasks.activate(task.id) }
                            else { task.session.togglePlayback() }
                        } label: {
                            Image(systemName: isSuspended || task.isPaused ? "play.fill" : "pause.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.5), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(isSuspended || task.isPaused ? "Play" : "Pause"))

                        DockSpeedButton(task: task)
                        DockVolumeButton(task: task, isActive: isActive,
                                         taskIndex: taskIndex, taskCount: taskCount)
                        // 「回到选集页」：原来只藏在**双击**里。
                        //
                        // ⛔ 双击是这颗键存在的原因。用户要求「单击即响应，点击则挪到最前」，
                        //    而单击只要与「双击」共存，SwiftUI 就得等双击超时（≈0.3s）才敢
                        //    认定这是单击 —— 于是「点一下换层」这件事永远慢半拍。
                        //    现在单击是**唯一**的点按语义（提到最前 + 主选择），
                        //    回选集页改成这颗显式键：看得见、点得到、不用抢时间窗口。
                        Button { open() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.5), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(L10n.text("Open Episode List")))
                    }
                    .padding(6)
                }
                // ⛔ 退出键**不再放在画面内部**（此前是 topTrailing + 28pt 圆圈）。
                //
                // 那时它和左上角「暂停」同款同尺寸、同在画面里，用户分不清哪个是
                // 播放控制、哪个会销毁任务；视频亮色内容上 0.5 黑底也发灰看不清。
                //
                // 新设计见卡片外层的 `dockCloseButton`：贴在**卡片右上外沿**、
                // 红底 + 白 X、32pt 热区、与画面无重叠。
                // 进度条：既能看进度，也能拖。
                //
                // 原来这里是一条 2px 的**只读**细线 —— 「哪个看到哪」看得出，但想往回退 30 秒
                // 只能点进播放页。小窗的全部意义是不打断观看，所以它必须能直接调进度。
                //
                // ⛔ 拖动手势必须挂在**比细线更高**的热区上（`contentShape` 给 22pt），
                //    否则 2pt 的命中区用户根本按不住；视觉上仍然是细线，不占画面。
                // ⛔ 拖动期间不能用 `task.fraction` 画：`session.position` 的采样是 1 秒一拍。
                //    所以这里画的是 `shownFraction`（拖动时是手指位置，否则是播放进度），
                //    状态由本卡的 `scrubFraction` 统一保管，标题栏拖动也写同一份。
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // ⛔ 进度条**必须挂在 dragSurface 之外**。
                //
                // 它原来是画面区的 `.overlay` —— 而画面区整个包在 `dragSurface` 里，
                // 于是「调进度」和「搬窗口」同一个视图层级里竞争：
                // 进度条是 `highPriorityGesture(minimumDistance: 0)`，手指一落下就激活；
                // 父层的搬窗口手势也在同一串触摸上被识别 → 每帧既 seek 又算 dragOffset，
                // 画面跟着抖、窗口移动不顺滑。
                //
                // 现在把进度条移到 `dragSurface` **外层**：它覆盖在画面上，
                // 触摸先由它接（`highPriorityGesture`），搬窗口那一路在它下面，
                // 落在进度条以外的区域才轮到搬窗口。两者在层级上就分开了，
                // 不再需要 `seekFlag` 那种运行时让路。
                .overlay(alignment: .bottom) {
                    // 底部细线与下方标题栏**共用同一份拖动状态**（`scrubFraction`），
                    // 所以拖标题栏时这条线也会跟着走、也会浮出读数。
                    DockProgressBar(task: task,
                                    fraction: shownFraction,
                                    isScrubbing: isScrubbing,
                                    onScrub: scrub)
                }
            }
            // ↓ 下方标题栏：**也用来调进度**。
            //
            // 用户要求：「拖标题栏需要=拖进度条，因为进度条太窄」。
            // 底部那条 22pt 热区在小屏上确实不好按，而标题栏有 30pt 高、几乎占满卡宽，
            // 是更自然的进度拖动面。所以整条标题栏都接 seek，且**不搬窗口**
            // （它不在 `dragSurface` 里）。
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.caption.weight(.semibold)).lineLimit(1)
                if !task.subtitle.isEmpty {
                    Text(task.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // 整条标题栏接同一个拖动实现（`scrub`）—— 与底部细线共用状态与节流。
            //
            // ⛔ 原来这里是「每帧一次零容差精确 seek」，也就是用户报的
            //    「拖标题栏不会改变进度、画面不移动、没有进度条调整的样式」的根因：
            //      · 零容差 seek 要求解码器从最近关键帧逐帧解到目标帧，
            //        每帧来一次就排队积压，画面反而越来越落后；
            //      · 它只 seek，不写任何拖动状态 ⇒ 底部细线不动、没有标点、没有读数；
            //      · 松手后 `session.position` 要等下一拍采样才更新 ⇒ 线弹回原处。
            //    现在走 `scrub`：拖动中节流预览、松手精确落定、状态与细线同源。
            //
            // 坐标用 `.local`：标题栏自带 10pt 横向 padding，`local` 已经是它的内容坐标，
            // 与底部条（无 padding）用同一个 `DockScrub.inset` 口径即可对齐。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(value.location.x, width: scaledWidth, ended: false)
                    }
                    .onEnded { value in
                        scrub(value.location.x, width: scaledWidth, ended: true)
                    }
            )
            // ⛔ 必须是 `scaledWidth`，不是 `width`。
            //
            // 原来这里写死基础宽度：视频画面按 `scaledWidth` 缩放，标题行却始终满宽。
            // 缩小（捏到 0.6）时画面比标题行窄 → 右侧露出一条 `regularMaterial`
            // 的浅色底，用户看到的就是「迷你小窗缩放后右边一条白边」；
            // 放大时反过来，标题行右侧塌下去一块。两者现在同一个宽度源。
            .frame(width: scaledWidth, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.1),
                              lineWidth: isActive ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        // ── 退出键：贴在卡片**右上外沿**，不与画面重叠 ──
        //
        // 设计要点（对着旧版的问题逐条改）：
        //   ① **位置**：卡片右上角外沿（offset 半出界），不再压在视频画面上。
        //      多个卡片纵向排列时，一排红点沿右侧对齐，扫视即可定位。
        //   ② **形状/颜色**：实心红底 + 白 X。左上角「暂停」仍是黑色半透明圆。
        //      破坏性操作与播放控制在颜色上就分开，不会点错。
        //   ③ **热区 32pt**：比视觉尺寸大，拇指好按；视觉 22pt 不喧宾夺主。
        //   ④ **长按确认**：`.onLongPressGesture` 才真正销毁 —— 轻点只提示，
        //      避免误触把正在看的任务清掉（坞里可能有好几个）。
        .overlay(alignment: .topTrailing) {
            DockCloseButton { store.videoTasks.remove(task.id) }
                .offset(x: 8, y: -8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // ★ 轻点 = **提到最前 + 设为主选择**（同一个动作，一次到位）。
        //
        // 用户 2026-11-17：「调整图层顺序应该单击即响应，点击则挪到最前。
        // 而不是在面板里复杂操作」。所以点按只有这一个语义，没有第二个候选动作。
        //
        // ⛔ 原来这里是
        //      `TapGesture(count: 2).onEnded { open() }.exclusively(before: TapGesture())`
        //    `.exclusively` 的意思是「先看是不是双击，不是才当单击」——
        //    于是**每一次单击都要等双击超时（≈0.3s）**才生效。换层慢半拍、
        //    连着点两张卡时第一下还会被吞掉。这正是「单击不响应」的机制。
        //
        //    现在双击不再存在（「回到选集页」改成了画面左上角那颗显式的展开键，
        //    管理器里也有同款），单击识别器单独一路，手指一抬就生效。
        //
        // ⛔ 用 `simultaneousGesture` 而不是 `gesture`：子层**不能独占**触摸。
        //    父层的拖动要用同一串触摸的坐标，独占会让它一帧都收不到。
        // ★ 单击 = 提到最前；**双击 = 回到那一集的选集页**（2026-11-17 加回）。
        //
        // 用户：「双击迷你小窗没有办法返回选集播放页」。双击曾被移除（见上一条注释），
        // 现在按用户要求加回，但**不能恢复 `.exclusively(before:)`** ——
        // 那会让每次单击都等双击超时（≈0.3s）才生效，正是历史上「单击不响应」的成因。
        //
        // 两条识别器**并行**挂：单击不等双击、双击不等单击。
        // 双击时单击也会触发一次 `activate` —— **无害**：
        // `open()` 第一句就是 `activate(task.id)`（见 `open()` 的实现），
        // 重复调用是幂等的（已置顶的再置顶一次）。
        //
        // ⛔ 顺序有讲究：**双击写在单击之前**。两个 `simultaneousGesture` 都会收到
        //    同一次轻点序列，双击那份只在第二下抬起时触发 `open()`；若把单击写在前面，
        //    `open()` 里 `take()` 已经把这张卡从坞里摘掉，随后那次 `activate` 的
        //    `guard let index = tasks.firstIndex(...)` 找不到 id 直接返回 ——
        //    声音会停在坞里另一张卡上（`open()` 内那段注释记的正是这个坑）。
        //    现在双击先跑，`open()` 内部自己先 `activate` 再 `take`，顺序天然正确。
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleTap?() }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                // `activate` 内部就把这张卡挪到数组首位 —— 数组顺序 = 图层顺序，
                // 首位画在最上层（`zIndex` 在坞里给）。
                store.videoTasks.activate(task.id)
            }
        )
        // ★ 捏合**只在摆放层**（`DockPlacedCard.pinchGesture`）识别。
        //
        // ⛔ 2026-11-17：这里原来还挂着一条自己的 `MagnificationGesture`，而摆放层那条
        //    也挂着 —— 两条都 `simultaneousGesture`，于是同一次捏合被算了两遍：
        //    `scaledWidth = width × ownScale × pinch × externalPinch`，捏到 1.5 倍时
        //    画面是 2.25 倍，松手两个 `pinch` 归 1、`ownScale` 只写了 1.5，
        //    视觉上就是「放大过头又缩回去」。现在只剩摆放层一条，本卡只读 `externalPinch`。
        // ★ 拖动中的实时位移**在本卡叠加**。
        //
        // ⛔ 这一行是「跟手」的关键读取点：`livePan`（`@GestureState`）
        //    在拖动期间每帧给新值，但**不触发依赖重算** ——
        //    所以只有这一处 offset 会变，卡片树本身不重建。
        //    没有这一行，手势收到了事件也没人用，表现就是「松手才跳」。
        .offset(x: clampedLivePan.width, y: clampedLivePan.height)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(task.title))
    }

    /// 点卡片回到**那一集的选集页**。
    ///
    /// 会话交接的顺序见 `VideoTaskCenter.take`：先 `adoptSession` 把同一个 `AVPlayer`
    /// 交给前台，再置 `playing`，最后把「压哪一页」作为请求交给自己所在分区的栈。
    private func open() {
        // ⛔ 「切声音」与「回到那一页」必须在**同一次点击**里按这个顺序做完。
        //
        // 拆成两处（卡片 `.onTapGesture{open()}` + 坞 `.simultaneousGesture{TapGesture→activate}`）
        // 时顺序不可靠：`open()` 会把这个 task 从坞里摘掉，若 `activate` 后跑，
        // 它拿到的是一个已不在坞里的 id，`activate` 的 guard 直接返回 ——
        // 结果是「点回来之后，声音留在坞里的另一张卡片上」，而用户明明点的是这一张。
        store.videoTasks.activate(task.id)
        guard let target = store.videoTasks.take(task.id, store: store) else { return }
        store.pendingTaskRoute = Route {
            AnyView(VideoDetailView(video: target.video, client: target.client))
        }
    }
}

/// **单张卡片**的声音键：点开一个滑杆 + 静音开关。
///
/// 用户要求：「在迷你播放的窗口上可以进行单独小窗的声音设定」+「还要加一档静音」。
/// 所以两件事都在这里：
///   · **静音**（`.muted`）：这一张一点声都不出，哪怕它是当前选中的那张；
///   · **音量**（`.level`）：这一张固定在一个音量，不受全局档位摆布；
///   · **跟随全局**（nil）—— 用户把它拖回默认时的状态。
///
/// 为什么用 `Menu` 而不是自己画一个浮层：菜单能拿到系统级的事件处理
/// （点外面自动关、外接键盘、VoiceOver），手搓浮层在坞这种**可拖动浮层**上
/// 容易与拖动/缩放手势打架 —— 坞的外层就挂着 `DragGesture` 和 `MagnificationGesture`。
///
/// 坞卡片的**进度条**：既能看，也能拖；拖动时给出样式与「已播 / 总长」读数。
///
/// ## 它只负责「画」和「把手指位置报上去」
///
/// 用户 2026-11-17 的实测要求：「进度条调整（**标题栏拖动也算进度条**）」。
/// 所以底部这条线必须与下方标题栏**共用同一份拖动状态** —— 状态因此上提到
/// `VideoTaskCard`，这里只读 `fraction` / `isScrubbing`。
/// 分开存两份时的表现正是用户报的：「没有真正进度条调整的样式」——
/// 拖标题栏时底部线一动不动、也没有任何读数。
///
/// ## 四个必须守住的点
/// 1. **命中区要比视觉大**：视觉 2pt 好看但按不住，热区外扩到 44pt。
/// 2. **拖动中不能用 `session.position` 画**：它是采样值，seek 之后要等下一拍 tick。
///    拖动期间画手指位置（`fraction` 由卡片给），松手才交出控制权。
/// 3. **拖动中要真的发 seek**（节流 + 大容差）：不发 seek 画面一帧都不动，
///    用户看到的就是「拖了不改变进度、画面不移动」。落定那一刻再发零容差精确 seek。
/// 4. **轨道与命中区用同一个内缩**（`DockScrub.inset`）：否则手指放在圆角上
///    有线无响应，或拖到头了还差一截。
private struct DockProgressBar: View {
    let task: VideoTask
    /// 这一帧该画到哪（0…1）：拖动时是手指位置，否则是播放进度。
    let fraction: Double
    let isScrubbing: Bool
    /// 手指位置上报（x、控件宽、是否落定）。
    let onScrub: (CGFloat, CGFloat, Bool) -> Void

    /// 直播没有可拖的时间轴：不给读数，也不画拖动样式。
    private var showsReadout: Bool { !task.session.isLive }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let inset = DockScrub.inset
            let trackW = max(width - inset * 2, 1)
            let f = min(max(fraction, 0), 1)
            let barH: CGFloat = isScrubbing ? 6 : 2
            let thumb: CGFloat = isScrubbing ? 13 : 6
            let fillW = trackW * CGFloat(f)
            let knobX = inset + min(max(fillW, 0), trackW)

            ZStack(alignment: .leading) {
                // 轨道：拖动时整体提亮，让「正在调」这件事肉眼可见。
                Capsule()
                    .fill(.white.opacity(isScrubbing ? 0.38 : 0.22))
                    .frame(width: trackW, height: barH)
                    .offset(x: inset)
                // 已播部分
                Capsule()
                    .fill(.white.opacity(isScrubbing ? 1 : 0.9))
                    .frame(width: max(0, fillW), height: barH)
                    .offset(x: inset)
                // 标点：常驻一颗小点，拖动时放大并加阴影，圆心与轨道共中线。
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .overlay(Circle().strokeBorder(.black.opacity(isScrubbing ? 0.35 : 0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(isScrubbing ? 0.45 : 0), radius: 3)
                    .offset(x: knobX - thumb / 2)
            }
            .frame(width: width, height: max(22, thumb), alignment: .leading)
            .overlay(alignment: .leading) {
                // 读数气泡：`12:34 / 45:00`（总时长未知时退化为百分比）。
                // 位置跟着手指走，并钳在卡内（贴边时不露到卡片外）。
                if isScrubbing, showsReadout {
                    Text(DockScrub.readout(fraction: f, duration: task.session.duration))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.78), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .offset(x: min(max(knobX - 52, 0), max(0, width - 104)), y: -18)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isScrubbing)
            // 热区比视觉大：手指落在画面底部那一条上都能接住。
            .contentShape(Rectangle().inset(by: -11))
            // ⛔ 必须 `highPriorityGesture`：画面区挂着「搬窗口」的拖动，
            //    同级或外层优先时会变成「拖进度条=搬窗口」。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onScrub(value.location.x, width, false) }
                    .onEnded { value in onScrub(value.location.x, width, true) }
            )
        }
        .frame(height: 22)
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text("\(Int(min(max(fraction, 0), 1) * 100))%"))
    }
}

/// 坞卡片的**倍速键**：点一下在常用档位之间循环，当前倍速直接写在键面上。
///
/// ⛔ 为什么是「循环」而不是弹菜单：坞卡片最小只有 ~120pt 宽，弹菜单会把它盖住，
///    而且坞里常同时挂两三张，菜单不知道该贴哪一张。循环的代价是「找 1.5× 要点三下」，
///    但每一次点击都有立即可见的反馈（键面数字变了），不会误操作。
/// ⛔ 1.0 必须显示成「1×」而不是不显示 —— 用户要能确认「现在就是正常速度」。
private struct DockSpeedButton: View {
    let task: VideoTask

    /// 与观看页倍速菜单同一组档位（`OneSkin.speeds`），避免两处不一致。
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    private var current: Float { task.session.speed }

    /// 键面文字：0.75 → "0.75×"，1 → "1×"，1.5 → "1.5×"。
    private var label: String {
        let s = current
        let text = s == s.rounded() ? String(format: "%.0f", s) : String(format: "%.2g", s)
        return text + "×"
    }

    /// 非 1× 时高亮 —— 用户离开这一集很久再回来，要能一眼看出「怎么一直在快放」。
    private var isBoosted: Bool { abs(current - 1) > 0.001 }

    var body: some View {
        Button {
            let speeds = Self.speeds
            // 找最近的一档再进一格；当前值不在表里（比如外部设成 1.75）时回到 1×。
            let index = speeds.firstIndex { abs($0 - current) < 0.001 }
            let next = index.map { speeds[($0 + 1) % speeds.count] } ?? 1
            task.session.setSpeed(next)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(height: 28)
                .padding(.horizontal, 7)
                .background(isBoosted ? Color.accentColor.opacity(0.85) : .black.opacity(0.5), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Playback Speed"))
        .accessibilityValue(Text(label))
    }
}

/// 图标反映**当前实际状态**（不是「设定值」）：静音就显示斜杠喇叭，
/// 否则按音量显示三档之一。用户扫一眼就知道哪一张在出声。
private struct DockVolumeButton: View {
    @Environment(Store.self) private var store
    let task: VideoTask
    /// 它是不是当前选中的那一张（全局 `.focused` 下只有这张出声）。
    let isActive: Bool
    /// 这一张在坞里的位置与总数 —— **必须与 `applyMuting()` 用同一对值**，
    /// 否则图标/滑杆与实际听到的声音分叉（见 `VideoTaskCard.taskIndex` 的注释）。
    var taskIndex: Int = 0
    var taskCount: Int = 1

    /// 这一张现在**实际**的音量（0…1），用于图标分档与滑杆初值。
    ///
    /// 优先级与 `DockAudioPolicy.output` 一致：卡片设定 → 全局档位。
    private var effectiveVolume: Float {
        let out = DockAudioPolicy.current
            .output(isActive: isActive, taskIndex: taskIndex, taskCount: taskCount,
                    override: task.audioOverride)
        #if DEBUG
        // 探针（真机判据）：UI 侧算出来的音量与它用的入参。
        // #14 的缺陷形态正是「入参两套」——这里若与 applyMuting 的真实
        // index/count 不一致，图标/滑杆就会与实际听到的声音分叉。
        // 真机验收：坞里挂 2 张卡 → 日志里两张卡的 idx/count 必须分别是 0/2、1/2，
        // 且 muted 与图标一致。旧的写死版本恒为 0/1。
        oneSkinLog("DOCKVOL idx=\(taskIndex) count=\(taskCount) active=\(isActive) "
            + "muted=\(out.isMuted) vol=\(String(format: "%.3f", out.volume)) "
            + "override=\(task.audioOverride.map { "\($0)" } ?? "nil")")
        #endif
        return out.volume
    }

    /// 现在到底出不出声。`isMuted` 与 `volume == 0` 都算「不出声」——
    /// 图标要按用户听到的结果画，不能只信其中一个字段。
    private var isSilent: Bool {
        let output = DockAudioPolicy.current
            .output(isActive: isActive, taskIndex: taskIndex, taskCount: taskCount,
                    override: task.audioOverride)
        return output.isMuted || output.volume <= 0.001
    }

    private var symbol: String {
        if isSilent { return "speaker.slash.fill" }
        let volume = effectiveVolume
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Menu {
            Button {
                // 静音与「解除静音」是同一个开关的两种方向：点一下切过去。
                // 解除时回到「跟随全局」，而不是回到某个猜测的音量 ——
                // 用户没有表达过「我要 60%」，替他猜一个数只会让人莫名其妙。
                if isSilent {
                    store.videoTasks.setAudio(nil, for: task.id)
                } else {
                    store.videoTasks.setAudio(.muted, for: task.id)
                }
            } label: {
                Label(isSilent ? L10n.text("Unmute This One") : L10n.text("Mute This One"),
                      systemImage: isSilent ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }

            Divider()

            // 滑杆直接改这一张的音量。设成 `.level(...)` 就等于接管了全局档位。
            //
            // 用 `Slider` 放在菜单里：iOS 允许，且比「点几次加减」好按。
            // `step: 0.05` 让手感有一格一格的感觉，避免拖出 0.4237 这种数。
            Slider(
                value: Binding(
                    get: { Double(effectiveVolume) },
                    set: { store.videoTasks.setAudio(.level(Float($0)), for: task.id) }
                ),
                in: 0...1, step: 0.05
            ) {
                Text("Volume")
            }
            .accessibilityLabel(Text(L10n.text("Volume for this one")))

            Divider()

            Button {
                // 「跟随全局」= 清掉这一张的覆盖。必须给这个出口：
                // 否则用户单独设过之后，就再也回不到「跟着设置走」的状态。
                store.videoTasks.setAudio(nil, for: task.id)
            } label: {
                Label(L10n.text("Follow the Global Setting"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(task.audioOverride == nil)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                // 单独设过声音的那一张加一点底光：坞里几张卡片长得很像，
                // 「哪一张被单独调过」要看得出来，否则用户忘了自己改过什么。
                .overlay {
                    if task.audioOverride != nil {
                        Circle().strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                    }
                }
        }
        .accessibilityLabel(Text(L10n.text(isSilent ? "This one is silent" : "Sound for this one")))
    }
}

/// 迷你播放器的**退出键**（破坏性操作，与播放控制明显区分）。
///
/// 为什么不用普通 `Button` 直接干掉任务：
///   坞里可能同时有好几个任务（要求 5），误触一次就永久丢掉一个正在看的进度。
///   所以：**轻点 = 抖动提示**（告诉用户「这是要长按的」），**长按 = 真正销毁**。
///
/// 视觉：**用项目调色板**，不用系统红 —— 红色在 One 的暗色体系里很突兀。
///   · 底：`OneSkinPalette.button`（#4F4D4D，与「继续播放」按钮同一档）
///   · X：`OneSkinPalette.primary`（#F8F8F8）
///   · 描边：`buttonStroke`（白 16%）
/// 与左上角「暂停」的区分靠**位置**（卡片外沿）和**形状**（更小、带描边），
/// 而不是靠颜色跳出来 —— 坞是常驻浮层，不该有刺眼的红点。
private struct DockCloseButton: View {
    let action: () -> Void
    @State private var nudge = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(OneSkinPalette.primary)
            .frame(width: 20, height: 20)
            .background(OneSkinPalette.button.opacity(0.95), in: Circle())
            .overlay(Circle().strokeBorder(OneSkinPalette.buttonStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 2.5, y: 1)
            .rotationEffect(.degrees(nudge ? 8 : 0))
            .animation(.spring(response: 0.18, dampingFraction: 0.4), value: nudge)
            // 热区 32pt：视觉 20pt 不喧宾夺主，热区够拇指按
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            // ⛔ 不要再做成「长按才关」。
            //
            // 上一版是「轻点抖动提示 / 长按 0.45s 才销毁」，用户实测反馈
            // **「关闭按钮没有反应，关闭不了」** —— 因为预期就是点一下关掉。
            // 防护误触应该靠**热区做小 + 位置在卡片外沿**，不是靠隐藏单击。
            .onTapGesture {
                nudge = true
                action()
            }
            .accessibilityLabel(Text("Close"))
            .accessibilityAddTraits(.isButton)
    }
}

/// 坞本体：一列可拖动、可捏合缩放的卡片，贴在右下角。
///
/// 为什么是「一列」而不是「叠成一摞」：坞里可以同时挂多个（要求 5），一列让用户一眼
/// 看全「现在还有哪几个在看」。叠放会让上面那张的点击区盖住下面的，
/// 而这一版的诉求正是「随时选择回到哪一个」。
/// 坞的**管理入口**：只要有任务就常驻屏幕，与「卡片画不画」无关。
///
/// ## 为什么必须有它
///
/// 用户报「进入播放页迷你小窗就消失了，或者误触也没了」。
///
/// 进观看页时卡片**必须**让位（两层视频叠在一起会穿帮），这没错；
/// 错在让位之后**屏幕上没有任何东西**能证明「这里还有几集在播」，
/// 也没有任何入口把它们叫回来 —— 用户只能猜，猜不到就等于丢了。
///
/// 所以这颗常驻按钮承担三件事：
///   · 点一下 = 收起 / 展开坞里的卡片（`collapsed`）
///   · 长按 / 右键 = 打开坞管理器（悬浮列表，逐集操作）
///   · 角标 = 当前几集在播；有内容被藏起来时图标变实心
///
/// ⛔ 它**不能**自己带 `DragGesture` 之外的命中拦截：
///    坞在右下角，这颗按钮贴在同一角，任何全屏热区都会挡住下面的卡片。
struct DockHandleButton: View {
    @Environment(Store.self) private var store
    /// 前台是否盖着（观看页/全屏播放器）。只用于决定图标与角标。
    let coveredByForeground: Bool

    private var center: VideoTaskCenter { store.videoTasks }

    private var badge: String? { center.badge(coveredByForeground: coveredByForeground) }
    private var hidden: Bool { center.handleShowsHiddenContent(coveredByForeground: coveredByForeground) }

    /// 停靠到哪个角。持久化 —— 下次进来还在用户放开手的那个角。
    @AppStorage("dockHandle.anchor") private var anchorRaw = DockHandleAnchor.bottomTrailing.rawValue
    private var anchor: DockHandleAnchor {
        DockHandleAnchor(rawValue: anchorRaw) ?? .bottomTrailing
    }
    /// 拖动中的自由位置（跟手用）。松手清空，回到吸附角。
    @State private var dragPoint: CGPoint?
    /// 刚刚拖动过 —— 用来吞掉紧随其后的那次点击。
    ///
    /// ⛔ 不加这一条就会「拖完顺手把坞收起/展开」：SwiftUI 里 `Button` 的单击
    ///    与同时挂着的 `DragGesture` 会都收到这次触摸，拖动结束时 `Button`
    ///    仍可能判定为一次 tap。用户只是想挪个位置，结果面板被收起来了。
    @State private var justDragged = false

    private static let buttonSide: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let stopped = DockHandleAnchor.center(of: anchor, in: size,
                                                  button: CGSize(width: Self.buttonSide, height: Self.buttonSide),
                                                  inset: 12)
            let spot = dragPoint.map {
                DockHandleAnchor.clampedCenter($0, in: size,
                                               button: CGSize(width: Self.buttonSide, height: Self.buttonSide),
                                               inset: 12)
            } ?? stopped
            button
                // 用 `position` 而不是 alignment：拖动时要能落在任意位置，
                // 吸附是松手那一刻把点吸回角，不是换 alignment（那会跳一下）。
                .position(x: spot.x, y: spot.y)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            // 中心点跟手：`location` 是触点，按钮中心跟着触点走。
                            dragPoint = value.location
                        }
                        .onEnded { value in
                            // 松手吸附到最近的角，并落盘。
                            let nearest = DockHandleAnchor.nearest(to: value.location, in: size)
                            anchorRaw = nearest.rawValue
                            dragPoint = nil
                            // 吞掉这一次的点击，一口气之后再放开。
                            justDragged = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(280))
                                justDragged = false
                            }
                        }
                )
        }
        // 容器本身不拦命中：只有那颗 44pt 按钮接手势。
        .allowsHitTesting(true)
    }

    private var button: some View {
        Button {
            // 单击：收起/展开。这是最高频的动作。
            // 刚拖过就不算点击（见 `justDragged` 的说明）。
            guard !justDragged else { return }
            center.toggleCollapsed()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: hidden ? "rectangle.inset.bottomright.filled"
                                          : "rectangle.inset.bottomright")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        // 长按打开管理器：逐集看/切/关，比一格格点更省事。
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in center.showsManager = true }
        )
        .contextMenu {
            Button(L10n.text("Manage Mini Players"), systemImage: "list.bullet.rectangle") {
                center.showsManager = true
            }
            Button(center.collapsed ? L10n.text("Show Mini Players") : L10n.text("Hide Mini Players"),
                   systemImage: center.collapsed ? "eye" : "eye.slash") {
                center.toggleCollapsed()
            }
        }
        .accessibilityLabel(Text(L10n.text("Mini Players")))
        .accessibilityValue(Text(badge ?? "0"))
    }
}

/// 坞**管理器**：一个悬浮列表，逐集显示进度并提供切到前台 / 关闭。
///
/// ## 为什么是浮层而不是页面
///
/// 用户要求「要有一个独立的管理器，可以悬浮窗打开」。
/// 做成页面会 push 走当前内容 —— 而坞的意义正是「不打断正在做的事」，
/// 管理器也一样：看一眼、关掉一集、切一集，然后继续原来的页面。
///
/// ⛔ 用 `overlay` + `.transition`，不要用 `.sheet`：
///    sheet 在 Duo 折叠/展开时会重建，且会盖掉坞本身的拖动上下文。
struct DockManagerPanel: View {
    @Environment(Store.self) private var store
    /// 贴着哪一边。右上角入口打开时贴右上。
    var alignment: Alignment = .topTrailing

    private var center: VideoTaskCenter { store.videoTasks }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("Mini Players"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(center.tasks.count)")
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    center.showsManager = false
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Close")))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            // 工具栏：整体动作。原来这里只有「关闭」，用户要一个个点。
            HStack(spacing: 14) {
                Button {
                    // 全部暂停 / 全部继续：按「当前是否还有在播的」决定方向。
                    let anyPlaying = center.tasks.contains { $0.session.player.rate != 0 }
                    for t in center.tasks {
                        if anyPlaying { t.session.player.rate = 0 }
                        else if !center.collapsed || true { t.session.togglePlayback() }
                    }
                    // ⛔ 20 个窗时「全部继续」不能真的让 20 路一起解码 ——
                    //    那是解码器硬上限，不是意愿问题。这里立刻按预算重算一遍：
                    //    超出预算的重新挂起（并记下「本来在播」，轮到它时自动续上）。
                    center.applyMuting()
                } label: {
                    Label(center.tasks.contains { $0.session.player.rate != 0 }
                          ? L10n.text("Pause All") : L10n.text("Play All"),
                          systemImage: center.tasks.contains { $0.session.player.rate != 0 }
                          ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Play All")))

                // 「恢复上次窗口」：把上次退出前开着的小窗一键摆回来。
                //
                // 用户要求：「历史播放窗口 坐标 各个窗口进度，需要记忆住，
                // 在下次重新进入 app 的时候可以一键恢复上次打开的所有迷你小窗」。
                // 只在**有东西可恢复**时给这颗键 —— 按了没反应的键比没有更糟。
                if !center.resumable.isEmpty {
                    Button {
                        Task { await center.restore(center.resumable, store: store) }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.text("Restore Last Windows")))
                }

                // 「整理一次」：把多窗摆成互不重叠的网格、尺寸统一，**摆完就放开**。
                //
                // 用户 2026-11-17：「进行图层整理 状态不应该是锁定的，只整理一次后即可自由拖动，
                // 并且整理要根据平铺来，而不是图层互相折叠了」。所以这里是一个**动作**：
                // 点一下按容器尺寸算一遍网格、写回每张卡的位置与尺寸，然后回到自由模式。
                Button {
                    center.tidy()
                    center.showsManager = false
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Tidy Once")))

                // 「锁定整理」：同一个网格，但位置与尺寸一直由布局决定。
                //
                // 用户要求「锁定整理可以保留，锁定整理得把视窗统一」——
                // 锁定态下所有卡共用格子宽度（`DockLayout.uniformTiles`），
                // 拖动不生效，要摆位就先解锁。
                Button {
                    center.toggleLayoutLock()
                } label: {
                    Image(systemName: center.isLayoutLocked
                          ? "lock.fill"
                          : "lock.open")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(center.isLayoutLocked ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text(center.isLayoutLocked
                                                   ? "Unlock Layout" : "Lock Tiled Layout")))

                Button {
                    // 一键归位：把被拖丢/缩太小的卡片全部拉回来。
                    // 这是用户可执行的自救 —— 比任何边界算法都可靠。
                    center.resetCardPlacement()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Reset Placement")))

                // ⛔ 这里**不再提供「隐藏所有小窗」**。
                //
                // 用户报「管理器里面还是存在会将迷你小窗隐藏的情况，并且不能找回」。
                // 管理器是**管理**的地方，不该有一个把全部窗口藏掉的键 ——
                // 它和「关闭」在视觉上太像，误触就等于「小窗全没了」。
                //
                // 收起/展开留在右下角那颗常驻入口上（`DockHandleButton`），
                // 那里语义明确、且收起来之后入口本身还在，永远找得回来。

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    center.removeAll()
                    center.showsManager = false
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Close All")))

                Button {
                    center.showsManager = false
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Close")))
            }
            .padding(.horizontal, 12).padding(.bottom, 10)

            // 被挂起的说明：卡片多于解码预算时，后面几路是暂停的。
            // 不明说的话，用户会以为「坏了」。
            // 状态行：几路在播 / 几路被挂起。
            //
            // 2026-11-16 起 `decoding == dock`，挂起数恒为 0，所以平时显示的是
            // 「N 路同时播放」—— 这是用户要的可观测证据：他要能确认「八个都真的在解」，
            // 而不是只看卡片在那儿。若哪天把 `decoding` 调小，这一行会立刻变成
            // 「x 路播放 · y 路已暂停」，不需要再改 UI。
            let suspended = DockDecodingBudget.suspendedCount(order: center.tasks.map(\.id),
                                                              budget: PlaybackCapacity.decoding)
            let playing = center.tasks.filter { $0.session.player.rate != 0 }.count
            HStack(spacing: 6) {
                Text(suspended == 0
                     ? L10n.text("%@ playing at once", String(playing))
                     : L10n.text("%@ playing · %@ paused", String(playing), String(suspended)))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(center.tasks) { task in
                        row(task)
                        Divider().padding(.leading, 60)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private func row(_ task: VideoTask) -> some View {
        // ⛔ **整行不再是 Button**（原来是这样，于是「点一下就关掉」）。
        //
        // `take()` 的语义是「把这一集**从坞里摘走**、交回前台」。挂在整个行上之后，
        // 用户在管理器里点标题、点海报、点进度，任何一下都会把窗口摘掉 ——
        // 他并不是要切回前台，只是想看一眼或点个暂停。这就是用户报的
        // 「点对应窗口直接关闭」。
        //
        // 现在：行本身只负责显示与选中；**只有「切到前台」那颗明确的键才 take**。
        HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.35))
                    // 走 `PosterImage`：源的海报常要 Referer，裸 `AsyncImage` 会 403。
                    if let url = task.posterURL {
                        PosterImage(url: url, headers: task.posterHeaders)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "play.rectangle").foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 44, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.footnote.weight(.medium)).lineLimit(1)
                    Text(task.subtitle.isEmpty ? "\(Int(task.fraction * 100))%"
                                               : task.subtitle)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)

                // 「设为主选择」：只换主语（蓝框 / PiP / 音频），不摘除、不跳页。
                //
                // 用户要求「在管理器应该能进行这个切换，因为这个蓝框影响应用外小窗播放主体是谁」。
                // 主选择决定三件事，全在 `activeTask` 上：
                //   · 蓝框画在哪张卡（`isActive`）
                //   · 应用外小窗（PiP）的 `contentSource` 交给谁
                //   · 哪一路出声（`DockAudioPolicy`）
                Button {
                    center.activate(task.id)
                } label: {
                    Image(systemName: task.id == center.activeTaskID
                          ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(task.id == center.activeTaskID ? Color.accentColor : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Make Active")))

                // ⛔ 这里**不再有「上移一层」**。
                //
                // 用户 2026-11-17：「调整图层顺序应该单击即响应，点击则挪到最前，
                // 而不是在面板里复杂操作」。逐层按钮就是那个「复杂操作」：
                // 要叠三层就得在这个列表里按三次，而且按完还得回去看效果。
                //
                // 现在改图层只有一种手法：**点那张卡片**（轻点 = 提到最前 + 成为主选择）。
                // 这个列表里点某一行也等价（见 `row` 末尾的 `onTapGesture`）。

                // 「回到选集页」：把这集从坞里摘走，并把页面推到它的选集页。
                //
                // ⛔ 原来这里只调了 `take`，**没有设 `pendingTaskRoute`** ——
                //    于是任务从坞里消失了，页面却原地不动。用户报的
                //    「管理器能不能回到选集页面」就是这一条：
                //    点一下，小窗没了，但什么也没发生，等于把窗口弄丢了。
                //
                // 现在与卡片双击走**同一条**路径（`open()` 的语义）：
                // take → 拿到 video/client → 把 Route 交给 `pendingTaskRoute`。
                Button {
                    guard let target = center.take(task.id, store: store) else {
                        center.showsManager = false
                        return
                    }
                    center.showsManager = false
                    store.pendingTaskRoute = Route {
                        AnyView(VideoDetailView(video: target.video, client: target.client))
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Episode List")))

                Button {
                    task.session.togglePlayback()
                    // 同上：管理器里的「播放」也不能绕过解码预算。
                    center.applyMuting()
                } label: {
                    Image(systemName: task.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(task.isPaused ? "Play" : "Pause"))

                Button(role: .destructive) {
                    center.remove(task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Close")))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            // 点这一行 = 设为主选择 + **提到最前**（同一个动作，见 `activate`）。
            //
            // 列表顺序就是图层顺序（第一行最上），所以点一下的效果与直接点卡片一样：
            // 它跳到第一行，同时蓝框、PiP 主体、声音都归它。**不摘除**、不跳页。
            .onTapGesture { center.activate(task.id) }
            // ★ 长按拖动 = 把这扇窗「拖出来」摆到松手的位置。
            //
            // ⛔ 用 `LongPressGesture` 起手再转 `DragGesture`，不要直接用 DragGesture：
            //    这一行里还有四个按钮（设为主窗 / 选集页 / 暂停 / 关闭），
            //    裸 DragGesture 会在手指一落下时就把点击吃掉，按钮全按不动。
            //    长按 0.3s 起手是 iOS 上「把东西拎起来」的通行手势，不与点击冲突。
            //
            // ⛔ 落点用 `coordinateSpace: .global`（屏幕坐标），由坞换算成自己的相对坐标 ——
            //    管理器是**浮层**，它的局部坐标与坞毫无关系，用 `.local` 会把窗口扔到屏幕外。
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value else { return }
                        center.requestDrop(task.id, at: drag.location)
                        center.showsManager = false
                    }
            )
    }
}

/// 坞里**一张已摆放的卡片**：位移与拖动状态住在这一层。
///
/// ## 为什么单独拆出来（拖动卡顿的根因修法）
///
/// 位移原来写在坞的 `@State perCardOffset` 里。拖动时每帧改一次，**整个坞 body 重算**：
/// 所有卡的 `DockPlayerLayer`（`UIViewRepresentable`）都会被 `updateUIView` 碰一遍 ——
/// 重设 `videoGravity`、重跑 `pip.attach`、重新布局视频层。八张卡一起被这样折腾，
/// 帧率就掉下来了，用户看到的是「拖起来一顿一顿」。
///
/// 现在位移是这一层自己的 `@State`，拖动只让这张卡的 body 失效。
///
/// ## 两级缓存，缺一不可
///
/// 1. **本层 `@State dragOffset`**：位移只影响自己。
/// 2. **视频层 `DockVideoLayerBox` 等值短路**：拖动期间真正影响画面的值
///    （player/gravity/pip/covered/尺寸）**一个字都没变**，所以 `updateUIView`
///    不会被每帧调用 —— 那里面重设 `videoGravity`、重跑 `pip.attach`、
///    重新布局 `AVPlayerLayer`，才是掉帧的直接原因。
/// 「搬窗口」的命中区：**底部让开 `bottomInset`**，其余区域照常。
///
/// ⛔ 为什么需要自定义 Shape：`Rectangle().inset(by:)` 是**四边等距**内缩，
///    会把左右和顶部也一起吃掉 —— 那会让贴近边缘的拖动失效。
///    这里只缩底部一条，正好对应进度条的热区。
struct DockDragShape: Shape {
    var bottomInset: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY,
                    width: rect.width,
                    height: max(0, rect.height - bottomInset)))
    }
}

/// 拖动窗口的命中区要从底部让开多少（pt）。
///
/// ⛔ 必须盖住进度条的**实际命中区**，不是它的视觉高度：
///    `DockProgressBar` 视觉 `.frame(height: 22)`，但 `.contentShape(Rectangle().inset(by: -11))`
///    把热区上下各外扩 11pt ⇒ 实际命中区高 **44pt**。
///    按 22 让开，仍会有 22pt 叠在一起抢触摸 —— 那就是「拖进度时窗口跟着动」。
///
/// 取 44 让开整个热区。代价是画面底部 44pt 不能拖窗口，
/// 但那一段本来就该调进度（正是用户要的），不影响搬窗口的手感。
let dockProgressHitHeight: CGFloat = 44

private struct DockPlacedCard: View {
    @Environment(Store.self) private var store
    let task: VideoTask
    let index: Int
    let width: CGFloat
    /// 锁定整理时的**统一宽度**（格子宽）。非空时压过 `width × ownScale`。
    ///
    /// 用户要求「锁定整理得把视窗统一」—— 统一的是**渲染宽度**，
    /// 所以不能靠把每张卡的 `ownScale` 调成同一个值（各卡基础宽相同但比例不同，
    /// 而且 `ownScale` 是用户捏出来的个人偏好，不该被布局改写）。
    let widthOverride: CGFloat?
    /// 位置与尺寸都由布局锁死：拖动照收手势，但不写回（拖不动的感觉才叫锁定）。
    let locksPlacement: Bool
    let gravity: AVLayerVideoGravity
    let pip: PictureInPicture?
    let isActive: Bool
    let coveredByForeground: Bool
    let ownScale: CGFloat
    let onScaleChange: (CGFloat) -> Void
    let containerSize: CGSize
    let taskCount: Int
    let resetRequest: Int
    let slot: CGSize
    /// 平铺模式下的位置。非空时**压倒** `dragOffset` 与 `slot`。
    ///
    /// 平铺是「把多窗整理好」，用户不该再手动微调某一格 ——
    /// 位置完全由布局决定才叫平铺。
    let tileOffset: CGSize?
    /// 这张卡此刻是否处于伪全屏（双击置顶）。
    ///
    /// 只影响两件事：`placed` 临时返回 `.zero`（居中铺满），以及禁用拖拽/捏合。
    /// **不参与**宽度计算 —— 宽度走 `widthOverride`，由坞层每帧从容器反算。
    let pseudoFullscreen: Bool
    /// 双击回调（坞层持有状态，卡片只上报）。见 `VideoTaskCard.onDoubleTap`。
    let onDoubleTap: () -> Void

    /// 这张卡当前位置。`nil` 表示还在默认落点上。
    ///
    /// ⛔ 初值取自**上次存档的坐标**（`lastKnownOffset`）——
    ///    这是「记住窗口坐标」在视图侧的落点。没存过才用默认错开排布。
    @State private var dragOffset: CGSize?
    /// 是否已把存档坐标接上。**用类实例，不用 `@State`。**
    ///
    /// ⛔ 这是「拖动一直飘」的第二个根因：
    ///    守卫是 `@State` 时，视图**重建一次它就重置为 false**，
    ///    于是 `onAppear` 又跑一遍 seed，把 `dragOffset` 拽回 `lastKnownOffset`。
    ///    而 `lastKnownOffset` 刚在上一轮拖动结束时被写过 ——
    ///    拖动中只要发生一次视图重建，位置就被拉回原位，表现为「一直飘」。
    ///
    ///    换成引用容器后，守卫不随视图重建重置，seed 真的只做一次。
    private final class SeedFlag { var done = false }
    @State private var seedFlag = SeedFlag()
    /// 捏合时的瞬时倍率（松手才算进 `ownScale`）。
    @State private var pinch: CGFloat = 1
    /// 拖动起点（`DragGesture.translation` 是相对起手的累计量）。
    /// 拖动基准。**用类实例，不用 `@State`。**
    ///
    /// ⛔ 这是「拖动一直跳动/一直飘」的根因：
    ///    `onChanged` 里 `if dragStart == nil { dragStart = placed }` 这一句，
    ///    在 `dragStart` 是 `@State` 时**会触发一次 body 重算**。
    ///    重算会重建传给卡片的闭包 → 手势上下文被打断 → 下一帧 `translation`
    ///    重新从 0 起算，而基准又刚被换过 ⇒ 位置在「基准 + 累计」之间来回跳。
    ///
    ///    改成引用容器后，读、写都不进 SwiftUI 的依赖图，
    ///    拖动过程中只有 `dragOffset` 一处会让视图失效，闭环干净。
    private final class DragAnchor { var value: CGSize? }
    @State private var dragAnchor = DragAnchor()

    /// 这张卡的位置。伪全屏时**临时返回 `.zero`**（居中铺满）。
    ///
    /// ⛔ 为什么用「读时覆写」而不是「进入时存原值、退出时写回」：
    ///    写回方案要处理「伪全屏期间 dragOffset 被整理/重钳/转屏改过」的冲突，
    ///    而 `dragOffset` / `slot` / `tileOffset` 在本方案里**全程一个字节都没被写**，
    ///    退出伪全屏后这个计算属性自动回到原值 —— 零还原成本、零状态同步风险。
    ///    （captain 2026-11-17 指出我先前的设计自相矛盾：既说「不动位置」又说「居中铺满」。
    ///      矛盾的正确解法就是这个：**位置来源不变，只在读的时候换个值**。）
    private var placed: CGSize {
        if pseudoFullscreen {
            // ⛔ **不能返回 `.zero`**：坞的 ZStack 是 `alignment: .bottomTrailing`（:2987），
            //    `.offset(.zero)` 意味着「卡片右下角贴容器右下角」= 落在角上，不是居中。
            //
            // 居中所需的偏移：bottomTrailing 对齐时卡片左上角默认在
            // `(W−cw, H−ch)`，要挪到 `((W−cw)/2, (H−ch)/2)` ⇒ 偏移为负的一半余量。
            //
            // `cardSize` 此刻已是**伪全屏尺寸**（它由 `renderWidth` 派生，而
            // `renderWidth ← askedWidth ← widthOverride ← pseudoFullscreenWidth`），
            // 所以这里量的是放大后的卡片，量对了。
            let c = cardSize
            return CGSize(width: -(containerSize.width - c.width) / 2,
                          height: -(containerSize.height - c.height) / 2)
        }
        return tileOffset ?? dragOffset ?? slot
    }

    /// 这张卡**没被容器压过**的整卡宽度。
    private var askedWidth: CGFloat { widthOverride ?? (width * ownScale) }

    /// 真正拿去渲染的宽度：先过 `fit`，保证捏到再大也放得进容器。
    ///
    /// ⛔ 只钳位不钳尺寸是不够的：用户能捏到 2.2 倍，320pt 的基础宽在手机上
    ///    就是 700pt+，比屏幕还宽 —— 那种尺寸无论怎么摆都要出界，
    ///    而 `DockCardClamp` 在「卡片比容器大」时只能居中溢出。
    private var renderWidth: CGFloat {
        guard containerSize.width > 1, containerSize.height > 1 else { return askedWidth }
        let aspect = max(task.aspectRatio, 0.2)
        let fitted = DockCardClamp.fit(
            CGSize(width: askedWidth,
                   height: askedWidth / aspect + VideoTaskDock.chromeHeight),
            in: containerSize)
        return fitted.width
    }

    /// 拖动允许的位移区间（相对**起手位置**）。
    ///
    /// 由「偏移的合法区间」减去当前基准得到：`base + delta` 必须仍在
    /// `[card + margin - container, -margin]` 之间。
    /// 卡片比容器还宽时区间会反向，这里用 min/max 归一 —— 那种情况下交给 `fit` 收尺寸。
    private var panBounds: CGRect {
        // 伪全屏时**禁用拖拽**：返回空区间，任何位移都会被夹回原点。
        // （尺寸与位置都由容器决定，手动拖动必然出界。）
        if pseudoFullscreen { return CGRect(x: 0, y: 0, width: 0, height: 0) }
        let base = dragOffset ?? slot
        let m = DockCardClamp.margin
        let loX = cardSize.width + m - containerSize.width - base.width
        let hiX = -m - base.width
        let loY = cardSize.height + m - containerSize.height - base.height
        let hiY = -m - base.height
        return CGRect(x: min(loX, hiX), y: min(loY, hiY),
                      width: abs(hiX - loX), height: abs(hiY - loY))
    }

    /// 这张卡此刻的整卡尺寸（含标题栏），钳位与存档都用它。
    private var cardSize: CGSize {
        CGSize(width: renderWidth,
               height: renderWidth / max(task.aspectRatio, 0.2) + VideoTaskDock.chromeHeight)
    }

    var body: some View {
        card
            // ⛔ 位移必须**逐帧即时**，所以显式清掉动画。
            //
            // 祖先（坞的 ZStack）挂着一个 `.animation(.smooth(0.22), value: 卡片id序列)`，
            // 那是给「卡片增删」用的。但它会向下渗透到子树的**所有**几何变化 ——
            // 包括这里的 `.offset`。不清掉的话，手指拖动时画面被 0.22 秒动画追着走，
            // 就是「不跟手、松手才显示」。
            //
            // 用 `transaction` 而不是在外面关掉整个动画，是为了**只**影响位移这一处：
            // 增删过渡、缩放动效都还在。
            //
            // ⛔ 顺序：`transaction` 必须写在 `.offset` **之后**。
            //    修饰符只作用于它之前已构建的视图链 —— 写在前面盖不住 `offset`，
            //    等于白写（而且不会报错，只会「看起来没生效」）。
            // `transition` 放在 `transaction` **外层**（更靠后）：增删过渡走祖先的
            // `.animation(..., value: id 序列)`，不经过下面那个 `animation = nil`。
            .offset(placed)
            .transaction { $0.animation = nil }
            // ⛔ 这里**不再挂拖动**。
            //
            // 拖动已经下移到 `VideoTaskCard.dragSurface`，只覆盖画面区 ——
            // 那是用户的明确要求：「进度条部分 和下方白条标题栏 部分不应该拖动小窗位置」。
            // 挂在整张卡上会让底部 22pt 的进度条热区和标题栏都变成「拖窗口」，
            // 进度条就再也拖不动了。
            //
            // 捏合仍留在整卡：缩放窗口在哪个区域开始都合理（用户不会在标题栏上捏）。
            .simultaneousGesture(pinchGesture)
            // ★ 搬窗口的手势**挂在这一层**（摆放层），用 `@GestureState` 驱动。
            //
            // ⛔ 为什么必须在这里、而不是在卡片的 `dragSurface` 里：
            //    卡片是通过**闭包参数**把拖动上报出来的。闭包每帧都是新对象，
            //    SwiftUI 判定「入参不等」→ 卡片树（含 `DockVideoLayerBox`）每帧重建
            //    → 位置在重建中抖动。这就是「一直跳、一直飘」。
            //
            //    现在手势只改卡片自己的 `livePan`（`@GestureState`），它不参与依赖重算，
            //    拖动期间卡片树完全不动，只有布局用新值画偏移 —— 干净跟手。
            //    松手时才把结果写进 `dragOffset`（`@State`），负责持久化与重钳。
            // 搬窗口已下移到卡片画面区（见 `VideoTaskCard.dragSurface`）。
            //
            // ⛔ 这里**不能再挂拖动**。摆放层的 `.gesture` 会被卡片内 tap 的
            //    `simultaneousGesture` 抢先（子层优先），表现为「松手才跳」；
            //    换成 `simultaneousGesture` 又会覆盖进度条热区（拖进度时窗口也动）。
            //    两个位置都试过，只有挂在卡片画面区内部才同时满足两边。

            .transition(.scale(scale: 0.9).combined(with: .opacity))
            // 首次出现时把存档坐标接上（只做一次，之后由用户拖动决定）。
            .onAppear {
                guard !seedFlag.done else { return }
                seedFlag.done = true
                if task.lastKnownOffset != .zero { dragOffset = task.lastKnownOffset }
            }
            // ⛔ 兜底：容器尺寸一变（折叠/展开、转屏）就重新钳一次。
            //
            // 用户在横屏把窗口摆在右侧，合上机身之后那块区域可能整块不存在了 ——
            // 卡片就成了「有、但看不见、也点不到」。这正是用户说的
            // 「不能找回不在屏幕内的小窗」。
            //
            // 不能只靠拖动时的 clamp：那只在**用户下一次拖**的时候生效。
            //
            // ⛔ 卡片的尺寸必须用 `cardSize`（含捏合后的宽度与标题栏），
            //    不是基础 `width` —— 用基础宽算边界，放大后的卡照样会出屏。
            .onChange(of: containerSize) { _, new in
                guard new.width > 1, new.height > 1 else { return }
                // 锁定时位置由网格算，不需要这里兜底。
                guard !locksPlacement, let cur = dragOffset else { return }
                let fixed = DockCardClamp.clamp(cur, card: cardSize, in: new)
                if fixed != cur {
                    dragOffset = fixed
                    task.lastKnownOffset = fixed
                }
            }
            // 从管理器拖出来的落点：直接把自己摆过去（先钳一次，落点也可能在屏幕外）。
            .onChange(of: store.videoTasks.pendingDropOffset[task.id]) { _, landed in
                guard let landed else { return }
                let fixed = DockCardClamp.clamp(landed, card: cardSize, in: containerSize)
                dragOffset = fixed
                dragAnchor.value = nil
                store.videoTasks.pendingDropOffset[task.id] = nil
            }
            // 一键归位：把自己回到默认落点。
            .onChange(of: resetRequest) { _, _ in
                dragOffset = nil
                dragAnchor.value = nil
                pinch = 1
            }
    }

    /// 卡片本体。`Equatable` 短路：拖动期间入参不变，这里直接跳过重建。
    private var card: some View {
        VideoTaskCard(task: task, width: widthOverride ?? width, gravity: gravity,
                      isActive: isActive, pip: pip,
                      coveredByForeground: coveredByForeground,
                      // 渲染宽度 / 基础宽 = 这一帧该用的倍率（已过 `fit`）。
                      ownScale: renderWidth / max(widthOverride ?? width, 1),
                      onScaleChange: onScaleChange,
                      taskIndex: index, taskCount: taskCount,
                      externalPinch: pinch,
                      isLayoutLocked: locksPlacement,
                      panBounds: panBounds,
                      // ★ 松手才上报：拖动中的逐帧位移由卡片自己的
                      //   `livePan` 承担，这里只负责「落定 + 存档」。
                      onPanEnded: { translation in
                          // 锁定整理时位置由网格决定，手动拖不生效 ——
                          // 不然「锁定」只是看起来锁定，松手就漂走。
                          guard !locksPlacement else { return }
                          let base = dragOffset ?? slot
                          let raw = CGSize(width: base.width + translation.width,
                                           height: base.height + translation.height)
                          let final = DockCardClamp.clamp(raw, card: cardSize, in: containerSize)
                          dragOffset = final
                          task.lastKnownOffset = final
                          if let context = task.channel.historyContext {
                              VideoTaskCenter.savePlacement(context.id + "|" + context.episodeID,
                                                            scale: ownScale, offset: final)
                          }
                      },
                      // ⚠️ 必须写在 `onPanEnded` **之后**：Swift 成员初始化按声明顺序
                      //    （`VideoTaskCard.onPanEnded` 声明在前、`onDoubleTap` 在其后）。
                      onDoubleTap: onDoubleTap)
    }


    private var pinchGesture: some Gesture {
        MagnificationGesture()
            // 伪全屏时**禁用捏合**：尺寸由容器反算，手捏会与它打架；
            // 且松手时 `DockCardClamp.clamp` 会按伪全屏尺寸钳位，把卡片推到界外。
            .onChanged { value in
                guard !pseudoFullscreen else { return }
                pinch = locksPlacement ? 1 : value
            }
            .onEnded { value in
                defer { pinch = 1 }
                guard !locksPlacement, !pseudoFullscreen else { return }
                onScaleChange(min(max(ownScale * value, 0.35), 2.2))
            }
    }
}

struct VideoTaskDock: View {
    @Environment(Store.self) private var store
    let gravity: AVLayerVideoGravity
    let pip: PictureInPicture
    /// 前台观看页在演 —— 坞里所有卡的画面都让出 `AVPlayer`（见 `DockPlayerLayer`）。
    var coveredByForeground: Bool = false
    /// **每张卡各自的缩放**（键是 `VideoTask.id`）。缺省 1。
    @State private var perCardScale: [UUID: CGFloat] = [:]
    /// **每张卡各自的位置**（相对右下角的偏移）。缺省 `.zero`。
    /// 坞整体的位置（没有卡片自己的偏移时作起点）。由 `RootView` 持有以便换形态重钳。
    @Binding var offset: CGSize
    /// 坞整体缩放（仅作**基础宽度**；单卡缩放另算，见 `perCardScale`）。
    @Binding var scale: CGFloat

    /// **伪全屏**：双击某张卡把它铺满容器并置顶，再双击还原（用户 2026-11-17）。
    ///
    /// ## 为什么只存 id，不存尺寸
    ///
    /// ⛔ 尺寸**不能**存成常量。伪全屏宽度必须每帧从 `containerSize` 反算 ——
    ///    转屏 / 折叠 / 展开都会改容器，存常量就会重演用户报过的
    ///    「窗口溢出屏幕太多」。所以这里只记「是哪一张」，尺寸见 `pseudoFullscreenWidth`。
    ///
    /// ## 必须保存「原位置」（captain 2026-11-17 复核抓到我的设计矛盾）
    ///
    /// 我先前写过「只改宽度、不动位置 ⇒ 不用存原位置」，**那是错的**。
    /// 事实：卡片的唯一位置来源是 `.offset(placed)`（`:2664`），而
    /// `placed = tileOffset ?? dragOffset ?? slot`（`:2605`）。
    /// 伪全屏若要让卡片**居中铺满**，`.offset` 必须给 `.zero` —— 那就覆盖了 `placed`，
    /// 不存原值就还原不回去（卡片会停在左上角）。
    ///
    /// 但**不需要把原位置存进坞层**：让 `placed` 在伪全屏时临时返回 `.zero` 即可
    /// （见 `DockPlacedCard.placed` 的 `guard`）。`dragOffset` 与 `slot` 全程未被写，
    /// 退出时 `placed` 自动回到原值 —— 零还原成本、零状态同步风险。
    /// 这比「存快照 + 退出写回」更稳：写回要处理「期间的拖动/整理/转屏改了 dragOffset」的冲突，
    /// 而临时覆写读值不产生任何冲突面。
    @State private var pseudoFullscreenID: UUID?

    /// 卡片钳位：判据与实现在 `TVCore/DockCardClamp`（那里能单测）。
    /// 这里只做一次转调，避免两处各写一份边界公式。
    static func clampCardOffset(_ offset: CGSize, card: CGSize, in container: CGSize) -> CGSize {
        DockCardClamp.clamp(offset, card: card, in: container)
    }

    /// 卡片标题栏高度（pt）。
    ///
    /// ⛔ 平铺时**必须算进格子高度**：卡片高度 = 画面高 + 标题栏，少了这 34pt，
    ///    每张卡都比自己的格子高一截，上下两排就会叠在一起 ——
    ///    用户说的「整理完图层互相折叠了」有一半来自这里。
    static let chromeHeight: CGFloat = 34

    /// 伪全屏宽度：**每帧从容器双向反算**（不是常量）。
    ///
    /// 公式：高度上限 = 容器高 − 标题栏；按片源比例反算宽度；再与容器宽取小。
    /// 这样宽、高**都不超容器**，转屏/折叠后自动跟上。
    ///
    /// ⛔ 不能只给 `containerSize.width`：`renderWidth` 只钳宽度，
    ///    高度是 `width / aspect + chromeHeight` —— 竖屏片源（aspect ≈ 0.56）
    ///    直接给满宽会算出远超容器的**高度**，正是「溢出」的成因。
    private func pseudoFullscreenWidth(for task: VideoTask, in container: CGSize,
                                       safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat? {
        guard container.width > 1, container.height > 1 else { return nil }
        let aspect = max(task.aspectRatio, 0.2)
        // ⛔ 安全区必须显式扣掉（captain 2026-11-17 指出我原公式漏了这一项）：
        //    伸进刘海 / Home 条会让右上关闭键与底部进度条被遮挡。
        let maxPictureHeight = container.height - Self.chromeHeight - safeTop - safeBottom
        guard maxPictureHeight > 1 else { return nil }
        let byHeight = maxPictureHeight * aspect
        return min(container.width, byHeight)
    }

    /// 整理（单次整理 / 锁定整理）用的格子。
    ///
    /// 统一宽度、逐行排开、从右下角往里收 —— 用户要求「整理要根据平铺来」
    /// 「锁定整理得把视窗统一」。几何在 `DockLayout.packedTiles`（能单测），
    /// 这里只负责把当前的卡片比例与基础宽度喂进去。
    private func tidyTiles(in container: CGSize, cardWidth: CGFloat) -> [DockLayout.Tile] {
        let tasks = store.videoTasks.tasks
        guard !tasks.isEmpty else { return [] }
        return DockLayout.packedTiles(count: tasks.count,
                                      aspects: tasks.map { max($0.aspectRatio, 0.2) },
                                      cardWidth: cardWidth,
                                      chrome: Self.chromeHeight,
                                      in: container)
    }

    /// 「整理一次」：按当前容器算一遍整齐的网格，写进每张卡的位置与尺寸，
    /// 然后**回到自由模式** —— 整理是动作，不是状态。
    ///
    /// - Parameter keepLocked: 由「锁定整理」触发时传 true（保持锁定）。
    ///   锁定那一下也要把位置与尺寸**写进每张卡自己的账**，
    ///   否则解锁的瞬间它们会跳回锁定前的位置 —— 用户会以为「一解锁就散了」。
    private func applyTidy(container: CGSize, cardWidth: CGFloat, keepLocked: Bool = false) {
        let tasks = store.videoTasks.tasks
        let tiles = tidyTiles(in: container, cardWidth: cardWidth)
        guard !tiles.isEmpty else { return }
        var landed: [UUID: CGSize] = [:]
        for (index, task) in tasks.enumerated() where index < tiles.count {
            let tile = tiles[index]
            let offset = DockCardClamp.clamp(DockLayout.offset(for: tile, in: container),
                                             card: tile.size, in: container)
            // 统一视窗：每张卡的缩放都落到**同一个格子宽**。
            let scaleForCard = tile.size.width / max(cardWidth, 1)
            perCardScale[task.id] = scaleForCard
            task.lastKnownOffset = offset
            landed[task.id] = offset
            if let context = task.channel.historyContext {
                VideoTaskCenter.savePlacement(context.id + "|" + context.episodeID,
                                              scale: scaleForCard, offset: offset)
            }
        }
        withAnimation(.smooth(duration: 0.25)) {
            store.videoTasks.pendingDropOffset = landed
            if !keepLocked { store.videoTasks.layoutMode = .free }
        }
    }

    /// 管理器的拖放落点。坐标系三层必须分清（这里是本类型最容易错的地方）：
    ///   ① 管理器给的 `point` 是**屏幕（global）**坐标；
    ///   ② 卡片偏移是**相对坞右下角**的偏移（往左/上为负）；
    ///   ③ 容器尺寸是坞自己的 `geo.size`。
    ///
    /// 换算：坞内坐标 = 全局点 − 坞的全局原点 → 再转成相对右下角的偏移。
    private func handleDrop(_ request: VideoTaskCenter.DropRequest,
                            container geo: GeometryProxy,
                            width: CGFloat) {
        guard let point = request.point else { return }
        let origin = geo.frame(in: .global).origin
        let insideX = point.x - origin.x
        let insideY = point.y - origin.y
        // 卡片中心落到手指处：相对右下角 = 坞内点 − 容器右下角。
        let raw = CGSize(width: insideX - geo.size.width,
                         height: insideY - geo.size.height)
        guard let task = store.videoTasks.tasks.first(where: { $0.id == request.id }) else { return }
        let cardH = width / max(task.aspectRatio, 0.2) + Self.chromeHeight
        let clamped = DockCardClamp.clamp(raw,
                                          card: CGSize(width: width, height: cardH),
                                          in: geo.size)
        task.lastKnownOffset = clamped
        // 立刻反映到视图：把落点写进这张卡的状态。
        store.videoTasks.pendingDropOffset = [request.id: clamped]
    }

    var body: some View {
        GeometryReader { geo in
            if !store.videoTasks.tasks.isEmpty {
                let landscape = geo.size.width > geo.size.height
                let baseWidth = landscape ? min(geo.size.width * 0.34, 320) : min(geo.size.width * 0.62, 240)
                // ⛔ 不要再用「多张就整体缩到 72%」。
                //
                // 用户明确要求：「迷你小窗每个窗口要能单独调整大小，而不是黏成一块」。
                // 原来这里是坞级一个 `packed` 系数，所有卡片共用一个 `width` ——
                // 改大小只能整列一起变，且多张时被强制压到 72%，视觉上就「黏成一块」。
                // 现在每张卡有自己的 `perCardScale`，坞只提供「基础宽度」。
                let width = min(max(baseWidth * scale, 120), geo.size.width - 24)
                // ★ 每张卡是**独立的浮窗**，不是一个列表里的行。
                //
                // 用户的诉求原话：「迷你小窗每个窗口要能单独调整大小，而不是黏成一块」、
                // 「我拉着一个走，另外一个也走，缩放一个另外一个也缩放」。
                // 所以这里不再用 `VStack` 排成一列 —— 那样天然共享父级 offset/手势。
                //
                // 现在：`ZStack` 里每张卡各自 `.offset(自己的位置)`、各自带
                // `DragGesture` 与 `MagnificationGesture`，位置与大小都按 `task.id` 分开存。
                // 初次出现时给一个错开的默认落点（右下角往上排），之后完全由用户摆布。
                // 整理网格**算一次**，别在 `ForEach` 里每张卡各算一遍。
                //
                // ⛔ 原来这一行写在 `ForEach` 内部：`packedTiles` 里有「按 0.05 步长往下试」
                //    的循环（最多十几轮 × 行列），8 张卡就是 8 次完整试排，而且每次 body
                //    重算都要再来一遍。它只是「给定张数与容器」的纯函数，本来就该在循环外。
                let tiles = tidyTiles(in: geo.size, cardWidth: width)
                ZStack(alignment: .bottomTrailing) {
                    ForEach(Array(store.videoTasks.tasks.enumerated()), id: \.element.id) { index, task in
                        // ★ 每张卡包一层 `DockPlacedCard`，**位移状态就住在这一层里**。
                        //
                        // ⛔ 这是「拖动时卡顿」的根因修法。
                        //
                        // 原来位移写在坞自己的 `@State perCardOffset` 上。拖动一帧改一次，
                        // **整个坞 body 都要重算** —— 于是每帧都会重建所有卡的
                        // `DockPlayerLayer`（`UIViewRepresentable`），`updateUIView` 里
                        // 每次都在重设 `videoGravity`、重跑 `pip.attach`、重新布局视频层。
                        // 8 张卡一起被这么折腾，帧率当然掉。
                        //
                        // 现在位移属于这一张卡自己的 `@State`：拖动只让**这一张**的 body 失效，
                        // 兄弟卡片的 `DockPlayerLayer` 不会被 `updateUIView` 再碰一次。
                        //
                        // ⛔ 视频层另有 `DockVideoLayerBox` 做等值短路 —— 拖动时它拦住
                        //    `DockPlayerLayer.updateUIView`，这才是掉帧的直接原因。
                        // 参数先落到局部常量，再交给 `DockPlacedCard`。
                        //
                        // ⛔ 不这么写，编译器会报「unable to type-check in reasonable time」——
                        //    这个 init 有 15 个参数，其中三个是内联的闭包/方法调用，
                        //    一起塞进一个字面量就超出类型推导预算。
                        let cardCount = store.videoTasks.tasks.count
                        let locked = store.videoTasks.isLayoutLocked
                        let tile = index < tiles.count ? tiles[index] : nil
                        // 锁定整理：位置与宽度都由格子给，用户拖不动、捏不动。
                        // 再钳一次是兜底：卡多到连最小缩放都排不下时，网格会顶到屏幕外。
                        let thisTile: CGSize? = locked
                            ? tile.map {
                                DockCardClamp.clamp(DockLayout.offset(for: $0, in: geo.size),
                                                    card: $0.size, in: geo.size)
                              }
                            : nil
                        // 新窗（还没有自己的坐标）的默认落点 = 同一个网格里它那一格。
                        //
                        // ⛔ 原来这里是「第 n 张往上错开 n 个卡高」：8 张时最后几张
                        //    整块在屏幕上方之外 —— 既看不见也点不到，正是用户说的
                        //    「图层互相折叠」。现在默认就是整齐的一格，绝不出屏。
                        let slot = tile.map { DockLayout.offset(for: $0, in: geo.size) } ?? .zero
                        // 伪全屏优先级**高于**平铺统一宽：用户在伪全屏时整理一次，
                        // 期望的是「继续满屏」，不该被打回格子尺寸。
                        let pseudoWidth = (pseudoFullscreenID == task.id)
                            ? pseudoFullscreenWidth(for: task, in: geo.size,
                                                    safeTop: geo.safeAreaInsets.top,
                                                    safeBottom: geo.safeAreaInsets.bottom) : nil
                        let uniformWidth: CGFloat? = pseudoWidth
                            ?? (locked ? tile?.size.width : nil)
                        let scale = perCardScale[task.id] ?? 1
                        let active = task.id == store.videoTasks.activeTaskID
                        let reset = store.videoTasks.resetRequest
                        DockPlacedCard(
                            task: task,
                            index: index,
                            width: width,
                            widthOverride: uniformWidth,
                            locksPlacement: locked,
                            gravity: gravity,
                            pip: pip,
                            isActive: active,
                            coveredByForeground: coveredByForeground,
                            ownScale: scale,
                            onScaleChange: { perCardScale[task.id] = $0 },
                            containerSize: geo.size,
                            taskCount: cardCount,
                            resetRequest: reset,
                            slot: slot,
                            tileOffset: thisTile,
                            pseudoFullscreen: pseudoFullscreenID == task.id,
                            // ★ 双击 = 伪全屏置顶 / 再双击还原（用户 2026-11-17）。
                            //
                            // ## 为什么用「状态机幂等」而不是 `.exclusively(before:)`
                            //
                            // `.exclusively` 让单击**等双击超时**（≈0.3s）才生效 —— 正是
                            // `:1660` 注释记的「换层慢半拍」。这里两条 `simultaneousGesture`
                            // 并行挂，单击立刻响应。
                            //
                            // 并行带来的问题：双击时单击也会跑一次 `activate`。但本实现里
                            // **`activate` 不参与伪全屏状态**（它只改 tasks 数组顺序 = zIndex），
                            // 而伪全屏的切换是下面这一段独立逻辑 ⇒ 两次调用互不覆盖 ⇒ 幂等。
                            //
                            // ⛔ 这也正是 t12 与 captain 推演风险①的差别：风险①说
                            //    「伪全屏要记录原尺寸 + 原位置，两条手势都会覆盖」。
                            //    但本设计**不记录位置**（只改宽度、不动 offset），
                            //    宽度也不存状态（每帧从容器反算）⇒ 没有可被覆盖的东西。
                            // ⛔ 幂等的关键：这里**只切一个 id**，不记录任何位置。
                            //
                            // 双击时单击那次 `activate` 只改 tasks 数组顺序（= zIndex），
                            // 完全不碰 `pseudoFullscreenID` ⇒ 两条手势互不覆盖。
                            //
                            // 「原位置」不需要存：见 `DockPlacedCard.placed` 的注释 ——
                            // 伪全屏是让 `placed` **临时返回 .zero**，而 `dragOffset` / `slot`
                            // 一个字节都没被写，退出时 `placed` 自动回到原值。
                            onDoubleTap: {
                                pseudoFullscreenID = (pseudoFullscreenID == task.id) ? nil : task.id
                            })
                            // ★ 图层顺序：数组首位 = 最上层。
                            //
                            // ⛔ 少了这一行，「提最前」是反的：`ZStack` 按声明顺序画，
                            //    后画的在上 —— 首位反而被压在最底下。用户点一下卡片
                            //    看到的是「它跑到底下去了」，于是又去管理器里按上移。
                            .zIndex(Double(cardCount - index))
                    }
                }
                // 卡片**增删**的淡入淡出。只认 id 序列的变化，不认位移。
                //
                // ⛔ 这行本身没错，错在它以前**同时**管住了位移。它挂在 ZStack 上，
                //    子树里任何变化都会被包进这 0.22 秒 —— 包括拖动时的 `.offset`。
                //    于是手指每移一点，画面都被动画追 0.22 秒，表现就是
                //    用户说的「拖动不跟手、没有实时跟、松手后才显示」。
                //
                // 现在两边分工明确：
                //   · 这里 → 只负责「某张卡出现/消失」的过渡
                //   · `DockPlacedCard` 里的位移 → 用 `.transaction { $0.animation = nil }`
                //     显式关掉动画，逐帧即时跟手
                // 管理器把某一扇窗「拖出来」：把它的位置改到松手处。
                //
                // ⛔ 换算必须用坞自己的全局原点：
                //    管理器给的是**屏幕坐标**，而卡片位置存的是**相对坞右下角的偏移**。
                //    直接用屏幕坐标当偏移，会把窗口扔到屏幕外（用户说的"拖出来就没了"）。
                .onChange(of: store.videoTasks.dropRequest) { _, request in
                    guard let request else { return }
                    defer { store.videoTasks.consumeDrop() }
                    handleDrop(request, container: geo, width: width)
                }
                // 坞里有什么变了就存一次快照（增删、换集）。
                // 进度由 `saveSnapshot` 读取当下的 `session.position`，所以这里
                // 只需要在**结构**变化时触发；进度靠退出前那一次兜底。
                .onChange(of: store.videoTasks.tasks.map(\.id)) { _, _ in
                    store.videoTasks.saveSnapshot()
                    // 超过容量被逐出时告诉用户是哪一部。
                    // ⛔ 静默消失与「自己弄丢了」在体感上没有区别 —— 必须说。
                    if let gone = store.videoTasks.lastEvictedTitle {
                        store.notice = L10n.text("Put away %@ — at most %@ at once",
                                                 gone, String(PlaybackCapacity.dock))
                        store.videoTasks.lastEvictedTitle = nil
                    }
                }
                .animation(.smooth(duration: 0.22), value: store.videoTasks.tasks.map(\.id))
                // 「整理一次」：几何只有这一层知道（容器尺寸），所以动作落在这里。
                .onChange(of: store.videoTasks.tidyRequest) { _, _ in
                    applyTidy(container: geo.size, cardWidth: width)
                }
                // 刚进「锁定整理」时先整一次，并把结果写进每张卡自己的账 ——
                // 这样解锁之后它们就停在原地、可以接着拖，而不是弹回锁定前的散乱摆位。
                .onChange(of: store.videoTasks.layoutMode) { _, mode in
                    guard mode == .tiled else { return }
                    applyTidy(container: geo.size, cardWidth: width, keepLocked: true)
                }
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
                // ⛔ 这里**不要 `.padding(12)`**。
                //
                // `.padding` 套在「与容器等大」的 frame 外面时，子层仍按 `geo.size` 排版、
                // 再整体被推 12pt —— 底边和右边那 12pt 直接落到屏幕外，
                // 卡片贴着右下角的默认位就有一截看不见（用户说的「被屏幕吃掉」）。
                // 内缩改由 `DockCardClamp.margin` 与网格的 `spacing` 负责，那两处是算出来的。
            }
        }
    }
}
#endif
