import SwiftUI
import TVCore

struct VideoDetailView: View {
    #if DEBUG && os(iOS)
    /// 自动旋转回归钩子的单实例闸；转屏会重复触发 `onAppear`。
    @MainActor private static var qaRotateCycleRunning = false
    #endif
    #if os(iOS)
    /// 「页面还活着」的代数。`onAppear` 每跑一次就 +1。
    ///
    /// 用途只有一个：判断某次 `onDisappear` 到底是**离场**，还是**折叠/展开把页面重挂了一次**。
    ///
    /// ⛔ 必须是**静态**的，不能是 `@State`：折叠重挂会换掉页面身份，
    /// 新实例的 `@State` 全是初始值 —— 旧实例挂的延时任务在新实例里既看不到也取消不掉，
    /// 于是「展开一下」照样会把这一集塞进坞里（用户报的迷你播放器就是这么冒出来的）。
    @MainActor private static var pageGeneration = 0
    #endif
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// Opened from Continue Watching: on an iPhone the page resumes it at once.
    var resume: PlaybackHistoryEntry? = nil
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// 只在 `scheduleSettlePlaybackOnLeave()` 里读：已经退到后台时不能等宽限窗，
    /// 否则退场裁决会先看到「没有载体」而去起应用外浮窗。
    @Environment(\.scenePhase) private var scenePhase
    // ⛔ 全屏状态必须**跨页面身份重建存活**（mi3s 2026-11-09）：
    // 设备日志（oneskin.log）铁证：detail onAppear 反复触发 133 次（页面身份重建循环），
    // @State fullScreen 每次重建归零 —— 用户点全屏后 fs=true 铺满一帧，页面一重建
    // 就被弹回非全屏，表现为「竖屏点全屏没反应 / 全屏闪一下就退出」。
    // 改 @AppStorage 持久化：状态与页面身份解耦，重建后自动恢复。
    // 退出点（exitFullScreen / onDisappear / 折叠复位）照常写 false。
    @AppStorage("watchFullScreen") private var fullScreen = false
    /// 折叠带（x 区间）。`nil` = 这台设备/这个系统给不出分界信息，退回原推导。
    ///
    /// 这是对齐 One 1.7.0 的关键一步（见 `Docs/duo/One-1.7.0-旋转与折叠适配审查.md`）：
    /// One 的 `VideoDetailPage` 直接持有 `__division: State<CGRect?>`，
    /// 布局按**那条带**算，而不是按 `duoExpanded` 这类布尔二次推导。
    /// 我们此前的形态链是 `duoExpanded → sideways → 布局分支`，
    /// 每一环都是间接推断，折叠瞬间多个输入同时变，必然出现自相矛盾的中间态。
    @State private var foldGap: FoldGap?
    /// 横向折痕（书本 / 帐篷半折）。有它 = 半折形态；`nil` = 不是半折或信息不可用。
    @State private var horizontalFold: FoldGap.HorizontalBand?
    /// 遮挡内缩（四边）。Duo 展开时遮挡在右上角，
    /// 统一塞 `safeAreaInsets` 会把内容多推半个屏。
    @State private var occlusionInsets: OcclusionInsets = .zero
    /// 铰链是否 **partiallyOpen**（`DeviceHinge.status`，iOS 27.1+）。
    ///
    /// 这是判「摊开 vs 半折」的**权威**信号：折缝位置会随握持角度漂
    /// （摊开态实测中心比 0.507 / 0.554 / 0.600 都出现过），
    /// 用「偏离正中多少」反推必然把摊开误判成半折（P0-1）。
    /// `nil` = 系统没报；此时才退回几何判据。
    @State private var hingePartiallyOpen: Bool?
    /// 上一次 `landscapeScreen` 判定出的**竖向态**（`true` = 上一次是竖持）。
    /// 传给 `OneSkinShapeResolver.isLandscape(wasPortrait:)` 做滞回：
    /// 保证 `portraitExit` 那个松阈值真的能被走到，转屏动画扫过临界点时形态不抖。
    /// `nil` = 尚无上次结论（首次判定）。
    ///
    /// ⛔ 只在 `commitLandscapeHysteresis()` 里写，**绝不在 body 求值期间写**。
    ///    （写法见 `resolvedLandscapeScreen()` 的注释：在计算属性里回写 @State
    ///    就是「Modifying state during view update」，会让形状判据多跑一轮、来回翻。）
    @State private var lastPortraitByRatio: Bool? = nil
    /// 详情页的选集抽屉开关。
    ///
    /// ⛔ **不能用 `store.showsEpisodes`**：那个键是上游全屏播放器
    /// （`PlayerView.swift` 的 `.sheet`）在用。详情页与全屏同时挂同一个键，
    /// 置 true 会**同时触发两个 sheet** —— iOS 同层弹不了两个，
    /// 结果是页面被挤回推荐首页、后续所有触摸失效。这正是用户报的现象。
    /// 详情页用自己的 @State，两条路径互不干扰。
    @State private var showsAllEpisodes = false
    /// 换源面板。
    @State private var showsCrossSource = false
    /// 本次离开页面**已经由本页明确处理过**，`onDisappear` 不要再自己猜。
    ///
    /// 两个写入点，语义都是「去向已定，别再动」：
    ///   · `collapseToMiniPlayer()` —— 会话已登记进坞，`onDisappear` 不能停播；
    ///   · `exitWatchPage()` —— 已经停播并 pop，`onDisappear` 什么都不该做。
    ///
    /// ⛔ 名字原来是 `leaveHandled`（「为缩小窗而离开」）。**退出键复用它之后，
    /// 名字就与事实相反了** —— 退出键走这条路径恰恰是为了**不进**小窗。留着旧名，
    /// 下一个人读到 `if leaveHandled { return }` 会以为「进了小窗所以跳过停播」，
    /// 从而在退出这条路上写出「让它也去登记坞」的错补丁。改名是最小成本的防错。
    ///
    /// 为什么必须有这个一次性意图（而不是让 `onDisappear` 每次自己判断）：
    /// `onDisappear` 在 pop 过渡里可能被跑、`onAppear` 也可能再跑一次；没有这个旗标，
    /// 「按小窗键 → pop 过渡中 onAppear 又跑一次」会把刚登记好的状态抹掉 ——
    /// 那正是旧版「点了没反应」的根因。
    @State private var leaveHandled = false
    /// 哔哩哔哩皮肤的画中画控制器。
    ///
    /// ⛔ 此前哔哩哔哩皮肤**没有自己的 PiP 实例**，画面层 `BiliSkinPicture` 也没接
    /// `attach`，于是 `PictureInPicture.current` 恒 nil：
    ///   · 全屏右缘那颗 `pip` 键调 `startCurrent()`，第一行 guard 就返回 —— 点了没反应；
    ///   · `RootView.arbitrate` 里 `pipPossible: PictureInPicture.current != nil` 恒 false
    ///     → `PlaybackExit` 走 ③b 返回 `.keep` → 离开 App 不浮窗也不登出，音频后台空转。
    /// 现在与 One 皮肤同一套做法：一个皮肤一个实例，各自绑自己那条 `AVPlayerLayer`。
    /// 不能与 One 皮肤共用 —— 一个 `AVPlayer` 同时只驱动一层画面，
    /// 共用会让悬浮窗只剩声音（见 `PictureInPicture.sourceLayer` 的注释）。
    @State private var biliPip = PictureInPicture()
    /// 换源结果的反馈（成功/失败各一句），三秒后自己消失。
    @State private var crossSourceNotice: String?
    /// 选集抽屉当前停在哪一档高度。集合固定 `[.medium, .large]`，只换这个值。
    @State private var episodeDetent: PresentationDetent = .medium
    /// 选集抽屉：搜索词与当前页（每页 10 集）。
    @State private var episodeQuery = ""
    @State private var episodePage = 0
    /// 选集抽屉的筛选维度。
    enum EpisodeFilter: String, CaseIterable, Identifiable {
        case all, unwatched, downloaded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .unwatched: "未看"
            case .downloaded: "已下载"
            }
        }
    }
    @State private var episodeFilter: EpisodeFilter = .all
    /// 每页集数，可在抽屉里切换。
    static let pageSizeChoices = [10, 20, 50]
    @State private var episodePageSize = 10
    @State private var episodeScroll: Episode.ID?
    /// The page's player shows its picture (or an error); until then the page's cover stays over it.
    @State private var playerStarted = false
    /// Back on the cover while it starts: shown for a moment by a tap, as the player's controls are.
    @State private var coverBack = false
    /// The page's player, whose wait the cover tells about.
    @State private var playerSession: PlaybackSession?
    /// 最近一次「确定在播」的会话快照。
    ///
    /// ⛔ 为什么需要它：`Store.playing` 的 `didSet` 在 `playing == nil` 时会把
    /// `activeSession` / `activeSessionChannel` **一起清空**：
    ///     if playing == nil { activeSession = nil; activeSessionChannel = nil }
    /// 而 `playing` 在一次 body 求值、一次坞交接、一次转屏里都可能瞬时变成 nil。
    /// 于是 `oneSkinStageSession` 在那些帧返回 nil → `avPlayer` 为 nil →
    /// 画面层走 `else` 画海报。
    //
    /// 真机实证（8.11.6，同一进程内相邻两帧）：
    ///     PICCHK avPlayer=NIL 走海报 win=523x294      ← 这一帧 session 丢了
    ///     PICCHK ok avPlayer=yes item=true ps=1080x1920 win=371x659  ← 下一帧又回来了
    /// 用户看到的就是「一会儿有画面一会儿只有海报」，放大了就是「只出海报」。
    ///
    /// 会话对象一旦建立就一直活着（`PlaybackSession` 由 `@State`/`@Observable` 持有），
    /// 所以这里缓存它不会延长任何生命周期，只是避免「store 清槽 → 本页失明」。
    @State private var lastGoodSession: PlaybackSession?
    /// The source's config center, open in the app (`ConfigCenterView`).
    @State private var showsConfigCenter = false
    #endif
    @State private var requestTask: Task<Void, Never>?
    /// 线路样本解析的**独立**句柄。
    ///
    /// ⛔ 不能和 `requestTask` 共用。上一版把它挂进 `startRequest`，本意是
    /// 「用户点播放时取消掉线路解析，给播放让路」—— 结果是一个真实的功能回归：
    /// `startRequest` 会 `previous?.cancel()`，于是**每点一次播放，线路解析整轮被取消**，
    /// `lineSamples` 永远只填到第一条甚至一条没有。而线路菜单（`OneSkin.lineLatencies`）
    /// 正是按 `lineSamples` 逐线发 HEAD 的 —— 菜单里除当前线路外每条都显示「不通」。
    ///
    /// 正确的分工：
    ///   · `requestTask` —— 播放请求，后一次取消前一次（用户换集/换线，旧的该废）；
    ///   · `lineSampleTask` —— 线路摸底，**不因播放而取消**，只随页面消失而取消，
    ///     并在每次解析前主动等待 `busy`，把脚本线程让给正在起播的那一次。
    /// 这样「播放不被 4~9 条线路堵住」和「线路菜单有数」同时成立。
    @State private var lineSampleTask: Task<Void, Never>?
    @State private var detail: Video?
    /// Short labels (第1集) for lines whose episode names are file names, by episode id (#318). Display only.
    @State private var episodeLabels: [Episode.ID: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var pendingPlan: PlaybackPlan?
    @State private var pendingEpisode: Episode?
    @State private var choosingQuality = false
    @State private var synopsisExpanded = false
    @State private var selectedFlag: String?
    /// 倒序: the episode lists show the last episode first. A per-page preference, so flipping one
    /// video's list around never flips every other video's.
    @State private var reversesEpisodes = false
    /// Play takes over focus from the loading placeholder; otherwise nothing is focused once details load.
    @FocusState private var playFocused: Bool
    /// ⛔ **2026-11-09 根治「横竖屏切换后界面一直推移 / 得重启才恢复」**
    ///
    /// 这两个值以前是 `.onGeometryChange` 写回的 @State，却又驱动
    /// `upstreamWatchBody` 的列宽、画面高度、`duoExpanded` / `isWide` 判据 ——
    /// 「测量 → 写 State → 改布局 → 再测量」自激闭环，每转一次屏缩一圈，
    /// 右侧浅色列不断往左推进来。历史修法清一色是阈值 / 双帧确认 / 冻结缓存，
    /// 都只是减速；冻结还会把几何卡在旧值，正是「得重启 App 才生效」。
    ///
    /// 现在它们是**纯派生值**：只读静态屏幕边界 + 离散界面方向，
    /// 不测量自身、不写状态、不缓存。同形态下每次求值完全相同，没有环可自激；
    /// 方向一变立即得到新值，一次到位，也不会卡死。
    #if os(iOS)
    private var layoutSize: CGSize {
        // ═══ 绝不测量「视图自身」 ═══
        //
        // 这个值参与形态判定 → 决定 stage 布局 → 决定视图 frame。
        // 若它读「本视图的测量结果」（`liveContainerSize` / `cachedLiveContainer` /
        // `GeometryReader.proxy.size`），就构成 **frame → 形态 → frame** 闭环。
        //
        // 实测代价（真机 Duo 2026-11-12）：
        //   ROOT dt=1ms（每秒 1000 次重排）；SHAPE 翻转 3141 次
        //   （split 1570 / fullBleed 1571，各占一半，永远收敛不了）；
        //   同帧内 ROOT 行 shape=fullBleed 而 stage 行 shape=split。
        //
        // 唯一安全来源：**UIKit 自己的 keyWindow.bounds**。
        // 它由系统窗口管理，不随我们的 SwiftUI 重排变化 —— 没有任何回灌路径。
        // 方向交换也由系统完成（旋转后 keyWindow.bounds 直接是新的宽高），
        // 不依赖 `interfaceOrientation`（Duo 内屏那个值是假的）。
        let win = UIApplication.shared.appWindowScene?.keyWindow?.bounds.size
        if let win, win.width > 1, win.height > 1 { return win }
        let b = UIApplication.shared.appWindowScene?.screen.bounds.size
            ?? UIApplication.shared.appScreenBounds.size
        return b
    }
    private var containerWidth: CGFloat { layoutSize.width }
    private var containerHeight: CGFloat { layoutSize.height }

    /// 半折折痕的**绝对 y**（容器坐标系，窗口顶 = 0），给 `OneSkinStage` 直接用。
    ///
    /// ⛔ 16.5：不要再用「比例」往下传。`topH = box.height × ratio` 是把
    ///    窗口高的比例乘到**更矮的 box** 上（窗口 951、box 917），
    ///    边界比真实折痕高 ~17pt，再叠 5% 量化最坏多 ±11pt —— 画面下沿与
    ///    折缝之间那条错位/黑边就是它。折痕矩形与 stage 共用同一个原点，
    ///    直接把 y 当高度，误差为零。
    private var halfFoldSplitY: CGFloat? {
        guard let band = horizontalFold, band.isHorizontal else { return nil }
        guard band.centerY > 1 else { return nil }
        return band.centerY
    }

    /// 半折时**上半个屏**占整高的比例，直接取折痕中心。
    ///
    /// 折痕不在正中央时（帐篷略前倾、书本略后翻），画面列必须与折痕对齐，
    /// 否则上半画面和中途开始的折痕面会错位。没有折痕信息时退回 0.5。
    private var halfFoldSplitRatio: CGFloat {
        guard let band = horizontalFold, band.isHorizontal, containerHeight > 1 else { return 0.5 }
        let raw = band.centerY / containerHeight
        // 夹到 0.25–0.75（与 `splitsContainer` 同一区间）
        let clamped = min(max(raw, 0.25), 0.75)
        // ★ 必须**量化**：`band.centerY` 来自系统 `reservedRegions` 的矩形，
        // 半折（书本/帐篷）时铰链角度连续变化 → `centerY` 逐帧变 →
        // `topH = box.height * ratio` 逐帧变 → 画面列与 HalfFoldConsole 的
        // `.frame(height:)` 每帧变 → **半折形态下整页持续推移**。
        //
        // 这是四个形态里**唯一一个输入本身就是连续量**的形态，
        // 也是实测「每秒 213–479 次重算」最严重的那一档。
        // 量化到 5% 一档：铰链微小晃动不再改变布局，明显折动仍跟手。
        return (clamped * 20).rounded() / 20
    }
    #else
    // macOS / tvOS 没有设备旋转，测量回写不构成闭环，保留原行为。
    @State private var containerWidth: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    #endif

    /// 真实布局容器尺寸（这一帧真正可用的逻辑尺寸）。
    ///
    /// **为什么需要它**：`screen.bounds` 在折叠/多窗口设备上不可信 ——
    ///   · Duo 内屏恒报原生竖持 2007×2853（不随方向交换）；
    ///   · Fig 虚拟机报设备规格 951×669，而物理窗口只有 466×678；
    ///   · `interfaceOrientation` 在 Duo 内屏是假值。
    /// 三者任一为假，形态判据（duoExpanded / landscapePage /
    /// halfFoldSplitRatio / oneSkinShape）全部失效，表现为「每种形态都不对」。
    ///
    /// **为什么不构成反馈环**（这是之前反复踩的坑）：
    ///   写入用的是 `.onGeometryChange` 量到的 `size`，而布局**不读它做尺寸计算** ——
    ///   `layoutSize` 只把它当作「容器多大」这一事实，不再据此反推内容高度；
    ///   且写入前做了 8pt 量化，同一个桶内不重复写状态。
    @State private var liveContainerSize: CGSize = .zero
    /// 量到的尺寸先量化再写，避免亚点抖动反复触发 body。
    private func commitLiveContainer(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        func q(_ v: CGFloat) -> CGFloat { max(8, (v / 8).rounded(.down) * 8) }
        let next = CGSize(width: q(size.width), height: q(size.height))
        guard next != liveContainerSize else { return }
        liveContainerSize = next
        // 同步给几何层：`OneSkin.fixedScreenSize()` 是静态方法，
        // 读这个静态缓存而不是 `screen.bounds`。
        #if os(iOS)
        OneSkin.cachedLiveContainer = next   // `OneSkin` 在 tvOS 不存在（One 皮肤只在 iOS）
        #endif
    }
    /// The picture's own width-over-height, reported by the player once the stream is known.
    /// 16:9 until then, which is what most sources serve and therefore the least surprising guess.
    @State private var playerAspectRatio: CGFloat = 16.0 / 9.0
    /// 画面比例模式（二进制实证 5 种）。持久化到 `OneSkin.fitModeKey`。
    // 键名走 `BiliAspectMode.storageKey`（与 `OneSkin.fitModeKey` 同值）：
    // `OneSkin` 属 OneSkin 文件簇（整体只在 iOS 编译），而本 `@State` 在 tvOS 也存在。
    @State private var biliAspectMode: BiliAspectMode = BiliAspectMode.fromStored(
        UserDefaults.standard.string(forKey: BiliAspectMode.storageKey)
    )
    /// 只用来触发 body 重算（滤镜存在 UserDefaults，不是 @State）。
    @State private var biliColorFilterTick: UInt = 0
    /// 每条线路的测速样本（线路名 → 已解析的播放地址）。
    /// 只放**真正解析出来**的地址：type 3/4 的源要先经 preparePlayback 才能拿到流，
    /// 直接拿 `episode.address` 去测等于测一个解析不了的字符串，数字毫无意义。
    @State private var lineSamples: [String: OneSkinLineSample] = [:]
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @State private var artAspect: CGFloat?
    /// TMDB's backdrop once its picture has loaded. The source's cover stays until then, and when it never does
    /// (image.tmdb.org is blocked on some networks, #237).
    @State private var loadedBackdrop: URL?
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    @State private var signingIn: CloudDrive?
    /// A sign-in the source's CatPawOpen bundle runs itself (UC's TV token).
    @State private var bundleSignIn: BundleSignIn?
    @State private var choosingDownloads = false
    /// 从选集卡上的下载角标进来时要预勾的集；从页面底部「下载」进来时为空。
    @State private var downloadPreselect: Set<String> = []
    /// How many episodes were just queued, shown briefly under the header.
    @State private var queuedNotice: Int?
    /// A line has no episode to continue the one playing: shown briefly under the header.
    @State private var lineNotice: String?
    /// TMDB's details for the video (TMDBViews.swift). The page shows the source's own until they are in, then fades them in.
    @State var tmdb = TMDBLookup()
    /// The source's own recommendations, shown under the video when TMDB has none for it. Loaded lazily, once TMDB
    /// has answered, so the related list fills the space below the episodes instead of leaving it blank.
    @State private var siteRelated: [Recommendation] = []
    private var flags: [String] {
        var seen = Set<String>()
        return (detail?.episodes ?? []).map(\.flag).filter { seen.insert($0).inserted }
    }
    private var activeFlag: String { flags.contains(selectedFlag ?? "\u{0}") ? selectedFlag! : (flags.first ?? "") }
    /// The active line's episodes. `activeFlag` goes through every episode, so it is read once, not once per episode:
    /// in the filter it made each page update quadratic (4 lines of 1,000 episodes took seconds, and iOS killed the app).
    private var activeEpisodes: [Episode] {
        let flag = activeFlag
        return (detail?.episodes ?? []).filter { $0.flag == flag }
    }
    /// 仅供诊断日志的离散形态签名，不参与任何布局计算。
    private var layoutSignature: String {
        #if os(iOS)
        let o = UIApplication.shared.appWindowScene?.interfaceOrientation.rawValue ?? -1
        return "h\(String(describing: sizeClass))|v\(String(describing: verticalSizeClass))|o\(o)|fs\(fullScreen)|skin\(oneSkinActive)"
        #else
        return "h\(String(describing: sizeClass))"
        #endif
    }

    private var wideMinWidth: CGFloat {
        #if os(tvOS)
        1200
        #else
        760
        #endif
    }
    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        let previous = requestTask
        previous?.cancel()
        requestTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            // [mi3s] 二开：选集播放页的**系统栏位**与**页面生命周期**只在这里挂一次。
            //
            // 以前 `watchBody` 的两条渲染分支（One 皮肤 `oneSkinBody` / 上游原版
            // `upstreamWatchBody`）各自抄了一遍 `statusBarHidden` /
            // `persistentSystemOverlays` / `setBarVisibility(:for: .navigationBar|.tabBar)`
            // / `navigationBarBackButtonHidden` / `hidesAppTabBar`，生命周期
            // （方向锁 / 转屏 / 换集 / 离页）也只写在 upstream 那一支 ——
            // 于是皮肤一开，方向锁和转屏就集体失踪。两份代码的判据必然分叉，
            // 用户看到的就是「横屏没有菜单栏、竖屏又有」。
            //
            // 现在两份都收成唯一一处：栏位认 `WatchSystemChrome`（单一判据 `fullScreen`），
            // 生命周期认 `watchPageLifecycle`（两条分支共用同一套）。
            if watchLayout {
                watchPageLifecycleBody(watchBody
                    // 读折叠带与遮挡（iOS 27.1 用官方 reservedRegions）。
                    // 挂在这里而不是各皮肤内部：三皮肤共用同一份几何，
                    // 不会出现「One 皮肤知道折痕、哔哩哔哩皮肤不知道」的分叉。
                    //
                    // `containerSize` 用 `layoutSize`（keyWindow.bounds）：
                    // 遮挡矩形的「贴顶/贴底/贴左/贴右」必须按**当前方向的容器**判。
                    // 以前由探针自己去读 `appScreenBounds.height`（物理屏、不随方向
                    // 交换），横持时那条判据整个错位 —— P1-8。
                    .readFoldRegion(fold: $foldGap,
                                    horizontalFold: $horizontalFold,
                                    occlusion: $occlusionInsets,
                                    hingePartiallyOpen: $hingePartiallyOpen,
                                    containerSize: layoutSize)
                    // ★ 摄像头挖孔避让。`occlusionInsets` 由 `FoldRegionReader` 从
                    // iOS 27.1 的 `reservedRegions` 读出（Duo 合盖时挖孔在顶部、
                    // 展开时在右上角），**以前只写不读 —— 探针算完了没人用**，
                    // 于是「竖屏控件压到挖孔下面」这个一直存在的问题根本没被修。
                    //
                    // 全屏时不避让：全屏是沉浸态，画面就该铺满，
                    // 控件由各皮肤自己的安全区处理。
                    // ⛔ 不能把 `occlusionInsets` 直接当增量再补一次（BUG-O）。
                    //
                    // `occlusionInsets.top` 是 occlusion 矩形的**绝对下边界**
                    // （`OcclusionInsets.init` 里取 `rect.maxY`，从容器顶算起）；
                    // 而系统**已经**把内容推到了 `safeAreaInsets.top`。
                    // 两者是同一坐标系里语义重叠的两个量，直接相加 = 推两遍：
                    //   safe=84、occlusion=60 → 实推 144（多 60）
                    //   safe=84、occlusion=100 → 实推 184（多 84，本该只补 16）
                    //
                    // 只补「系统安全区没盖住的那一段」：
                    //   补量 = max(0, occlusion - safe)
                    // 这样 safe 已经够时补 0，occlusion 超出时才补差额。
                    // ⛔ 已删除 `.occlusionTopUp(occlusionInsets, fullScreen:)`（16.1）。
                    //
                    // 遮挡现在**只有一个消费端**：`OneSkinStage` → `geoDriver` →
                    // `OneSkinGeometry.box` 扣四边。理由：
                    //   · 皮肤本体是 `.ignoresSafeArea([.top, .horizontal])`，
                    //     挂在它外层的 `.safeAreaPadding` 会被忽略安全区连带铺出去；
                    //     顶/左/右三条补量对内容**完全不生效**，只有底部真压缩高度。
                    //     同一个量一半生效一半不生效，几何层却以为一点没让位。
                    //   · 两套机制并行 = 底部被扣两遍、侧边一次没扣。
                    // 现在遮挡统一进几何：`box` 变小 → 所有皮肤/控件跟着同一个盒走。
                    .watchSystemChrome(fullScreen: fullScreen))
                    // 退出键：挂在**页面**这一层，不在画面窗口里（用户 2026-11-11）。
                    //
                    // ⛔ 不能挂进 `OneSkinChrome.topBar`：那一层被
                    // `.frame(winW, winH).offset(winX, winY)` 锁在画面窗口内，
                    // 画在里面的键无论怎么调都在窗口里 —— 那正是用户要求移出来的东西。
                    //
                    // 三条渲染分支（One / 哔哩哔哩 / 上游原版）共用这一颗：
                    // 挂在这里就是「一处画、处处有」，不会出现某个皮肤没有退出键。
                    .overlay(alignment: .topLeading) { watchPageExitButton }
                    // The upright watch page is immersive and its navigation bar is hidden, so the
                    // edge swipe is its way back. One screen edge only: the player owns the rest.
                    .background { EdgeSwipeBack(enabled: !fullScreen && !duoExpanded) }
            } else {
                pageBody
            }
            #else
            pageBody
            #endif
        }
        // 选集抽屉。**挂在这里**，与 `.downloadPicker` 同级 ——
        //
        // 关键教训：挂在 `watchBody` 内部时，无论用 @State 还是 store 都弹不出来
        // （`episodes tapped` 有日志、状态也置了，但 sheet 的内容闭包从未执行）。
        // `watchBody` 是 `@ViewBuilder` 里的 if/else 分支，OneSkin 那一支还叠了
        // `.hidesAppTabBar` / `.setBarVisibility` 这类改动 UIKit 层级的修饰符，
        // 在分支内部挂 sheet 找不到稳定的呈现锚点。
        // 而 `.downloadPicker` 挂在本层（Group 之后）一直能弹 —— 照它挂就对。
        // iOS 专属：`showsAllEpisodes` / `allEpisodes` 都在 `#if os(iOS)` 里，
        // 不包起来 macOS / tvOS 会编译失败（此前只有 iOS 构建过，问题被掩盖）。
        #if os(iOS)
        .sheet(isPresented: $showsAllEpisodes) {
            #if DEBUG
            let _ = oneSkinLog("episodes sheet BUILDING eps=\(activeEpisodes.count) pages=\(episodePageCount)")
            #endif
            allEpisodes
        }
        // 换源面板。与选集抽屉同层挂在 Group 之后 —— 分支内部挂 sheet 找不到稳定锚点。
        .sheet(isPresented: $showsCrossSource) {
            CrossSourceSheet { candidate in
                // 换成功：面板自己关。这里只给一句反馈，让用户确认「确实换了」。
                withAnimation(.smooth(duration: 0.2)) {
                    crossSourceNotice = L10n.text("Now playing from %@", candidate.sourceName)
                }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.smooth(duration: 0.2)) { crossSourceNotice = nil }
                }
            } onFailed: { message in
                withAnimation(.smooth(duration: 0.2)) { crossSourceNotice = message }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(.smooth(duration: 0.2)) { crossSourceNotice = nil }
                }
            }
            .environment(store)
        }
        .onChange(of: showsAllEpisodes) { _, open in
            // 每次打开重新落档：宽屏（Duo 展开 / iPad）直接给满高，窄屏先给半屏。
            guard open else { return }
            episodeDetent = (duoExpanded || sizeClass == .regular) ? .large : .medium
        }
        #endif
        .safeAreaInset(edge: .bottom) { if !isWatchPage { loadingCard } }
        // ★ 滞回状态的**唯一写入点**（P1-5）。
        //
        // `landscapeScreen` 原来是「计算属性里顺手回写 @State」，而它被
        // `sideways` → `duoExpanded` → `oneSkinShape` 在**同一次 body 求值里**
        // 反复调用，等于每次刷新都写状态：多余一轮 pass，滞回值还可能在
        // 「读到旧值 → 写入新值」之间来回翻。
        //
        // 现在把写挪到 `onChange`：body 只读，事件到了才写。
        // `layoutSize` 是 keyWindow.bounds（UIKit 所有），旋转/折叠时由系统
        // **离散地**改一次（动画期间会连续经过若干中间值，`onChange` 每次都写，
        // 但每次都是幂等判断 + 一次赋值，且形态判定本身有滞回带兜着）。
        // `initial: true` 让页面第一次出现时也落一次，避免首帧没有历史值。
        #if os(iOS)
        .onChange(of: layoutSize, initial: true) { _, _ in
            commitLandscapeHysteresis()
        }
        #endif
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            #if os(iOS)
            // ★ iOS：**只读，绝不写状态**。布局尺寸由 `layoutSize` 纯派生，
            // 这里量到的 `size` 不参与任何布局决策 —— 反馈环从根上不存在。
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaLogGeometry") {
                let sb = UIApplication.shared.appWindowScene?.screen.bounds.size ?? .zero
                NSLog("GEO probe=%.0fx%.0f derived=%.0fx%.0f sig=%@ hSize=%@ vSize=%@ duo=%@ land=%@ port=%@ scrW=%.0f scrH=%.0f shape=%@",
                      size.width, size.height, containerWidth, containerHeight, layoutSignature,
                      String(describing: sizeClass), String(describing: verticalSizeClass),
                      String(describing: duoExpanded), String(describing: landscapeScreen),
                      String(describing: portraitExpanded), sb.width, sb.height,
                      String(describing: oneSkinShape))
            }
            #endif
            // ⛔ 不再写 `liveContainerSize`。它会构成 frame→形态→frame 闭环。
            // 尺寸唯一来源改成 `layoutSize` 的 keyWindow.bounds（UIKit 所有）。
            // 这里只保留 POSTURE 探测的读，不写任何布局状态。
            _ = size
            // ═══════ POSTURE 探测：每次容器尺寸提交后打印一次完整判据 ═══════
            // 建立 6 形态 × 全屏/非全屏 的实测矩阵，之后据此一次定案判据表。
            //
            // ★ 2026-11-13 第四轮：「打满」—— 不再需要 `qaLogPosture` 开关。
            //   这一行是**形态判定的唯一入口证据**（页面级 `oneSkinShape` 就是
            //   在这里被算出来的）；旧版要显式传 `-qaLogPosture 1` 才有输出，
            //   而真机上用户只装包、不会带启动参数 —— 等于这行日志永远不存在。
            //   现在 DEBUG 下无条件打，用 gate 限流防刷爆。
            do {
                let shapeName = oneSkinShape.logName
                if OneSkinProbeGate.allow(
                    "POSTURE",
                    value: "\(shapeName)|\(Int(size.width))x\(Int(size.height))"
                ) {
                let sb = UIApplication.shared.appWindowScene?.screen.bounds.size ?? .zero
                let fg = foldGap
                let hf = horizontalFold
                let lc = OneSkin.cachedLiveContainer
                let ins = OneSkin.safeInsetsForProbe()
                let lcStr: String = lc.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
                let fgStr: String = fg == nil ? "nil" : (fg!.isVertical ? "vertical" : "horizontal")
                let hfStr: String = hf == nil ? "nil" : (hf!.isHorizontal ? "horizontal" : "other")
                let idiomStr: String = (UIDevice.current.userInterfaceIdiom == .phone) ? "phone" : "other"
                let a = "POSTURE shape=\(shapeName) container=\(Int(size.width))x\(Int(size.height))"
                let b = " screen=\(Int(sb.width))x\(Int(sb.height)) cachedLive=\(lcStr)"
                let c = " hSize=\(String(describing: sizeClass)) vSize=\(String(describing: verticalSizeClass)) idiom=\(idiomStr)"
                let d = " orient=\(UIDevice.current.orientation.rawValue) foldGap=\(fgStr) hFold=\(hfStr)"
                let e = " duo=\(duoExpanded) side=\(sideways) landPage=\(landscapePage)"
                let f = " landScreen=\(landscapeScreen) portExp=\(portraitExpanded) fs=\(fullScreen)"
                let segSafe = " safe=\(Int(ins.top)),\(Int(ins.bottom)),\(Int(ins.leading)),\(Int(ins.trailing))"
                let _ = oneSkinLog(a + b + c + d + e + f + segSafe)
                }
            }
            #else
            containerWidth = size.width
            containerHeight = size.height
            #endif
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DetailAurora(poster: video.poster, headers: video.posterHeaders) }
        #else
        // [mi3s] One 皮肤自带黑底（OneSkinBackdropLayer）。这里如果再挂 screenBackdrop，
        // 会把 Backdrop 那层浅色（244,246,251）铺在最底下，OneSkin 的半透明黑压不住它，
        // 结果整页发白 —— 控件和文字全部看不清，像素判读也全是噪声。
        // One 实测底色是 #000 / #0E0E0E，所以皮肤开着时不挂主题底。
        #if os(iOS)
        .modifier(ScreenBackdropIfNeeded(enabled: !oneSkinActive))
        #else
        // `oneSkinActive` 是 iOS-only；本平台没有 One 皮肤 → 主题底恒启用。
        .modifier(ScreenBackdropIfNeeded(enabled: true))
        #endif
        #endif
        .screenTitle(video.name).task {
            store.searchModel.suspend()
            // A Continue Watching card, or a favorite, can still be on screen when the vault relocks
            // (timeout, a screenshot, the app going to the background). The page must not then reveal a
            // hidden source's title, cover, or episode list, nor resume it. The resume path's own choke
            // point (`resumeHistory`) refuses playback, but this page would still draw the details.
            let blocked = if let resume {
                !store.vault.permitsPlayback(sourceKey: resume.context.sourceKey, origin: resume.context.origin)
            } else {
                !store.vault.permits(site: client.site, fallback: client.origin)
            }
            if blocked {
                store.error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
                dismiss()
                return
            }
            #if os(iOS)
            // From Continue Watching the watch page resumes at once, resolving its own details.
            let continues = watchLayout && watchChannel == nil && store.resumingHistoryID == nil
            if continues, let resume { store.resume(resume) }
            #endif
            if detail == nil { await loadDetail() }
            #if os(iOS)
            // A video of one episode then plays by itself, from where the viewer stopped if watched before. One of
            // several waits on its cover for the viewer to choose the line and episode (#260).
            if continues, resume == nil, watchChannel == nil, store.resumingHistoryID == nil, activeEpisodes.count <= 1 {
                playWatchCover()
            }
            // Opened on a video of several episodes with nothing watched before: the viewer's next step is
            // picking one, so the episode list comes up rather than a cover with a Play button that only leads
            // to the same list. A video watched before skips this — its continuation is the point of opening it.
            // On the Duo's unfolded landscape the episode grid already lives in the right column beside the
            // picture, so the auto-pop sheet would only cover it — skip the pop there.
            // [mi3s] OneSkin 皮肤开着时**不再自动弹选集 sheet**：
            // 皮肤详情栏里本来就有选集区，再弹全屏 sheet 只会盖住右栏、遮掉画面控件。
            // ⚠️ 必须连 `biliActive` 一起排除。判据写的是 `!oneSkinActive`，而
            // `oneSkinActive` 在哔哩哔哩皮肤下是 false（两条皮肤互斥）——
            // 于是 B站皮肤一进来，上游这个自动弹的选集 sheet 就把整个皮肤页盖住了。
            // 实测：截图里只剩上游抽屉的「lineA/lineB、10/页、1/3、24集」，
            // 皮肤自己的控件全在它下面。
            if opensIntoEpisodes, store.resumingHistoryID == nil, watchChannel == nil,
               !(duoExpanded && sideways), !portraitExpanded,
               !oneSkinActive, !biliActive, !choosingDownloads {
                // ⛔ 必须是 `showsAllEpisodes`（本页抽屉的键）。
                // 写 `store.showsEpisodes` 打开的是上游全屏播放器的面板 —— 本页没有宿主，
                // 结果「什么都不弹」，还留下一个 true 的脏状态。
                showsAllEpisodes = true
            }
            #endif
            #if DEBUG && os(iOS)
            // 仅 iOS：本段读写的 `showsAllEpisodes` / `choosingDownloads` / `watchChannel` /
            // `activeEpisodes` / `play` 都声明在 `#if os(iOS)` 段内（One 皮肤配套 UI）。
            // `-qaDownloadPicker 1` / `-qaEpisodesSheet 1`：截图用的抽屉直开入口。
            // 两者同层，不能同时为 true（iOS 同层只剩一个 presenter），打开一个先关另一个。
            if UserDefaults.standard.bool(forKey: "qaDownloadPicker") {
                showsAllEpisodes = false
                choosingDownloads = true
            }
            if UserDefaults.standard.bool(forKey: "qaEpisodesSheet") {
                choosingDownloads = false
                showsAllEpisodes = true
            }
            // `-qaWatchPlay 1` 直接起播第一集：控件层只在 session 起来后才画，
            // 多集片源默认停在封面，没有这条就截不到「真实播放中」的控件版式。
            if UserDefaults.standard.bool(forKey: "qaWatchPlay"),
               watchChannel == nil, let first = activeEpisodes.first ?? detail?.episodes.first {
                await play(first)
            }
            #endif
        }
        .onAppear {
            store.watchPageOpen = true
            #if os(iOS)
            // 页面回来了 = 上一次 `onDisappear` 不是离场（折叠/展开的重挂）。
            // 代数 +1 会让那次挂起的「收进坞」判定在到期时自行作废。
            Self.pageGeneration &+= 1
            #endif
            // 进页面就为每条线路解析一个可测速地址（不阻塞首帧）。
            //
            // ⛔ 用**自己的**句柄，不走 `startRequest`（见 `lineSampleTask` 的说明）。
            //    重复 onAppear（折叠/展开重建）先取消上一轮，避免两轮同时解析。
            #if os(iOS)
            // `buildLineSamples` / `lineSampleTask` 属 iOS-only（多线路测速菜单是 iPhone 概念）。
            lineSampleTask?.cancel()
            lineSampleTask = Task { await buildLineSamples() }
            #endif
            #if DEBUG
            let switchDelay = UserDefaults.standard.double(forKey: "qaSwitchEpisode")
            oneSkinLog("detail onAppear watchPageOpen=\(store.watchPageOpen) qaSwitchEpisode=\(switchDelay)")
            // `-qaSwitchEpisode <秒>`：无人值守回归「换集后播放器是否渲染新内容」。
            // 先起播第一集，等 N 秒再播第二集，对比两次截图 / oneskin.log 即可，
            // 不必在模拟器上模拟点击（simctl 没有 tap）。
            if switchDelay > 0 {
                Task { @MainActor in
                    // 等订阅导入 + 详情落地；最多 8 秒。
                    for _ in 0..<16 where activeEpisodes.count < 2 {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard activeEpisodes.count > 1 else {
                        oneSkinLog("qaSwitchEpisode: 需要至少两集，实际 \(activeEpisodes.count)")
                        return
                    }
                    let first = activeEpisodes[0], second = activeEpisodes[1]
                    oneSkinLog("qaSwitchEpisode: first -> \(first.name)")
                    await play(first)
                    try? await Task.sleep(for: .seconds(switchDelay))
                    guard !Task.isCancelled else { return }
                    oneSkinLog("qaSwitchEpisode: second -> \(second.name)")
                    await play(second)
                }
            }
            #endif
        }
        .onDisappear {
            store.watchPageOpen = false
            store.isWatchPageMounted = false
            // 页面走了 —— 但**先别急着**决定这一集去哪：折叠/展开同样会跑 `onDisappear`，
            // 而它只是换了个版式，不是离场。判据见 `scheduleSettlePlaybackOnLeave()`。
            //
            // 去向规则（2026-11-12 用户裁决）：
            //   只要没按「退出」键，离开播放页就一律收进迷你播放器继续播；
            //   `leaveHandled` 为真时（小窗键 / 退出键已自行处理）不重复处理。
            #if os(iOS)
            scheduleSettlePlaybackOnLeave()
            #endif
            // ⛔ 离开观看页必须**归还载体声明**。
            //
            // `presentingPlayer` 的语义是「播放页在前台」。观看页本身就是那个页 —— 它退出时
            // 若还留着 true，弹层判据 `(!presentingPlayer)` 为假、而 `playsInWatchPage` 也随
            // scope 清空变假，于是 `fullScreenCover` 会**突然弹出来盖住用户退回的那一页**。
            //
            // 同时这一步也让退场裁决器看到「没有页面内画面」，从而正确走小窗 / 登出分支，
            // 而不是以为画面还在。
            store.presentingPlayer = false
            requestTask?.cancel()
            lineSampleTask?.cancel()
            lineSampleTask = nil
            #if os(iOS)
            // The page itself is gone (not just folded/unfolded): leave Full Screen. The video keeps playing,
            // so the floating mini player (RootView) takes over and the viewer can still get back to it.
            // On a fold this view stays alive, so playback carries on into the other layout.
            // 页面消失只清理**自己的**全屏状态。方向不再由这里强制回竖屏：
            // 全屏与方向已解耦（`setFullScreen` / `exitFullScreen` 都不碰
            // `PlayerOrientation`），横屏页离开时再 `set(landscape: false)`
            // 会主动把整机转回竖屏，把这一页的方向偏好污染到下一个页面 ——
            // 正是用户说的「每个页的全屏机制没有独立做好，无法共用」。
            // 方向只由旋转键与播放器关闭时的 `release()` 管。
            if fullScreen { fullScreen = false }
            // ⚠️ 必须释放方向锁。整个仓库此前**没有任何一处调用 `PlayerOrientation.release()`**
            // —— 从全屏（横屏）退出页面后，`fullScreenOwnsOrientation` 与 `.landscape` 掩码
            // 都留在原地，整机就锁在横屏，重启 App 也回不来（真机实测：o=90）。
            // `release()` 会清 `isLocked` / `holdsPortrait`，并在 `mask == .landscape` 时转回竖屏；
            // 但闸门还在，所以先关闸门再释放。
            PlayerOrientation.setFullScreenHeld(false)
            PlayerOrientation.release()
            #endif
        }
        .task(id: detail?.id) {
            // The source's related titles load beside TMDB's lookup, not after it: a title TMDB doesn't know
            // (or a Worker that is slow) would otherwise leave the space under the video empty until the
            // lookup timed out. The related list shows the source's own titles while TMDB is still thinking,
            // and TMDB's recommendations replace them once they arrive.
            async let tmdbLookup: Void = startTMDB()
            async let related: Void = loadRelatedFallback()
            _ = await (tmdbLookup, related)
        }
        .onChange(of: choosingQuality) { _, open in if !open && !busy { loadingEpisode = nil } }
        #if os(iOS)
        // 全屏时把**全局**左滑返回关掉。
        //
        // 全屏是沉浸态：左滑该由播放器自己解释（拖进度 / 手势），而不是把整页弹走。
        // 本页自己那份 `EdgeSwipeBack` 已经有 `enabled: !fullScreen` 这道闸，
        // 但它只管本页；`GlobalSwipeBack` 是挂在 TabView 上的常驻那一份，
        // 不给信号它会照样在边缘起手时 pop。离开本页时复位。
        .onChange(of: fullScreen, initial: true) { _, on in SwipeBack.blocked = on }
        .onDisappear { SwipeBack.blocked = false }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showsConfigCenter) { ConfigCenterView { await configCenterAddress() } }
        #endif
        // Sign in where playback failed, then resume the episode that needed the account.
        #if !os(tvOS)
        .sheet(item: $bundleSignIn) { pending in
            CatPawSignInView(client: client, provider: pending.provider) {
                if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
            }
        }
        #endif
        #if os(macOS)
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei {
                XunleiSignInView { if let episode = playbackIssue?.episode { startRequest { await play(episode) } } }
            } else if drive == .baidu {
                // Baidu signs in with a code to scan on a Mac, as in Settings.
                CloudQRLoginView(drive: .baidu) { retryAfterSignIn() }
            } else {
                CloudLoginView(provider: drive.provider) { cookie, ticket in
                    try await drive.provider.saveLogin(cookie, ticket: ticket)
                    if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
                }
            }
        }
        #elseif os(iOS)
        // The drive's own sign-in page; the code is for signing in with another phone.
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else {
                WebSignInView(service: drive.webSignIn, signedIn: retryAfterSignIn) {
                    CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() }
                }
            }
        }
        #else
        .fullScreenCover(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else { CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() } }
        }
        #endif
        .downloadPicker(isPresented: $choosingDownloads) {
            DownloadPicker(video: video, site: client.site, flag: activeFlag,
                           episodes: activeEpisodes, origin: client.origin,
                           // One 皮肤 / 全屏时页面是黑的，抽屉也跟着黑，避免浅色材质糊在画面上。
                           dark: drawerIsDark,
                           startsLarge: drawerStartsLarge,
                           preselect: downloadPreselect) { count in
                guard count > 0 else { return }
                withAnimation(.smooth(duration: 0.2)) { queuedNotice = count }
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation(.smooth(duration: 0.2)) { queuedNotice = nil } }
            }
        }
        .confirmationDialog(L10n.text("Choose quality"), isPresented: $choosingQuality, titleVisibility: .visible) {
            if let plan = pendingPlan, let episode = pendingEpisode {
                ForEach(plan.choices) { choice in
                    Button(choice.name) { startRequest { await resolve(plan, choice: choice, episode: episode) } }
                }
            }
        }
    }

    /// One page on Mac, iPad and Apple TV: the banner, the synopsis, the episodes, then TMDB's cast and facts. An episode
    /// rail beside the banner (once used for long lists, and always on Apple TV) squeezed the banner into a card.
    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if detail != nil {
                    episodePanel
                    tmdbExtras
                } else if let error {
                    errorCard(error).padding(.top, 12)
                } else {
                    // The Play placeholder in the header holds focus while details load.
                    DetailSkeleton()
                }
            }
            .pageContainer()
        }
    }

    private var isWatchPage: Bool {
        #if os(iOS)
        watchLayout
        #else
        false
        #endif
    }

    /// 抽屉是否用深色底：One 皮肤或全屏时页面是黑的，浅色材质会糊在画面上。
    private var drawerIsDark: Bool {
        #if os(iOS)
        oneSkinActive || fullScreen
        #else
        false
        #endif
    }

    /// 抽屉是否从满高开始：宽屏（Duo 展开 / iPad）下 medium 会变成居中小卡，
    /// 两个抽屉都会显得又小又空。
    private var drawerStartsLarge: Bool {
        #if os(iOS)
        duoExpanded || sizeClass == .regular
        #else
        false
        #endif
    }

    @ViewBuilder private var loadingCard: some View {
        if busy {
            // Keyed by the step, so the timer restarts when details turn into resolving a link.
            LoadingCard { .source(client.site, origin: client.origin, title: busyTitle) }
                .id(busyTitle)
                .frame(maxWidth: .infinity).padding(.horizontal, Layout.gutter).padding(.bottom, 24)
        }
    }
    @ViewBuilder private var playbackBanner: some View {
        if let count = queuedNotice {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent)
                Text(count == 1 ? L10n.text("1 episode added to Downloads.") : L10n.text("%lld episodes added to Downloads.", count)).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button(L10n.text("Show Downloads")) { store.section = .downloads }.settingsButton()
            }
            .padding(Spacing.panel)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        // 换源的反馈与换线共用同一个条位：两者都是「刚才那个动作的结果」，
        // 分成两条会在短时间内叠成两层，而用户只关心最新那条。
        #if os(iOS)
        let barNotice: String? = crossSourceNotice ?? lineNotice
        #else
        // `crossSourceNotice` 在 iOS 段声明（换源是 iPhone 的跨源切换）；tvOS 只有换线提示。
        let barNotice: String? = lineNotice
        #endif
        if let notice = barNotice {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill").foregroundStyle(Brand.accent)
                Text(notice).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
            }
            .padding(Spacing.panel)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let issue = playbackIssue {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: issue.drive != nil || issue.signIn != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.amber)
                    .frame(width: 36, height: 36)
                    .background(Brand.amber.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Couldn't play %@", EpisodeRow.title(issue.episode.name)))
                            .font(.headline).lineLimit(2)
                        Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).selectable()
                    }
                    HStack(spacing: 8) {
                        if let drive = issue.drive {
                            Button(drive.signInTitle) { signingIn = drive }.settingsButton(prominent: true)
                        }
                        #if !os(tvOS)
                        if let provider = issue.signIn {
                            Button(L10n.text("Get UC TV Token")) { bundleSignIn = BundleSignIn(provider: provider) }
                                .settingsButton(prominent: true)
                                .accessibilityIdentifier("playbackIssue.bundleSignIn")
                        }
                        #endif
                        Button(L10n.text(issue.blockedBeforeRequest ? "Try Anyway" : "Retry")) {
                            startRequest { await play(issue.episode, skipAccountCheck: true) }
                        }
                        .settingsButton(prominent: issue.drive == nil && issue.signIn == nil)
                        #if os(tvOS)
                        // A focusable action instead of the small corner close button.
                        Button(L10n.text("Dismiss")) { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } }.settingsButton()
                        #endif
                    }
                }
                Spacer(minLength: 0)
                #if !os(tvOS)
                Button { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss")).help(L10n.text("Dismiss"))
                #endif
            }
            .padding(Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    private func errorCard(_ error: String) -> some View {
                    ErrorStateCard(
                        title: detail == nil ? L10n.text("Unable to load video details") : L10n.text("Unable to start playback"),
                        message: detail == nil
                            ? L10n.text("Try again, or go back and choose another video.")
                            : L10n.text("Try another episode or playback source."),
                        details: error,
                        retry: detail == nil ? { startRequest { await loadDetail() } } : nil,
                        goBack: { dismiss() },
                        busy: busy,
                        backTitle: L10n.text("Go back")
                    )
    }
    private var busyTitle: String {
        if detail == nil { return L10n.text("Loading video details…") }
        let episode = detail?.episodes.first { $0.id == loadingEpisode }
        return episode.map { L10n.text("Getting the video link for %@…", EpisodeRow.title($0.name)) } ?? L10n.text("Getting the video link…")
    }
    private func loadDetail() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await client.detail(video.id, cached: client.site.type == 3 || client.site.type == 4)
            try Task.checkCancellation()
            // Worked out once, off the main thread: a line can hold thousands of episodes.
            let episodes = value.episodes
            #if DEBUG
            oneSkinLog("detail loaded: eps=\(episodes.count) flags=\(Set(episodes.map(\.flag)).sorted())")
            #endif
            episodeLabels = await Task.detached(priority: .userInitiated) { EpisodeLabels.labels(episodes) }.value
            detail = value
            // 默认线路：走全仓唯一的优先级出口 `LinePreference`，与选集面板同一口径。
            //
            // ① 用户这次亲自选的（`selectedFlag` 已被点过就不再动它 —— 这就是「用户选择优先」）
            // ② 上次看这部剧用的那条（#362）
            // ③ 第一条现在就能播的（不是没登录的网盘）
            // ④ 第一条
            //
            // ⛔ 上一版这里写 `watchedFlag ?? CloudDrive.preferredFlag(flags)`，而面板那边
            //    只读历史记录、没有「能播的线」兜底 —— 两套规则算出两条不同的线，
            //    用户看到「面板高亮 A、实际播 B」。
            if selectedFlag == nil {
                selectedFlag = LinePreference.choose(
                    flags: flags,
                    picked: nil,          // 走到这里即 `selectedFlag == nil`，没有本次选择
                    watched: watchedFlag,
                    playableNow: { CloudDrive.preferredFlag([$0]) != nil }
                )
            }
            #if os(tvOS)
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "detail \(client.reportContext)", error)
            self.error = error.localizedDescription
            #if os(tvOS)
            // The loading placeholder that held focus is gone: Retry in the hero takes it.
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        }
    }
    /// What this device knows shows at once; otherwise the lookup starts once the source's details are in (their
    /// synopsis and episodes help tell works of the same name apart).
    private func startTMDB() async {
        guard TMDBLookup.applies(to: client.site) else { return }
        let key = TMDBMatchStore.key(source: client.site.key, video: video.id)
        guard let detail else { _ = await tmdb.prepare(key: key); return }
        let request = TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video,
                                        source: TMDBMatch.SourceRef(key: client.site.key, name: client.site.name))
        // AI-generated videos and short dramas aren't on TMDB: the page keeps the source's own data.
        guard !TMDBMatch.labeledNotOnTMDB(request) else { tmdb.skip(); return }
        await tmdb.run(key: key, request: request)
    }
    /// The source's own related titles, shown when TMDB has no recommendations for the video. Loaded once per page;
    /// `relatedSection` only uses them while TMDB's recommendations are empty, so a matched title never shows both.
    private func loadRelatedFallback() async {
        guard siteRelated.isEmpty else { return }
        if let recs = try? await client.recommendations() {
            guard !Task.isCancelled else { return }
            siteRelated = recs
        }
        #if DEBUG && os(iOS)
        NSLog("RELATED-FALLBACK count=%d", siteRelated.count)
        #endif
    }
    /// A video without episodes. A config center entry (a CatPawOpen bundle's, #311, or a Wex plugin's, #360) opens its page in the app.
    @ViewBuilder private func noEpisodes(_ detail: Video) -> some View {
        #if os(iOS)
        if ConfigCenter.page(of: detail, site: client.site) != nil {
            Button { showsConfigCenter = true } label: { Label(L10n.text("Open Config Center"), systemImage: "gearshape") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.configCenter")
        } else {
            Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        }
        #else
        Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        #endif
    }
    #if os(iOS)
    /// The config center's address now. Asking the bundle again gives its current port, which changes when iOS took
    /// back its socket while the app was suspended; the page's details can be older than that, or cached.
    private func configCenterAddress() async -> URL? {
        let fresh = try? await client.detail(video.id)
        return (fresh ?? detail).flatMap { ConfigCenter.page(of: $0, site: client.site) }
    }
    #endif
    /// TMDB's story when it has one, else the source's synopsis.
    private func synopsisText(_ detail: Video) -> String {
        if let story = tmdb.details?.story, !story.isEmpty { return story }
        return detail.synopsis
    }
    /// The lookup's progress or its question, then TMDB's cast, facts and notice, under the page's own content.
    @ViewBuilder private var tmdbStatus: some View {
        TMDBLookupStatus(lookup: tmdb)
    }
    @ViewBuilder private var tmdbExtras: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let details = tmdb.details {
                if !details.cast.isEmpty { TMDBCastRow(cast: details.cast) }
                TMDBInfoGrid(details: details)
                TMDBFooter(lookup: tmdb, title: currentVideo().name)
            }
            relatedSection
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    /// "猜你喜欢" over the related list. The list itself falls back from TMDB's recommendations to the source's
    /// own related titles, then to this video's episodes, so the space below the video never sits empty.
    @ViewBuilder private var relatedSection: some View {
        let recs = tmdb.details?.recommendations ?? []
        if !recs.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            TMDBRelatedList(titles: recs) { store.searchVideos($0) }
        } else if !siteRelated.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(siteRelated) { item in
                    switch item.destination {
                    case .detail(let video):
                        RouteLink { CatalogDestination(video: video, client: client) } label: {
                            RelatedCard(title: item.name, subtitle: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                        }
                    case .search(let query):
                        Button { store.searchVideos(query) } label: {
                            RelatedCard(title: item.name, subtitle: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                        }
                        .tmdbCardButton()
                    }
                }
            }
        } else if detail != nil, !activeEpisodes.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(shownOrder(activeEpisodes)) { episode in
                    Button { startRequest { await play(episode) } } label: {
                        RelatedCard(title: episodeTitle(episode), subtitle: SourceLabel(client.site.name).text,
                                    poster: video.poster, headers: video.posterHeaders)
                    }
                    .tmdbCardButton()
                }
            }
        }
    }
    private var bannerHeight: CGFloat {
        #if os(tvOS)
        // Leaves the synopsis in view under it.
        min(max(containerWidth * 0.38, 480), 680)
        #else
        min(max(containerWidth * 0.42, 280), 540)
        #endif
    }
    /// TMDB's backdrop banner once its picture is in, the source's cover and title until then.
    @ViewBuilder private var tmdbHero: some View {
        if let details = tmdb.details, let backdrop = details.backdrop, backdrop == loadedBackdrop {
            let banner = TMDBBanner(details: details, backdrop: backdrop, unmatched: tmdb.answer?.unmatched ?? "") { playControl }
            banner.frame(height: bannerHeight).transition(.opacity)
        } else {
            hero.transition(.opacity)
        }
    }
    private var headerLayout: AnyLayout {
        #if os(iOS)
        if sizeClass == .compact { return AnyLayout(HStackLayout(alignment: .top, spacing: 16)) }
        #endif
        return AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }
    private var compactDetail: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    @ViewBuilder private func synopsis(_ detail: Video) -> some View {
        let text = synopsisText(detail)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(.secondary)
                    .lineLimit(synopsisExpanded ? nil : synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if text.count > 100 {
                    let toggle = Button(L10n.text(synopsisExpanded ? "Show Less" : "Show Full Synopsis")) { synopsisExpanded.toggle() }
                    #if os(tvOS)
                    toggle.controlButton()
                    #else
                    toggle.buttonStyle(.plain).font(.subheadline.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full width, so Down from the banner's buttons reaches Show Full Synopsis wherever they sit.
            .tvFocusSection()
        }
    }
    private var synopsisLineLimit: Int {
        #if os(tvOS)
        4
        #else
        3
        #endif
    }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #elseif os(iOS)
        compactDetail ? 104 : 150
        #else
        Layout.detailPoster
        #endif
    }
    private var isWide: Bool { containerWidth >= wideMinWidth }
    /// The details, with the list's poster when the details came without one.
    func currentVideo() -> Video { (detail ?? video).keepingPoster(video.poster, headers: video.posterHeaders) }

    private func videoFavorite() -> FavoriteItem {
        .video(FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()))
    }

    private func episodeFavorite(_ episode: Episode) -> FavoriteItem {
        .episode(FavoriteEpisode(video: FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()), episodeFlag: episode.flag, episodeName: episode.name, episodeID: episode.id))
    }

    @ViewBuilder private var playControl: some View {
        if let detail {
            if let first = activeEpisodes.first ?? detail.episodes.first {
                // Beside the poster on a phone there is no room for both labels: Download drops to its icon.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: false); videoFavoriteButton }
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: true); videoFavoriteButton }
                }
            } else {
                #if os(tvOS)
                // No episodes, so no Play: without a button here nothing on the page could take focus, and Back
                // did nothing at all.
                goBackButton(prominent: true).focused($playFocused)
                #endif
            }
        } else if error == nil {
            // On Apple TV the hero fills the screen and the skeleton below it is off-screen: the
            // Play button's placeholder holds focus, so Back leaves the page instead of the app.
            SkeletonBlock(cornerRadius: 10).frame(width: 150, height: 40).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            #if os(tvOS)
            // The details failed. The error card's buttons are below the full-screen hero, out of the remote's reach,
            // so the hero offers them too; they hold focus, and Back leaves the page again.
            HStack(spacing: 10) {
                Button { startRequest { await loadDetail() } } label: { Label(L10n.text("Retry"), systemImage: "arrow.clockwise") }
                    .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
                    .disabled(busy)
                    .focused($playFocused)
                    .accessibilityIdentifier("detail.retry")
                goBackButton(prominent: false)
            }
            #endif
        }
    }
    #if os(tvOS)
    private func goBackButton(prominent: Bool) -> some View {
        Button { dismiss() } label: { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
            .controlButton(prominent: prominent).controlSize(.large)
            .accessibilityIdentifier("detail.goBack")
    }
    #endif
    private func playButton(_ episode: Episode) -> some View {
        Button { startRequest { await play(episode) } } label: {
            HStack(spacing: 8) {
                if loadingEpisode == episode.id { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                Text(L10n.text("Play"))
            }
            .font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 8)
        }
        .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
        .focused($playFocused)
    }
    private func downloadButton(iconOnly: Bool) -> some View {
        Button { choosingDownloads = true } label: {
            Label(L10n.text("Download"), systemImage: "arrow.down.circle")
                .labelStyle(DownloadLabelStyle(iconOnly: iconOnly))
                .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large).accessibilityLabel(L10n.text("Download"))
    }
    /// Icon-only, beside Play and Download. An empty heart keeps the control color; a saved one is rose.
    /// Set as text in their font, so the button is as tall as theirs: a bare image made a smaller one on Apple TV.
    private var videoFavoriteButton: some View {
        let saved = store.favorites.contains(videoFavorite())
        let title = saved ? L10n.text("Remove %@ from favorites", currentVideo().name) : L10n.text("Add %@ to favorites", currentVideo().name)
        return Button { store.favorites.toggle(videoFavorite()) } label: {
            Group {
                if saved {
                    Text(Image(systemName: "heart.fill")).foregroundStyle(Brand.rose)
                } else {
                    Text(Image(systemName: "heart"))
                }
            }
            .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large)
        .accessibilityLabel(title).help(title)
        .accessibilityIdentifier("detail.favorite")
    }
    /// Share the video's TMDB page, whose link is stable (a source's playback address is temporary).
    @ViewBuilder private var shareButton: some View {
        #if !os(tvOS)
        if let link = tmdb.details?.link {
            ShareLink(item: link) {
                Text(Image(systemName: "square.and.arrow.up"))
                    .font(.headline).lineLimit(1).fixedSize()
            }
            .controlButton().controlSize(.large)
            .accessibilityLabel(L10n.text("Share"))
            .accessibilityIdentifier("detail.share")
        }
        #endif
    }
    /// The source's cover in TMDB's banner shape, so the page keeps its layout when TMDB's backdrop fades in, and for
    /// titles TMDB doesn't have.
    private var hero: some View {
        PosterBanner(poster: video.poster, headers: video.posterHeaders, title: video.name, subtitle: video.remarks,
                     aspect: $artAspect) { playControl }
            .frame(height: bannerHeight)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            // TMDB's banner at any width, so a matched title's page looks the same everywhere.
            if isWide || hasBackdrop {
                tmdbHero
                playbackBanner
                tmdbStatus
                if let detail, !synopsisText(detail).isEmpty {
                    synopsis(detail).font(.body).padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: posterWidth)
                        .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    // As tall as the 2:3 poster, so the buttons line up with its bottom edge.
                    MinHeightLayout(minHeight: posterWidth * 1.5) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(video.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            if !video.remarks.isEmpty { Text(video.remarks).font(.subheadline).foregroundStyle(.secondary) }
                            if let facts = tmdb.details?.facts, !facts.isEmpty {
                                Text(facts).font(.subheadline).foregroundStyle(.secondary).transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            playControl
                        }
                    }
                    Spacer(minLength: 0)
                }
                playbackBanner
                tmdbStatus
                if let detail { synopsis(detail) }
            }
        }
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.45), value: loadedBackdrop)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
        .task(id: tmdb.details?.backdrop) {
            // Into TMDBArtwork's cache, so the banner shows it at once.
            guard let backdrop = tmdb.details?.backdrop,
                  await TMDBArtwork.load(backdrop, maxPixels: TMDBBannerMetrics.backdropPixels) != nil,
                  !Task.isCancelled else { return }
            loadedBackdrop = backdrop
        }
    }
    private var hasBackdrop: Bool {
        tmdb.details?.backdrop != nil && tmdb.details?.backdrop == loadedBackdrop
    }
    @ViewBuilder private var episodePanel: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        #if os(tvOS)
                        if items.count > 1 {
                            episodeOrderButton(count: items.count)
                        } else {
                            Text(L10n.text("Episodes")).font(.headline)
                        }
                        #else
                        Text(L10n.text("Episodes")).font(.headline)
                        Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        if items.count > 1 { episodeOrderButton }
                        #endif
                        Spacer(minLength: 8)
                        if flags.count == 1, !activeFlag.isEmpty {
                            Text(SourceLabel(activeFlag).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    flagPicker
                    episodeList(items)
                }
            }
        }
    }
    @ViewBuilder private var flagPicker: some View {
        if flags.count > 1 {
            #if os(tvOS)
            ChipRow {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        Chip(title: flag.isEmpty ? L10n.text("Play") : flag, selected: flag == activeFlag) { selectedFlag = flag }
                    }
                }
            }.tvFocusSection()
            #else
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { selectedFlag = $0 }
            #endif
        }
    }
    #if os(tvOS)
    /// On Apple TV the heading itself turns the list around (倒序): one glass button whose arrow shows the order,
    /// up for the first episode first, down for the last.
    private func episodeOrderButton(count: Int) -> some View {
        Button { reversesEpisodes.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: reversesEpisodes ? "arrow.down" : "arrow.up").contentTransition(.symbolEffect(.replace))
                Text(L10n.text("Episodes"))
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .glassPill()
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #else
    /// The small button beside the episode count that turns the lists around (倒序).
    private var episodeOrderButton: some View {
        Button { reversesEpisodes.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(reversesEpisodes ? Brand.accent : Color.secondary)
                .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
        .help(L10n.text("Reverse Order"))
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #endif

    /// What the pickers show for an episode: its short label when its line has them, else its name without the size tag.
    private func episodeTitle(_ episode: Episode) -> String { episodeLabels[episode.id] ?? EpisodeRow.title(episode.name) }

    /// The episodes in the order the lists show them. Only the lists: Play and the next episode still follow the source.
    private func shownOrder(_ items: [Episode]) -> [Episode] { reversesEpisodes ? items.reversed() : items }

    #if os(iOS)
    // 仅 iOS：选集抽屉的分页 / 筛选 / 搜索 —— 依赖 `episodeFilter`/`episodeQuery`/
    // `episodePage`/`episodePageSize`/`currentEpisodeID`/`watchChannel`，
    // 均声明在 `#if os(iOS)` 段内。tvOS 没有 iPhone 选集抽屉。
    // MARK: 选集抽屉的分页 / 筛选 / 搜索

    /// 搜索 + 筛选之后的集（按当前排序）。空搜索 = 全集。
    ///
    /// 三级管道，顺序固定：**先筛选 → 再搜索**。
    /// 反过来的话，「未看 + 搜 12」会在全部里搜出第 12 集，再被未看筛掉，
    /// 用户会以为「第 12 集不见了」——实际是搜到了又被筛走。
    private var filteredEpisodes: [Episode] {
        var items = shownOrder(activeEpisodes)

        switch episodeFilter {
        case .all:
            break
        case .unwatched:
            items = items.filter { !isWatched($0) }
        case .downloaded:
            items = items.filter { download($0)?.status == .completed }
        }

        let q = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        // 纯数字按「第 N 集」判：用户搜 12 想的是第 12 集，
        // 不是标题里含「12」的那一批（「2012」不该命中）。
        if let n = Int(q) {
            let exact = items.filter { ep in
                if let num = TMDBMatch.episodeNumber(ep.name) { return num == n }
                return episodeTitle(ep).contains("\(n)")
            }
            // 有精确集号命中就只给精确结果；没有才退回子串匹配。
            if !exact.isEmpty { return exact }
        }
        return items.filter { ep in
            episodeTitle(ep).localizedCaseInsensitiveContains(q) || ep.name.localizedCaseInsensitiveContains(q)
        }
    }

    /// 这部剧里「看过」的集：episodeID → 是否看完。
    ///
    /// 不能拿 `watchHistory`（单条续播点）来判断 —— 它只代表「上次看到哪一集」，
    /// 用它筛「未看」会把除当前集以外的所有集都当成未看。
    /// 真正的逐集记录在 `store.visibleHistory.entries` 里，每条含
    /// `context.videoID`（哪部剧）与 `context.episodeID`（哪一集）。
    /// 按本剧的 scope 收一遍，就是这个抽屉需要的完整「已看」集合。
    private var watchedEpisodeIDs: Set<String> {
        let scope = watchScopes
        return Set(store.visibleHistory.compactMap { entry in
            guard scope.contains(entry.context.id) else { return nil }
            // 有进度或已看完才算「看过」；刚点开几秒不算，否则「未看」会漏掉。
            return entry.progress > 0.02 || entry.completed ? entry.context.episodeID : nil
        })
    }

    /// 这一集是否看过。正在播的那集始终算已看。
    private func isWatched(_ episode: Episode) -> Bool {
        if episode.id == currentEpisodeID, watchChannel != nil { return true }
        return watchedEpisodeIDs.contains(episode.id)
    }

    /// 搜索提交时跳到第一处命中所在的页。
    ///
    /// 基于**过滤后**的列表算下标：`filteredEpisodes` 已经把筛选和搜索都应用过了，
    /// 所以这里第一项就是命中项，页码恒为 0 —— 但保留函数是为了
    /// 「搜 12 直接翻到含第 12 集那一页」的语义：当搜索是纯数字且列表里
    /// 没有精确集号（退回子串匹配）时，仍然定位到第一个含该数字的位置。
    private func jumpToFirstMatch() {
        let q = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { episodePage = 0; return }
        let list = filteredEpisodes
        guard !list.isEmpty else { episodePage = 0; return }
        if let n = Int(q),
           let idx = list.firstIndex(where: { TMDBMatch.episodeNumber($0.name) == n }) {
            episodePage = idx / max(episodePageSize, 1)
        } else {
            episodePage = 0
        }
    }

    private var episodePageCount: Int {
        max(1, Int(ceil(Double(filteredEpisodes.count) / Double(max(episodePageSize, 1)))))
    }

    /// 当前页。页码越界时自动夹回（切换筛选/搜索后总数变小的情况）。
    private var pagedEpisodes: [Episode] {
        let all = filteredEpisodes
        let size = max(episodePageSize, 1)
        let page = min(episodePage, max(0, episodePageCount - 1))
        let start = min(page * size, max(0, all.count))
        let end = min(start + size, all.count)
        guard start < end else { return [] }
        return Array(all[start..<end])
    }
    #endif

    private func episodeList(_ items: [Episode]) -> some View {
        // A chip fits about six characters before it truncates (《一…); longer names get rows.
        let longNames = (items.map { (episodeLabels[$0.id] ?? $0.name).count }.max() ?? 0) > 6
        // Under a full-width banner, long names fill columns rather than one stretched list.
        let rowColumns = isWide ? [GridItem(.adaptive(minimum: 320), spacing: 8)] : [GridItem(.flexible())]
        // TMDB's stills, when its season lines up with most of the episodes and has pictures for them; without
        // pictures the small chips read better than empty tiles. While TMDB is still looking, tiles with the episode
        // numbers, so its stills fade into the same tiles instead of chips turning into tiles.
        let stills = tmdb.episodes(items)
        let showsStills = items.count > 1
            && (stills.values.filter { $0.still != nil }.count * 2 >= items.count || (tmdbPending && items.count <= 60))
        let columns = showsStills ? [GridItem(.adaptive(minimum: TMDBMetrics.episodeTile), spacing: TMDBMetrics.spacing, alignment: .top)]
            : longNames ? rowColumns : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: showsStills ? TMDBMetrics.spacing : longNames ? 4 : 8) {
            ForEach(shownOrder(items)) { episode in
                let saved = download(episode)
                Group {
                    if showsStills {
                        Button { startRequest { await play(episode) } } label: {
                            TMDBEpisodeTile(name: episodeTitle(episode), info: stills[episode.id], loading: loadingEpisode == episode.id, width: nil)
                        }
                        .tmdbCardButton()
                        .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
                        .accessibilityLabel(episode.name)
                    } else if longNames {
                        EpisodeRow(name: episode.name, label: episodeLabels[episode.id], loading: loadingEpisode == episode.id, download: saved) {
                            startRequest { await play(episode) }
                        }
                    } else {
                        Chip(title: episodeLabels[episode.id] ?? episode.name, selected: loadingEpisode == episode.id, fill: true) { startRequest { await play(episode) } }
                            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if store.favorites.contains(episodeFavorite(episode)) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 12, weight: .semibold))
                            .foregroundStyle(Brand.rose)
                            .padding(4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contextMenu {
                    // The file name a label stands for: its resolution and codec can matter on a netdisk line.
                    if episodeLabels[episode.id] != nil { Text(episode.name) }
                    FavoriteMenuButton(item: episodeFavorite(episode), name: episode.name)
                    if saved == nil || saved?.status == .failed {
                        Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                            DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin),
                                                            title: video.name, poster: video.poster, posterHeaders: video.posterHeaders,
                                                            environmentID: store.environments.activeID)
                        }
                    } else if let saved {
                        Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                            DownloadLibrary.shared.remove([saved.id])
                        }
                    }
                }
            }
        }
        #if os(tvOS)
        // Room for the focused glass row, which grows toward the trailing edge.
        .padding(.trailing, 16).padding(.vertical, 6)
        #endif
        .tvFocusSection()
        .animation(.smooth(duration: 0.4), value: showsStills)
    }
    /// Mac and iPad, under the banner: TMDB hasn't answered yet. Short-drama-length lists stay chips (see episodeList).
    private var tmdbPending: Bool {
        #if os(tvOS)
        false
        #else
        isWide && (tmdb.phase == .looking || (tmdb.phase == .idle && TMDBLookup.applies(to: client.site)))
        #endif
    }
    private var episodeMin: CGFloat {
        #if os(tvOS)
        170
        #else
        // Room for 第 10 集 / 第01集 without an ellipsis.
        100
        #endif
    }
    /// 这一集在本环境下的下载记录。
    ///
    /// 必须走 `visibleItem(for:)` 而不是 `item(for:)`：另一环境下过的那一集是一条独立记录，
    /// 在别的环境里既不该显示「已下载」徽标，也不该走「从设备播放」那条路 —— 那条路会当场
    /// 抛「这个下载已不在本机」，因为它是另一环境名下的。
    private func download(_ episode: Episode) -> DownloadItem? {
        DownloadLibrary.shared.visibleItem(for: DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin))
    }
    private func play(_ episode: Episode, skipAccountCheck: Bool = false) async {
        #if DEBUG
        oneSkinLog("play episode=\(episode.name) flag=\(episode.flag) busy=\(busy)")
        #endif
        guard !busy else { return }
        // A downloaded episode plays from the device: no link to fetch, and it works offline.
        if let saved = download(episode), saved.status == .completed {
            store.playing = DownloadLibrary.shared.channel(for: saved)
            return
        }
        // Cloud-drive plugins wait for an in-app login that cannot appear on this platform,
        // which surfaces only as a 60-second timeout. Ask for the account up front instead.
        if !skipAccountCheck, let drive = CloudDrive.missingLogin(forFlag: episode.flag) {
            withAnimation(.smooth(duration: 0.25)) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.loginHint, drive: drive, blockedBeforeRequest: true)
            }
            return
        }
        busy = true; loadingEpisode = episode.id
        withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil }
        defer { busy = false; if !choosingQuality { loadingEpisode = nil } }
        do {
            let plan = try await client.preparePlayback(episode)
            try Task.checkCancellation()
            if plan.choices.count > 1 {
                pendingPlan = plan; pendingEpisode = episode; choosingQuality = true
            } else {
                let playback = store.subscription.map { client.applying($0) } ?? client
                let resolved = try await playback.resolvePlayback(plan, choice: plan.choices[0])
                try Task.checkCancellation()
                store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
                #if DEBUG
                oneSkinLog("play OK url=\(String(describing: resolved.url).prefix(90))")
                #endif
            }
        } catch {
            #if DEBUG
            oneSkinLog("play FAIL \(error)")
            #endif
            fail(episode, error)
        }
    }
    private func resolve(_ plan: PlaybackPlan, choice: PlaybackChoice, episode: Episode) async {
        busy = true; loadingEpisode = episode.id
        defer { busy = false; pendingPlan = nil; pendingEpisode = nil; loadingEpisode = nil }
        do {
            let playback = store.subscription.map { client.applying($0) } ?? client
            let resolved = try await playback.resolvePlayback(plan, choice: choice)
            try Task.checkCancellation()
            store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
        } catch { fail(episode, error) }
    }
    private func retryAfterSignIn() {
        if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
    }
    private func fail(_ episode: Episode, _ error: Error) {
        #if DEBUG
        oneSkinLog("fail \(episode.name): \(error)")
        #endif
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // [融合修正] 原来这里调 `CloudDriveLoginRequired(bundleMessage:)`，
        // 但那个初始化器在全仓库都不存在（备份分支也没有）——这行一直是编译不过的死代码，
        // 只是本文件此前没进 target 才没暴露。改为按错误文本判断，语义不变：
        // 网盘要求登录时，错误描述里会带驱动名。
        let login = error as? CloudDriveLoginRequired ?? CloudDriveLoginRequired.matching(message: error.localizedDescription)
        // A drive that needs signing in is expected, not a failure to report.
        if login == nil {
            Diagnostics.shared.failure("catalog", "play \(client.reportContext) flag=\(episode.flag)", error)
        }
        withAnimation(.smooth(duration: 0.25)) {
            // Plugins report a missing or expired drive login in their own words ("夸克授权失败，请扫码登录");
            // say what happened and offer the sign-in instead of echoing them.
            if let login, let drive = CloudDrive(rawValue: login.rawValue) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else if let provider = CatPawSignIn.provider(for: error.localizedDescription) {
                // Signed in, but the bundle wants a token its own code gives; signing in again would change nothing.
                playbackIssue = PlaybackIssue(episode: episode, message: L10n.text("You're signed in to UC, but this source plays UC accounts without premium through UC's TV app, which needs a token of its own. Get it once with the UC Browser app, or choose another line."),
                                              drive: nil, blockedBeforeRequest: false, signIn: provider)
            } else if let drive = CloudDrive(flag: episode.flag), CloudDrive.isLoginFailure(error.localizedDescription) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else {
                playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription,
                                              drive: CloudDrive.missingLogin(forFlag: episode.flag), blockedBeforeRequest: false)
            }
        }
    }

    /// This video's playback scopes (`PlaybackHistoryContext.id`); the details may carry another ID than the list's.
    private var watchScopes: Set<String> {
        let origin = client.site.origin(or: client.origin)
        return Set([video.id, detail?.id].compactMap { $0 }.map { EpisodeSkipSettings.scope(origin: origin, source: client.site.sourceKey, video: $0) })
    }
    /// Whether opening this page should land on the episode list instead of a cover.
    ///
    /// A video of several episodes with nothing watched before has no single episode to
    /// start: the first one may be the wrong line, and the previous behaviour left the
    /// viewer on a Play button that opened the very list they now get directly.
    private var opensIntoEpisodes: Bool {
        #if os(iOS)
        guard watchLayout, activeEpisodes.count > 1 else { return false }
        return watchHistory == nil
        #else
        return false
        #endif
    }
    /// Where the viewer stopped last time, for Continue.
    private var watchHistory: PlaybackHistoryEntry? {
        store.visibleHistory.first { watchScopes.contains($0.context.id) }
    }
    /// The line of the episode playing, else of the one watched last, while the details still have it: the page opens
    /// on that line so the episode shows in its list, not on the first line (#362).
    private var watchedFlag: String? {
        guard let episodes = detail?.episodes else { return nil }
        #if os(iOS)
        let context = watchChannel?.historyContext ?? watchHistory?.context
        #else
        let context = watchHistory?.context
        #endif
        return context?.episode(in: episodes)?.flag
    }

    #if os(iOS)
    // MARK: iPhone watch page

    private var watchLayout: Bool { WatchPage.applies(sizeClass, verticalSizeClass) }

    /// Landscape on a phone held sideways: the page splits left/right rather than stacking — the picture
    /// on the left, the episode list on the right. A phone held sideways is compact in both directions
    /// (`compact × compact`). The Duo's *folded outer* display in portrait reports `regular × compact`,
    /// which `verticalSizeClass == .compact` alone mistook for sideways and wrongly split; requiring the
    /// horizontal class too keeps the outer portrait a single stacked column (video on top, details below).
    private var landscapePage: Bool { sizeClass == .compact && verticalSizeClass == .compact }
    /// iPhone Duo's inner display: still a phone (`idiom == .phone`) but regular in both directions.
    /// It is not "held sideways" — it is a real folded-out tablet-sized screen — so it uses the same
    /// two-column layout as a landscape phone (picture on the left, synopsis + episodes on the right).
    /// A real iPad (`idiom == .pad`) never reaches here: `WatchPage.applies` keeps it on the plain
    /// detail page.
    private var duoExpanded: Bool {
        #if DEBUG
        // `-qaDuoExpanded 1` renders this branch anywhere, so the folded-out layout can be photographed
        // without an iPhone Duo simulator — that model needs an iOS 27.1 runtime, and on a machine that
        // only has 26.5 / 27.0 the device type refuses to be created at all.
        if UserDefaults.standard.bool(forKey: "qaDuoExpanded") { return true }
        #endif
        // The Duo unfolded is a tablet-sized screen, much wider than the folded outer cover. Held upright
        // its classes report `.regular × .regular`; held sideways they report `.regular × .compact`, the
        // *same classes as the folded outer cover*. So the classes alone can't tell unfolded from folded —
        // the width can: wide = unfolded, narrow = folded.
        // A landscape phone (compact × compact) is wide too, but it is NOT the Duo unfolded — it keeps its
        // immersive single-surface layout. Only a regular-width phone (the Duo's inner display) can be unfolded.
        // ★ 折叠带优先：系统给了分界线，就以它为准。
        //
        // `foldGap != nil` 表示「这台设备确实摊开了，分界线在这里」——
        // 那是**系统观测到的物理事实**，比 `containerWidth > 600` 这类阈值推断可靠。
        // 反过来 `duoExpanded == false` 但 `foldGap != nil` 的情况（宽屏但没到 600pt、
        // 或 size class 抖动）也能被纠正。
        //
        // 注意：`foldGap == nil` **不等于**「没折叠」—— 它只表示「这条信息不可用」
        // （更早的系统、非折叠设备、或查询失败）。所以 nil 时仍走原来的推断，
        // 不能直接返回 false，否则会把所有旧设备的正常行为一起改坏。
        if let foldGap, foldGap.isVertical { return true }

        return UIDevice.current.userInterfaceIdiom == .phone
            && sizeClass == .regular
            && (containerWidth > 600 || verticalSizeClass == .regular)
    }
    /// Whether the screen itself is genuinely wider than tall. The Duo's inner display held sideways
    /// reports `regular × .regular` in practice (the size class does NOT flip to `.compact` as the
    /// comment above assumed), so a `verticalSizeClass` test misreads the unfolded landscape as upright.
    /// `screen.bounds.width > height` is no better: the inner display reports its *native* portrait
    /// bounds (2007×2853) even while its `interfaceOrientation` is `.landscapeLeft/Right` (rot90), so a
    /// bounds comparison always read "upright" and the unfolded landscape borrowed the portrait
    /// full-bleed layout. The interface orientation is discrete and cannot sit at the width:height
    /// critical point during the unfold/rotate animation, so it is the stable signal that keeps the
    /// two unfolded shapes — landscape column vs portrait full-bleed — independent.
    /// 是否横持（纯读，**不写任何状态**）。
    ///
    /// ⛔ 原来这里是「计算属性里顺手回写 `lastPortraitByRatio`」的写法：
    ///    `body` → `biliSkinBody` / `oneSkinTabReserve` / `splitsWatchPage`
    ///    → `sideways` → 本属性 ⇒ **每次 body 求值都写一次 @State**。
    ///    SwiftUI 下那是「Modifying state during view update」：额外一轮 pass，
    ///    状态还可能被丢弃；而 `oneSkinShape` 在同一次 body 里要被求值好几次，
    ///    于是滞回值来回翻 —— 转屏时形态抖、控件跳的其中一个来源。
    ///
    /// 现在拆成两半：
    ///   · 本函数（及 `landscapeScreen`）**只读**：窗口 + 界面方向 + 上一次结论；
    ///   · 回写落在 `commitLandscapeHysteresis()`，只由**离散事件**
    ///     （窗口尺寸变化 / 页面出现）调用，见 `body` 上的 `.onChange(of: layoutSize)`。
    private func resolvedLandscapeScreen() -> Bool {
        // ⛔ `interfaceOrientation` 在 **Duo 内屏竖持**时不可靠：实测报 `.landscapeLeft`，
        //    而同一时刻窗口实际是 669×780（竖的）。
        //
        // 这个假值往下游传染得很远：
        //   · `sideways = duoExpanded && landscapeScreen` → 展开竖持被判成「展开横屏」；
        //   · `layoutSize` 按它交换宽高 → 排版基准算成 951×669；
        //   · 三栏按 951 分（左列 507 + 间隙 + 右栏 427）铺到 669 宽上 → **横向溢出 282pt**，
        //     右栏被推出屏幕 —— 用户报的「展开竖屏时整页推移、右边被切掉」。
        //     （实测日志：`ROOT proxy=669x780` 与 `stage box=951x669` 同时出现。）
        //
        // 修法：方向信号与**窗口实际比例**不一致时，以窗口为准。
        //
        // ⛔ 这里读的是 `window.bounds`，**不是** SwiftUI 的 `proxy.size`：
        //    后者是本视图布局的输出，拿它回写布局基准就构成自反馈环
        //    （`layoutSize` 的注释里记的那次「右侧浅色列不断往左推进」）。
        //    `window.bounds` 归 UIKit 所有，只随系统的旋转/折叠变化，不会被我们的重排带着走。
        let declared: Bool = {
            switch UIApplication.shared.appWindowScene?.interfaceOrientation {
            case .landscapeLeft, .landscapeRight: return true
            default: return false
            }
        }()
        // 只有「摊开的大屏」才做这个校正 —— 手机横持与外屏行为原样不动。
        //
        // ⛔ 这里**不能**用 `duoExpanded` 当门：它读 `containerWidth`，
        //    而 `containerWidth` ← `layoutSize` ← `landscapeScreen` ← 本函数 —— 构成计算环。
        //    改判「窗口短边是否够大」：Duo 内屏 669、iPad 744+，都远大于阈值；
        //    外屏 466、iPhone 393 都小于它。这个量只来自 UIKit 的窗口，与我们的布局无关。
        let window = UIApplication.shared.appWindowScene?.keyWindow?.bounds.size
            ?? UIApplication.shared.appScreenBounds.size
        // ⛔ 判「大屏」用**长边**，不是短边。
        //
        // 原代码 `min(w,h) > 600` 在真机 Duo 上恒为 false：
        //   keyWindow.bounds = 678×466（物理屏）→ min = 466 < 600
        //   ⇒ guard 直接 return declared，`OneSkinShapeResolver` **从未执行**，
        //     滞回完全失效，形态只能靠 interfaceOrientation（内屏不可靠）——
        //     这就是「双页判不出来、永远单页」的最后一环。
        //
        // 内屏容器实测 672×492 / 594×688，短边 492/594 也 < 600，
        // 所以无论用物理屏还是容器，短边阈值都不成立。改用**长边**：
        //   内屏 678/688 > 600 ✓   外屏 466/492 < 600 ✗   iPhone 852 > 600 ✓
        // 手机 iPhone 竖持长边 852 也会进这个分支，但 `isLargeScreen` 只是
        // 「允许做容器校正」的开关，普通手机容器宽高比远离阈值，不会被改写。
        let isLargeScreen = max(window.width, window.height) > 600
        guard isLargeScreen else { return declared }
        return OneSkinShapeResolver.isLandscape(declaredIsLandscape: declared,
                                                containerSize: window,
                                                wasPortrait: lastPortraitByRatio,
                                                isLargeScreen: true)
    }

    private var landscapeScreen: Bool { resolvedLandscapeScreen() }

    /// 把这次判定结果落进滞回状态，供**下一次**判定用。
    ///
    /// 只由离散事件调用（窗口尺寸变化 / 页面出现），不在 body 求值里跑。
    /// 幂等：值没变就不写，不会自激。
    private func commitLandscapeHysteresis() {
        let nextPortrait = !resolvedLandscapeScreen()
        guard lastPortraitByRatio != nextPortrait else { return }
        lastPortraitByRatio = nextPortrait
    }
    /// [mi3s] 二开：Duo 摊开后默认**留在竖屏**（单列：画面在上、详情与选集在下）。
    /// 想看双列就把设备转横 —— 不再一展开就强制横屏。
    ///
    /// 原来这里有三层「强制 sideways」：`unfoldingToLandscape`（落向横屏的轮询窗口）、
    /// `unfoldedLandscapeHolds`（轮询失败后继续硬撑双列），外加 `landLandscape()`
    /// 主动请求旋转。结果是「展开 = 双屏」，用户要的竖屏形态永远看不到。整套已删除：
    /// `landscapeScreen` 只在设备**真的**横过来时才为真。
    ///
    /// ## 锁定态冻结握持（第五点需求的第二层）
    ///
    /// iPhone Duo 的内屏**不遵守 `supportedInterfaceOrientations`** —— 锁了方向，系统照样
    /// 会按物理握持改窗口形状（`duo-games` 实测：只支持横屏的构建，在桌面半折时仍拿到
    /// 669×951 的竖高窗口）。所以「锁屏防误触」在内屏上**无法靠方向掩码兑现**，
    /// 只能靠「自己不再理会握持变化」。
    ///
    /// 做法：锁定期间把横竖判定**冻结**在锁定那一刻的值。
    ///   解锁后立刻恢复跟随真实空间；`sideways` 是派生量，不需要额外清理。
    ///
    /// ⛔ 只冻结**横竖**，绝不冻结 `duoExpanded`。
    ///    折叠/展开是真实的物理事件（用户把手机合上就该回到外屏），
    ///    把它一起冻住会让画面留在内屏布局上、外屏一片空白。
    ///    区分标准很清楚：
    ///      · 握持转向 = 同一个形态、同一个窗口、只是宽高互换 → 锁定时忽略
    ///      · 折叠/展开 = 形态本身变了（`duoExpanded` 翻转）→ 永远响应
    private var sideways: Bool {
        // 冻结值优先：锁定时记下的横竖，切换形态（折叠/展开）时自动失效。
        if let frozen = landscapeFrozenWhileLocked, frozen.expanded == duoExpanded {
            return duoExpanded && frozen.landscape
        }
        return duoExpanded && landscapeScreen
    }

    /// 锁定那一刻的横竖判定。`nil` = 没锁。
    ///
    /// 带 `expanded` 是为了「折叠/展开时自动失效」：形态一变，旧冻结值就不再适用，
    /// 于是 `sideways` 回到真实判据 —— 折叠永远被响应。
    private struct LandscapeFreeze: Equatable {
        let landscape: Bool
        let expanded: Bool
    }
    @State private var landscapeFrozenWhileLocked: LandscapeFreeze?

    /// 锁定状态的可观察镜像 —— `PlayerOrientation.isLocked` 是普通静态量，
    /// SwiftUI 看不见它变化，没法直接 `onChange`。
    ///
    /// 由 `OneSkinPlayerChrome` 那颗锁钮通过
    /// `.onChange(of: PlayerOrientation.isLocked)` → 发通知 → 这里回读；
    /// 也在这里的 `onAppear` 回读一次。只做「镜像 + 转发」，不持有真相。
    @State private var lockedForShape = false

    private var portraitExpanded: Bool { duoExpanded && !sideways }
    /// The page is laid out left/right — picture on one side, details and episodes beside it — rather
    /// than stacked. True for a phone held sideways and for the unfolded Duo held sideways; Full
    /// Screen owns the whole display instead, so it never splits.
    private var splitsWatchPage: Bool { (landscapePage || (duoExpanded && sideways)) && !fullScreen }
    /// What plays at the top of the page: one of this video's episodes.
    private var watchChannel: Channel? {
        store.playing.flatMap { watchScopes.contains($0.historyContext?.id ?? "") ? $0 : nil }
    }
    /// The episode playing, else the one watched last: marked in the list, which scrolls to it.
    private var currentEpisodeID: Episode.ID? {
        guard let episodes = detail?.episodes else { return nil }
        return (watchChannel?.historyContext ?? watchHistory?.context)?.episode(in: episodes)?.id
    }

    /// As in Bilibili's app: the player at the top, under the status bar, and the title, actions, synopsis and
    /// episodes scrolling below it. Full Screen grows the same player over the page, so playback carries on.
    ///
    /// One structure for every shape of the phone. The picture sits at the top of the page with the details
    /// and episode list under it; held sideways — and on the unfolded Duo's wide inner display — the same two
    /// pieces are laid out left/right instead. `AnyLayout` swaps the *axis*, never the views, so the player
    /// keeps its identity through every fold, turn and Full Screen. It used to be written once per branch
    /// (stacked, split, and a third full-bleed one for the upright unfolded Duo), which tore the view down
    /// and rebuilt it on each move: the `AVPlayerLayer` left the window (AVKit answered with a second,
    /// unwanted Picture in Picture window), playback re-ran its setup, and the page's orientation hold was
    /// released mid-turn — the picture, and then the whole page, drifted.
    @ViewBuilder private var watchBody: some View {
        // [mi3s] 二开：One 皮肤。开关在设置里（`OneSkinPreferencePanel`），
        // 存 `UserDefaults` 的 `oneSkinEnabled`。关着就走下面原版 `upstreamWatchBody`，
        // 一个字节的版式都没换。
        if biliActive {
            // [mi3s] 哔哩哔哩皮肤：独立一层，与 One 皮肤、上游原版三者并存。
            // 画面同样由自绘 AVPlayerLayer 承载（镜像只翻画面不翻弹幕字幕），
            // 会话仍由下面离屏 stage 产生 —— 两条皮肤共用同一个 `oneSkinSessionStage`。
            biliSkinBody
                .ignoresSafeArea(edges: fullScreen ? .all : [.top, .horizontal])
                .padding(.bottom, oneSkinTabReserve.bottom)
                .padding(.trailing, oneSkinTabReserve.trailing)
                .background(BiliPalette.page.ignoresSafeArea())
                .background(alignment: .topLeading) {
                    // 和 One 皮肤同一个理由：用 offset 推到屏幕外，不用 opacity ——
                    // 极低 opacity 时 SwiftUI 可能跳过子树渲染，onAppear 就不触发。
                    oneSkinSessionStage
                        .frame(width: 8, height: 8)
                        .offset(x: -4000, y: -4000)
                        .allowsHitTesting(false)
                }
                // ★ 三个面板分开挂，用枚举区分。
                //
                // 不能用 `.sheet(isPresented:)` 叠两个 —— 实测同层第二个会被静默丢掉；
                // 而且哔哩哔哩这三个面板的**条目集本来就不同**，共用一个 bool 也不对。
                .overlay { biliPanelOverlay }
                // 画面比例：**唯一真实来源是 `AVPlayerItem.presentationSize`**。
                // 皮肤路径下视图层 `aspect` 回调不触发，`playerAspectRatio` 会一直停在
                // 16:9 初值 —— 于是横屏切竖屏后播放器尺寸不跟着变（用户实测反馈）。
                // 这里在每次播放会话变化 / 进入页面时轮询一次，读到非零尺寸就更新。
                .task(id: playerSession?.player.currentItem) {
                    await syncAspectFromPresentationSize()
                }
                #if DEBUG
                // `-qaBiliSettings 1` 自动展开面板给截图用（guest 里点不到小图标）。
                //
                // ⚠️ 不能放在 `.onAppear` 里判 `fullScreen`：onAppear 触发时
                // `@AppStorage("watchFullScreen")` 还没被读到本视图状态，恒为 false，
                // 于是无论怎么配都开成 `.actionMenu`（实测把全屏页盖成了详情页菜单）。
                // 改成监听 `fullScreen` 的变化 —— 它变 true 时再开对应面板。
                // ⚠️ 只在**本次启动确实传了 -qaBiliSettings** 时自动开面板。
                // 之前只判 `qaBiliOpenSettings` 这个持久键 —— 截图时写进去一次，
                // 之后每次进详情页都会自动弹菜单盖住页面（用户实测「进视频直接开了弹窗」）。
                // `qaBiliSettings` 由 QALaunch 按启动参数逐次重写（不传就 remove），
                // 所以它是可靠的「本次是否要 QA 开面板」判据。
                .onChange(of: fullScreen, initial: true) { _, isFull in
                    #if DEBUG
                    guard UserDefaults.standard.bool(forKey: "qaBiliSettings") else { return }
                    if isFull {
                        biliPanel = (!landscapeScreen) ? .settings : .rail
                    } else {
                        biliPanel = .actionMenu
                    }
                    #endif
                }
                #endif
        } else if oneSkinActive {
            // [mi3s] One 皮肤整屏独立：不吃上一层的列宽/内边距，
            // 自己从全屏尺寸开始排版（横屏双列必须拿到完整宽高）。
            oneSkinBody
                // ★ 选集页**只让画面上边越界，底部要留给菜单栏**。
                //
                // 原来是无条件 `.ignoresSafeArea()`（四个方向全忽略）——
                // OneSkin 会一路铺到屏幕最底，把底部标签栏整个盖住。
                // 用户报「选集播放页应该保留原本的菜单栏」，根因就是它：
                // `TabBarHider` 的日志证明标签栏的 isHidden 一直是 false
                // （`want=false now=false`），它没被藏，是被盖了。
                //
                // 全屏时必须继续全忽略，否则四周的 letterbox 会留出白边。
                .ignoresSafeArea(edges: fullScreen ? .all : [.top, .horizontal])
                // ★ 光「不忽略底部」还不够：iOS 26 的液态玻璃标签栏是**浮层**，
                // 它不撑大 `safeAreaInsets`，系统只给 34pt Home 指示条 ——
                // 选集卡片会从玻璃下面穿过去、被压掉半行（截图逐像素量过）。
                // 让哪一边看方向：竖持让底边（底部胶囊），横持让右边（贴右缘的竖排胶囊）。
                // 全屏两边都归零（全屏本来就没有菜单栏）。
                // 竖持：底部浮动胶囊（约 50pt，浮在 34pt Home 指示条之上）。
                // 与右边同理用 `padding` 而不是 `safeAreaPadding` —— 两条边一个写法，
                // 免得下次又要在「安全区 vs 内缩」上猜一遍。让位条由下面的 pageBase 垫底。
                // ⛔ 已移除这里的 `.padding(.bottom, 36)` / `.padding(.trailing, 64)`。
                //
                // 让位量已由 `OneSkinGeometryDriver.box` 在**几何层**算进去
                // （横持扣右 47pt；竖持四边全 0，因为实测内容铺满到 951×669）。
                // 这里再 padding 一次就是**双重扣减**：内容按满尺寸排、塞进
                // 小二三十 pt 的容器，所有控件整体错位 ——
                // 这就是用户报「尺寸完全对不上」的根因。
                //
                // 胶囊条是**浮层**（overlay），不占布局。实测截图里右缘 47pt
                // 就是纯黑留白（x=904..951 最大亮度仅 14–28），胶囊浮在那条带上。
                // 让位出来的那一条不能露系统页面底色（浅灰一条，比压住内容更难看）。
                // 用 One 自己的整页底色垫在下面：海报渐变在页边本来就近黑，接缝看不出来。
                .background(OneSkinPalette.pageBase.ignoresSafeArea())
                // OneSkin 用 `OneSkinFixedPicture` 自绘画面，但 session 由
                // PlaybackView 的 `onAppear` 启动、`opened:` 回调交回来。
                // 所以这里仍挂一份离屏的 PlaybackView —— 但**只要 session，
                // 不要它的画面层**（stageOnly）；否则会多一个
                // AVPlayerViewController 与选集页的 AVPlayerLayer 抢 player，
                // 竖屏片源最容易变成黑屏「看不了」。见 PlaybackView.stageOnly。
                .background(alignment: .topLeading) {
                    // 用 offset 推到屏幕外而不是 opacity：opacity 极低时 SwiftUI
                    // 可能跳过子树渲染，`onAppear` / `opened:` 就不触发。
                    //
                    // ★★ 这里的播放器是「控件每秒推移」这个环的**源头**。
                    //
                    // 只写 `.frame(width: 8, height: 8)` 是不够的 —— 那只给**建议尺寸**。
                    // `oneSkinSessionStage` 里是真正的 `PlaybackView`
                    // （`AVPlayerViewController` + `AVPlayerLayer`，`videoGravity =
                    //  ResizeAspect`），UIKit 图层会按**视频自身的比例**报 intrinsic
                    // size，SwiftUI 拿它当「子视图理想尺寸」，经 `.background`
                    // 回灌给父级 `oneSkinBody`，再被根部 `GeometryReader` 量到：
                    //
                    //   proxy 变 → stage 按 proxy 重排 → 播放器层再算 intrinsic →
                    //   proxy 再变 → …
                    //
                    // 实测日志（Fig，fullBleed 竖持）：
                    //   ROOT 每秒 344 次、dt=9–24ms；
                    //   proxy=751x743 → 746x743 → 739x744 → 735x743 → 730x743 → 728x743
                    //   高度稳定在 743/744，**宽度一路缩**（视频 16:9 在把父级往窄里拉）。
                    //
                    // 修法：三件事一起做，缺一个都还在漏尺寸 ——
                    //   ① `.fixedSize()`     拒绝 intrinsic size 反向影响父级
                    //   ② `.clipped()`       把任何溢出的图层裁在 8×8 内
                    //   ③ `.frame(8,8)`      仍给出落点
                    // ★ 用 `.hidden()` 让 UIKit 子树**真的不渲染**，而不是只挪位置。
                    //
                    // 实测（Fig，AX 树）：`.offset(x: -4000)` 之后，AX 里仍有一个
                    //   w=547.52 h=307.98 (比例 1.7778 = 16:9) x=-448.09
                    // 的元素 —— 正是 `AVPlayerViewController` 按视频固有比例报出来的
                    // UIKit 图层。`.fixedSize()` / `.clipped()` 只管 SwiftUI 布局，
                    // 管不住 UIKit 子视图自身的 frame：它没被移到 -4000，停在 -448，
                    // 带着 547×308 的 16:9 画面浮在内容层上，把左侧内容盖住。
                    // 这就是用户报「所有内容都偏左、被盖住」的直接来源。
                    //
                    // `.hidden()` 保留视图在层级里（`onAppear` / `opened:` 照常触发，
                    // 会话仍能建立），但让 UIKit 不再绘制、也不参与命中测试。
                    oneSkinSessionStage
                        .frame(width: 8, height: 8)
                        .fixedSize()
                        .clipped()
                        .offset(x: -4000, y: -4000)
                        .hidden()
                        .allowsHitTesting(false)
                }
                // ⛔ 片源比例：One 皮肤此前**从不更新** `playerAspectRatio`（BUG-N）。
                //
                // 上面那句「唯一真实来源是 `AVPlayerItem.presentationSize`」原来只挂在
                // 哔哩哔哩分支上；One 分支没有，`OneSkinStage` 内部也没有任何
                // `presentationSize` 消费者（`OneSkin.swift` 里那段轮询早被删了）。
                // 于是 One 皮肤的 `aspectRatio` 永远是 16:9 初值：
                //   · fullBleed / halfFold 的 `picH = 宽 / 片源比` 按横片算，
                //     竖屏片源本该占 532pt 高，实际按 16:9 只给 376pt，
                //     画面被压成中间一条、上下大黑边；
                //   · 竖屏片源的「填充」也就没有意义。
                // 这条直接违反项目铁律「画面比例唯一真源是 `presentationSize`」。
                //
                // 与哔哩哔哩那一支用**同一个**函数、同一个 `task(id:)` 触发点，
                // 两个皮肤不再各有一套比例来源。
                .task(id: playerSession?.player.currentItem) {
                    await syncAspectFromPresentationSize()
                }
                // [mi3s] 系统栏位（状态栏 / 导航栏 / 标签栏 / Home 指示条）
                // 已经**不在这一支里写**了 —— 见 `body` 里 `watchBody` 外层挂的
                // `WatchSystemChrome`。判据只有 `fullScreen` 一个，两条渲染分支共用，
                // 不会再出现「改了一边漏了另一边」。
        } else {
            upstreamWatchBody
        }
    }

    /// One 观看页三态。判据**全部来自离散信号**，不看容器宽高比：
    ///   split      = Duo 摊开 + 横持（sideways），或手机横持（landscapePage）
    ///   fullBleed  = Duo 摊开 + 竖持（portraitExpanded）＝「展开宽屏」
    ///   column     = 其余（折叠态 / 立式手机）
    ///
    /// 2026-11-09：这里原来用 `containerWidth > containerHeight` 判 split。
    /// 容器尺寸在折叠 / 旋转动画里是**连续量**，会在临界点反复翻转；
    /// 而 `containerWidth/Height` 又是 `.onGeometryChange` 写回的 @State，
    ///   于是形成「改布局 → 再量到新尺寸 → 再改形态」的自激环，表现为两种展开态
    /// 分不开、控件坐标每帧漂移。`sideways` 只看 `interfaceOrientation`
    /// （离散）、`duoExpanded` / `landscapePage` 只看 size class（离散），
    /// 形态一旦定下就不会因亚点尺寸变化而抖动。
    private var oneSkinShape: OneSkinShape {
        #if DEBUG
        // QA 覆盖：强制指定形态，用于无人值守验收。
        // ★ 这里必须覆盖**全部五态** —— 之前只认 wide/sideways，
        // 而 `effectiveShape` 又只认 column/split，导致 halfFold/fullBleed
        // 这两态在任何 QA 参数下都无法抵达（「每种形态都不对」的一部分）。
        if UserDefaults.standard.bool(forKey: "qaOneSkinWide") { return .fullBleed }
        if UserDefaults.standard.bool(forKey: "qaOneSkinSideways") { return .split }
        if UserDefaults.standard.bool(forKey: "qaOneSkinHalfFold") { return .halfFold }
        if UserDefaults.standard.bool(forKey: "qaOneSkinColumn") { return .column }
        #endif
        // ★ 半折优先：横向折痕落在容器中部 = 书本 / 帐篷，是第五态。
        //
        // 判据来自系统给的 division 矩形（`FoldGap.horizontalBand`）：
        // 横带中心落在容器 25%–75% 之间才算半折 —— 贴顶/贴底的横带
        // 是状态栏或手势条，不是折痕，不能误判。
        // 这一支必须排在 duoExpanded 之前：半折时 size class 仍报 regular，
        // 若先走 duoExpanded 会被当成「摊开竖持」，画面铺满整屏而控制台丢失。
        // ★ 判据单一来源：**容器宽高比**（离散比例分桶）。
        //
        // 之前用 sizeClass + containerWidth>600 + interfaceOrientation 三路推断，
        // 其中两路在 Duo 上不可靠：
        //   · Duo 内屏横持实际报 `regular × regular`（sizeClass 不翻转）；
        //   · `interfaceOrientation` 在内屏恒报 landscape（假值）。
        // 容器宽高比是**这一帧真正可用的几何事实**，无需任何设备信号推断，
        // 也不会因为 size class 抖动而翻转（配合 8pt 分桶）。
        let w = max(layoutSize.width, 1)
        let h = max(layoutSize.height, 1)
        let ratio = w / h

        // 半折：折缝把容器分成两半。**两种方向都要认**。
        //
        // ★★ P0-1：判据顺序必须是「铰链状态 → 几何」。
        //
        // 铰链状态（`DeviceHinge.status`，iOS 27.1+）是**权威**的：
        //   closed / partiallyOpen / fullyOpen 三档，
        //   半折 ⟺ partiallyOpen，摊开 ⟺ fullyOpen。没有中间解释空间。
        //
        // 而折缝**位置**不是判据：代码自己记录的摊开态实测中心比就有
        //   0.600 / 0.554 / 0.507 三种（斜着拿、手挡住一部分都会变）。
        // 原来写 `abs(centerRatio - 0.5) > 0.06` 判半折 —— 0.554 和 0.600
        // 都 > 0.06，于是**摊开竖屏被直接判成半折**：上下两个物理半屏，
        // 详情和选集整块消失，胶囊条还按另一套假设落位。这是单点影响最大的一个。
        //
        // 现在：铰链报了就用铰链；铰链没报（旧系统 / 非折叠设备）才退回几何，
        // 而且退回时阈值放到 15% —— 宁可把「极端的半折」漏成双列，
        // 也不能把「正常的摊开」误判成半折（后者会让整页内容消失）。
        if let hingePartiallyOpen {
            if hingePartiallyOpen { return .halfFold }
            // fullyOpen / closed：明确不是半折，跳过下面所有折缝偏移猜测。
        } else {
            // 铰链不可用 → 几何兜底（阈值 0.15，理由见上）。
            if let foldGap, foldGap.width > 0 {
                let foldCenterRatio = foldGap.centerX / max(w, 1)
                if abs(foldCenterRatio - 0.5) > 0.15 { return .halfFold }
            }
        }
        // 横折缝（书本/帐篷趴着）：折缝确实是**横穿中部**的带。
        // 这条只在铰链不可用时才算数 —— 铰链明确说 fullyOpen 就别再猜了。
        if hingePartiallyOpen == nil,
           let horizontalFold, horizontalFold.splitsContainer(h) {
            return .halfFold
        }

        // 宽高比 ≥ 1.15 → 横向容器：左右双列。
        // 不区分「Duo 摊开」还是「手机横持」—— 对排版来说二者只需不同列数，
        // 差异（内屏要不要右让位）交给几何层的 `shape.isLandscape` 处理。
        // ★ 判据改严：双页横屏 vs 单页竖屏必须靠**宽高比 + 绝对宽**双条件分开。
        //
        // 实测（真机 Duo）：
        //   双页横屏态 container = 672×492  ratio 1.37  → split
        //   单页竖屏态 container = 594×688  ratio 0.86  → 非 split
        // ratio 1.15 这条线本身够用；真正丢判据的是下面那条「w>=500 → fullBleed」，
        // 它把「内屏竖持」和「外屏竖持」混成同一个 fullBleed，
        // 于是双页/单页两态看起来一样。改为按**容器宽**区分三档。
        if ratio >= 1.15 { return .split }

        // 竖持分支：按容器宽度分两档，不再混成一档。
        //   · 内屏竖持：容器宽 ≈ 594（≥500）→ 宽屏变体，画面全出血 + 详情抽屉
        //   · 外屏/手机竖持：容器宽 ≈ 466（<500）→ 标准单列
        if ratio < 1.15 {
            return w >= 500 ? .fullBleed : .column
        }

        return .column
    }

    @AppStorage(OneSkin.enabledKey) private var oneSkinEnabled = true  // [临时验证] 默认开，QA 参数传不进 Fig-clone
    @AppStorage(OneSkin.speedKey) private var oneSkinSpeed: Double = 1
    /// [mi3s] 三态换皮：原版 / One / 哔哩哔哩。
    ///
    /// 存空串就是「还没选过」，此时按 `PlaySkin.current` 走 —— 那个计算属性会把旧版
    /// 只有 `oneSkinEnabled` 一个布尔的状态迁移过来，升级不会掉皮肤。
    /// 不直接把默认值写成 `PlaySkin.current.rawValue`：`@AppStorage` 的默认值只在
    /// 键缺失时被读，两者等价，但写空串让「没选过」这个状态显式可判。
    /// ⛔ 默认值**不能**是空串。
    ///
    /// `@AppStorage` 在键缺失时把默认值写回 UserDefaults，而它同时是 Picker 的绑定源。
    /// 实测（vphone guest，wda.prdc.yingxia.guji）：手工把 plist 写成 `playSkin=bilibili`，
    /// 启动后立刻被改回 `native` —— 因为属性初始化先以 `""` 写入，
    /// `playSkin` 计算属性读到非法值退回 `.current`（`.native`），Picker 随即把它落盘。
    /// 默认值直接取迁移结果，就不会有这个覆盖窗口。
    @AppStorage(PlaySkin.key) private var playSkinRaw = PlaySkin.current.rawValue
    /// 哔哩哔哩详情页上的选集抽屉。详情页与播放页是两级，抽屉挂在详情页。
    /// 当前打开的哔哩哔哩弹出面板。
    ///
    /// 实测哔哩哔哩有**三个互不相同**的面板（条目集都不一样），不能共用一个 bool：
    /// `actionMenu`（详情页更多）/ `settings`（竖屏齿轮，含 Speed+Timer）/
    /// `rail`（横屏全屏三点，含镜像/后台/画幅）。
    @State private var biliPanel: BiliPanel?

    /// 打开设置面板时要聚焦的分区。实测底栏三个文字按钮（字幕/倍速/画质）
    /// 打开的是**同一个**面板，靠滚动位置区分落点。
    @State private var biliSettingsFocus: BiliSettingsFocus = .speed
    /// 详情页选集抽屉内的倒序开关。
    @AppStorage("biliEpisodesReversed") private var biliReversesEpisodes = false
    /// 当前集序号（1 基）；没有集就 0。详情页的 `N/M` 用它。
    private var currentEpisodeIndex: Int {
        let episodes = activeEpisodes
        guard !episodes.isEmpty else { return 0 }
        if let chosen = currentEpisode, let idx = episodes.firstIndex(where: { $0.id == chosen.id }) {
            return idx + 1
        }
        if let id = currentEpisodeID, let idx = episodes.firstIndex(where: { $0.id == id }) {
            return idx + 1
        }
        return 1
    }

    private var playSkin: PlaySkin {
        if let stored = PlaySkin(rawValue: playSkinRaw) { return stored }
        return PlaySkin.current
    }

    /// [mi3s] QA 强制开关：启动参数 `-qaOneSkin`（或 `qaOneSkin=1`）时强制启用皮肤，
    /// 免去验证时和 cfprefsd 抢 UserDefaults 的麻烦。普通用户走 `oneSkinEnabled`（设置页）。
    private var oneSkinActive: Bool {
        // 同 key 在 OneSkinPreferencePanel 里也是 @AppStorage；两处默认值必须一致，
        // 否则谁先构造谁决定实际值（曾因那边默认 false 导致皮肤永远不生效）。
        guard !biliActive else { return false }
        return oneSkinEnabled || UserDefaults.standard.bool(forKey: "qaOneSkin")
    }

    /// 哔哩哔哩皮肤是否生效。QA 用 `-qaBiliSkin`。
    private var biliActive: Bool {
        // 探针：皮肤判据的每个输入都打出来。
        // 用户报「设置里选 One，界面仍是哔哩哔哩，杀进程重进也一样」——
        // 只有三个可能：①`playSkin` 没写成 one ②`oneSkinEnabled` 被置 false
        // ③`qaBiliSkin` 残留 true。一次打清，不再分层猜。
        // ⛔ 只认「本次启动」标记，不认持久域里的 `qaBiliSkin`。
        //
        // 真机 plist 直读实证：`playSkin=one`、`oneSkinEnabled=true`、
        // 但 `qaBiliSkin=true` —— 用户明明选了 One，界面永远是哔哩哔哩。
        // `qaBiliSkin` 是旧版本会写回持久域的 QA 开关，一旦写成 true 就自锁，
        // 设置里改什么都不生效（`guard !biliActive else { return false }` 先把它挡掉）。
        // 现在 QA 参数只在启动那一次写入易失标记，正常启动会被清掉。
        let qa = UserDefaults.standard.bool(forKey: "qaBiliSkinActiveThisLaunch")
        let r = qa || playSkin == .bilibili
        #if DEBUG
        oneSkinLog("SKINCHK raw=\(playSkinRaw) skin=\(playSkin) qaBili=\(qa) oneEnabled=\(oneSkinEnabled) bili=\(r)")
        #endif
        return r
    }

    /// 选集页要给菜单栏让出的空间。
    ///
    /// iOS 26 的标签栏是浮层、不进 `safeAreaInsets`，所以必须自己让位；
    /// 而且**形状随方向变**：竖持是底部横胶囊，横持是贴右缘的竖胶囊。
    /// 只让底边是之前「横屏内容被菜单栏盖住」的原因（Duo 内屏截图逐像素量过）。
    private var oneSkinTabReserve: (bottom: CGFloat, trailing: CGFloat) {
        // ⛔ 此前这里三个分支**全返回 (0,0)** —— 等于「永远不让位」。
        //
        // 那个决定的前提是「`WatchSystemChrome` 把 tabBar 恒收掉」。但同文件里
        // `.setBarVisibility(fullScreen ? .hidden : .visible, for: .tabBar)` 只在**全屏**收，
        // 非全屏时 iOS 26 的液态玻璃胶囊照常渲染，而它是**浮层**、不进 `safeAreaInsets`，
        // 于是没有任何一边给它让位：
        //   · 竖持：底部横向胶囊压住最后一行（选集卡片被压掉半行）；
        //   · 横持：它收成**贴右缘的竖排胶囊**，直接压住右栏的选集按钮与第 2 集卡片。
        // `WatchPageChrome.swift` 里 `WatchTabBarReserve`（bottom 36 / trailing 64）
        // 当初就是按截图逐像素量出来解决这件事的，但**从来没接线**（全仓零引用，纯死代码）。
        // 现在按形态接上：竖持让底边，横持让右边。
        guard !fullScreen else { return (0, 0) }
        return landscapeScreen
            ? (0, WatchTabBarReserve.trailing)
            : (WatchTabBarReserve.bottom, 0)
    }

    // MARK: One 皮肤用到的三处取值
    // 观看页把「在播的是哪一集」「是不是本站播放」「跳 10 秒」这三件事原本写在各处内联表达式里，
    // 皮肤层需要具名入口，就在这里收一次，不复制上游逻辑。

    /// 在播的那一集；没在播就是列表里的第一集。
    private var currentEpisode: Episode? {
        if let id = currentEpisodeID { return activeEpisodes.first { $0.id == id } }
        return activeEpisodes.first
    }

    /// 这一页自己正在播（而不是别处有小窗或在推流）。
    private var playingOnThisPage: Bool {
        guard let channel = watchChannel else { return false }
        return store.playing == channel
    }

    /// 前后跳 10 秒，走播放器自己的 `skip(_:)`。
    private func skip(by seconds: Double) {
        playerSession?.skip(seconds)
    }

    /// 为**每条线路**解析出可测速的真实播放地址。
    ///
    /// 为什么要逐线解析、而不是直接拿 `episode.address`：
    /// type 3/4（CatPaw / 苹果CMS 播放器接口）的 `address` 只是个 play 参数，
    /// 必须过 `preparePlayback` + `resolvePlayback` 才变成可请求的流地址。
    /// 拿原始字符串去 HEAD，测的是一个不存在的 URL，数字纯属摆设。
    ///
    /// 每条线路取「当前正在看的这一集」；该线没有这一集时退回它的首集。
    ///
    /// ⛔ **这里是「进播放页就变慢、连点播放都受影响」的第一现场**（RCA H1/H9，已判决）。
    ///
    /// 上一版对一个 `flags` 里的**每一条线路**同时 `addTask`，没有任何并发上限，而且：
    ///   1. 它们全部走 `preparePlayback` → 脚本运行时，而 `ScriptThread` 是**单线程串行**的
    ///      （ScriptRuntime.swift:199-215）。4~9 条线路的插件调用因此排成一队，
    ///      用户紧接着点播放的那一次 `preparePlayback` **排在这一队后面** ——
    ///      他看到的「点播放要等很久」就是这么来的。
    ///   2. 这批解析由裸 `Task {}` 启动（`.onAppear` 里），不进 `requestTask`，
    ///      所以 `play()` 的 `startRequest` **取消不到它**（:305-313）。
    ///
    /// 现在两条约束：
    ///   · **只在后台、串行、且让位给播放**：一次只解析一条线，且每条之前都看一眼
    ///     「用户有没有已经在播 / 正在起播」—— 有就立刻收手，把脚本线程还给它。
    ///   · **按 base 缓存优先**（One 的 `latencyByBase`）：同 host 刚测过的线路不再解析。
    ///     解析是这一步最贵的动作（要过插件），比一次 HTTP 探针贵得多。
    ///
    /// 结果仍然逐条落进 `lineSamples`，所以线路菜单照旧一条条亮起来 —— 只是不再挡路。
    private func buildLineSamples() async {
        guard let episodes = detail?.episodes, !flags.isEmpty else {
            await MainActor.run { lineSamples = [:] }
            return
        }
        let playing = episodes.first { $0.id == currentEpisodeID }
        let lines = flags
        // `subscription` 是主线程隔离的，先在主线程取好快照，再并发解析。
        let base = client
        let playback = store.subscription.map { client.applying($0) } ?? client

        // ★ 按次收费的源：只预热**免费的那一半**，不替用户把所有线路都签出来。
        //
        // 看剧AI 的官方线路是服务端现签、按集扣词元的。它的三档（普通 / 官方1080 / 官方4K）
        // 在我们这边是三条「线路」，于是上一版进详情页就把三条全解一遍 —— 每打开一部剧，
        // 官方 1080 与官方 4K 各扣一次额度（约 3 万 + 6 万词元），而用户可能只是想看看简介；
        // 更糟的是脚本线程是串行的，这三签排在前面，用户紧接着点播放时**就排在它们后面**，
        // 他看到的等待正是「等我自己点开的那三条线路」。
        //
        // 现在只问这一集的分集线路表（不扣额度），签名留到他点播放的那一刻。
        // 其余线路在菜单里显示「未测」而不是「不通」——没解析过就不该说人家不通；
        // 他真去点那条线时，`probeLines` 会按需解析，那一次花销是他自己要求的。
        if base.site.prefetchesLineList {
            if let episode = playing ?? episodes.first { await base.prefetchPlayback(episode) }
            return
        }

        // 这一轮的身份：换集 / 换线 / 重进页面会开新一轮，旧轮次的解析到这里就该收手。
        let generation = await MainActor.run { SourceProbeStore.shared.beginProbeGeneration() }

        for flag in lines {
            // ★ 让位给「正在起播」，**不是**让给「已经在播」。
            //
            // ⛔ 这里曾经写成 `!busy && watchChannel == nil`，是一个真实的功能回归：
            //    线路菜单（`OneSkin.lineLatencies`）只在**播放态**的胶囊带里出现，
            //    而它按 `lineSamples` 逐线发 HEAD。一旦 `watchChannel != nil` 就 break，
            //    于是播放中打开线路菜单，除当前线路外每条都显示「不通」——
            //    那不是测出来的，是根本没解析。
            //
            // 正确的让位边界只有一个：`busy`（正在解析/起播某一集）。
            // 那一刻脚本线程要给播放让路，所以先等它结束；已经播起来之后，
            // 剩余线路逐条串行解析是可以接受的代价（一集只有 4~9 条线，且已去重）。
            var waited = 0
            while await MainActor.run(body: { busy }) {
                // 起播通常 1~3 秒；超过 10 秒说明卡住了，这一轮就收手，
                // 让用户自己按「重新测速」——不无限占用脚本线程。
                if waited >= 20 { return }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            let current = await MainActor.run { SourceProbeStore.shared.isCurrentGeneration(generation) }
            guard current, !Task.isCancelled else { return }

            let onLine = episodes.filter { $0.flag == flag }
            guard let ep = onLine.first(where: { $0.id == playing?.id }) ?? onLine.first else { continue }

            // 这一条已经解析过（`lineSamples` 里的成果，比如上一轮或折叠重进页面）就不重复解析。
            // 解析要过插件运行时，是这一步最贵的动作。
            if await MainActor.run(body: { lineSamples[flag] != nil }) { continue }

            do {
                let plan = try await base.preparePlayback(ep)
                guard let choice = plan.choices.first else { continue }
                let channel = try await playback.resolvePlayback(plan, choice: choice)
                let sample = OneSkinLineSample(url: channel.url, headers: channel.headers)
                // 逐条写回：线路菜单一条条亮起来，而不是等全部解析完才一起出现。
                await MainActor.run { lineSamples[flag] = sample }
            } catch {
                // 解析不出（该线没有这一集 / 源报错）：跳过，不编造。
                continue
            }
        }
    }

    /// ⛔ 换集修复（2026-11-09）：选集页画面必须绑到「真正在播」的那一个 AVPlayer。
    ///
    /// `Store.playbackSession(for:)` 遇到新 channel 会**新建一个空会话**；但
    /// `PlaybackView` 的 `@State session` 在视图身份不变时不会跟着 init 参数换，
    /// 而是由 `.onChange(of: channel)` 在**原 player** 上替换 currentItem
    ///（上游就是这么设计换集的）。换集后两边就此分叉：`oneSkinBody` 若仍用
    /// `store.playbackSession(for: watchChannel)`，会把 `OneSkinFixedPicture`
    /// 绑到一个没有 item 的新 player 上，只剩海报虚化；声音却还在旧 player
    /// 上播 —— 用户看到的「换集后播放器不渲染新内容」。
    ///
    /// `playerSession` 由离屏 stage 的 `onStageSession` / `opened:` 交回，指向
    /// PlaybackView 实际持有的会话，换集时保持不变，正好长期一致。
    /// `??` 右侧延迟求值：只有首次 `onAppear` 之前才回退到 store（此时两者本就
    /// 是同一个对象）；换集后 `playerSession` 已有值，不会再新建空会话。
    /// 现读 `presentationSize` 得到片源比例；无 item / 未就绪时 nil（调用方回退）。
    private var oneSkinLiveAspect: CGFloat? {
        guard let sz = oneSkinStageSession?.player.currentItem?.presentationSize,
              sz.width > 0, sz.height > 0 else { return nil }
        let r = sz.width / sz.height
        return (r.isFinite && r > 0.2 && r < 6) ? r : nil
    }

    private var oneSkinStageSession: PlaybackSession? {
        // ⛔ 这里**只能读，不能建**。
        //
        // 原来写的是 `store.playbackSession(for:)` —— 那个函数在频道不匹配时
        // 会新建一个空会话并顶替 `activeSession`。而本属性是**计算属性**，
        // 每次 `body` 求值都会执行一次，于是：
        //   · 真正在播的会话被顶掉、变成孤儿（它还挂着 item，但没人读它）；
        //   · 新会话 `currentItem == nil` → 画面层无 item → 只显示海报。
        // 真机日志（8.11.5，用户报「部分视频只出海报」）：
        //   VIDSRC in=1.7778 ps=0x0 st=-1 dur=-1 ext=- host=- noItem   ← 坏源
        //   VIDSRC in=0.5625 ps=1080x1920 st=1 dur=114 ext=mp4 n=1     ← 好源
        // 「部分」的成因：`Channel.id` 只含 group|name|url，而
        // `activeSessionChannel == channel` 比的是**全字段**。换集/换线路/
        // 从坞回来时两者不等 → 每帧新建空会话 → 该源永远 noItem。
        // ① 优先用本页持有的强引用（`onStageSession` 交回来的那一个）。
        if let playerSession { return playerSession }
        // ② 其次用 `lastGoodSession` —— 见下方说明。
        if let lastGoodSession { return lastGoodSession }
        // ③ 最后才去 store 查（首次进入、`onStageSession` 还没回传时）。
        guard let channel = watchChannel else { return nil }
        return store.currentSession(for: channel)
    }

    /// `oneSkinStageSession` 三档的**只读**诊断串，喂给 `OneSkinStage.stageDiag`。
    ///
    /// ⛔ 只读：这里绝不能调 `playbackSession(for:)`（会新建并顶掉正在播的会话）。
    /// 字段含义（真机上 `PICCHK avPlayer=NIL ... stage=...` 一行即可定性）：
    ///   ps=1/0   `playerSession` 有没有值
    ///   lgs=1/0  `lastGoodSession` 有没有值
    ///   wc=1/0   `watchChannel` 有没有值
    ///   st=1/0   `store.currentSession(for: watchChannel)` 有没有值
    ///   pl=1/0   `store.playing` 有没有值
    ///   ac=1/0   `store.activeSessionChannel` 有没有值
    ///   eq=1/0   `activeSessionChannel == watchChannel`（**全字段比较**）
    ///   item=1/0 `store.activeSession` 的 player 有没有 currentItem
    private var oneSkinStageDiag: String {
        // ⛔ 只用 Store 的**公开**接口：`activeSession` / `activeSessionChannel`
        //    是 `private`（Store.swift:546），这里读不到也不该读。
        //    `currentSession(for:)` 已经内含「activeSession 存在且频道全字段相等」，
        //    所以 `st` 自己就是 eq 的结论。
        func b(_ v: Bool) -> Int { v ? 1 : 0 }
        let wc = watchChannel
        let st = wc.flatMap { store.currentSession(for: $0) }
        return "ps=\(b(playerSession != nil)) lgs=\(b(lastGoodSession != nil))"
            + " wc=\(b(wc != nil)) st=\(b(st != nil))"
            + " pl=\(b(store.playing != nil))"
            + " item=\(b(st?.player.currentItem != nil))"
    }

    /// 哔哩哔哩版式：半屏卡片 + 详情 + 选集抽屉；全屏时齿轮从右侧划出设置面板。
    ///
    /// 与 One 分支的区别只有版式和控件位置 —— 会话、换集、字幕、弹幕全部走同一套引擎，
    /// 所以这里传的参数几乎和 `oneSkinBody` 一样，少的是 One 自己的 chip 与配色状态。

    /// 三个弹出面板的宿主。
    ///
    /// 用 `overlay` 而不是 `sheet`：哔哩哔哩这三个面板都是**浮在画面上**的
    /// （详情页操作菜单、全屏齿轮设置、横屏右缘竖条），不是全屏 modal。
    /// 实测它们的形态各不相同，所以每个分支自己决定摆放位置。
    /// 上一集（`bbplayer_fullscreen_playlast`）。
    ///
    /// 不去 B 站侧找「上一条」，直接用**当前线路的集数列表** ——
    /// 这是播放器自己的能力，与账号生态无关。
    private func awaitPreviousEpisode() {
        guard let cur = currentEpisode,
              let idx = activeEpisodes.firstIndex(where: { $0.id == cur.id }),
              idx > 0 else { return }
        Task { await play(activeEpisodes[idx - 1]) }
    }

    /// 截当前画面（`bbplayer_fullscreen_screenshot`）。
    ///
    /// 用 `AVPlayerItemVideoOutput` 拿不到当前显示帧时，退回到 `AVPlayerLayer`
    /// 的 `render(in:)` —— 两种都只截画面本身，不含 SwiftUI 控件（与哔哩哔哩一致）。
    private func saveCurrentFrame() {
        guard let layer = playerSession?.player.currentItem else { return }
        _ = layer
        let bounds = UIApplication.shared.appScreenBounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { ctx in
            // 画面层：从当前视图树里找到 AVPlayerLayer 直接渲染
            if let window = UIApplication.shared.appWindowScene?.windows.first {
                window.layer.render(in: ctx.cgContext)
            }
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    /// 从 `AVPlayerItem.presentationSize` 同步画面比例。
    ///
    /// 硬约束：这是**唯一可靠来源**。`presentationSize` 在 item 未 ready 时是 `.zero`，
    /// 所以要轮询到非零为止；拿到后就停。
    @MainActor
    private func syncAspectFromPresentationSize() async {
        for _ in 0..<40 {
            // ⛔ 必须读 `oneSkinStageSession`，不能只读 `playerSession`。
            //
            // `playerSession` 只有 `PlaybackView` 的 `onStageSession` 闭包会给它赋值；
            // One 皮肤走 `stageOnly: true`，那条闭包路径不一定跑 —— 实测真机日志：
            //   `ASPECTSYNC TIMEOUT 未拿到 presentationSize，仍用 1.7778`
            // 于是一整场都按 16:9 排版，竖屏源（0.5625）的窗口高度算错，
            // 详情列被挤出屏幕（用户报「竖屏源只看到海报」）。
            //
            // 而 `oneSkinStageSession` 正是 `OneSkinStage` 实际拿去渲染的那个会话
            // （`playerSession ?? store.playbackSession(for:)`），比例必须问它。
            let probeSession = playerSession ?? oneSkinStageSession
            if let size = probeSession?.player.currentItem?.presentationSize,
               size.width > 0, size.height > 0 {
                let ratio = size.width / size.height
                #if DEBUG
                // 探针：用户报「竖屏源仍按 16:9 排版」。这条能分清是
                // ① 拿不到 presentationSize（回退 16:9），还是
                // ② 拿到了但被范围闸门挡掉。
                oneSkinLog("ASPECTSYNC size=\(Int(size.width))x\(Int(size.height)) ratio=\(String(format: "%.4f", ratio)) old=\(String(format: "%.4f", playerAspectRatio))")
                #endif
                if ratio.isFinite, ratio > 0.2, ratio < 6,
                   abs(ratio - playerAspectRatio) > 0.01 {
                    playerAspectRatio = ratio
                }
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
        }
        #if DEBUG
        oneSkinLog("ASPECTSYNC TIMEOUT 未拿到 presentationSize，仍用 \(String(format: "%.4f", playerAspectRatio))")
        #endif
    }

    /// 全屏态四钮共用的弹窗（以「画质」框为基准款式）。
    /// 内容按 `biliSettingsFocus` 切换：subtitles / speed / quality / episodes。
    @ViewBuilder private var fullscreenPopupPanel: some View {
        BiliFullscreenPopup(
            title: fullscreenPopupTitle,
            trailing: fullscreenPopupTrailing,
            landscape: false,
            onClose: { biliPanel = nil }
        ) {
            fullscreenPopupRows
        }
    }

    /// 横屏版：同一款式，右下角 208pt 窄条。
    /// 单独抽成属性，避免塞进 switch 里触发类型检查过载（实测会编译失败）。
    @ViewBuilder private var fullscreenPopupPanelLandscape: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            BiliFullscreenPopup(
                title: fullscreenPopupTitle,
                trailing: fullscreenPopupTrailing,
                landscape: true,
                onClose: { biliPanel = nil }
            ) {
                fullscreenPopupRows
            }
            .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    private var fullscreenPopupTitle: String {
        switch biliSettingsFocus {
        case .subtitles:   return L10n.text("Subtitles")
        case .speed:       return L10n.text("Speed")
        case .quality:     return L10n.text("Resolution")
        case .episodes:    return L10n.text("Episodes")
        case .timer:       return L10n.text("Timer")
        case .aspect:      return L10n.text("Aspect Ratio")
        case .colorFilter: return L10n.text("Color Filter")
        case .menuEditor:  return L10n.text("Customize Menu")
        }
    }

    /// 只有画质框右上有 `Advanced Settings >`（实测）。
    private var fullscreenPopupTrailing: String {
        biliSettingsFocus == .quality ? L10n.text("Advanced Settings") : ""
    }

    @ViewBuilder private var fullscreenPopupRows: some View {
        // 实测（全屏 More 面板首屏）：最上面是**四个大按钮横排** ——
        //   See Original / Watch Later / PiP / Cast，各 85×102
        // 之前整段缺失，于是点 More 第一眼看到的是 Speed，与哔哩哔哩完全不同。
        HStack(spacing: 0) {
            heroButton("rectangle.on.rectangle", L10n.text("See Original")) { biliPanel = nil }
            heroButton("clock", L10n.text("Watch Later")) { biliPanel = nil }
            heroButton("pip", L10n.text("PiP")) { biliPip.startFloating() }
            heroButton("airplayvideo", L10n.text("Cast")) { biliPanel = nil }
        }
        .padding(.bottom, 8)

        // ⚠️ 结构照 `BBPlayerPlaySettingWidget` 的真实 5 个 Cell 重建。
        //
        // swift-section 实证（/tmp/bili_objc.txt:788530）：
        //   BBPlayerOperationListCell            _operationListCell   ← 操作四键（横排 UICollectionView）
        //   BBPlayerPlaySettingPlaybackRateCell  _playbackRateCell    ← 倍速
        //   BBPlayerPlaySettingPlaybackModeCell  _playbackModeCell    ← 播放模式
        //   BBPlayerPlaySettingScaleCell         _scaleCell           ← 画面比例
        //   BBPlayerPlaySettingConfigCell        _configCell          ← 配置入口
        //
        // 每个 Cell 内部都是 `UILabel *_titleLbl` + `NSArray *_btnArray`（一排按钮），
        // 且 PlaybackRateCell 有 `-calculateBtnNumOfLineWithWidth:` ——
        // **每行按钮数按可用宽度动态算**，不是固定列数。
        // 所以我之前用「3 列 GridItem」或「9 行单列」都是错的：
        // 正确形态是**每类一行，行内按钮按宽度自动折行**。
        // ★ 用户自定义菜单（设置里拖过的顺序 + 隐藏项）**必须在这里出现**。
        //
        // `BiliMenuConfig`（BiliMenuCustomization.swift）存了 `biliMenuOrder` /
        // `biliMenuHidden`，编辑页 `BiliMenuEditorView` 也在写它们 ——
        // 但**全项目没有任何读取方**：本面板只渲染固定五个 Cell，
        // `menuRow(for:)` 定义了却零调用。用户排完菜单、隐藏了几项，
        // 播放器里一点变化都没有 —— 这就是「二开功能写了没落地」。
        //
        // 现在：自定义菜单排在上面（顺序与显隐都按配置），
        // 五个固定 Cell 排在下面 —— 后者对齐 B站二进制（`BBPlayerPlaySetting*Cell`），
        // 是「面板本体」，不被用户配置影响；前者是用户自己的快捷入口。
        ForEach(BiliMenuConfig.visible) { item in
            menuRow(for: item)
        }

        ForEach(BiliPlaySettingSection.allCases, id: \.self) { section in
            playSettingSection(section)
        }

        // 编辑入口（rea 实证 `-[BBPlayerPlaySettingWidget editBtnClicked]`）。
        BiliPopupRow(text: L10n.text("Customize Menu") + "  ›",
                     selected: false, height: BiliPopupMetrics.rowHeight) {
            biliSettingsFocus = .menuEditor
        }

        switch biliSettingsFocus {
        case .speed:
            // 倍速。`BiliSettingsFocus.speed` 是**默认落点**（底栏 Speed 键、
            // 齿轮面板都把它设成 .speed），而这个 switch 此前**没有这个 case** ——
            // 于是点「倍速」打开的面板主体是空的，只有上面的固定几行。
            // 档位与 One 皮肤一致（`OneSkin.speeds`），七档。
            ForEach(OneSkin.speeds, id: \.self) { (rate: Float) in
                BiliPopupRow(text: OneSkin.label(rate),
                             selected: abs(oneSkinSpeed - Double(rate)) < 0.01,
                             height: BiliPopupMetrics.rowHeight) {
                    oneSkinSpeed = Double(rate)
                    playerSession?.setSpeed(rate)
                    biliPanel = nil
                }
            }
        case .quality:
            // 实测：Auto (720P HD) / 720P HD / 480P SD / 360P Smooth
            ForEach(["Auto (720P HD)", "720P HD", "480P SD", "360P Smooth"], id: \.self) { (q: String) in
                BiliPopupRow(text: L10n.text(q), selected: false,
                             height: BiliPopupMetrics.rowHeight) {
                    biliPanel = nil
                }
            }
        case .subtitles:
            BiliPopupRow(text: L10n.text("Off"), selected: false,
                         height: BiliPopupMetrics.rowHeight) {
                UserDefaults.standard.set(false, forKey: "biliSubtitlesOn")
            }
            BiliPopupRow(text: L10n.text("Chinese"),
                         selected: UserDefaults.standard.bool(forKey: "biliSubtitlesOn"),
                         height: BiliPopupMetrics.rowHeight) {
                UserDefaults.standard.set(true, forKey: "biliSubtitlesOn")
            }
        case .episodes:
            if activeEpisodes.isEmpty {
                BiliPopupRow(text: L10n.text("No episodes"), selected: false,
                             height: BiliPopupMetrics.rowHeight) {}
            } else {
                ForEach(activeEpisodes) { (ep: Episode) in
                    BiliPopupRow(text: ep.name, selected: ep.id == currentEpisode?.id,
                                 height: BiliPopupMetrics.rowHeight) {
                        withAnimation(.smooth(duration: 0.2)) { biliPanel = nil }
                        Task { await play(ep) }
                    }
                }
            }
        case .menuEditor:
            // 菜单项自定义面板（与 One 独立）。
            BiliMenuEditorView(onClose: { biliSettingsFocus = .speed })
        case .timer:
            // 实测五档：Disabled / 15:00 / 30:00 / 60:00 / **Custom**
            // 之前缺最后一档 Custom。
            ForEach([0, 15, 30, 60], id: \.self) { (m: Int) in
                BiliPopupRow(text: m == 0 ? L10n.text("Disabled") : "\(m):00",
                             selected: false, height: BiliPopupMetrics.rowHeight) {
                    if m == 0 { BiliPlayerExtras.shared.cancelSleep() }
                    else { BiliPlayerExtras.shared.startSleep(minutes: m) }
                }
            }
            BiliPopupRow(text: L10n.text("Custom"), selected: false,
                         height: BiliPopupMetrics.rowHeight) {
                biliPanel = nil
            }
        case .aspect:
            // 画面比例。二进制实证 5 档：`ratio16_9` / `ratio4_3` /
            // `ratioadjustcontent` / `ratioadjustscreen` / `ratiocentercrop`。
            // 此前这个 case 缺失 —— `BiliSettingsFocus.aspect` 在别的入口能设到，
            // 但这个 switch 没处理，面板会画成空白（用户点了「画面比例」什么都不出来）。
            ForEach(BiliAspectMode.allCases) { (mode: BiliAspectMode) in
                BiliPopupRow(text: mode.label,
                             selected: BiliAspectMode.current == mode,
                             height: BiliPopupMetrics.rowHeight) {
                    UserDefaults.standard.set(mode.stored, forKey: OneSkin.fitModeKey)
                    biliPanel = nil
                }
            }
        case .colorFilter:
            // 色彩滤镜（二进制实证 `color_filter`）。
            ForEach(BiliColorFilter.allCases) { (filter: BiliColorFilter) in
                BiliPopupRow(text: filter.label,
                             selected: BiliColorFilter.current == filter,
                             height: BiliPopupMetrics.rowHeight) {
                    UserDefaults.standard.set(filter.rawValue, forKey: "biliColorFilter")
                    biliPanel = nil
                }
            }
                default:
            // 其余 focus（speed / aspect / colorFilter / backgroundPlay / mirrorFlip /
            // miniPlayer / screenshot / lockScreen / danmuSettings）的内容
            // 已由上方 `ForEach(BiliPlaySettingSection.allCases)` 的五个 Cell 渲染，
            // 这里不再重复（重复会出现两套同样的 UI）。focus 只用来滚到那一段。
            EmptyView()
}
    }

    /// 渲染播放设置的一个 Cell（照 `BBPlayerPlaySettingWidget` 的 5 个成员）。
    @ViewBuilder
    private func playSettingSection(_ section: BiliPlaySettingSection) -> some View {
        switch section {
        case .operation:
            // `BBPlayerOperationListCell` 的四键**已由 `fullscreenPopupRows` 顶部的
            // `heroButton` 那组渲染**（带图标、各 85×102，与实测一致）。
            // 这里若再画一遍会重复两套同样的按钮 —— 所以本 Cell 不再产出内容。
            EmptyView()

        case .playbackRate:
            // `BBPlayerPlaySettingPlaybackRateCell` —— speed05…speed30 七档
            BiliPSCellRow(title: section.title, minChipWidth: 44) {
                ForEach([Float(3.0), 2.0, 1.5, 1.25, 1.0, 0.75, 0.5], id: \.self) { (v: Float) in
                    BiliPSChip(text: speedLabel(v),
                               selected: abs(oneSkinSpeed - Double(v)) < 0.01) {
                        oneSkinSpeed = Double(v); playerSession?.setSpeed(v)
                    }
                }
            }

        case .playbackMode:
            // `BBPlayerPlaySettingPlaybackModeCell` —— actionloop/next/nextloop/quit 四态
            BiliPSCellRow(title: section.title, minChipWidth: 76) {
                ForEach(BiliPlayMode.allCases, id: \.self) { (m: BiliPlayMode) in
                    BiliPSChip(text: L10n.text(m.title), selected: currentPlayMode == m) {
                        applyPlayMode(m)
                    }
                }
            }

        case .scale:
            // `BBPlayerPlaySettingScaleCell` —— ratio* 五种
            BiliPSCellRow(title: section.title, minChipWidth: 68) {
                ForEach(BiliAspectMode.allCases) { (m: BiliAspectMode) in
                    BiliPSChip(text: L10n.text(m.label), selected: biliAspectMode == m) {
                        biliAspectMode = m
                        UserDefaults.standard.set(m.stored, forKey: OneSkin.fitModeKey)
                    }
                }
            }

        case .config:
            // `BBPlayerPlaySettingConfigCell` —— 对应 16 个 `_show*Item` 布尔
            BiliPSCellRow(title: section.title, minChipWidth: 96) {
                BiliPSToggleChip(text: L10n.text("Mirror Flip"),
                                 on: Binding(get: { BiliPlayerExtras.shared.mirror },
                                             set: { BiliPlayerExtras.shared.mirror = $0 }))
                BiliPSToggleChip(text: L10n.text("Background Play"),
                                 on: Binding(get: { BiliPlayerExtras.shared.backgroundAudio },
                                             set: { BiliPlayerExtras.shared.backgroundAudio = $0 }))
                BiliPSToggleChip(text: L10n.text("Auto-Play Next"),
                                 on: Binding(get: { store.autoPlayNext },
                                             set: { store.autoPlayNext = $0 }))
                BiliPSToggleChip(text: L10n.text("Loop playback"),
                                 on: Binding(get: { playerSession?.looping ?? false },
                                             set: { setSkinLooping($0) }))
            }
        }
    }

    /// 当前播放模式（由 looping/autoPlayNext 两布尔反推四态）。
    private var currentPlayMode: BiliPlayMode {
        BiliPlayMode.from(loops: playerSession?.looping ?? false,
                          advances: store.autoPlayNext)
    }

    private func applyPlayMode(_ mode: BiliPlayMode) {
        setSkinLooping(mode.loopsCurrent)
        store.autoPlayNext = mode.autoAdvances
    }

    /// 循环开关的**唯一写入口**：同时写会话与 `OneSkin.loopKey` 偏好。
    ///
    /// ⛔ 为什么必须双写（复核 t7 的 H1）：
    ///   两种皮肤对这个偏好的写入口径原本不一致 ——
    ///   · One 的 chip（`OneSkin.swift:3570`）：`loop.toggle()` 写偏好 **+** `session?.looping`
    ///   · Bili 的 6 个入口：**只写会话**，从不写偏好
    ///   ⇒ Bili 里开循环 → 切回 One ⇒ `seedLoopPreference()` 用偏好的 old 值（false）
    ///     覆盖会话的 true —— **用户在 Bili 里开的循环被 One 吃掉了**。
    ///   `OneSkin.loopKey` 是全局共享的（两个皮肤同一个键），所以两个入口必须同口径。
    ///
    /// 另一个原因：`seedLoopPreference()` 只负责「启动对齐」，它读的正是这个偏好 ——
    /// 偏好若从不被 Bili 写入，重启后 One 仍会按旧值把它盖掉。
    ///
    /// 单向性：这里写的是「用户明确选择的循环状态」，所以偏好与会话**同时**设成同一个值，
    /// 不存在「谁覆盖谁」的问题 —— 它们本来就是同一个语义的两个载体。
    func setSkinLooping(_ on: Bool) {
        playerSession?.looping = on
        UserDefaults.standard.set(on, forKey: OneSkin.loopKey)
    }

    /// 把自定义菜单项映射成一行（点击后切到对应面板段）。
    @ViewBuilder
    private func menuRow(for item: BiliMenuItem) -> some View {
        BiliPopupRow(text: L10n.text(item.label) + "  ›", selected: false,
                     height: BiliPopupMetrics.rowHeight) {
            switch item {
            case .speed:          biliSettingsFocus = .speed
            case .quality:        biliSettingsFocus = .quality
            case .subtitles:      biliSettingsFocus = .subtitles
            case .episodes:       biliSettingsFocus = .episodes
            case .timer:          biliSettingsFocus = .timer
            case .aspectRatio:    biliSettingsFocus = .aspect
            case .colorFilter:    biliSettingsFocus = .colorFilter
            case .danmuSettings:  biliPanel = .danmuSettings
            case .backgroundPlay:
                BiliPlayerExtras.shared.backgroundAudio.toggle()
                biliPanel = nil
            case .mirrorFlip:
                BiliPlayerExtras.shared.mirror.toggle()
                biliPanel = nil
            case .miniPlayer:
                // 同上：菜单里的「小窗」是应用内小窗，不是画中画。
                biliPanel = nil
                collapseToMiniPlayer()
            case .screenshot:
                saveCurrentFrame()
                biliPanel = nil
            case .lockScreen:
                biliPanel = nil
            case .adBlock:
                // 广告拦截：与 One 皮肤、原版播放器、HLS 代理同一个键。
                // 这一行的动作是**就地开关**（不是切面板），和其它「一次性动作」同类，
                // 所以顺手关掉面板。
                //
                // ⛔ 必须走 `AdSkip.enabled` 的 setter，不要自己拼 `UserDefaults.set`。
                // 这个键在仓里已经有 5 个读取者（设置页 / One / 原版 / 哔哩哔哩 / PlaybackView），
                // 每多一处手写，就多一处将来漏改的地方。`AdSkip` 是它的唯一写入点。
                AdSkip.enabled.toggle()
                biliPanel = nil
            }
        }
    }

    /// 全屏弹窗顶部的四个大按钮（实测 85×102，图标在上文字在下）。
    private func heroButton(_ symbol: String, _ title: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(BiliPalette.primary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(BiliPalette.secondary)
                    .lineLimit(1)
            }
            .frame(width: 85, height: 102)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func speedLabel(_ v: Float) -> String {
        v == Float(Int(v)) ? String(format: "%.1f", v) : String(format: "%g", v)
    }

    @ViewBuilder private var biliPanelOverlay: some View {
        if let biliPanel {
            // ⚠️ `alignment: .bottom` 是必须的。
            // ZStack 默认 `.center`，里面那层全屏遮罩（`Color.black`）会把
            // 子视图整体居中 —— 于是「底部升起」的弹窗被顶到了屏幕中间
            // （真机实测：`分辨率` 标题跑到 y=16，菜单项从 y=158 起）。
            ZStack(alignment: .bottom) {
                // 遮罩：点空白处关闭
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.smooth(duration: 0.2)) { self.biliPanel = nil } }

                switch biliPanel {
                case .actionMenu:
                    // 实测（`/tmp/popup.png` 取色）：操作菜单**有实体底色**，
                    // 是一整块 `#F7F7F9` 白面板，从 y≈0.400 铺到屏幕底，上沿 `#C8CCD0` 分界线。
                    //
                    // ⚠️ 关闭入口只留**外层那层遮罩**（`Color.black.opacity(0.28)` 已铺满全屏
                    // 并带 onTapGesture）。之前在这里又叠了一层 `Rectangle().fill(Color.clear)`
                    // 加 onTapGesture —— 两层手势叠在同一区域，SwiftUI 只认一层，
                    // 结果两个都不灵，菜单彻底关不掉（实测卡死）。
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        BiliActionMenu(
                            portrait: !landscapeScreen,
                            speed: Binding(
                                get: { Float(oneSkinSpeed) },
                                set: { oneSkinSpeed = Double($0); playerSession?.setSpeed($0) }
                            ),
                            autoPlayNext: Binding(
                                get: { store.autoPlayNext },
                                set: { store.autoPlayNext = $0 }
                            ),
                            loopPlayback: Binding(
                                get: { playerSession?.looping ?? false },
                                set: { setSkinLooping($0) }
                            )
                        )
                        // 实测垂直范围：上沿在归一化 y≈0.400（678 × 0.40 ≈ 271pt），铺到屏幕底。
                        // **横屏不整宽**：左 20% / 右 13% 不是面板色（截图逐点采样 `/tmp/pop2.png`）。
                        //   竖屏：整宽 `#F7F7F9`
                        //   横屏：x 0.20~0.87，底色 `#F4F7F8`（比竖屏灰 3 阶）
                        // 白面板本体：**从 y≈0.400 铺到屏幕底**（实测），
                        // 不是「内容自身加 padding 当底」。所以背景挂在菜单容器上，
                        // 并给它一个「屏高 × (1-0.400)」的最小高度，让面板真的铺到底。
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 16)
                        .frame(minHeight: UIApplication.shared.appScreenBounds.height * 0.60,
                               alignment: .top)
                        .background(landscapeScreen
                                    ? BiliPalette.popupSurfaceLandscape
                                    : BiliPalette.popupSurface)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(BiliPalette.popupEdge)
                                .frame(height: 0.5)
                        }
                        // 横屏实测也不是整宽：x 0.20~0.87
                        .padding(.horizontal, landscapeScreen ? UIApplication.shared.appScreenBounds.width * 0.20 : 0)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)

                // 全屏态：四钮（Subtitles/Episodes/Speed/Auto）统一套用「画质框」款式。
                // 见 `BiliFullscreenPopup`：竖屏底部升起整宽、横屏右侧 208pt 窄条，
                // 标题行左右分置、选项行距 61、深色底 #212326。
                //
                // 与详情页的 `.settings`（白色下半屏面板）是**两套**，不能混。
                case .settings where landscapeScreen && fullScreen:
                    fullscreenPopupPanelLandscape
                        .transition(.move(edge: .trailing))

                case .settings where landscapeScreen:
                    // 详情页横屏：底部大面板会把画面挤没，走右缘竖条。
                    // （全屏横屏已在上一个 case 走统一弹窗款式。）
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        BiliSettingsRail(
                            sleepMinutes: Binding(
                                get: {
                                    guard let left = BiliPlayerExtras.shared.sleepRemaining else { return 0 }
                                    return max(0, Int((left / 60).rounded()))
                                },
                                set: { minutes in
                                    if minutes <= 0 { BiliPlayerExtras.shared.cancelSleep() }
                                    else { BiliPlayerExtras.shared.startSleep(minutes: minutes) }
                                }
                            ),
                            playMode: Binding(
                                get: {
                                    BiliPlayMode.from(loops: playerSession?.looping ?? false,
                                                      advances: store.autoPlayNext)
                                },
                                set: { mode in
                                    // 走统一入口（会话 + 偏好双写），理由见 `setSkinLooping` 的注释。
                                    setSkinLooping(mode.loopsCurrent)
                                    store.autoPlayNext = mode.autoAdvances
                                }
                            ),
                            mirror: Binding(
                                get: { BiliPlayerExtras.shared.mirror },
                                set: { BiliPlayerExtras.shared.mirror = $0 }
                            ),
                            backgroundAudio: Binding(
                                get: { BiliPlayerExtras.shared.backgroundAudio },
                                set: { BiliPlayerExtras.shared.backgroundAudio = $0 }
                            ),
                            fitToScreen: Binding(
                                get: { UserDefaults.standard.object(forKey: OneSkin.fitModeKey) as? String == "fit" },
                                set: { UserDefaults.standard.set($0 ? "fit" : "fill", forKey: OneSkin.fitModeKey) }
                            ),
                            speed: Binding(
                                get: { Float(oneSkinSpeed) },
                                set: { oneSkinSpeed = Double($0); playerSession?.setSpeed($0) }
                            )
                        )
                        .frame(width: min(112, UIApplication.shared.appScreenBounds.width * 0.24))
                    }

                // 全屏竖屏：四钮统一套「画质框」款式（深色底部升起）。
                case .settings where fullScreen:
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        fullscreenPopupPanel
                    }
                    .ignoresSafeArea(edges: .vertical)
                    .transition(.move(edge: .bottom))

                case .settings:
                    // 详情页竖屏：底部白色覆盖面板（与全屏是两套配色）。
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        BiliSettingsSheet(
                            speed: Binding(
                                get: { Float(oneSkinSpeed) },
                                set: { oneSkinSpeed = Double($0); playerSession?.setSpeed($0) }
                            ),
                            sleepMinutes: Binding(
                                // `BiliPlayerExtras` 存的是**截止时刻**（`sleepDeadline`），不是分钟数；
                                // 这里换算成分钟供面板显示，写入时再换回截止时刻。
                                get: {
                                    guard let left = BiliPlayerExtras.shared.sleepRemaining else { return 0 }
                                    return max(0, Int((left / 60).rounded()))
                                },
                                set: { minutes in
                                    if minutes <= 0 { BiliPlayerExtras.shared.cancelSleep() }
                                    else { BiliPlayerExtras.shared.startSleep(minutes: minutes) }
                                }
                            ),
                            autoPlayNext: Binding(
                                get: { store.autoPlayNext },
                                set: { store.autoPlayNext = $0 }
                            ),
                            loopPlayback: Binding(
                                get: { playerSession?.looping ?? false },
                                set: { setSkinLooping($0) }
                            ),
                            backgroundAudio: Binding(
                                get: { BiliPlayerExtras.shared.backgroundAudio },
                                set: { BiliPlayerExtras.shared.backgroundAudio = $0 }
                            ),
                            // 字幕开关：本仓库**没有**字幕偏好键，`PlaybackSession` 也没暴露该属性，
                            // 所以用皮肤自带的一个本地键，只影响本皮肤的显示意图。
                            subtitlesOn: Binding(
                                get: { UserDefaults.standard.bool(forKey: "biliSubtitlesOn") },
                                set: { UserDefaults.standard.set($0, forKey: "biliSubtitlesOn") }
                            ),
                            mirror: Binding(
                                get: { BiliPlayerExtras.shared.mirror },
                                set: { BiliPlayerExtras.shared.mirror = $0 }
                            ),
                            onSubtitleSettings: { self.biliPanel = .subtitleSettings },
                            onDanmuSettings: { self.biliPanel = .danmuSettings },
                            onMoreSettings: { self.biliPanel = .moreSettings },
                            onNotes: { self.biliPanel = .notes },
                            onClose: { self.biliPanel = nil }
                        )
                        // ⚠️ 实测是**贴底覆盖面板**，不是悬浮圆角卡片。
                        // 之前用 `cornerRadius 16` + 左右 8pt padding + 底部 8pt，
                        // 渲染出来是一个居中悬浮的白话框 —— 与哔哩哔哩那种
                        // 「从底边整宽升起、四角只有上圆角、贴满左右和底」完全不是一类东西。
                        // 现在：整宽、只切上圆角、底部贴屏幕边（不 inset）。
                        // ⚠️ 高度按屏幕比例算，不能写死 420。
                        // 竖屏 678 高时 420 留 258pt 给画面（合理）；
                        // 横屏只有 466 高，420 会盖掉 90%，把画面挤成一条缝。
                        // 实测哔哩哔哩面板约占屏幕 62%。
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .frame(maxHeight: max(240, UIApplication.shared.appScreenBounds.height * 0.62))
                        .background(BiliPalette.panel)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 12, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 12
                        ))
                        .ignoresSafeArea(edges: .bottom)
                    }

                case .episodes:
                    // 选集容器：**两个方向都由抽屉打开**（用户明确要求）。
                    //
                    // 差别只在抽屉的**摆放位置与宽度**：
                    //   · 竖屏 → 从底部升起，占满整宽
                    //   · 横屏 → 从右缘滑出，占宽 36.7%（实测边界 x=1288/2034）
                    // 抽屉内部版式一致：系列信息区 + Episodes/Ascending + 单列列表。
                    HStack(spacing: 0) {
                        if !landscapeScreen {
                            // 竖屏：整宽
                        } else {
                            Spacer(minLength: 0)
                        }
                        BiliEpisodeDrawer(
                            episodes: activeEpisodes,
                            playing: currentEpisode,
                            flags: flags,
                            activeLine: activeFlag,
                            title: detail?.name ?? video.name,
                            summary: detail.map { L10n.text("%@ videos", String($0.episodes.count)) } ?? "",
                            reversed: $biliReversesEpisodes,
                            onSelectLine: { flag in selectWatchLine(flag) },
                            onFavorite: { store.favorites.toggle(videoFavorite()) },
                            onPlay: { episode in
                                withAnimation(.smooth(duration: 0.2)) { self.biliPanel = nil }
                                Task { await play(episode) }
                            }
                        )
                        // 宽度按**当前屏幕宽**算比例，不能写死 678 ——
                        // 678 是横屏宽；竖屏只有 466，写死会让面板宽出屏幕 200pt。
                        .frame(width: landscapeScreen
                               ? UIApplication.shared.appScreenBounds.width * BiliMetrics.landscapePanelFraction
                               : nil)
                        .background(BiliPalette.panel)
                    }
                    // 竖屏抽屉从**底部**升起（对齐到底），横屏贴右缘满高。
                    .frame(maxHeight: .infinity, alignment: landscapeScreen ? .center : .bottom)
                    .frame(maxHeight: landscapeScreen ? .infinity : UIApplication.shared.appScreenBounds.height * 0.72)
                    .ignoresSafeArea(edges: .vertical)

                case .rail:
                    // 实测：右缘竖条，可视宽 63pt（x=615 / 屏宽 678）。
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        BiliSettingsRail(
                            sleepMinutes: Binding(
                                // `BiliPlayerExtras` 存的是**截止时刻**（`sleepDeadline`），不是分钟数；
                                // 这里换算成分钟供面板显示，写入时再换回截止时刻。
                                get: {
                                    guard let left = BiliPlayerExtras.shared.sleepRemaining else { return 0 }
                                    return max(0, Int((left / 60).rounded()))
                                },
                                set: { minutes in
                                    if minutes <= 0 { BiliPlayerExtras.shared.cancelSleep() }
                                    else { BiliPlayerExtras.shared.startSleep(minutes: minutes) }
                                }
                            ),
                            playMode: Binding(
                                get: {
                                    BiliPlayMode.from(loops: playerSession?.looping ?? false,
                                                      advances: store.autoPlayNext)
                                },
                                set: { mode in
                                    // 走统一入口（会话 + 偏好双写），理由见 `setSkinLooping` 的注释。
                                    setSkinLooping(mode.loopsCurrent)
                                    store.autoPlayNext = mode.autoAdvances
                                }
                            ),
                            mirror: Binding(
                                get: { BiliPlayerExtras.shared.mirror },
                                set: { BiliPlayerExtras.shared.mirror = $0 }
                            ),
                            backgroundAudio: Binding(
                                get: { BiliPlayerExtras.shared.backgroundAudio },
                                set: { BiliPlayerExtras.shared.backgroundAudio = $0 }
                            ),
                            fitToScreen: Binding(
                                get: { UserDefaults.standard.object(forKey: OneSkin.fitModeKey) as? String == "fit" },
                                set: { UserDefaults.standard.set($0 ? "fit" : "fill", forKey: OneSkin.fitModeKey) }
                            ),
                            speed: Binding(
                                get: { Float(oneSkinSpeed) },
                                set: { oneSkinSpeed = Double($0); playerSession?.setSpeed($0) }
                            )
                        )
                        // 实测可视宽 63pt（x=615 / 屏宽 678），但那是「内容固有宽被裁切」
                        // 的结果 —— 照 63 建布局会把「自动连播」「循环播放」全裁成「自动…」。
                        // 取 112：比实测可视宽略宽，保证中文标签完整，仍只占右缘一条。
                        // 实测是右半屏宽面板，不是 63pt 窄条。
                        // 抓到 20 元素版：四个大按钮从 x=342 起（各 85x102，步长 85），
                        // Timer 整排也从 342 起 —— 宽 = 678-342 = 336pt。
                        // 之前按可视宽 63pt 做成 112pt，把 Timer 那排整个裁掉了。
                        .frame(width: UIApplication.shared.appScreenBounds.width * 0.495)
                        .clipShape(RoundedRectangle(cornerRadius: 0))
                        // 实测（`/tmp/fs.png` 取色）：全屏弹窗是**深色面板 `#212326`**，
                        // 不是透明浮在画面上。上沿有一道 `#3D3F43` 边，
                        // 段落之间是 `#D8D9DC` 亮线。
                        //
                        // ⚠️ 详情页弹窗是白色 `#F7F7F9`，这里是深色 —— 两套配色不可混用。
                        .background(BiliPalette.fullscreenPopup)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(BiliPalette.fullscreenPopupEdge)
                                .frame(width: 0.5)
                        }
                    }
                // 设置面板里四个整宽可点行的子面板（之前是空回调）。
                case .subtitleSettings:
                    BiliSubtitleSettingsView(onClose: { self.biliPanel = .settings })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(BiliPalette.panel)
                case .danmuSettings:
                    BiliDanmuSettingsView(onClose: { self.biliPanel = .settings })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(BiliPalette.panel)
                case .moreSettings:
                    BiliMorePlaybackSettingsView(onClose: { self.biliPanel = .settings })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(BiliPalette.panel)
                case .notes:
                    BiliNotesView(videoID: video.id, onClose: { self.biliPanel = .settings })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(BiliPalette.panel)
                }
            }
            .transition(.opacity.combined(with: .move(edge: biliPanel == .settings ? .bottom : .trailing)))
            .animation(.smooth(duration: 0.24), value: biliPanel)
        }
    }

    @ViewBuilder private var biliSkinBody: some View {
        // 哔哩哔哩是**三个独立屏幕族**，不是一套布局换参数。
        //
        // 类名证据（595 个 BBPlayer 类里）：
        //   BBPlayerFullScreen{Top,Bottom,Left,Right}Widget
        //   BBPlayerHalfScreen{Top,Bottom,Left,Right}Widget + HalfScreenBottomRowLayout
        //   BBPlayerPortraitScreen{Top,Bottom}Widget   （只有上下，没有左右）
        //
        // 所以这里也是三个平级页面组件，各自吃 `BiliMetrics` 里的实测值：
        //   · 全屏      → BiliFullScreenPage
        //   · 横屏展开  → BiliLandscapePage（左画面 + 右信息列）
        //   · 竖屏      → BiliPortraitPage（顶部卡片 + 内联选集）
        //
        // 三个弹出面板也分开挂（实测条目集不同）：
        //   actionMenu（详情页更多）/ settings（竖屏齿轮）/ rail（横屏竖条）
        if fullScreen {
            BiliFullScreenPage(
                video: video,
                session: oneSkinStageSession,
                position: playerSession?.position ?? 0,
                duration: playerSession?.duration ?? 0,
                portrait: !landscapeScreen,
                episodes: activeEpisodes,
                playing: currentEpisode,
                isFavorite: store.favorites.contains(videoFavorite()),
                danmakuOn: danmakuOnForSkin,
                speed: Float(oneSkinSpeed),
                // `quality` 是 `Int?`（当前清晰度序号），不是对象；
                // 要显示名得从会话的 `qualities` 里按序号取。
                qualityLabel: currentQualityLabel,
                onBack: { exitFullScreen() },
                onLike: {},
                onShare: {},
                // 实测：竖屏全屏的齿轮打开的是**底部设置面板**（Speed/Timer/开关），
                // 只有横屏全屏才用右缘竖条。之前一律开 .rail，竖屏下就是一条
                // 被挤在右缘的窄条，既不像哔哩哔哩也读不全。
                // ⚠️ 全屏 `More operations` 实测打开的是**深色右侧面板**（`#212326`，
                // 宽约 37%、贴右缘）—— 正是四钮统一弹窗款式的横屏形态。
                // 之前指向 `.rail`，那是个**死分支**（`BiliSettingsRail` 用 112pt 窄条
                // + `BiliPalette.panel`），形态和实测完全不符。
                // 现在走 `.settings`，由 `landscapeScreen && fullScreen` 分支渲染
                // `fullscreenPopupPanelLandscape`（208pt、`#212326`、标题左右分置）。
                onSettings: { biliSettingsFocus = .speed; biliPanel = .settings },
                onTogglePlay: {
                    if let episode = currentEpisode ?? activeEpisodes.first, !playingOnThisPage {
                        Task { await play(episode) }
                    } else {
                        playerSession?.togglePlayback()
                    }
                },
                onSeekBack: { skip(by: -10) },
                onSeekForward: { skip(by: 10) },
                onNext: { advanceEpisode() },
                onPrevious: { awaitPreviousEpisode() },
                // 「小窗」= **应用内**小窗（哔哩哔哩的 `miniscreen` 就是这个语义），
                // 与「画中画」是两件事。
                //
                // ⛔ 这里原来写的是 `PictureInPicture.startCurrent()` —— 两个错叠在一起：
                //   1) 语义错：小窗键去做画中画；
                //   2) 事实上恒为空操作：哔哩哔哩画面层当时从不 attach，
                //      `PictureInPicture.current` 永远 nil，guard 第一行就返回。
                // 现在走 `onMiniPlayer`（One 皮肤同一套），由页面置
                // `store.miniPlayerActive` 并 dismiss，RootView 挂小窗卡片。
                onMiniScreen: { collapseToMiniPlayer() },
                onScreenshot: { saveCurrentFrame() },
                onSeekTo: { fraction in
                    guard let session = playerSession, session.duration > 0 else { return }
                    session.seek(to: session.duration * fraction)
                },
                panelOpen: biliPanel != nil,
                // 三个按钮都打开同一个设置面板，但**意图不同**：
                // 字幕要滚到字幕区、倍速要滚到 Speed、画质要滚到画质。
                // 之前三个都只写 `.settings`，面板打开后一律停在顶部，
                // 用户点「字幕」看到的是 See Original —— 点了等于没点。
                // 全屏底栏四个按钮的分派（由二进制类族裁决，不是猜）：
                //   Subtitles / Speed / Auto → `.settings`（`BBPlayerPlaySettingWidget`
                //     的五个 Cell 里就有 scale/rate/subtitle 这些项）
                //   Episodes               → `.episodes`（**独立** `BBPlayerEpisodeListWidget`，
                //     与 PlaySettingWidget 平级，不在其 Cell 之内）
                // 两者配色/形态必须统一（深色 BiliFullscreenPopup），只差内容。
                // ⚠️ 之前注释写成「四个都走 .settings」与代码矛盾，已按实证改正。
                onSubtitles: { biliSettingsFocus = .subtitles; biliPanel = .settings },
                onSpeed: { biliSettingsFocus = .speed; biliPanel = .settings },
                onQuality: { biliSettingsFocus = .quality; biliPanel = .settings },
                onToggleDanmu: { toggleSkinDanmaku() },
                // Episodes：独立 `BBPlayerEpisodeListWidget`，但仍用**同一款式**的
                // `BiliFullscreenPopup`（同配色同圆角），只是内容换成选集列表。
                onEpisodes: { biliPanel = .episodes },
                // 哔哩哔哩皮肤自己的 PiP 实例：画面层据此登记内容源。
                pip: biliPip
            )
        } else if oneSkinShape == .split {
            BiliLandscapePage(
                video: video,
                session: oneSkinStageSession,
                position: playerSession?.position ?? 0,
                duration: playerSession?.duration ?? 0,
                aspectRatio: BiliAspectMode.effectiveAspect(sourceRatio: playerAspectRatio),
                episodes: activeEpisodes,
                playing: currentEpisode,
                flags: flags,
                activeLine: activeFlag,
                seriesTitle: detail?.name,
                summary: detail?.name ?? "",
                isFavorite: store.favorites.contains(videoFavorite()),
                pip: biliPip,
                danmakuOn: danmakuOnForSkin,
                onBack: { leavePlayer() },
                onCast: {},
                onMore: { biliPanel = .actionMenu },
                onFollow: {},
                onLike: {},
                onDislike: {},
                onCoin: {},
                onFavorite: { store.favorites.toggle(videoFavorite()) },
                onShare: {},
                onEpisodes: { biliPanel = .episodes },
                onPlay: { episode in Task { await play(episode) } },
                onSettings: { biliSettingsFocus = .speed; biliPanel = .settings }
            )
        } else {
            BiliPortraitPage(
                video: video,
                session: oneSkinStageSession,
                position: playerSession?.position ?? 0,
                duration: playerSession?.duration ?? 0,
                aspectRatio: BiliAspectMode.effectiveAspect(sourceRatio: playerAspectRatio),
                episodes: activeEpisodes,
                playing: currentEpisode,
                flags: flags,
                activeLine: activeFlag,
                seriesTitle: detail?.name,
                seriesSummary: detail?.name ?? "",
                isFavorite: store.favorites.contains(videoFavorite()),
                danmakuOn: danmakuOnForSkin,
                pip: biliPip,
                onBack: { leavePlayer() },
                onCast: {},
                onMore: { biliPanel = .actionMenu },
                onTogglePlay: {
                    if let episode = currentEpisode ?? activeEpisodes.first, !playingOnThisPage {
                        Task { await play(episode) }
                    } else {
                        playerSession?.togglePlayback()
                    }
                },
                onFullScreen: { setFullScreenEnteringCurrentOrientation() },
                onToggleDanmu: { toggleSkinDanmaku() },
                onFollow: {},
                onLike: {},
                onDislike: {},
                onCoin: {},
                onFavorite: { store.favorites.toggle(videoFavorite()) },
                onShare: {},
                onPlay: { episode in Task { await play(episode) } },
                onSeekTo: { fraction in
                    guard let session = playerSession, session.duration > 0 else { return }
                    session.seek(to: session.duration * fraction)
                },
                onEpisodes: { biliPanel = .episodes }
            )
        }
    }

    /// ⛔ 这个 `@AppStorage` **只为建立依赖，不为了读值**。
    ///
    /// 原来 `danmakuOnForSkin` 直接读 `UserDefaults`，本视图对它没有 SwiftUI 依赖：
    /// 在弹幕面板里拨了开关，`VideoDetailView` 的 body 不会因为这个键变化而重算，
    /// 弹幕层要等到下一次**别的原因**（进度 sampler 每秒 tick、或其他状态变化）才更新 ——
    /// 用户看到的是「拨了要等一下才生效」，极端情况下（暂停中、无 tick）看起来像没生效。
    /// 复核 H1 指出这一点。
    @AppStorage(DanmakuPreference.key) private var danmakuEnabledStored = true

    /// 哔哩哔哩皮肤的弹幕开关。
    ///
    /// 注释原来写「与 One 分开存，避免互相覆盖」是**错的**：两边用的是同一个
    /// `DanmakuPreference.key`（`"danmakuEnabled"`），本来就是同一份值 ——
    /// 这正是「在 One 里关掉弹幕、切到哔哩哔哩也是关的」的原因，属预期行为，不是缺陷。
    /// 现在改为读上面的 `@AppStorage`，依赖与语义同时对上。
    private var danmakuOnForSkin: Bool { danmakuEnabledStored }

    /// 当前清晰度的显示名。`PlaybackSession.quality` 只有序号，
    /// 名字在 `qualities` 里；取不到就显示 `Auto`（与哔哩哔哩一致）。
    private var currentQualityLabel: String {
        guard let session = playerSession,
              let index = session.quality,
              session.qualities.indices.contains(index) else {
            return L10n.text("Auto")
        }
        return session.qualities[index].label
    }

    private func toggleSkinDanmaku() {
        // 哔哩哔哩的弹幕开关写 `DanmakuPreference.key`。
        //
        // ⛔ 原注释写「覆盖层本身监听同一个 key」——不实：`DanmakuOverlay` 并不监听这个 key
        //    （它接收调用方传进来的显隐判断，只 `@AppStorage` 了 area/fontSize 两个样式键）。
        //    真正让开关生效的是上面那个 `@AppStorage` 建立的依赖 ⇒ 本视图重算 ⇒
        //    三个 Bili 播放页拿到新的 `danmakuOn` ⇒ 弹幕层出现/消失。
        danmakuEnabledStored.toggle()
    }

    /// 全屏里的「下一集」。没有下一集就不动，不要静默从头开始。
    private func advanceEpisode() {
        let list = activeEpisodes
        guard list.count > 1, let current = currentEpisode,
              let i = list.firstIndex(where: { $0.id == current.id }),
              i + 1 < list.count else { return }
        let next = list[i + 1]
        Task { await play(next) }
    }

    /// 切换线路：复用上游那套「换 flag 后播续上当前集」的逻辑，One 与哔哩哔哩两个皮肤共用。
    private func selectWatchLine(_ flag: String) {
        let previous = activeFlag
        selectedFlag = flag
        guard watchChannel != nil, let episodes = detail?.episodes else { return }
        let playing = episodes.first { $0.id == currentEpisodeID }
        guard let same = episode(on: flag, matching: playing, in: episodes) else {
            selectedFlag = previous
            withAnimation(.smooth(duration: 0.2)) { lineNotice = L10n.text("This line doesn't have this episode.") }
            Task { try? await Task.sleep(for: .seconds(4)); withAnimation(.smooth(duration: 0.2)) { lineNotice = nil } }
            return
        }
        if same.id != currentEpisodeID { startRequest { await play(same) } }
    }

    /// One 版式：黑底一列，画面→控制条→标题→主按钮→标签→选集。
    /// 画面仍是同一套播放引擎，只是把画面当成一个 View 传进去，皮肤层不认识 `PlaybackSession`。
    @ViewBuilder private var oneSkinBody: some View {
        OneSkinStage(
            video: video,
            detail: detail,
            current: currentEpisode,
            playing: playingOnThisPage,
            busy: busy,
            // ★ 直接从 `session` 现算片源比例，不读 `@State playerAspectRatio`。
            //
            // 真机日志（竖屏源 presentationSize 1080×1920）：
            //   `pictureColumn aspect=1.7777` 出现 **613 次**，`aspect=0.5625` 只 235 次
            // —— 同一个源，窗口在 523×294 ⇄ 371×659 之间反复跳。
            // 原因是 `playerAspectRatio` 由异步 `.task` 写入，写完后要下一轮
            // body 求值才可见；期间任何重排都拿旧值（16:9）排版。
            // `presentationSize` 是同步可读的事实（项目铁律：画面比例唯一真源）。
            aspectRatio: BiliAspectMode.effectiveAspect(
                sourceRatio: oneSkinLiveAspect ?? playerAspectRatio
            ),
            // 探针由 OneSkinStage 内部读 aspectRatio 打，见 ASPECTDBG。
            shape: oneSkinShape,
            stageDiag: oneSkinStageDiag,
            // 遮挡（四边）：唯一消费端是几何层（`box` 扣边），见 16.1。
            // 位置必须紧跟 `shape`（声明次序），否则 memberwise init 参数错位。
            occlusion: occlusionInsets,
            // 片源身份：字幕文件、请求头、片头片尾 scope、上下集都靠它（成员顺序在 shape 之后）。
            channel: watchChannel,
            // ⛔ 换集修复：画面与画质菜单都用「真正在播」的会话，
            // 不能每集重新 `store.playbackSession(for:)` 取一个空会话。
            // 详见 `oneSkinStageSession` 注释。
            avPlayer: oneSkinStageSession?.player,
            session: oneSkinStageSession,
            // One 的进度条两端是「已播 / −剩余」，没有真值就画不出进度。
            // session 是 @Observable，这两个值变化会带着皮肤一起重绘。
            // ⛔ `position` / `duration` 已不再传给 `OneSkinStage`。
            //
            // 这两个值来自 `@Observable` 的 `PlaybackSession`，播放时每秒 ~60 次更新。
            // 原来把它们作为参数传进 `OneSkinStage`，等于让**整个皮肤视图（含根部
            // `GeometryReader`）每帧重建** —— 这就是「控件一直在推移」的真凶。
            // 实测：每秒 479 次 ROOT 重算，dt=7–11ms。
            //
            // 唯一需要进度的是「继续播放」按钮文字，已收进 `OneContinueHint`，
            // 由那个叶子视图自己观察 session。父级不再跟着进度重绘。
            // 这里曾传 `picture: { watchStage }`，但 OneSkinStage 从未调用它
            //（画面由 OneSkinPlayerLayer + avPlayer 自绘）。真正的 PlaybackView 是
            // 下面 oneSkinBody 上挂的 `.background(watchStage)`，它负责触发 session.prepare。
            // ⛔ 不再传 `onBack`（2026-11-11）：控件层里已没有返回键，
            // 退出由页面层的 `watchPageExitButton` 负责（它一律退出页面并关音频）。
            // 一键退全屏：只改状态，不碰页面栈 —— 全屏时窗口内那颗还是走这条路。
            onExitFullScreen: { exitFullScreen() },
            onPlay: { episode in
                Task { await play(episode) }
            },
            onTogglePlay: {
                // 上游没有单独的暂停/继续入口：停止走 store，继续就再播当前集。
                // ⛔ 停止必须走 `store.stopPlaying()`：裸赋 `playing = nil` 会跳过
                // session.stop()（历史保存 / 流清理 / 弹幕清空 / upcoming 取消），
                // Store.playing.didSet 只把对象置 nil —— 与 Store.swift:343 注释
                // 「playing = nil alone skips that teardown and leaks」一致。
                if playingOnThisPage {
                    store.stopPlaying()
                } else if let episode = currentEpisode ?? activeEpisodes.first {
                    Task { await play(episode) }
                }
            },
            onSeekBack: {
                skip(by: -10)
            },
            onSeekForward: {
                skip(by: 10)
            },
            onSeekTo: { fraction in
                // 进度条松手：把 0…1 换算成秒再定位。
                // 时长未知（live / 刚起播）时忽略，不猜。
                guard let session = playerSession, session.duration > 0 else { return }
                session.seek(to: session.duration * fraction)
            },
            onFullScreen: {
                // ⛔ 不能再用「片源比例 > 1」决定全屏方向。
                //
                // 原来写的是 `setFullScreen(landscape: playerAspectRatio > 1)`：
                // 横版片源进全屏就被**强制**转成横屏，竖版片源被强制转成竖屏，
                // 用户手上的旋转键在全屏里又被 `fullScreenOwnsOrientation` 闸门挡住
                // （`rotate(to:)` 与 `turn(to:)` 都不改写全屏态的 mask）。
                // 结果就是「全屏只能在片源那一个方向」——
                // 用户明确要求「全屏也要能横屏也能竖屏」。
                //
                // 现在：进全屏**沿用当前屏幕方向**，之后由旋转键自由切换
                // （见 `PlayerOrientation.setFullScreenHeld` / `rotateInFullScreen`）。
                setFullScreenEnteringCurrentOrientation()
            },
            onEpisodes: {
                // 本页的抽屉只认 `showsAllEpisodes`。
                //
                // 曾经这里写的是 `store.showsEpisodes`（上游全屏播放器的键），
                // 于是「点选集没反应」：本页的 sheet 读的是 @State，而 store 那个键
                // 在本页没有宿主，只留下一个 true 的脏状态。
                // 闭包捕获 @State 包装器本身、共享同一存储，写它是有效的 ——
                // 之前判定「写入被副本丢弃」是误诊，真正写错的是键。
                showsAllEpisodes = true
            },
            onToggleSkin: {
                withAnimation(.smooth(duration: 0.25)) { oneSkinEnabled = false }
            },
            onDownload: {
                downloadPreselect = []
                choosingDownloads = true
            },
            onFavorite: {
                store.favorites.toggle(videoFavorite())
            },
            // 「用其他播放器打开」：把当前流地址交给系统，由 VLC / Infuse / nPlayer 接管。
            // 真机 One 的第三颗图标就是这个（AX label「用其他播放器打开」）。
            // 没有流地址时静默（未开始播放 / 线路还没解析）。
            onOpenExternal: {
                // `Channel.url` 已经是 `URL`，不需要再转。
                guard let url = watchChannel?.url else { return }
                #if os(iOS)
                UIApplication.shared.open(url)
                #endif
            },
            onShare: {
                // One 分享的是稳定链接（TMDB 页），没有就静默（ShareLink 同样会隐藏）。
                if let link = tmdb.details?.link {
                    #if !os(tvOS)
                    let activity = UIActivityViewController(activityItems: [link], applicationActivities: nil)
                    if let scene = UIApplication.shared.appWindowScene,
                       let root = scene.keyWindow?.rootViewController {
                        var presenter = root
                        while let presented = presenter.presentedViewController { presenter = presented }
                        if let pop = activity.popoverPresentationController {
                            pop.sourceView = presenter.view
                            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                        }
                        presenter.present(activity, animated: true)
                    }
                    #endif
                }
            },
            isFavorite: store.favorites.contains(videoFavorite()),
            lines: flags,
            activeLine: activeFlag,
            // 半折时上半个屏占多少 —— 跟随折痕真实位置，不用固定 0.5。
            // 位置必须与声明次序一致（`activeLine` 之后、`lineSamples` 之前）。
            halfFoldSplitRatio: halfFoldSplitRatio,
            // 折痕的绝对 y（容器坐标）。`stage` 优先用它算上半屏高度，
            // 比「比例 × 更矮的 box」少一次误差放大（见 halfFoldSplitY 注释）。
            halfFoldSplitY: halfFoldSplitY,
            lineSamples: lineSamples,
            onSelectLine: { flag in
                // 复用上游 watchLines 的换线逻辑：换 flag 后播「续上当前集」的那一集。
                let previous = activeFlag
                selectedFlag = flag
                guard watchChannel != nil, let episodes = detail?.episodes else { return }
                let playing = episodes.first { $0.id == currentEpisodeID }
                guard let same = episode(on: flag, matching: playing, in: episodes) else {
                    selectedFlag = previous
                    withAnimation(.smooth(duration: 0.2)) { lineNotice = L10n.text("This line doesn't have this episode.") }
                    Task { try? await Task.sleep(for: .seconds(4)); withAnimation(.smooth(duration: 0.2)) { lineNotice = nil } }
                    return
                }
                if same.id != currentEpisodeID { startRequest { await play(same) } }
            },
            onRotate: {
                // 横竖屏切换：按**当前形态**反向转（BUG-M）。
                //
                // ⛔ 原来用 `interfaceOrientation` 取反。而 iPhone Duo 的内屏
                //    **不遵守 `supportedInterfaceOrientations`**，它自己转
                //    （`device-facts.md`："The inner display does not honor your supported
                //     interface orientations — it rotates regardless"），实测内屏
                //    竖持时仍报 `.landscapeLeft`。于是：
                //      内屏竖持 → nowLandscape=true → set(landscape:false) → 请求竖屏
                //      可用户此刻**就是竖的**，旋转键等于原地不动。
                //    外屏是普通 iPhone 语义，那条路上这个信号是对的 —— 所以这个 bug
                //    只在展开后出现，很难联想到这里。
                //
                // 现在：横竖只认 `oneSkinShape`（`.split` 即横持，其余为竖持），
                // 与版面、控制栏配置用的是**同一个**形态真源。
                let nowLandscape = (oneSkinShape == .split)
                PlayerOrientation.set(landscape: !nowLandscape)
            },
            onMiniPlayer: {
                // One 皮肤「缩成小窗」键。与哔哩哔哩皮肤的 `collapseToMiniPlayer()` 是同一件事，
                // 收成一个具名方法，三处入口（One / 哔哩哔哩 / 菜单项）不再各写一遍顺序。
                collapseToMiniPlayer()
            },
            onFold: {
                // 合拢/展开由 OneSkinStage 自己的 `folded` 驱动，这里只留钩子。
            },
            // 「复制视频链接」「用外部播放器打开」都吃当前直链。
            streamURL: watchChannel?.url,
            streamHeaders: watchChannel?.headers ?? [:],
            // 全屏态：OneSkin 之前完全没接这个状态，皮肤下点全屏没有任何变化。
            isFullScreen: fullScreen,
            // 铰链状态：只用来告几何层「折叠态跨档了」，不参与任何坐标计算。
            hingePartiallyOpen: hingePartiallyOpen
        )
        // 倍速是皮肤自己的开关，但要真的落到播放器上；开关变了才下发，避免每次重绘都设一遍。
        .onChange(of: oneSkinSpeed) { _, value in
            playerSession?.setSpeed(Float(value))
        }
        .onAppear {
            #if DEBUG
            // ★ 时序探针：`-qaLogSkinSeed 1` 时打印「onAppear 那一刻 playerSession 是否已就绪」。
            //
            // 为什么需要它：B1 的整个论证建立在「onAppear 时 playerSession 为 nil」这一步上，
            // 而这一步此前**只是时序推演，没有任何运行时读数**（复核 t7 与我本人都是推的）。
            // 有了这行，模拟器上跑一次 `-qaLogSkinSeed 1 -qaOneSkin -qaSection home -qaPage detail:...`
            // 就能把「推演」变成「读数」——不必等真机。
            // 判据：日志出现 `SEED onAppear session=nil` ⇒ 旧写法必失效；`session=有` ⇒ 需要重新审。
            NSLog("SEED onAppear session=%@ speed=%.2f",
                  playerSession == nil ? "nil" : "ready", oneSkinSpeed)
            #endif
            if oneSkinSpeed != 1 { playerSession?.setSpeed(Float(oneSkinSpeed)) }
        }
        // ⛔ 只有 `onAppear` 是不够的 —— 这条我自己在本文件别处写过理由，却漏了这里。
        //
        // `playerSession` 的唯一赋值源是 `onStageSession`（在 `watchStage:3845`，
        // 属于 `watchStage` 视图），而上面那个 `onAppear` 在 `oneSkinBody` 内 ——
        // **两者不在同一视图层级，onAppear 必然先跑**，那一刻 `playerSession` 还是 nil，
        // `?.` 把整句静默丢弃。且 `OneSkinStage` 调用处无 `.id()`，identity 不变，
        // onAppear 不会因会话就绪而重跑。
        // 后果（用户可感知）：One 里设 1.5× 退出重进 → chip 显示 1.5×，实际按 1.0× 播。
        //
        // 判时序要看**视图层级**，不看行号先后（`:3491 < :3845` 只是佐证）。
        // 与 `armSleepTimer()` 双挂（onAppear + onChange(watchChannel)）同一修法；
        // 也与 loop 的 `seedLoopPreference()` 同一形态 —— 修一个宿主时必须扫同文件的同构写法。
        .onChange(of: playerSession != nil) { _, ready in
            guard ready, oneSkinSpeed != 1 else { return }
            playerSession?.setSpeed(Float(oneSkinSpeed))
        }
        // [mi3s] 方向锁 / 转屏 / 折展收全屏 / 换集清会话，全部**不在这里写**：
        // 已统一到 `watchPageLifecycle()`，由 `body` 在 `watchBody` 外层挂一次。
        // 之前这里和 upstream 分支各写一套：皮肤开着时 upstream 那套根本不执行，
        // 方向锁与「折回外屏撤全屏」就跟着失效。
    }

    @ViewBuilder private var upstreamWatchBody: some View {
        // The picture's own shape, never a fixed 16:9 box: a 4:3 or a 2.35:1 film fills it exactly, so
        // the bars the old box drew inside the player are gone. The page reports what the stream is;
        // 16:9 is only the guess until it does.
        let ratio = max(playerAspectRatio, 0.4)
        let side = containerWidth > 0 ? containerWidth : 390
        // Landscape splits the page left/right instead of stacking, as One does: the picture keeps the
        // width it needs and the episode list uses the space beside it rather than below. A Duo unfolded
        // does the same across its wide inner display. Upright — the folded outer cover and the unfolded
        // inner display alike — stacks one column, picture on top, details and episodes below.
        let splits = splitsWatchPage
        // The folded-out Duo gives the right column a clamped share: wide enough for the episode tiles
        // and the synopsis, narrow enough to leave the picture room. Clamping to a range (instead of a
        // raw fraction) also stops the measured width feeding back into the column width and shrinking
        // the page turn after turn.
        let detailWidth = splits ? (duoExpanded ? min(max(containerWidth * 0.36, 300), 460) : max(0, containerWidth * 0.42)) : 0
        let playerWidth = splits ? max(1, side - detailWidth) : side
        // The picture keeps the stream's shape and takes at most half the upright screen, so the episode
        // list is on screen under it — on the unfolded Duo too, which used to hide that list behind a
        // half-height sheet while the picture owned the whole display. Full Screen is the way to give the
        // picture everything.
        let tall = containerHeight > 1 ? containerHeight : side * 1.6
        let pictureHeight = min(playerWidth / ratio, tall * 0.5)
        let stageHeight: CGFloat? = fullScreen ? nil : (splits ? max(1, tall) : max(1, pictureHeight))
        let axis = splits ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        ZStack(alignment: .top) {
            // Black belongs behind the picture, not behind the page: in the split layout a full-height
            // black band behind the details column left black text on black in light mode. Full Screen is
            // one black surface, so it keeps the plain black behind everything.
            if fullScreen || splits { Color.black.ignoresSafeArea() }
            axis {
                watchStage
                    .frame(width: splits ? playerWidth : nil, height: stageHeight)
                    .frame(maxWidth: fullScreen ? .infinity : nil, maxHeight: fullScreen ? .infinity : nil)
                if !fullScreen {
                    ScrollView {
                        watchDetails
                            .padding(.horizontal, splits ? Layout.gutter : 16)
                            .padding(.top, splits ? 16 : 14)
                            // The column runs to the physical bottom edge (the page hides the status bar
                            // and the tab bar's inset does not reach this pushed page), so the last card
                            // needs its own reserve or the home indicator cuts its caption.
                            .padding(.bottom, splits ? 48 : 24)
                    }
                    .scrollIndicators(.never)
                    .frame(width: splits ? detailWidth : nil)
                    .overlay(alignment: .leading) {
                        // A hairline between the picture and the details column, so the two-column page
                        // reads as two surfaces rather than text glued to the picture's edge.
                        if splits { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // [mi3s] 系统栏位与页面生命周期**不在这里写**：
        // 已提到 `body` 里 `watchBody` 的外层（`WatchSystemChrome` + `watchPageLifecycle`），
        // 与 One 皮肤那条分支共用同一份实现、同一个判据。
    }

    /// 选集播放页的生命周期 —— **两条渲染分支共用一份**。
    ///
    /// 为什么必须共用：这些钩子此前只挂在 `upstreamWatchBody` 上。One 皮肤开关一打开，
    /// `watchBody` 走的是 `oneSkinBody` 那一支，于是方向锁、转屏监听、
    /// 换集清会话、离页收回 scope 集体失踪 —— 表现是「皮肤开着，转屏行为和装了两个 App 一样」。
    ///
    /// 规则本身只留一处，改一次两边都生效：
    ///   · 折叠态钉竖屏、展开后交还给设备（不主动请求横屏）；
    ///   · **转屏不再自动进全屏**：横屏就是双列选集页，全屏只由全屏键进入；
    ///   · 换集清掉上一集的会话；离页收回页面 scope、解除方向锁。
    /// 把定时关闭的到点动作挂到 `BiliPlayerExtras` 单例上。
    ///
    /// 为什么需要多次调用：`playerSession` 由 `onStageSession` / `opened:` 回调赋回，
    /// `onAppear` 那一刻通常是 nil；换集后也可能变化。所以 `onAppear` 调一次、
    /// `playerSession` 非空状态变化时再调一次。
    private func armSleepTimer() {
        let sessionNow = playerSession
        let channelNow = watchChannel
        BiliPlayerExtras.shared.onSleep = { [weak sessionNow] in
            guard let sessionNow else { return }
            // 校验：它仍是「正在播这一集」的那个会话。不是就什么都不做 ——
            // 宁可不暂停，也不能误停别的集、更不能新建空会话。
            guard let channel = channelNow, sessionNow.isPlaying(channel) else { return }
            sessionNow.player.pause()
            Diagnostics.shared.record(.info, "bili", "sleep timer paused playback")
        }
        BiliPlayerExtras.shared.resumeSleepIfNeeded()
    }

    private func watchPageLifecycleBody<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                store.isWatchPageMounted = true
                store.watchPageScopes.formUnion(watchScopes)
                // ⛔ 定时关闭：把到点时要做的事挂上，并把已存的到点时刻接回来。
                //
                // `BiliPlayerExtras` 是单例（Duo 合拢/展开会把观看页整个撕掉重建，
                // `@State` 每次归零 —— 定时关闭会静默消失），注释里写明
                // 「页面出现时把 `onSleep` 重新挂上就行」——**但从来没有任何地方挂过它**。
                //
                // 后果：`startSleep` 的四个入口都通、ticker 每秒真跑、到点真调
                // `self.onSleep?()`，而 `onSleep` 恒为 nil ⇒ **到点什么都不会发生**。
                // `?.()` 这个可选调用让整条链在类型层面完全合法，编译器不会提醒。
                // 而且 `sleepBadge` 也没有 UI 消费 —— 用户连「设没设上」都看不到。
                //
                // 挂在 `watchPageLifecycleBody` 而不是各皮肤内部：三个 Bili 页面
                // （全集/横屏/竖屏）都从这里进，且只有这里拿得到 `playerSession`。
                //
                // ⛔ 闭包体里不要捕获 `self` 读 `playerSession`：本视图是 struct，
                //    捕获副本读的是**闭包创建那一刻**的快照。
                //
                // ⛔ 也不要现在就取 `let owningSession = playerSession` ——
                //    `playerSession` 是 `onStageSession` / `opened:` 回调**之后**才赋值的
                //    （`:3771/:3787`），`onAppear` 那一刻它通常是 nil。
                //    那样会挂上一个「捕获了 nil」的闭包，到点直接 return ——
                //    **等于把「什么都没发生」从原来的「没赋值」挪到了「赋了个空值」，
                //    症状一模一样，更难查。**（第一版就是这么写的，自己抓出来了。）
                //
                // 正确做法：把「当前会话」以**弱引用**带上，到点那一刻再校验它还是不是当前那个。
                //
                // ⛔ 不能用 `store.playbackSession(for: store.playing)` 现取 —— 它遇到
                //    新频道会**新建一个空会话并把 `activeSession` 换掉**（`Store.swift:551-555`），
                //    等于到点那一刻把真正在播的会话踢掉。`playing` 的 didSet 还会在
                //    `activeSessionChannel != playing` 时主动把 `activeSession` 清空，
                //    那种状态下现取必然新建空会话。**定时关闭不该顺手破坏播放状态。**
                //
                // ⛔ 也不能在 arm 时就把值固定下来（第一版错法，见 `d29fb84`）。
                //
                // 折中：`onAppear` 时 `playerSession` 常常还是 nil，所以**不能只挂一次** ——
                // 下面的 `.onChange(of: watchChannel)` 会在频道就绪/换集后再挂一次，
                // 保证最终挂上的是有值的那个。
                armSleepTimer()
                // ⛔ 这里**不再动坞**。
                //
                // 上一版写的是 `store.miniPlayerActive = false`（「回到观看页，小窗授权作废」）。
                // 单任务时代那等于「收回自己那一个小窗」，语义正好；
                // 现在 `miniPlayerActive` 是**整个坞**的投影，写它会：
                //   ① 把别的正在看的迷你播放器全部停掉（要求 5 明确禁止）；
                //   ② 在「按小窗键 → pop → onAppear 再跑一次」的时序里，
                //      把刚登记进坞的那一集抹掉 —— 正是旧版那个「点了没反应」。
                //
                // 「回到这一页就把**这一集**从坞里摘掉」由 `VideoTaskCenter.take` 完成
                // （点卡片时已经摘了）；不需要页面再补一刀。
                leaveHandled = false
                // ★ 选集页**一律不钉竖屏**。
                //
                // 用户的要求是：外屏要能横屏也能竖屏、展开横竖都行、全屏横竖都行。
                // `holdPortrait(true)` 会把 mask 锁成 `.portrait` —— 外屏横持会被
                // 系统**强行拉回竖屏**，用户手里的旋转键也无效（`rotate(to:)` 只改 mask，
                // 而页面每次 onAppear / 折叠都会再把它锁回竖）。
                //
                // 原来只有 One 皮肤这一支放开（`oneSkinActive ? false : !duoExpanded`），
                // 于是「原生/哔哩哔哩皮肤 + 外屏」永远只能竖持。
                // 现在两支都放开：横竖由用户与设备决定，页面不再钉任何方向。
                PlayerOrientation.holdPortrait(false)
                #if DEBUG
                // QA：`-qaWatchFullScreen 1` 直接进全屏，用来给「全屏控件层」截图
                // （真机上要靠点全屏键，模拟器不好触发）。
                if UserDefaults.standard.bool(forKey: "qaWatchFullScreen"), !fullScreen {
                    setFullScreen(landscape: true)
                }
                // QA：`-qaRotateCycle <秒>` 在**同一个进程内**反复真旋转。
                // 用来回归「横竖屏来回切，界面/控件是否累积推移、是否要重启才恢复」：
                // 每轮横→竖→横，对比首尾截图的竖直分界线 x 坐标即可。
                // 历史上这个 bug 反复出现却没被抓住，就是因为每次都靠人手转一次、
                // 看一眼，没有可重复的来回切换证据。
                let rotateEvery = UserDefaults.standard.double(forKey: "qaRotateCycle")
                // `onAppear` 在转屏时可能被重复调用；没有这道闸会启动多个并行
                // 定时器互相抢方向（实测日志出现三连 landscape，动画中间态失控）。
                if rotateEvery > 0, !Self.qaRotateCycleRunning {
                    Self.qaRotateCycleRunning = true
                    Task { @MainActor in
                        defer { Self.qaRotateCycleRunning = false }
                        var sideways = false
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(rotateEvery))
                            guard !Task.isCancelled else { break }
                            sideways.toggle()
                            PlayerOrientation.rotate(to: sideways ? .landscapeRight : .portrait)
                            oneSkinLog("qaRotateCycle -> \(sideways ? "landscape" : "portrait")")
                        }
                    }
                }
                #endif
            }
            // ⛔ 这里必须监听 `watchChannel`，**不能**监听 `playerSession == nil`。
            //
            // `playerSession` 在**换集时保持不变**（`:2350-2352` 注释自己写明），
            // 所以 `playerSession == nil` 这个 Bool 换集时是 `false → false`，**不触发**。
            // 那样闭包会一直绑着**换集前**的 `channelNow`，到点 `isPlaying(旧频道)` 为假
            // ⇒ 静默 return，连日志都没有。症状与原 P0 一样，只是触发条件从
            // 「从未挂载」变成「换过集」。（fix-reviewer ④ 指出，成立。）
            //
            // `watchChannel` 由 `store.playing` 派生，换集会变，且 `Channel` 是 `Hashable`
            // （`Models.swift:322`），可以直接作为 `onChange` 的观测值。
            .onChange(of: watchChannel) { _, _ in armSleepTimer() }
            .onChange(of: watchScopes) { old, new in
                store.watchPageScopes.subtract(old.subtracting(new)); store.watchPageScopes.formUnion(new)
            }
            .onChange(of: duoExpanded) { _, expanded in
                // ⛔ 折叠 / 展开会把画面层重挂一次，AVKit 会把「inline layer 离开屏幕」
                // 当成「用户离开 App」而自己浮出 PiP 窗。这是用户明确禁止的行为
                // （「转个横屏、展开个横竖屏就跳出应用外小窗」）。
                // 在动作前后临时关掉自动浮起，宽限窗过后自动恢复 —— 能力保留，误判被挡住。
                // 此前这一步只有注释、没有实现（`suspendAutomaticFloating()` 全仓无定义）。
                PictureInPicture.suspendAutomaticFloating()

                // 折叠 ⇄ 展开只改「方向锁」：折叠态钉竖屏（外屏），展开后交还给设备。
                // 这里不调 `landLandscape()`：展开的默认落点是**竖屏单列**，
                // 双列只在设备真的横过来时出现（`sideways` 只看 `landscapeScreen`）。
                // 同上：折叠/展开都不再钉方向。折叠进外屏也允许横持
                //（外屏宽 466，横过来是 678×466，双列依然排得下）。
                PlayerOrientation.holdPortrait(false)
                // A Full Screen started on the inner display must not carry onto the outer one:
                // folding while full-screen left the player filling a portrait screen it could not
                // turn, with the watch page's own layout gone.
                //
                // ⛔ 必须走 `exitFullScreen()`，不能直接写 `fullScreen = false`。
                // `PlayerOrientation.fullScreenOwnsOrientation` 是**全屏闸门**，
                // 只在 `setFullScreen` / `exitFullScreen` / 页面 disappear 时才会被清掉；
                // 而 `holdPortrait(_:)` 的第一行就是 `guard !fullScreenOwnsOrientation else { return }`。
                // 直接写 `fullScreen = false` 会留下「状态说不在全屏、闸门仍说在全屏」，
                // 于是上面那句 `holdPortrait(!expanded)` 被 guard 静默丢弃 ——
                // 外屏该钉竖屏而没钉，再展开时 `holdPortrait(false)` 同样被丢，
                // 之后三形态怎么切方向规则都不再生效，直到整页 disappear。
                if !expanded && fullScreen { exitFullScreen() }
            }
            // Fold/unfold flips the tab bar, the scrim's bleed and the controls' safe-area padding at
            // once; animate the lot together so the swap reads as one move, not a pop.
            .animation(.smooth(duration: 0.3), value: duoExpanded)
            // ★ 锁定态冻结握持（第五点第二层）。见 `sideways` 的注释。
            //
            // 锁定 → 把当前横竖记下来，此后握持怎么变版面都不动。
            // 解锁 → 清掉冻结，立刻回到跟随真实空间。
            //
            // 为什么需要这一层：内屏不遵守方向掩码（`duo-games` 实测），
            // 所以「锁定后不再理会握持」是内屏上唯一能兑现的防误触手段。
            .onChange(of: lockedForShape) { _, locked in
                if locked {
                    // ⛔ 用 `lock()` 内部的快照，**不要**现读 `landscapeScreen`。
                    //
                    // 后者读 `window.bounds`（连续量）：点锁定会先请求转向，
                    // 这一帧读到的是动画中间帧（669×951→951×669 途中约 810×810，
                    // 宽高比 1.0 ≤ portraitEnter 1.15）→ 判成横持 → 冻结值写反且永久保留。
                    // 快照在 `mask` 已定的时刻取，不存在这个窗口。
                    landscapeFrozenWhileLocked = LandscapeFreeze(landscape: PlayerOrientation.lockedLandscape,
                                                                 expanded: duoExpanded)
                } else {
                    landscapeFrozenWhileLocked = nil
                }
            }
            .onAppear {
                // 页面重建（形态切换会重建控件层）后按当前锁定状态重新冻结，
                // 否则「锁着进来」的一刻冻结值是 nil，握持仍会生效。
                lockedForShape = PlayerOrientation.isLocked
                if lockedForShape {
                    // 同上：用快照。页面重建时 `lockedLandscape` 仍在（它是静态量）。
                    landscapeFrozenWhileLocked = LandscapeFreeze(landscape: PlayerOrientation.lockedLandscape,
                                                                 expanded: duoExpanded)
                }
            }
            // 锁钮在 `OneSkinPlayerChrome` 里，隔了好几层视图；用广播回读最省事，
            // 不把「锁定」这个状态穿透成一串闭包参数。
            .onReceive(NotificationCenter.default.publisher(for: PlayerOrientation.lockStateDidChange)) { _ in
                lockedForShape = PlayerOrientation.isLocked
            }
            .onDisappear {
                // An iPhone Duo fold/unfold swaps `watchBody` for `pageBody` (and back) without the
                // page leaving, so the page-level `onDisappear` handles stopping playback and leaving
                // Full Screen. Here only the watch page's own contributions are undone; they are
                // re-established by `onAppear` when the watch page returns.
                store.isWatchPageMounted = false
                store.watchPageScopes.subtract(watchScopes)
                // Unconditional: an unfold sets the hold to false already, but closing the page while
                // folded shut used to skip this and leave the app held upright.
                PlayerOrientation.holdPortrait(false)
            }
            .onChange(of: watchChannel == nil) { _, ended in
                playerStarted = false
                if ended { playerSession = nil }
                if ended && fullScreen { setFullScreen(landscape: false) }
                // [mi3s] 二开：**转屏 / 起播都不再自动进全屏**。
                // 上游这里有 `phoneTurned()`：手机已经横着时，一起播就跳全屏。
                // 用户的诉求正好相反 —— 横屏是双列选集页（左画面 + 右详情 + 菜单栏），
                // 全屏只由全屏键显式触发。整个调用已删除，`phoneTurned` 也随之移除。
            }
            // 换线路换筛选后页码必须回到 1：新线路可能只有 20 集，
            // 停在第 50 页会被夹到末页，看起来像「跳到了最后一页」。
            .onChange(of: activeFlag) { _, _ in episodePage = 0 }
            .onChange(of: episodeFilter) { _, _ in episodePage = 0 }
    }

    /// The picture's own surface: black, so the bands a fit leaves inside it read as part of the frame
    /// rather than as the page showing through, with the player on top. Not clipped: in Full Screen the
    /// player ignores the safe area and reaches the physical edges, and a clip at the page's own bounds
    /// would cut that overflow back off. On the page the player stays inside its box, so there is nothing
    /// to clip there either.
    private var watchStage: some View {
        ZStack {
            Color.black
            watchPlayer(stageOnly: false)
        }
    }

    /// ⛔ 选集页（One 皮肤）用的离屏 stage：只产生/启动 `PlaybackSession`，
    /// 不渲染任何画面。画面统一由 `OneSkinFixedPicture` 的 `AVPlayerLayer` 画，
    /// 这样同一个 `AVPlayer` 只有一个渲染宿主，通用播放器样式改动
    /// （`AVPlayerViewController` / 按片源比例的 pictureBox）影响不到选集页。
    private var oneSkinSessionStage: some View {
        watchPlayer(stageOnly: true)
    }

    @ViewBuilder private func watchPlayer(stageOnly: Bool) -> some View {
        // One cover from opening the page to the first picture: the player's own wait stays under it, so nothing
        // swaps or flickers on the way.
        let covered = watchChannel == nil || (!playerStarted && !fullScreen)
        ZStack {
            if let channel = watchChannel {
                // ⛔ 换集修复：stageOnly 的 PlaybackView 身份不变，它的 @State session
                // 会在**原 player** 上换 item。这里同样复用同一个会话，别每集问
                // Store 要一个从未启动过的新会话 —— `playbackSession(for:)` 在
                // channel 变化时会顺手新建并顶掉 activeSession，是有副作用的。
                let stageSession = stageOnly
                    ? (playerSession ?? store.playbackSession(for: channel))
                    : store.playbackSession(for: channel)
                PlaybackView(channel: channel, session: stageSession,
                             watch: WatchPlayback(fullScreen: fullScreen, toggleFullScreen: setFullScreen,
                                                  leave: leavePlayer,
                                                  immersive: splitsWatchPage || duoExpanded,
                                                  started: { playerStarted = $0 }, opened: { playerSession = $0 },
                                                  // ⚠️ 硬约束：画面比例唯一真实来源是 `AVPlayerItem.presentationSize`，
                // **不得依赖视图层 `aspect` 回调** —— 该回调在 One/哔哩哔哩皮肤路径下
                // 根本不触发，于是 `playerAspectRatio` 永远停在 16:9 初值。
                // 表现：横屏切竖屏后播放器尺寸不变（用户实测反馈）。
                // 这里保留该回调只为上游原版路径（那边确实会触发），
                // 真正的更新走下面 `syncAspectFromPresentationSize()`。
                aspect: { ratio in
                    guard ratio.isFinite, ratio > 0.2, ratio < 6 else { return }
                    if abs(ratio - playerAspectRatio) > 0.01 { playerAspectRatio = ratio }
                },
                                                  // 同上：本页的抽屉只认 `showsAllEpisodes`。
                                                  openEpisodes: { showsAllEpisodes = true }),
                             stageOnly: stageOnly,
                             // 把 PlaybackView 实际持有的会话交回本页：选集页
                             // 画面层据此长期绑定同一个 AVPlayer（换集只换 item）。
                             onStageSession: { session in
                                 // ⛔⛔ 2026-11-13 第四轮：**空会话不许顶掉有 item 的会话。**
                                 //
                                 // 用户给出的三组合矩阵把范围锁死了：
                                 //   竖源 + 横持双栏 ❌ 纯海报
                                 //   竖源 + 竖持单列 ✅
                                 //   横源 + 横持双栏 ✅
                                 // 「横源 + 横持」正常 ⇒ 布局与分栏代码没问题（否则它也坏）。
                                 // 真正的差别在**会话**：坏的那一帧日志是
                                 //   `PICCHK ok avPlayer=yes item=false status=-1`
                                 //   `stage=ps=0 lgs=0 wc=1`
                                 // —— 三档全空，只剩 `store.currentSession(for:)` 那个**空会话**，
                                 //   于是 `player.currentItem == nil`，画面层走 `OneSkinPosterWash`
                                 //   画海报。竖持时 `ps=1`（本页强引用还在）所以正常。
                                 //
                                 // 原先这里无条件赋值：横持引起的 `PlaybackView` 重建会回调
                                 // 一个**新造的、还没挂 item 的**会话，把上一帧那个正在播的
                                 // 覆盖掉，且 `lastGoodSession` 一起被污染 —— 之后每一帧都取到
                                 // 空会话，**再也回不来**（不是掉一帧，是永久掉）。
                                 //
                                 // 现在：只有「带 item」的会话才有资格覆盖；空会话只在当前也空时
                                 // 才补位（首次进入/换集过渡）。正在播的东西不会被顶掉。
                                 let incomingHasItem = session.player.currentItem != nil
                                 let currentHasItem = playerSession?.player.currentItem != nil
                                 if incomingHasItem || !currentHasItem {
                                     playerSession = session
                                 }
                                 // 记下「确定在播」的那一个，供 store 清槽后继续取用。
                                 if incomingHasItem || lastGoodSession == nil {
                                     lastGoodSession = session
                                 }
                             })
            }
            if covered { watchCover.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.35), value: covered)
    }

    /// Back from the picture. In Full Screen that means back to the page — the details and the episode
    /// list the viewer was looking at — not out of the page: the button sits in the top-left corner of a
    /// page the viewer only enlarged, so closing the page under it dropped them on Home with the video
    /// floating in the mini player. Leaving the page itself is the cover's Back, or the edge swipe.
    private func leavePlayer() {
        guard !fullScreen else { return exitFullScreen() }
        exitWatchPage()
    }

    /// 「退出选集页」的**唯一实现**：彻底退出这一集，然后 pop。三个入口共用。
    ///
    /// ★ 2026-11-12 用户裁决（需求 1 vs 需求 4 的冲突，原话）：
    ///
    ///   **「返回 = 收进迷你播放器继续播；退出键 = 彻底退出那个视频，不止是关音频。」**
    ///
    ///   所以两条路彻底分开，不再有任何「猜意图」的成分：
    ///     · 返回键 / 导航栏 Back / 左滑 / 程序化 dismiss → `settlePlaybackOnLeave()`
    ///       一律收进坞继续播；
    ///     · 退出键（`exitWatchPage`）→ 停播、收尾、退出这一集，坞里**也不留**它的卡片。
    ///
    /// 「彻底退出」包含三件事，缺一件都会留下残影：
    ///   ① `stopPlaying()` —— 跑会话收尾（存进度、断流、停转封装、清弹幕）；
    ///   ② 把它**从坞里摘掉** —— 若这一集正好也在坞里（从坞点回来又点了退出），
    ///      只清前台会让它留在坞里继续播，用户以为退出了其实还在；
    ///   ③ pop 本页。
    ///
    /// 顺带确认：`leaveHandled = true` 只挡住 `onDisappear` 的自动收坞，
    /// 不影响上面三步 —— 顺序必须是「先置旗标，再停播，最后 pop」。
    private func exitWatchPage() {
        // ① 先记住要退的是哪一集（停播后 `store.playing` 就变 nil 了）。
        let leaving = store.playing
        // ② 告诉 `onDisappear`：这次去向已定，别再自动收进坞。
        leaveHandled = true
        // ③ 彻底退出：会话收尾 + 从坞里摘掉那一集。
        store.quitPlayback(leaving)
        // ④ 离开本页。
        dismiss()
    }

    /// 收进**应用内小窗**并离开本页（哔哩哔哩皮肤的「小窗」键与菜单项共用）。
    ///
    /// 与 One 皮肤的 `onMiniPlayer` 是同一件事，只是那条在 `OneSkinStage` 的泛型视图里、
    /// 走的是它自己的闭包；哔哩哔哩三个页面组件都没有这个入口，所以在这里收一个具名方法，
    /// 三个页面 + 菜单项都调它，避免第三处再写一遍并把顺序写错。
    ///
    /// ⛔ 顺序不能换（见 `onMiniPlayer` 里那段完整推导）：
    /// `miniPlayerActive = true` → `leaveHandled = true` → `dismiss()`。
    /// 先置全局开关再 pop，`RootView.floatsInMiniPlayer` 才来得及在下一帧挂上卡片；
    /// 而 `leaveHandled` 会挡住 `onAppear` 把刚设的 true 清掉。
    private func collapseToMiniPlayer() {
        guard let channel = store.playing else {
            // 没有在播就没有可缩小窗的画面 —— 直接退全屏/关页，别留一个空卡片。
            if fullScreen { exitFullScreen() } else { dismiss() }
            return
        }
        // ⛔ 顺序不能换：先把**这一集**交给坞（登记 + 摘掉前台槽），再 pop。
        //
        // 上一版是先置 `miniPlayerActive = true` 再由 `RootView` 去读 —— 那套只支持一个
        // 小窗。现在坞是真源：登记必须在 pop 之前完成，否则 `onDisappear` 里那句
        // 「不是为缩小窗而离开？那就停播」会把这一集直接杀掉（画面进去了，声音没了）。
        // 同时必须**摘掉前台槽**，否则前台与坞两边指着同一个会话，退出裁决会把它停掉。
        _ = channel
        store.dockForeground()
        leaveHandled = true
        if fullScreen { exitFullScreen() }
        dismiss()
    }

    /// 选集页的**退出键**（用户 2026-11-11：退出按钮要从视频窗口内移到界面上）。
    ///
    /// 三个必须写清的取舍：
    ///
    /// ① **它不再画在 `OneSkinChrome.topBar` 里。** 那一层被 `pictureColumn` 用
    ///    `.frame(winW, winH).offset(winX, winY)` 锁在画面窗口内 —— 画在那里的任何键，
    ///    无论怎么调整位置都在窗口里。界面级按钮只能挂在页面这一层。
    /// ② **从它退出不进小窗。** 用户明确要求：这条路径是「真的走」。
    ///    所以它先置 `leaveHandled = true`（挡住 `onDisappear` 里那句
    ///    「左滑才收坞、否则停播」的判定把它收进坞），再显式 `stopPlaying()`。
    ///    「收进坞」仍然存在，只是入口只有两个：小窗键、左滑。
    /// ③ **全屏时它不出现。** 全屏里画面就是整屏，窗口内那颗退全屏键已经落在界面上；
    ///    再叠一颗「退出页面」会让人误触 —— 全屏按退出键应当只退全屏，这是既有约定。
    @ViewBuilder private var watchPageExitButton: some View {
        // ⛔ 只给**没有自带返回键**的皮肤补这一颗。
        //
        // One 皮肤与控制栏（`OneSkinChrome`）里的返回键已经按用户要求摘掉了，
        // 它是这一颗的**唯一目标用户**。而：
        //   · 哔哩哔哩三个页面（`BiliPortraitPage` / `BiliLandscapePage` / `BiliFullScreenPage`）
        //     各自在 `playerCard` 顶栏里画着自己的返回键 —— 那是还原 B 站版式的一部分，
        //     动它就不再是 B 站的样子了；
        //   · 上游原版播放器（`MobilePlayer.topRow` / `screenTopRow`）同样有自己的返回键。
        // 不判皮肤就无条件挂，这两套都会变成**两个返回键**（一个在画面里、一个在界面上），
        // 而且两者行为不同 —— 用户点到哪个都会觉得「有时进小窗、有时不进」。
        if !fullScreen, oneSkinActive {
            Button {
                // 与「小窗键」的区别只有一条：**不停播转小窗，直接走人并关音频**。
                // 实现收在 `exitWatchPage()`，与哔哩哔哩皮肤的返回键共用同一条路径 ——
                // 两个皮肤的退出语义必须一致，否则「换个皮肤，返回行为就变了」。
                exitWatchPage()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.text("Leave Watch Page")))
            .accessibilityIdentifier("watch.exit")
            // ⛔ 避让必须走**安全区**，不能写死 padding。
            //
            // 这一页是 `statusBarHidden(true)` 的沉浸页，但 `safeAreaInsets` 仍然有效
            // （状态栏/刘海/Home 指示条都会算进去）。写死 `padding(.top, 6)` 的后果是：
            //   · 竖持：键压在状态栏那一行（Duo 合盖时挖孔在顶部，直接盖住）；
            //   · 横持：刘海在**左**，`leading` 只有 12pt —— 键整个陷进刘海区，
            //     点不到（正是 `OneSkinChrome` 里记过的「最边缘不能正常点击」）。
            // `safeAreaPadding` 由系统算，三种形态一次到位。
            // ⛔ 这里不再叠任何「遮挡补量」：遮挡只走几何层（16.1），
            //    页面外层那个 `OcclusionTopUp` 已删除，别再加第二套。
            .safeAreaPadding(.leading, 12)
            .safeAreaPadding(.top, 6)
        }
    }

    /// 选集页离场时，这一集该去哪 —— 用户的两条规则在这里落地。
    ///
    /// 规则（2026-11-11）：
    ///   · 返回上一层 → **关掉音频**（要求 4）；
    ///   · 左滑返回 → **继续播**，画面收进迷你播放器（要求 4 的例外 + 要求 1）。
    ///
    /// 判据是「怎么走的」，不是「有没有在播」：
    ///   · `leaveHandled`：用户按了小窗键，`collapseToMiniPlayer` 已经把会话
    ///     登记进坞了 —— 这里只把一次性意图复位，绝不重复登记（重复登记会多出一张卡片）；
    ///   · `SwipeBack.isPending`：系统左滑手势，语义与「小窗键」相同 —— 收进坞继续播；
    ///   · 其余：返回键 / 导航栏 Back / 程序化 dismiss → 停掉这一集。
    ///
    /// ⛔ 只处理**本页正在播的那一集**，绝不清整个坞。坞里可能还挂着别的片子
    /// （要求 5），`store.miniPlayerActive = false` 会把它们一起掐掉。
    /// 离开选集/全屏播放页时，这一集去哪。
    ///
    /// ★★ 2026-11-12 用户明确裁决（覆盖此前「返回＝关音频」的规则）：
    ///
    ///   **只要没按「退出」键，离开播放页就一律收进迷你播放器继续播。**
    ///
    /// 离场后**延迟**再决定这一集去哪 —— 折叠/展开不能被当成分手。
    ///
    /// 用户报的原话：「展开切合拢、合拢切展开，会产生迷你播放器，这个是不应该的」。
    ///
    /// 成因：Duo 折叠 / 展开会把观看页重挂一次（`onDisappear` 紧跟 `onAppear`，
    /// 本文件头部的日志记录里 `detail onAppear` 曾反复触发 133 次）。把
    /// `settlePlaybackOnLeave()` 直接写在 `onDisappear` 里，等于把「换了个版式」
    /// 判成「离开了播放页」→ `dockForeground()` → 主界面上凭空冒出一张迷你播放器，
    /// 而页面其实还在，于是前台没了会话、播放在坞里跑。
    ///
    /// ⛔ 判据不能靠尺寸/宽高关系（折叠前后可能一模一样），也不能靠 `@State`：
    /// 重挂会换掉页面身份，新实例既看不到也取消不掉旧实例挂的任务。
    /// 只用一条**事实**：页面回来了（`onAppear` 里 `pageGeneration += 1`），
    /// 那次离场就不成立。宽限窗取 0.35s ≈ 一次 pop 动画；真离场时迷你播放器
    /// 正好在页面退场动画结束时出现，用户看不到延迟。
    private func scheduleSettlePlaybackOnLeave() {
        Self.pageGeneration &+= 1
        let generation = Self.pageGeneration
        #if DEBUG
        oneSkinLog("detail onDisappear gen=\(generation) playing=\(store.playing?.name ?? "nil") "
            + "mounted=\(store.isWatchPageMounted) docked=\(store.videoTasks.hasTasks) phase=\(String(describing: scenePhase))")
        #endif
        // 已经退到后台：不会再有「折叠重挂」这回事，立刻结算。
        // 等 350ms 的话，退场裁决会先看到「页面上没有画面」而去起应用外浮窗，
        // 于是「返回 + 立刻上滑回主屏」会变成「浮窗 + 坞里还有一张卡」两层。
        if scenePhase == .background {
            settlePlaybackOnLeave()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            // 判据一：页面又活了（onAppear 跑过 / 挂载标志回来）= 折叠重挂，不是离场。
            // 判据二：**导航栈里还有页**。
            //
            // ⛔ 第二条是这轮的关键。真机日志（16:23）显示折叠到 466 宽时
            // `detail onDisappear` 会跑，但 350ms 内没有 `onAppear`（SwiftUI 把内容
            // 移出渲染树又插回，没重复发 appear），第一条判据永远不成立，
            // 于是同一集被塞进坞、屏幕上多出一张迷你播放器 —— 而那一刻 OneSkin
            // 仍在按 `466x644` 正常出帧，说明页面根本没走。
            //
            // 被 pop 时 `RouteStack` 的 path 会先清空（深度 0），折叠只改版式、
            // 深度不变。所以「深度 > 0」= 页面还在栈上 = 不许收坞。
            let stillOnStack = store.navDepth > 0
            guard generation == Self.pageGeneration,
                  !store.isWatchPageMounted,
                  !stillOnStack else {
                #if DEBUG
                oneSkinLog("SETTLE cancel gen=\(generation) now=\(Self.pageGeneration) "
                    + "mounted=\(store.isWatchPageMounted) nav=\(store.navDepth) —— 页面还在，不收坞")
                #endif
                return
            }
            settlePlaybackOnLeave()
        }
    }

    /// 只要用户在播放页（选集页 / 全屏播放页）上没有点那颗明确的退出按钮，
    /// 无论是按返回键、导航栏 Back、左滑手势还是程序化 dismiss，
    /// 都应该把小窗留在坞里 —— 而不是把音频关掉。
    ///
    /// 反过来说，「关音频」只有一个入口：`exitWatchPage()`（用户点了退出键）。
    /// 它先置 `leaveHandled = true`，所以走到这里时 `leaveHandled` 已经是 true，
    /// 下面的 `guard` 会直接返回，什么都不做（`exitWatchPage` 已自行停播）。
    ///
    /// 为什么这条要写这么死：用户的原话是「只要不在播放页…没有按退出，
    /// 那么都应该展示出迷你播放器」。这是**默认行为**，不是例外分支。
    private func settlePlaybackOnLeave() {
        defer { leaveHandled = false }
        // 明确退出（点了退出键）：`exitWatchPage()` 已经停播并 pop，这里不重复处理。
        if leaveHandled { return }
        guard store.playing != nil else { return }
        // ⛔ 折叠 / 展开（Duo）也会跑 `onDisappear`，那种「本页没走」的情况不该动播放。
        //
        // 第一道闸在 `scheduleSettlePlaybackOnLeave()`（页面回来就不收坞）；
        // 这里是第二道：「坞里已经登记着同一集了吗」。从坞里点卡片回来后，
        // `VideoTaskCenter.take` 已把它从坞里摘掉、`adoptSession` 交给前台；
        // 若这一页随后因清栈/重压/形态重建再跑一次 `onDisappear`，无条件
        // `dockForeground()` 就会把它**重新塞回坞里** —— 坞里凭空多一张卡片
        // （用户看到「点回来又冒出一张」），而且坞里其他卡片会被一起挤动。
        //
        // `dock()` → `add()` 本身按频道去重，所以重复登记不会产生两张同集卡片；
        // 但「刚回到前台的那一集又被塞回坞」这件事本身就是错的，得在这里拦住。
        guard !store.floatsInMiniPlayer(store.playing) else { return }
        // 第三道闸：导航栈里还有页 → 页面根本没走（折叠/展开只是换版式），不许收坞。
        //
        // 这一道是兜底：`dockForeground()` 全仓只有小窗键 / 退出键 / 这里三个调用点，
        // 小窗键与退出键都会先置 `leaveHandled`，所以真正能「凭空冒出一张迷你播放器」
        // 的只有这里。深度判据把这条路彻底关死，不依赖 onAppear 是否重发。
        guard store.navDepth == 0 else {
            #if DEBUG
            oneSkinLog("SETTLE skip nav=\(store.navDepth) —— 页面仍在栈上，不收坞")
            #endif
            return
        }
        // 其余一切离开方式 → 收进坞继续播。
        _ = SwipeBack.isPending   // 保留读它以免编译器警告；语义上不再分流
        #if DEBUG
        oneSkinLog("SETTLE dock playing=\(store.playing?.name ?? "nil") gen=\(Self.pageGeneration)")
        #endif
        store.dockForeground()
    }


    /// 明确地退出全屏（单向），绝不关页。
    ///
    /// 不能用 `setFullScreen(landscape:)` 代劳：那是个**对折开关**（`entering = !fullScreen`），
    /// 返回时只要读到一次过期的 `false`（皮肤层与页面层是两份状态，见 OneSkinStage
    /// 的 `fullScreenNow`），它就会把 `fullScreen` 设成 `true`；反过来读到过期的 `false`
    /// 又会走进 `dismiss()`——用户看到的就是「全屏里点返回，直接回到主页」。
    /// 返回是一条单向操作，实现也必须是单向的。
    private func exitFullScreen() {
        guard fullScreen else { return }
        withAnimation(.smooth(duration: 0.3)) { fullScreen = false }
        // ★ 退全屏必须**打开方向闸门**，否则页面从此再也钉不住方向。
        //
        // `PlayerOrientation.fullScreenOwnsOrientation` 一旦为 true，
        // `holdPortrait(_:)` 的第一行 `guard !fullScreenOwnsOrientation` 就把所有
        // 「折叠钉竖屏 / 展开松手」的写入静默丢弃。此前只有 `setFullScreen` 会设 true、
        // 只有页面 `onDisappear` 会设 false —— 于是：
        //   · 点返回键退全屏（`onBack: { exitFullScreen() }`）→ 闸门仍 true
        //   · 全屏中合盖（`onChange(of: duoExpanded)`）→ 闸门仍 true
        // 两种最常见的退出路径都漏了这一步，表现是「三形态来回切几次后，
        // 折叠不再钉竖屏、展开也不再松手，要重启 App 才恢复」。
        PlayerOrientation.setFullScreenHeld(false)
        // 与 setFullScreen 同一条规则：这里**不碰方向掩码**。原来这里
        // `PlayerOrientation.set(landscape: false)` 会把 mask 锁回竖屏 ——
        // 横屏全屏退回后用户再点旋转键，被这个锁住的 mask 拦住，表现为
        // 「横屏过来的 UI/控件漂移，重启才恢复」的一环。
        // 退全屏只是恢复页面布局；方向仍然只归旋转键管。
    }


    /// The cover's words while it waits: the source finding the episode's link, then the page's player getting it ready.
    private func coverStatus(_ elapsed: TimeInterval) -> PlaybackWait {
        if let session = playerSession, let channel = watchChannel, loadingEpisode == nil {
            return session.wait(elapsed: elapsed, resume: channel.resumePosition, linesHint: false)
        }
        let progress = LoadingProgress.source(client.site, origin: client.origin, title: busyTitle)
        return PlaybackWait(message: progress.title, detail: progress.detail)
    }

    /// 进全屏：**沿用当前屏幕方向**，不再由片源比例决定。
    ///
    /// 用户要求「全屏也要能横屏也能竖屏」。此前进全屏一律
    /// `setFullScreen(landscape: playerAspectRatio > 1)` —— 横版片源强制横屏、
    /// 竖版片源强制竖屏，而全屏态下旋转键又被方向闸门挡住，于是全屏只有一种方向。
    ///
    /// 现在：进去时保持用户此刻的握持方向，进去之后旋转键可以自由切换。
    private func setFullScreenEnteringCurrentOrientation() {
        guard !fullScreen else { exitFullScreen(); return }
        let nowLandscape: Bool = {
            switch UIApplication.shared.appWindowScene?.interfaceOrientation {
            case .landscapeLeft, .landscapeRight: return true
            default: return false
            }
        }()
        setFullScreen(landscape: nowLandscape)
    }

    private func setFullScreen(landscape: Bool) {
        let entering = !fullScreen
        withAnimation(.smooth(duration: 0.3)) { fullScreen = entering }
        // 进全屏时按片源方向请求（横版片源 → 横屏），退全屏时**显式回竖屏**。
        //
        // 两个坑都踩过：
        // ① 只写 `setFullScreenHeld` 而不调 `set(landscape:fullScreen:)` —— 方向掩码
        //    没更新，竖屏点全屏只铺满竖屏，与哔哩哔哩（直接进横屏全屏）不符。
        // ② 退全屏时把 `landscape`（片源比例）原样传进去 —— 掩码又被设成 `.landscape`，
        //    全屏退了机器还横着，且 `release()` 里的 `set(landscape:false)` 会被闸门拦住。
        // `fullScreenOwnsOrientation` 闸门已在 `PlayerOrientation` 内部解决互锁问题
        // （PlayerView.swift:812-818），这里可以放心用。
        PlayerOrientation.set(landscape: entering ? landscape : false, fullScreen: entering)
        // ★ 告诉方向系统「现在处于全屏」/「已经退出全屏」。
        //
        // 这是「全屏机制独立」的开关：
        //   · 进全屏 → `isFullScreenHeld = true`，此后 `holdPortrait(...)` 的任何写入
        //     都被丢弃，页面尺寸变化（duoExpanded / sizeClass）再也无法把方向拉回去；
        //   · 退全屏 → 关掉闸门，方向交还给页面习惯。
        PlayerOrientation.setFullScreenHeld(entering)
    }

    /// [已删除] `phoneTurned()`：转屏自动进全屏。
    ///
    /// 用户诉求是「选集播放页横屏竖屏一样，都保留菜单栏，只有全屏播放才隐藏」。
    /// 而这条上游逻辑把「手机横过来」直接翻译成「进全屏」，于是横屏永远看不到
    /// 双列选集页和菜单栏 —— 菜单栏按规则被收掉了，用户看到的就是「横屏没有菜单栏」。
    /// 现在转屏只是转屏：横屏 = 双列选集页（左画面 + 右详情 + 底部菜单栏），
    /// 全屏只由顶栏/底栏那颗全屏键显式进入。`turnedFullScreen` 这个配套状态一并删除，
    /// 别再让「转进去的全屏」和「按钮进的全屏」有两套退出条件。
    ///
    /// 若将来要恢复，唯一正确的做法是**在 `watchPageLifecycle` 里**加回，
    /// 不要在两条渲染分支里各写一份（那正是这次清掉的屎山）。

    /// The cover's Play: where the viewer stopped, else the line's first episode.
    private func playWatchCover() {
        if let watchHistory { store.resume(watchHistory); return }
        guard let first = activeEpisodes.first ?? detail?.episodes.first else { return }
        startRequest { await play(first) }
    }

    /// Before the picture: the cover across the top, blurred, while an episode starts. Otherwise (a video of several
    /// episodes waiting for one to be chosen, or an episode that failed, which the banner below explains) the cover
    /// shows clear, as Discover's page does, with Play.
    private var watchCover: some View {
        let starting = (detail == nil && error == nil) || busy || loadingEpisode != nil || store.resumingHistoryID != nil || watchChannel != nil
        let playable = watchHistory != nil || (activeEpisodes.first ?? detail?.episodes.first) != nil
        // The list's poster when there was one, so the picture doesn't change once the details arrive.
        let poster = video.poster != nil ? video : detail ?? video
        return WatchCoverBackdrop(poster: poster.poster, headers: poster.posterHeaders, loading: starting, clear: !starting, wide: (landscapePage || duoExpanded) && !fullScreen) { coverStatus($0) }
            .contentShape(Rectangle())
            .onTapGesture { if starting { withAnimation(.smooth(duration: 0.25)) { coverBack.toggle() } } }
            .task(id: coverBack) {
                guard coverBack else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { coverBack = false } }
            }
            .overlay {
                if !starting, playable {
                    Button { playWatchCover() } label: {
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .glassSurface(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Play"))
                    .accessibilityIdentifier("watch.play")
                }
            }
            .overlay(alignment: .topLeading) {
                // While it starts by itself nothing sits on the cover until it's tapped. Every shape of
                // the page shows it: the navigation bar is hidden on all of them (a white title strip
                // over a poster printed the name twice), so this is the only way back from the cover.
                if !starting || coverBack {
                    Button { leavePlayer() } label: { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                        .chromeButton()
                        .accessibilityLabel(L10n.text("Back"))
                        .accessibilityIdentifier("watch.back")
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    private var watchDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentVideo().name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let facts = tmdb.details?.facts, !facts.isEmpty {
                    Text(facts).font(.subheadline.weight(.medium)).lineLimit(2).transition(.opacity)
                }
                let meta = [currentVideo().remarks, currentVideo().year ?? "", SourceLabel(client.site.name).text].filter { !$0.isEmpty }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let genres = tmdb.details?.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre).font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
            if detail?.episodes.isEmpty == false {
                HStack(spacing: 10) { downloadButton(iconOnly: false); videoFavoriteButton; shareButton }
            }
            playbackBanner
            tmdbStatus
            if let detail { synopsis(detail) }
            if detail != nil {
                seasonPicker
                watchEpisodes
                tmdbExtras.padding(.top, 6)
            } else if let error {
                errorCard(error)
            } else {
                DetailSkeleton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its buttons are Liquid Glass, like the player's above them (#293).
        .environment(\.glassControls, true)
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    /// A row of the series' seasons, so a matched multi-season show can jump between them. Only shown when
    /// TMDB has more than one season and the viewer is on the matching one's details.
    @ViewBuilder private var seasonPicker: some View {
        if let details = tmdb.details, details.mediaType == .tv {
            let seasons = details.seasons.filter { $0.number > 0 }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.number) { season in
                            let selected = details.season?.number == season.number
                            Button {
                                Task { await tmdb.selectSeason(season.number) }
                            } label: {
                                Text(season.name.isEmpty ? L10n.text("Season %lld", season.number) : season.name)
                                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("detail.season.\(season.number)")
                        }
                    }
                }
            }
        }
    }

    /// As in Bilibili's 选集: one row of episodes that scrolls sideways to the one playing, and All for the full list.
    /// A video with one episode has no row (its only episode is the video); several lines still show to choose from.
    ///
    /// On the Duo's unfolded landscape (the two-column page) the right column is tall and wide enough to hold the
    /// whole list at once, so the sideways row gives way to a resident vertical grid — the episode list lives beside
    /// the picture instead of hiding behind an "All" sheet, the same way the synopsis and lines do.
    @ViewBuilder private var watchEpisodes: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                let compact = compactTileWidth(items) != nil
                // B站式数字卡片网格：展开双栏/竖屏 sheet 走常驻网格，每行约 6 个；窄屏外屏保留
                // 横向滚动 + 全部（布局形态不变，只把卡片换成数字方块）。
                if duoExpanded && items.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            episodeOrderButton
                        }
                        watchLines
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], spacing: 8) {
                            ForEach(shownOrder(items)) { watchEpisodeCard($0, fill: true) }
                        }
                    }
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    if items.count > 1 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            episodeOrderButton
                            if items.count > (compact ? 5 : 2) {
                                Button { showsAllEpisodes = true } label: {
                                    HStack(spacing: 3) { Text(L10n.text("All")); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 10).frame(minHeight: 32)
                                        .glassOrFill(.regular.interactive(), Color.clear, in: Capsule())
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("watch.allEpisodes")
                            }
                        }
                    } else if flags.count > 1 {
                        Text(L10n.text("Lines")).font(.headline)
                    }
                    watchLines
                    if items.count > 1 {
                        // scrollPosition rather than ScrollViewReader: scrollTo also scrolls the page's vertical
                        // scroll view, which pushed the title under the player.
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 8) { ForEach(shownOrder(items)) { watchEpisodeCard($0) } }
                                .scrollTargetLayout()
                                .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                        .scrollPosition(id: $episodeScroll, anchor: .center)
                        // Edge to edge, unclipped: the tiles' glass shadow ran past the row and was cut off in a band (#293).
                        .scrollClipDisabled()
                        .padding(.horizontal, -16)
                        .onAppear { episodeScroll = currentEpisodeID }
                        .onChange(of: currentEpisodeID) { _, id in if let id { withAnimation { episodeScroll = id } } }
                    }
                }
                }
            }
        }
    }

    /// The lines, when there are several. Choosing one while an episode plays switches to it on that line.
    @ViewBuilder private var watchLines: some View {
        if flags.count > 1 {
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { flag in
                let previous = activeFlag
                selectedFlag = flag
                guard watchChannel != nil, let episodes = detail?.episodes else { return }
                let playing = episodes.first { $0.id == currentEpisodeID }
                guard let same = episode(on: flag, matching: playing, in: episodes) else {
                    // This line has no episode to continue the one playing: stay on it, and say so.
                    selectedFlag = previous
                    withAnimation(.smooth(duration: 0.2)) { lineNotice = L10n.text("This line doesn't have this episode.") }
                    Task { try? await Task.sleep(for: .seconds(4)); withAnimation(.smooth(duration: 0.2)) { lineNotice = nil } }
                    return
                }
                if same.id != currentEpisodeID { startRequest { await play(same) } }
            }
            // Edge to edge and unclipped, like the episodes, so the strip doesn't cut the chips' glass shadow (#293).
            .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
            .padding(.horizontal, -16)
        }
    }

    /// The episode on `flag` that continues `playing`: the same name, else the same episode number (第20集 / EP20 /
    /// S01E20), else nil when this line has no such episode. With nothing playing, the line's first episode.
    private func episode(on flag: String, matching playing: Episode?, in episodes: [Episode]) -> Episode? {
        guard let playing else { return episodes.first { $0.flag == flag } }
        let line = episodes.filter { $0.flag == flag }
        if let same = line.first(where: { $0.name == playing.name }) { return same }
        if let number = TMDBMatch.episodeNumber(playing.name),
           let same = line.first(where: { TMDBMatch.episodeNumber($0.name) == number }) { return same }
        return nil
    }

    /// 当前这一集在 TMDB 里的剧照（16:9），作为观看页背景。
    ///
    /// 数据来自现成的 `watchStills(_:)`：它已经处理了「TMDB 的那一季和源站集数对得上」
    /// 与「这一季真的大部分集都有图」两个前置条件，对不上时返回空字典 ——
    /// 那种情况下剧照会张冠李戴（第 3 集的图配到第 5 集），比没有更糟。
    ///
    /// 因此这里只做一次查表：能查到就用，查不到返回 nil，由 `OneSkinStage` 退回海报。
    private var currentEpisodeStill: URL? {
        guard let id = currentEpisodeID else { return nil }
        return watchStills(activeEpisodes)[id]?.still
    }

    /// TMDB's stills for the line's episodes, when its season lines up with most of them and has pictures for them;
    /// otherwise none, and the episodes keep their small cards.
    private func watchStills(_ items: [Episode]) -> [Episode.ID: TMDBMatch.EpisodeInfo] {
        let stills = tmdb.episodes(items)
        return items.count > 1 && stills.values.filter { $0.still != nil }.count * 2 >= items.count ? stills : [:]
    }

    /// The width of the small tiles when every name is short (第1集, 01, 4K国语), or nil for two-line cards. The tiles
    /// are as wide as the widest name, at least 64 points: a fixed 64 cut off names of four or five characters such as
    /// 4K国语 or 第100集 (#290). Measures one name, in the same pass that checks their lengths.
    private func compactTileWidth(_ items: [Episode]) -> CGFloat? {
        var widest = "", widestUnits = 0
        for item in items {
            let title = episodeTitle(item)
            guard title.count <= 5 else { return nil }
            // Chinese and other wide characters take about twice the room of digits and Latin letters.
            let units = title.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
            if units > widestUnits { widest = title; widestUnits = units }
        }
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        let text = (widest as NSString).size(withAttributes: [.font: font]).width
        // 8 points of padding on each side, and a little room for the bold of the episode playing.
        return max(64, (text + 20).rounded(.up))
    }

    /// An episode as a B站-style number tile: a compact dark square with the episode number centred, the
    /// playing one inverted (light fill + dark number) as the one clear anchor. No still, no caption — the
    /// number is the whole tile, so the grid stays small and uniform across the three shapes. The resume
    /// state (watched halfway) is a "续 N%" corner badge instead of a bottom progress bar.
    private func watchEpisodeCard(_ episode: Episode, fill: Bool = false, chosen: (() -> Void)? = nil) -> some View {
        let current = episode.id == currentEpisodeID
        // B站式纯数字卡片：播放中集反白（浅底深字）是「正在播放」的唯一清晰锚点；续播集用
        // 左上角「续 N%」小角标代替底部进度条；未看是深灰底。无封面、无标题行，方块小而均匀。
        let playing = current && watchChannel != nil
        let resumeProgress: Double? = {
            guard current, watchChannel == nil, let history = watchHistory,
                  !history.completed, history.progress > 0 else { return nil }
            return history.progress
        }()
        let saved = download(episode)
        let number = TMDBMatch.episodeNumber(episode.name)
        let label = number.map(String.init) ?? episodeTitle(episode)
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        return Button {
            chosen?()
            // The episode already playing keeps playing.
            guard !(current && watchChannel != nil) else { return }
            startRequest { await play(episode) }
        } label: {
            ZStack {
                shape.fill(playing ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                if loadingEpisode == episode.id {
                    ProgressView().controlSize(.small).tint(playing ? Brand.onAccent : Color.primary)
                } else {
                    Text(label)
                        .font(.system(size: number == nil ? 13 : 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(playing ? Brand.onAccent : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .padding(.horizontal, 4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: fill ? nil : 64, height: fill ? nil : 64)
            .overlay(alignment: .topLeading) {
                if let resumeProgress {
                    Text(L10n.text("Resume %lld%%", Int((resumeProgress * 100).rounded())))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Brand.accent, in: Capsule())
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .id(episode.id)
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu {
            if episodeLabels[episode.id] != nil { Text(episode.name) }
            if saved == nil || saved?.status == .failed {
                Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                    DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin),
                                                    title: video.name, poster: video.poster, posterHeaders: video.posterHeaders,
                                                    environmentID: store.environments.activeID)
                }
            } else if let saved {
                Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                    DownloadLibrary.shared.remove([saved.id])
                }
            }
        }
    }

    /// 选集抽屉底部的分页条：上一页 / 「第 x / N 页」可点跳转 / 下一页。
    ///
    /// 为什么不用 `Picker` 或 Slider：集数可能上千，Picker 的滚轮太慢，
    /// Slider 又难以精确落到某一页。这里给「上一页 / 下一页」做粗调，
    /// 中间的页码点开一个输入框做精确跳转。
    private struct EpisodePager: View {
        @Binding var page: Int
        let pageCount: Int
        let total: Int
        @Binding var pageSize: Int
        @State private var editing = false
        @State private var draft = ""

        var body: some View {
            HStack(spacing: 12) {
                Button { page = max(0, page - 1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(page <= 0)
                .opacity(page <= 0 ? 0.35 : 1)

                Spacer(minLength: 0)

                VStack(spacing: 1) {
                    Button {
                        draft = "\(page + 1)"
                        editing = true
                    } label: {
                        Text("\(page + 1) / \(pageCount)")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    Text("\(total) 集")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                Button { page = min(pageCount - 1, page + 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(page >= pageCount - 1)
                .opacity(page >= pageCount - 1 ? 0.35 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .alert(L10n.text("跳到第几页"), isPresented: $editing) {
                TextField("1", text: $draft)
                    .keyboardType(.numberPad)
                Button(L10n.text("Cancel"), role: .cancel) {}
                Button(L10n.text("Go")) {
                    if let n = Int(draft), n >= 1 { page = min(pageCount - 1, n - 1) }
                }
            } message: {
                Text(L10n.text("共 %d 页，每页 %d 集", pageCount, pageSize))
            }
        }
    }

    private var allEpisodes: some View {
        NavigationStack {
            VStack(spacing: 0) {
                watchLines
                episodeDrawerControls
                Divider().opacity(0.4)
                ScrollView {
                    if pagedEpisodes.isEmpty {
                        Text(episodeQuery.isEmpty && episodeFilter == .all
                             ? L10n.text("没有剧集")
                             : L10n.text("没有匹配的剧集"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], spacing: 8) {
                            ForEach(pagedEpisodes) { watchEpisodeCard($0, fill: true) {
                                showsAllEpisodes = false
                            } }
                        }
                        .padding(16)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                EpisodePager(page: $episodePage, pageCount: episodePageCount,
                             total: filteredEpisodes.count, pageSize: $episodePageSize)
            }
            .navigationTitle(L10n.text("Episodes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { episodeOrderButton }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showsAllEpisodes = false } }
            }
        }
        .environment(\.glassControls, true)
        // ★ 抽屉自己铺深色底并锁深色外观。
        //
        // 之前什么都不铺，sheet 沿用系统浅色底（实测整页 247/247/247），
        // 而 OneSkin 整页是深色（#080808）—— 抽屉一弹就是一大片刺眼白，
        // 用户看到的就是「竖屏底下这块渐隐白层」。
        // 铺 `OneSkinPalette.stage`（#080808，与页底同色）并锁 dark，
        // 里面的 TextField / Menu / Divider / NavigationBar 才会跟着走深色。
        // sheet 的**材质本身**也要换掉。
        //
        // 只加 `.background(...)` 是不够的：iOS 26 的 sheet 自带一层
        // `.regularMaterial` 玻璃底（实测取样 RGB ≈ 114,113,113 的**中性灰**），
        // 它压在内容下面、盖住我们铺的深色，于是整片抽屉是灰的，
        // 且底部到 home indicator 安全区之间露出 9pt 深色 —— 就是用户看到的
        // 「底部白色渐隐块」。`.presentationBackground` 直接替掉那层材质。
        .presentationBackground(OneSkinPalette.stage)
        .preferredColorScheme(.dark)
        // 高度档位与下载抽屉**同一套**：`[.medium, .large]` + 用户拖拽。
        //
        // ⛔ 不要再用 `[.height(320)]`，也不要让档位集合随 `duoExpanded` 变：
        // 1) 320pt 里固定头（导航栏 44 + 线路 + 搜索 44 + 筛选 32 + 分页器 48）就吃掉 200+，
        //    列表只剩一行，用户以为「选集列表空了 / 只加载了一集」；
        // 2) 档位集合在 sheet 展示期间被替换（合拢 → 展开）时，当前档位会从集合里消失，
        //    UIKit 只能跳到剩下的唯一档位或直接收掉 —— 折叠一下抽屉自己变高/消失。
        // 展开态想默认给满高，用 `selection` 换档，不动集合。
        .presentationDetents([.medium, .large], selection: $episodeDetent)
        .presentationDragIndicator(.visible)
        .onChange(of: episodePageCount) { _, count in
            // 换线路 / 改筛选 / 改每页条数后总页数变小：页码夹回，否则分页器会显示「6 / 2」。
            if episodePage > count - 1 { episodePage = max(0, count - 1) }
        }
    }

    /// 抽屉顶部的搜索 + 筛选 + 每页条数。
    ///
    /// 三者在同一块里，因为它们是同一件事的三个维度：
    /// 「我要找哪几集」— 搜索限定内容、筛选限定范围、页大小决定一屏看多少。
    private var episodeDrawerControls: some View {
        VStack(spacing: 8) {
            // 搜索
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField(L10n.text("搜索集数或标题"), text: $episodeQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .onChange(of: episodeQuery) { _, _ in episodePage = 0 }
                    .onSubmit { jumpToFirstMatch() }
                if !episodeQuery.isEmpty {
                    Button { episodeQuery = ""; episodePage = 0 } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.07)))

            // 筛选 + 每页条数
            HStack(spacing: 8) {
                ForEach(EpisodeFilter.allCases) { f in
                    Button {
                        episodeFilter = f
                        episodePage = 0
                    } label: {
                        Text(f.label)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(
                                episodeFilter == f ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05)))
                            .foregroundStyle(episodeFilter == f ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                // 每页条数：10 / 20 / 50
                Menu {
                    ForEach(Self.pageSizeChoices, id: \.self) { n in
                        Button {
                            episodePageSize = n
                            episodePage = 0
                        } label: {
                            if episodePageSize == n { Label("\(n) / 页", systemImage: "checkmark") }
                            else { Text("\(n) / 页") }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(episodePageSize) / 页")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    #endif
}

#if os(iOS)
/// iPhone: a video's page is a watch page, its player at the top (`VideoDetailView`). iPhone Duo's inner
/// display (regular both ways) keeps the watch page too — it is still a phone (`idiom == .phone`), and it
/// folds back to the compact outer screen, so the playback page must survive the fold. Only a real iPad
/// (`idiom == .pad`) takes the tablet's plain detail page.
enum WatchPage {
    @MainActor static func applies(_ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?) -> Bool {
        // 原判据只认 `.phone`：虚拟机 / Duo 模拟器上 idiom 可能不是 .phone，
        // 会让观看页永远走 pageBody（图文详情页），One 皮肤根本没机会渲染。
        // 补一条：屏幕短边 < 600pt 也按手机观看页处理（真机 phone 亦满足）。
        if UIDevice.current.userInterfaceIdiom == .phone { return true }
        let b = UIApplication.shared.appScreenBounds.size
        return min(b.width, b.height) < 600
    }
}

/// A swipe from the left edge goes back, as on any pushed page: hiding the navigation bar turns that gesture off.
/// It also comes before the picture's slide-to-seek and the episode row's scrolling, which would otherwise take a
/// swipe that starts at the edge.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    /// Off in Full Screen, where the swipe would leave the page, and on a folded-out Duo, where the page keeps
    /// its own navigation bar (and the system sidebar owns the left edge).
    var enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enabled = enabled }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = true {
            didSet { if enabled != oldValue { apply(animated: false) } }
        }
        private weak var recognizer: UIGestureRecognizer?
        private weak var previous: UIGestureRecognizerDelegate?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // The swipe already under way goes on; other pages get the system's own rules back.
            disarm()
        }

        /// Only the immersive (enabled) page hides the navigation bar and arms the edge swipe. On a folded-out
        /// Duo the page keeps its nav bar and tab bar for an explicit way back, so this must not hide the bar —
        /// doing so left the expanded page with neither a back button nor a working swipe.
        private func apply(animated: Bool) {
            guard isViewLoaded, view.window != nil else { return }
            if enabled {
                // Pushed from a search field still active (after Search was pressed), the bar the page hides
                // stayed, and its Back showed over the page's own.
                if navigationController?.isNavigationBarHidden == false {
                    navigationController?.setNavigationBarHidden(true, animated: animated)
                }
                arm()
            } else {
                disarm()
            }
        }

        /// Again after a swipe that was let go halfway, which brings the page back.
        private func arm() {
            guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate !== self else { return }
            recognizer = pop; previous = pop.delegate
            pop.delegate = self; pop.isEnabled = true
        }

        private func disarm() {
            if let recognizer, recognizer.delegate === self { recognizer.delegate = previous }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            enabled && (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            enabled && other is UIPanGestureRecognizer
        }
    }
}
#endif

extension PlaybackHistoryEntry {
    /// The watched title as a list card, to open its page with.
    var listVideo: Video {
        Video(id: context.videoID, name: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
    }
}

private struct PlaybackIssue {
    let episode: Episode
    let message: String
    let drive: CloudDrive?
    /// True when playback was not attempted because a required account is missing.
    let blockedBeforeRequest: Bool
    /// A sign-in the source's CatPawOpen bundle runs itself (`CatPawSignIn.provider(for:)`).
    var signIn: String? = nil
}

private struct BundleSignIn: Identifiable {
    let provider: String
    var id: String { provider }
}

/// Cloud drives whose plugins need a saved login before they can return a stream.
// 由 `private` 放宽为 internal：`EpisodePicker` 的默认线路要复用
// `CloudDrive.preferredFlag(_:)`（「第一条现在就能播的线」），否则面板与播放页
// 会各有一套「哪条线能播」的判据 —— 那正是两处默认线路互相打架的根源。
// 放宽只影响可见性，不改变任何行为；该符号仍只在 App target 内使用。
enum CloudDrive: String, Identifiable {
    /// Xunlei's sign-in is only for CatPawOpen bundles, which say when it is missing; other sources play their Xunlei
    /// lines without it, so those lines are never held back for it. Baidu comes only from a plugin's error
    /// (`CloudDriveLoginRequired`), never from a line's name: other plugins sign in to it with their own code.
    case quark, uc, xunlei, baidu
    var id: String { rawValue }
    /// FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC.
    init?(flag: String) {
        let text = flag.lowercased()
        if text.contains("夸克") || text.contains("夸父") || text.contains("quark") { self = .quark }
        else if text.hasPrefix("uc") || text.contains("uc网盘") || text.contains("优汐") { self = .uc }
        else if text.contains("迅雷") || text.contains("xunlei") { self = .xunlei }
        else { return nil }
    }
    /// Lines from drives that sign in through the plugin's own QR code (FTY's 嘟嘟 is Baidu, 阿狸 is
    /// Aliyun). They ask for a scan the first time, so they never start a title on their own.
    static func withoutSignIn(_ flag: String) -> Bool {
        let text = flag.lowercased()
        return ["嘟嘟", "百度", "度盘", "baidu", "阿狸", "阿里", "aliyun"].contains { text.contains($0) }
    }
    /// The first line that can play now: not from a drive without a sign-in, nor one whose sign-in is missing.
    static func preferredFlag(_ flags: [String]) -> String? {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        return flags.first { flag in
            if withoutSignIn(flag) { return false }
            guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return true }
            let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
            return !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .xunlei: L10n.text("Xunlei")
        case .baidu: L10n.text("Baidu Netdisk")
        }
    }
    var signInTitle: String {
        switch self {
        case .quark: L10n.text("Sign In to Quark")
        case .uc: L10n.text("Sign In to UC")
        case .xunlei, .baidu: L10n.text("Sign In to %@", name)
        }
    }
    #if os(macOS)
    var provider: CloudProvider { self == .quark ? .quark : .uc }
    #else
    var qrDrive: CloudDriveQRLogin.Drive { self == .quark ? .quark : self == .baidu ? .baidu : .uc }
    var webSignIn: WebSignIn { self == .quark ? .quark : self == .baidu ? .baidu : .uc }
    #endif
    var loginHint: String { L10n.text("This source plays from %@ and needs you to sign in first.", name) }
    var expiredHint: String { L10n.text("Your %@ sign-in is missing or has expired. Sign in again to play this episode.", name) }
    static func missingLogin(forFlag flag: String) -> CloudDrive? {
        guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return nil }
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
        return cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? drive : nil
    }
    static func isLoginFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["授权", "登录", "扫码", "cookie", "login", "unauthorized"].contains { text.contains($0) }
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
// [mi3s] 二开：`EpisodeRow` 由 `private` 提为 `internal`，让上游 `PlayerEpisodesSheet` 也能复用同一行
// 渲染（否则两处各画一套，字号/间距迟早走偏）。见 03-侵入点登记表 I-06。
struct EpisodeRow: View {
    let name: String
    /// The episode's short label (第1集), shown in place of the name; the size tag stays as detail.
    var label: String? = nil
    let loading: Bool
    var download: DownloadItem? = nil
    let action: () -> Void
    @State private var hovering = false
    static func split(_ name: String) -> (title: String, detail: String?) {
        if let match = name.firstMatch(of: /^\s*\[([^\]]+)\]\s*(.+)$/) { return (String(match.2), String(match.1)) }
        return (name, nil)
    }
    static func title(_ name: String) -> String { split(name).title }
    /// Row type and height per platform: a Mac list size is unreadable from a sofa.
    private static var metrics: (text: CGFloat, icon: CGFloat, height: CGFloat, inset: CGFloat) {
        #if os(tvOS)
        (28, 18, 42, 0) // GlassRowStyle adds its own padding and focus glass
        #elseif os(iOS)
        (15, 11, 44, 14)
        #else
        (13, 10, 36, 12)
        #endif
    }
    private var parts: (title: String, detail: String?) {
        let parts = Self.split(name)
        return (label ?? parts.title, parts.detail)
    }
    var body: some View {
        let parts = parts
        let button = Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "play.fill").font(.system(size: Self.metrics.icon)).foregroundStyle(hovering ? .primary : .tertiary) }
                }
                .frame(width: Self.metrics.icon + 6)
                Text(parts.title).font(.system(size: Self.metrics.text, weight: loading ? .semibold : .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let detail = parts.detail {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                if let download { DownloadState(item: download) }
            }
            .padding(.horizontal, Self.metrics.inset).frame(minHeight: Self.metrics.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(loading ? 0.12 : (hovering ? 0.08 : 0.04)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        #if os(tvOS)
        button.glassRow()
        #else
        button.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }
}

private struct DownloadLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}

/// Gives its one subview at least `minHeight`, even in a scroll view, where `frame(minHeight:)`
/// leaves the content at its ideal height and spacers inside it never grow.
private struct MinHeightLayout: SwiftUI.Layout {
    var minHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: max(size.height, minHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}