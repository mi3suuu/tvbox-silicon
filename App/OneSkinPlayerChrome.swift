//
//  OneSkinPlayerChrome.swift
//  映匣 / Mi3s
//
//  「把上游仓库与二开播放器里的播放控件，全部搬进 One 皮肤页」的那一层。
//
//  为什么必须单独一层：
//  · 上游 `MobilePlayer.swift` 的控件与画面是一体的：`pictureCarrier` 在 iOS 上换成
//    `AVPlayerViewController`，AVKit 自己接管布局、无视 SwiftUI 给的 frame。One 版式
//    要把画面锁进固定 1.819 的窗口，只能自己用 `AVPlayerLayer` 画
//    （见 OneSkinWindowGeometry 的 LOCKED 段）。
//  · 于是 OneSkin 原来的控件是**另画的一份**，只有返回/全屏/合拢/旋转能点，`pip`、
//    `speaker` 只是图标；选集、画质、音轨、字幕、倍速、锁定、视频信息、弹幕、外播、
//    画中画、小窗、上/下集、手势全部缺席。
//
//  这一层不复制 MobilePlayer 的视图树，只复用它的**引擎侧**对象
//  （PlaybackSession / PictureInPicture / MediaTracks / Store.step /
//   SkipSegmentSources / QualityPicker / PlaybackInfoPanel / DanmakuOverlay /
//   Mi3sSubtitleOverlay / Mi3sExternalPlayerMenu / AirPlayButton），
//  控件外观仍按 One 的白色细线风格重画；控件清单与排布直接读二开的
//  `PlayerControlsLayout`（与播放器同一个 storageKey）。
//
//  曾经列在这里的两条缺口，现在都补齐了（2026-11-09 第三轮）：
//  · 语音字幕：管线本来就在 `TVCore.SpeechSubtitles`（公开类型），
//    只是没人从 One 页调它。现在按「设置里选过语言 + 本机有该语言离线模型」决定
//    这颗键出不出现，跑的时候带进度 HUD，离页取消。
//  · 长按倍速：从「固定 2×」换成 `TVCore.SpeedBoost` —— 长按后不松手继续拖动，
//    横滑改档位、下滑保持在当前档（再点顶部胶囊回原速）；连接跟不上时由 session 自动降档。
//
//  其余同轮补齐、值得记住位置的：
//  · 锁屏 / 控制中心：`VideoNowPlaying`（远程键 + 封面 + 进度），此前一条都没写过。
//  · 卡顿看门狗：`PlayerClock`（`StallWatchdog`）→ 画面下沿一条换线提示。
//  · 弹幕列表 / 投屏（`PlayOnButton`）/ 选集聚合（`CatalogPlaybackActions`）/
//    画质增强（`EnhancedVideoSurface` + 两个开关）。
//  · 顶栏格数按可用宽度算，不再是写死的 2 颗；`controlButton` 覆盖了枚举里的每一个控件
//    （此前画质/音轨/外播落到 `default: EmptyView()`，顶栏上是一颗点不动的空位）。
//

#if os(iOS)
import SwiftUI
import AVKit
import AVFoundation
import TVCore


// ═══════════════════════════════════════════════════════════════════════
// ⚠️ 长期约束（踩过两次，别再犯）
//
// 1. 决定 UI 结构的计算属性，只能用**离散量**。
//
//    `canMarkAd` 曾经依赖 `session.player.rate` 与调用链上的 `position`：
//    `position` 每秒被 `updateSkipping` 改写，于是「更多」菜单的内容被
//    判定为每帧都在变，列表持续重绘 —— 用户点不中、下拉选不了。
//
//    凡是 `if`/`ForEach`/`Section` 的分支条件，只允许读：
//      时长、开关、枚举、布尔、静态配置
//   禁止读：
//      播放位置、进度、速率、任何逐帧变化的量
//
// 2. 画面手势只保留**一个** `pressGesture`，由它自己计时区分
//    单击 / 双击 / 长按加速 / 横滑定位。
//
//    不要退回多手势 `simultaneousGesture` 平挂，也不要再用
//    `LongPressGesture().sequenced(before:)` —— 后者在 TapGesture 共存时
//    收不到 `.first(true)` 中间态，长按永远不会触发（表现为「单击即加速」）。
// ═══════════════════════════════════════════════════════════════════════

// MARK: - 播放控件总线

/// One 页与播放引擎之间的唯一接口。
///
/// 做成值类型 + 引用型成员：`session` / `pip` / `tracks` 都是 `@Observable`，
/// 值本身每次重绘重建无妨；不需要 `@StateObject` 那套生命周期，也就不会出现
/// 「页面重建把控件状态一起丢掉」的问题。
struct OneSkinPlayerKit {
    var session: PlaybackSession?
    var channel: Channel?
    /// 画中画控制器，由 OneSkinStage 以 `@State` 持有，并绑到它自己那条 AVPlayerLayer。
    var pip: PictureInPicture
    var tracks: MediaTracks
    /// 页面形态（`OneSkinShape`）。控制栏配置**只认这个**，不认窗口宽高比 ——
    /// 播放器窗口恒为横向（1.819），从窗口比例反推横竖会把竖持判成横持。
    var skinShape: OneSkinShape
    var layout: PlayerControlsLayout
    var openEpisodes: () -> Void
    var miniPlayer: () -> Void
    var toggleFullScreen: () -> Void
    var isFullScreen: Bool
}

// MARK: - 控件层

/// One 版式的全部播放控件 + 手势 + 提示。
///
/// 只画在 `winW × winH` 的窗口坐标系里，窗口怎么变它怎么跟着变
/// （旋转、合拢、全屏都不会飞出窗口 —— 2026-11-09 修过一轮，别再回到
/// 「每个控件 .position 挂在整列上」的老写法）。
struct OneSkinChrome: View {
    let kit: OneSkinPlayerKit
    let winW: CGFloat
    let winH: CGFloat
    let winX: CGFloat
    let winY: CGFloat
    let colW: CGFloat
    let colH: CGFloat
    let landscape: Bool
    let fullScreen: Bool
    /// 屏幕安全区（状态栏 / Home 指示条 / 横屏时的刘海）。
    ///
    /// 窗口坐标 (0,0) 在**全屏**与**展开宽屏**两种形态下就是屏幕 (0,0)：
    /// 画面从屏幕顶端开始画（`ignoresSafeArea`），顶栏按 `winH * 0.072` 落位时
    /// 正好压在状态栏那一行上 —— 时间与电量挤在返回键旁边，按键的下半截还落在
    /// 状态栏的热区里，点不准。底栏同理会被 Home 指示条咬掉一条。
    /// 横屏时刘海在**左边**，最左边那颗返回键整个陷进刘海区，点不到 ——
    /// 用户报的「最边缘不能正常点击」就是它。
    /// 所以顶/底栏的落点与左右边距都要受安全区夹逼，见 `topBarY` / `bottomBarY`。
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var safeLeft: CGFloat = 0
    var safeRight: CGFloat = 0

    /// **物理屏**在当前方向下的尺寸（宽 = 正在使用的那条边）。
    ///
    /// ⛔ 为什么必须单独传：`safeTop/Bottom/Left/Right` 是从**屏幕边**量出来的，
    ///    而 `colW/colH` 是**画面列**——两者只在全屏/竖持单列时才相等。
    ///    横持双列时画面列只有 523 宽，屏幕是 951：
    ///      · `spaceRightOfWindow = colW − winX − winW` 会算成 0
    ///        → `safeRight`（内屏横持实测 71）被当成「窗口内的安全区」全额扣掉，
    ///          进度条 / 剩余时间 / 全屏键整排左缩 ~39pt；
    ///      · `spaceBelowWindow = colH − winY − winH` 同病：
    ///        `edgeToEdge`（展开宽屏）时窗口就是画面列，`colH == winH`
    ///        → 误判「窗口贴屏幕底」，底栏凭空抬高 20/34pt。
    ///    这两个量只有拿**屏幕**做基准才成立。0 = 未知，退回列尺寸（旧行为）。
    var screenW: CGFloat = 0
    var screenH: CGFloat = 0

    /// 明确「退出全屏」——不是切换。
    ///
    /// 页面那份 `fullScreen` 与皮肤这份镜像（`fullScreenNow`）是两个变量，任一侧读到
    /// 过期值，返回就会落到 `dismiss()` 上 —— 用户看到的就是「全屏里点返回直接回主页」。
    /// 所以全屏下的返回走这条单向通道：只退全屏，绝不离开页面。
    ///
    /// ⛔ 这里**没有** `onBack` 了（2026-11-11）。选集页的退出键已迁到页面层
    /// （`VideoDetailView.watchPageExitButton`），因为这一层被
    /// `.frame(winW, winH).offset(winX, winY)` 锁在画面窗口内，画在这里的键出不了窗口。
    /// 留一个无人读取的 `onBack` 只会让人以为顶栏还有返回键。
    var onExitFullScreen: () -> Void = {}
    var onFold: () -> Void = {}
    var onRotate: () -> Void = {}

    @Environment(Store.self) private var store
    @AppStorage(PlayerControlsLayout.storageKey) private var layoutRaw = PlayerControlsLayout.standard.stored
    @AppStorage(DanmakuPreference.key) private var danmakuOn = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(PictureScaling.key) private var scalingRaw = PictureScaling.source.rawValue
    @AppStorage(Mi3sSubtitleStyle.storageKey) private var subtitleStyleData = Data()
    @AppStorage("subtitlePositions") private var subtitlePositionsData = Data()
    /// 倍速的持久化镜像（与底部胶囊条 chip 同一个 key）。
    /// ••• 菜单这条路径原来只写 session.speed，胶囊条 chip 读的是 AppStorage ——
    /// 两边显示不一致（菜单改成 2×，chip 还显示 1×）。写入同一 key 后自动同步。
    @AppStorage(OneSkin.speedKey) private var persistedSpeed: Double = 1
    /// 长按加速的起始档（可在设置里改）。与旧播放器同一个偏好键。
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    /// 画质增强（Smooth Motion / Sharper Picture）。与旧播放器和设置页同两个键。
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    /// 广告拦截总开关。与设置页、原版播放器、HLS 代理**同一个键**（`player.skipAds`）。
    @AppStorage(AdSkip.key) private var skipsAds = true
    /// 竖滑调亮度/音量（设置页「滑动调亮度与音量」）。
    ///
    /// ⛔ 以前这里没有这个开关，`dragged()` 只判几何位置就直接改亮度/音量 ——
    /// 用户在设置里关掉后**照样生效**。原生皮肤（`MobilePlayerView`）是判
    /// `parent?.levels == true` 的，两套皮肤行为分叉。
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    /// 双击左右跳过 10 秒；关掉后双击改为播放/暂停（上游 1.8.12 的开关，见 `PictureDoubleTap`）。
    @AppStorage(PictureDoubleTap.key) private var doubleTapSkips = true

    /// 控件锁：手势与遮挡层全部失效（只有「解锁」还能点）。
    @State private var locked = false
    /// 全屏下控件自动收起后的状态。选集页（非全屏）始终常驻 —— One 的版式就是那样，
    /// 收起会让用户找不到返回；全屏则相反，画面要干净，点一下再叫出来。
    @State private var chromeHidden = false
    @State private var hideTask: Task<Void, Never>?
    /// 单击与双击的仲裁：单击延迟 0.26s 执行，双击一落就取消它。
    @State private var tapTask: Task<Void, Never>?
    /// 「显示视频信息」开关。**必须与设置页/原生皮肤共用同一个键**
    /// （`PlaybackInfo.key` = `player.showInfo`）。
    ///
    /// ⛔ 原来这里是 `@State` —— 全仓 6 处 `@AppStorage(PlaybackInfo.key)` 声明，
    /// 唯独 One 不在其中。后果有两条：
    ///   ① 设置页「显示视频信息」对 One 皮肤**完全无效**；
    ///   ② 在 One 里点亮那颗 i 键，切一次形态（`@State` 随视图重建归零）就灭了。
    @AppStorage(PlaybackInfo.key) private var showsInfo = false
    /// 起播耗时浮层。
    ///
    /// One 的 `showPlaybackStats`：把「慢」拆成「解析 / 就绪 / 首帧 / 共几秒」，
    /// 画在播放器画面**右上角**，并注明这次走的是 HLS 还是 mp4 —— 用户报「起播慢」
    /// 时能直接看出慢在哪一段，不必去翻控制台。
    /// 数据源是 `PlayerClock.marks`（`PlaybackMarks` 的四个时间戳），
    /// 与卡顿看门狗同一份，不另记一套。
    @State private var showsPlaybackStats = false
    /// 「更多本剧」与「跳过片头片尾」两个 sheet 的开关。
    /// 这两项原属上游 `CatalogPlaybackActions`，收进枚举后在 One 页里自己持有。
    @State private var showsSeries = false
    @State private var showsSkip = false
    /// 手标广告区间那一页是否打开。
    @State private var showsAdRange = false
    /// 画面内剪辑层是否打开（直接在视频上拖选起止点）。
    @State private var showsAdTrim = false
    /// 「更多」面板是否展开。
    ///
    /// 它是个普通 `@State`，不是系统菜单 —— 这样父视图每秒重算（进度条读 `position`）
    /// 不会把已展开的列表重建一遍。见 `moreMenu` 的注释。
    @State private var showsMore = false
    @State private var externalStream: OneSkinHandoff?

    /// 双击跳转的累计气泡。
    @State private var skipped: (forward: Bool, total: Double)?
    @State private var skippedTask: Task<Void, Never>?
    @State private var taps = PictureTaps()

    /// 横滑定位。
    @State private var swipeStart: Double?
    @State private var swipeTarget: Double?
    /// 竖滑亮度 / 音量。
    @State private var level: (volume: Bool, value: Double)?
    @State private var levelTask: Task<Void, Never>?
    @State private var brightnessBefore: CGFloat?
    @State private var systemVolume = MusicVolumeSlider.SystemSlider()
    /// 长按倍速。
    ///
    /// 原来只做「按住 2×、松手恢复」（一个 `Double?`），比旧播放器少了三件事：
    /// 横滑改档、下滑保持、以及「连接跟不上时自动降一档」的节流。
    /// 现在直接用 `TVCore.SpeedBoost`（同一个类型、同一个偏好键），
    /// 手势也换成「长按 → 接着拖」的序列，否则拖动事件根本到不了这里。
    @State private var boost: SpeedBoost?

    /// 进度条拖动：拖动中不回写，松手才 seek（与旧实现一致）。
    @State private var scrubbing = false
    @State private var dragProgress: Double = 0

    /// 字幕文件与外观。
    @State private var subtitleTracks: [SubtitleTrack] = []
    @State private var chosenSubtitle: String?
    /// 「是否显式选过字幕」。`chosenSubtitle == nil` 有两个语义：「从没选过」和「选了 Off」。
    /// 没有这个标记，`activeSubtitle` 会把 nil 回退成第一条字幕 —— 用户没开过字幕却凭空
    /// 出现，且选了 Off 又回退到第一条，永远关不掉。这里把两者分开。
    @State private var subtitlesChosen = false
    @State private var subtitleStyle = Mi3sSubtitleStyle.standard
    @State private var subtitlePositions = SubtitlePositionMemory()

    /// 片头 / 片尾标记。
    @State private var skipSegment: SkipSegmentSources.Segment?
    @State private var skipCredits: SkipSegmentSources.Segment?
    @State private var skipFileLevel = false

    /// 语音字幕（听声写字幕）。
    /// 文件头「已知缺口」里曾写着「生成管线锁在 MobilePlayer 的私有方法里，这里按不可用处理」——
    /// 那句话现在不成立了：管线本来就在 `TVCore.SpeechSubtitles`，是公开类型，
    /// 只需要在这里拿 asset + 语言跑一遍。设置页选过语言、且本机有该语言的离线模型，
    /// 这颗键才会出现；否则不假装能点。
    @AppStorage(SpeechSubtitles.preferredLanguageKey) private var speechLanguageCode = ""
    @State private var generatingSubtitles = false
    @State private var subtitleProgress: Double = 0
    @State private var speechNote: String?
    @State private var speechTask: Task<Void, Never>?

    /// 锁屏 / 控制中心的「正在播放」。
    /// One 页此前**一条 Now Playing 都没写过**：锁屏只有一面空白，控制中心点不到，
    /// 耳机线控的播放/暂停也没有接收方。`VideoNowPlaying` 是旧播放器就在用的那一个，
    /// 直接复用（远程键、跳过 10 秒、进度拖动、封面全在里面），不另写一套。
    @State private var nowPlaying = VideoNowPlaying()

    /// 卡顿看门狗。
    ///
    /// 与旧播放器**同一份** `PlayerClock`（`StallWatchdog` 在它内部）：它盯的不是错误，
    /// 而是「位置一秒钟都不动」—— 一条线悄悄死掉时不会报错，只有这个能发现。
    /// One 页此前完全没有这条线，卡住了只能用户自己翻菜单换线。
    @State private var clock = PlayerClock()
    /// 弹幕列表面板。
    @State private var showsDanmakuList = false
    /// 投屏（DLNA 接收端 + AirPlay）。与旧播放器同一份浏览器。
    @State private var playOn = PlayOnBrowser()
    /// 画质增强的处理器**归会话所有**，这里只读（见 `session.enhancer`）。
    ///
    /// ⛔ 这里原来写的是 `@State private var enhancer: VideoEnhancer?` + 一个
    ///    `prepareEnhancer()` 工厂。那条路把「谁拥有 enhancer」从会话挪到了视图，
    ///    于是丢掉了会话天然给它的三件东西，三个都已实测确认：
    ///
    ///    ① **生命周期绑定**：`PlaybackSession.enhancer` 是 `let`、在 `init` 里建，
    ///       会话换 ⇒ enhancer 跟着换，天然 1:1。视图 `@State` 不会跟着会话走 ——
    ///       一旦本页原地换新会话，旧会话释放后 `VideoEnhancer.player`（`weak`）变 nil，
    ///       `refresh()` 首行 `guard let player` 永久早退 ⇒ enhancer 成空壳，
    ///       而消费端 `if let enhancer` 仍为真、画面层照画最后一帧。
    ///    ② **创建时机**：视图级创建意味着一开始开关是关的时候没有 enhancer，
    ///       所以必须另挂 `onChange` 去补建（原来那两个 `onChange` 就是为此存在），
    ///       而补建路径一旦漏挂一处（N1 就是这么漏的）用户就看到「开了没反应」。
    ///       会话级创建没有这个窗口 —— 会话建立时无论开关状态都建好。
    ///    ③ **空闲管线回收**：`makeEngineIfNeeded()` 在开关关掉时会把 `engine` 释放回 nil
    ///       并 `detachOutput()` 拆干净，所以「会话级总有一个 enhancer」不等于
    ///       「总持有一条 GPU 管线」。原注释担心的 use-after-free 由那一层守住，
    ///       不需要靠「视图层先不建」来守。
    ///
    /// 原版播放器（`MobilePlayer:429`）早就是读 `session.enhancer`，本条只是把 One 对齐。
    private var enhancer: VideoEnhancer? { session?.enhancer }

    private var session: PlaybackSession? { kit.session }
    private var channel: Channel? { kit.channel }
    /// 控制栏排布：**所有形态共用一份**（见 `PlayerControlsLayout`）。
    /// `layoutRaw` 只作为刷新信号保留 —— `@AppStorage` 需要它才能在本页重算。
    private var layout: PlayerControlsLayout {
        _ = layoutRaw
        return PlayerControlsLayout.current
    }
    private var scaling: PictureScaling { PictureScaling(rawValue: scalingRaw) ?? .source }

    private var position: Double { session?.position ?? 0 }
    private var duration: Double { session?.duration ?? 0 }
    private var playing: Bool { !(session?.paused ?? true) }
    private var seekable: Bool { session?.hasTimeline == true && session?.isLive == false }
    private var showsTransport: Bool { session != nil && session?.loading == false && session?.error == nil }

    // MARK: 尺寸

    /// **唯一**尺寸来源。以前这里是四个各算各的公式（宽取 winW、高取 winH、
    /// 字形又按宽再乘 0.34、播放键另取一套并夹到 30），落到屏幕上就是
    /// 「同一个播放器里控件有大有小」。现在只留一个比例尺，其余全是倍数。
    private var m: ChromeMetrics { ChromeMetrics(winW: winW, winH: winH) }

    /// 屏幕尺寸（当前方向）。未知时退回列尺寸，保持旧行为。
    private var screenSize: CGSize {
        CGSize(width: screenW > 1 ? screenW : colW,
               height: screenH > 1 ? screenH : colH)
    }

    /// 当前窗口所在那块屏的安全区。
    ///
    /// 只在构造控件层时读一次（形态切换会重建），不要在 `body` 里每帧读 ——
    /// 状态栏动画期间 inset 是连续变化的，会让整层控件跟着抖。
    static func safeInsets() -> (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        #if os(iOS)
        guard let window = UIApplication.shared.appWindowScene?.keyWindow else { return (0, 0, 0, 0) }
        let i = window.safeAreaInsets
        return (i.top, i.bottom, i.left, i.right)
        #else
        return (0, 0, 0, 0)
        #endif
    }

    /// 顶栏中心 y。设计值是 `winH * 0.072`；当窗口顶边贴着屏幕顶（全屏 / 展开宽屏）时，
    /// 这个值会落进状态栏里，所以再拿**安全区**兜一道：
    /// 顶栏热区的上沿不得高于 `safeTop`，否则时间 / 电量会和返回键抢同一行。
    private var topBarY: CGFloat {
        // 顶栏贴着**画面窗口**的顶边，不是贴着状态栏。
        //
        // 原来写的是：
        //   cleared = safeTop + hit/2 + edge - winY
        //   return max(design, cleared)
        // `cleared` 以**屏幕安全区**（状态栏底边）为基准，再减掉窗口偏移 ——
        // 于是控件跟的是状态栏，不跟画面窗口。典型症状就是用户报的
        // 「外屏竖屏时控件没有跟随视频播放器，而是跟随了状态栏内的安全区」：
        // 竖屏窗口从 y≈62pt 开始，`cleared` 却是按状态栏 59pt 算的，
        // 差值直接吃掉窗口内部本该有的间距，顶栏被顶到窗口下沿甚至外面。
        //
        // 正确语义：**默认按窗口比例**（One 实测 0.072）；
        // 只有当窗口**贴到屏幕顶**（winY 很小）时，才需要让开状态栏，
        // 且让开量是「安全区超出窗口顶部的那一段」，不是整个 safeTop。
        let design = max(winH * 0.072, m.hit / 2 + m.edge)
        // 窗口顶边在屏幕坐标系里的位置就是 winY（列顶 == 屏幕顶）。
        // 安全区若落在窗口内部（winY < safeTop），才需要把它顶下去。
        let safeInsideWindow = max(0, safeTop - winY)
        let cleared = safeInsideWindow + m.hit / 2 + m.edge
        let baseline = max(design, cleared)

        // ★ 传感器（灵动岛 / 刘海 / 挖孔）按**水平位置**分别避让。
        //
        // 上面那条 `cleared` 只回答「整条顶栏要压在哪儿」，它拿 `safeTop` 一刀切，
        // 假定了「遮挡物横贯整屏」。实际不是：
        //   · 竖屏灵动岛只在**中间一段**（约屏宽 27%），左右两侧是空的；
        //   · 横屏刘海在**左缘一条**，而那时 `safeTop` 通常为 0，这条判据根本不报警。
        // 于是用户报的「竖屏控件被摄像头压住 / 横屏最左边点不到」两件事，
        // 都不是这句 `cleared` 能解决的。真正的判据在 `OneSkinSafeArea`。
        let housing = OneSkinSafeArea.housing(
            screen: screenSize,
            safeTop: safeTop,
            safeLeft: safeLeft,
            portrait: !landscape
        )
        // 顶栏的内容水平范围：从窗口左缘 + 边距，到窗口右缘 − 边距。
        let x0 = winX + barLeading
        let x1 = winX + winW - barTrailing
        let clearedForHousing = OneSkinSafeArea.clearedCentreY(
            baseline,
            halfHeight: m.hit / 2,
            windowTop: winY,
            x0: x0,
            x1: x1,
            housing: housing,
            margin: m.edge
        )
        return clearedForHousing
    }

    /// 底栏中心 y。设计值是 `winH * 0.928`，同样要在窗口贴屏幕底时让开 Home 指示条。
    private var bottomBarY: CGFloat {
        // 底栏同理：基准是**窗口底边**，不是屏幕底边。
        //
        // 原来 `lowest = colH - winY - safeBottom - hit/2 - edge` 里的 `colH - winY`
        // 是「列底」，不是「窗口底」。竖屏时窗口只占列的上半段（446×244），
        // `colH - winY` 却拿整列高算，底栏被推到窗口下沿之外很远的地方；
        // 同时 `safeBottom`（Home 指示条）也被无条件扣掉 —— 可它根本不在窗口内部。
        let design = min(winH * 0.928, winH - m.hit / 2 - m.edge)
        // 窗口底边到**屏幕底边**还剩多少。
        //
        // ⛔ 原来写 `colH - winY - winH`（列底），展开宽屏 `edgeToEdge` 时
        //    窗口就是整列 → 差值 0 → 判定「窗口贴屏幕底」→ 把 Home 条那
        //    20/34pt 扣进窗口内部，底栏整体抬高。而窗口其实在中部，
        //    离屏幕底还有几百 pt。必须用屏幕高做基准。
        let spaceBelowWindow = max(0, screenSize.height - winY - winH)
        let safeInsideWindow = max(0, safeBottom - spaceBelowWindow)
        let lowest = winH - safeInsideWindow - m.hit / 2 - m.edge
        return min(design, max(lowest, m.hit / 2 + m.edge))
    }

    /// 顶/底栏的左右边距。
    ///
    /// 窗口左右不一定贴着屏幕边（双列 / 竖屏时窗口比列窄，居中内缩），
    /// 所以先把「窗口边缘到屏幕边缘」的距离减掉，再让开刘海：
    /// 横屏时刘海在左边，不减的话最左边那颗返回键整个陷进刘海区，点不到。
    private var barLeading: CGFloat {
        max(m.edge, m.edge + safeLeft - winX)
    }
    /// 右端边距。**只按窗口算，不掺列宽。**
    ///
    /// 原来写的是 `m.edge + safeRight - (colW - winX - winW)`：
    /// 后面那一项是「窗口右边缘 → 列右边缘」的空隙，双列/竖屏时窗口居中内缩，
    /// 这个空隙很大，被整个当成额外右边距扣掉 —— 于是整排内容（进度条 + 剩余时间
    /// + 全屏键）都往左缩，全屏键永远落不到画面窗口的右下角。
    ///
    /// 用户报的「进度条和全屏按钮没占满宽度、不在最右下角」就是它。
    /// 底栏的基准是**画面窗口**，不是它所在的列：窗口右边就是终点，
    /// 只需要让开窗口右侧的真实安全区（全屏时窗口贴到屏幕边才有意义）。
    private var barTrailing: CGFloat {
        // 底栏的右端基准是**画面窗口的右边**，不是所在列的右边，也不是屏幕右边。
        //
        // 实测算过错两版：
        //  ① 原式 `m.edge + safeRight - (colW - winX - winW)` —— 把「窗口右缘→列右缘」
        //     的空隙整个当成右边距扣掉，双列/竖屏时窗口居中，空隙很大，整排左缩。
        //  ② 改成 `safeRight - windowToScreenRight` —— 反过来了：窗口贴边时
        //     `windowToScreenRight = 0`，于是 `inset = safeRight` 全额生效。
        //     探针实测横屏下拿到 `R=89`（竖屏刘海的宽度），比原式更糟。
        //
        // 真正的语义：屏幕安全区**如果落在窗口内部**才需要让开；落在窗口外面
        // 的那部分天然就在画面之外，不该再变成内边距。
        // 窗口右缘在屏幕里的位置 = winX + winW（画面列贴屏幕左缘，列原点是 0）；
        // 屏幕宽度 = screenSize.width。窗口右侧还剩多宽？这段里有多少被安全区占掉？
        //
        // ⛔ 基准必须是**屏幕宽**，不是 `colW`：横持双列时画面列 523、屏幕 951，
        //    用列宽算出的余量恒为 0 → 把屏幕右缘那 71pt 安全区当成窗口内的，
        //    整排控件左缩 39pt（P1，见 16.2）。
        let spaceRightOfWindow = max(0, screenSize.width - winX - winW)
        let safeInsideWindow = max(0, safeRight - spaceRightOfWindow)
        return max(m.edge, m.edge + safeInsideWindow)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ZStack {
                // 画质增强：处理过的帧画在**画面之上、控件之下**。
                // 这一层与画面窗口同尺寸（winW×winH），所以不需要再对一次坐标。
                if let enhancer, VideoEnhancement.enabled {
                    EnhancedVideoSurface(enhancer: enhancer, gravity: scaling.gravity, bleeds: [])
                        .frame(width: winW, height: winH)
                        .allowsHitTesting(false)
                }
                if let session, danmakuOn, !session.danmaku.isEmpty, showsTransport {
                    DanmakuOverlay(player: session.player,
                                   comments: session.danmaku,
                                   opacity: session.danmakuOpacity,
                                   revision: session.danmakuRevision)
                        .opacity(locked ? 0.35 : 1)
                }
                // 手势层在字幕之下：字幕气泡本身可以拖，拖它不该被识别成 seek/亮度。
                gestureLayer
                subtitleLayer
                if showsTransport {
                    if locked {
                        // 锁定后控件不再响应，只留一个「解锁」——否则锁了就再也解不开。
                        unlockButton
                    } else if !chromeHidden || !fullScreen {
                        // 全屏且已收起时整层不画（点画面叫回来）；非全屏永远常驻。
                        topBar
                        centerTransport
                        bottomBar
                    }
                }
                morePanel
                // 画面内剪辑层：铺满窗口、盖在所有控件之上 ——
                // 剪的时候手势必须归它，否则一拖就变成"单击显示/隐藏控件"。
                if showsAdTrim, let session {
                    AdTrimOverlay(session: session,
                                  onCancel: { withAnimation(.easeOut(duration: 0.16)) { showsAdTrim = false } },
                                  onSaved: { range in
                                      withAnimation(.easeOut(duration: 0.16)) { showsAdTrim = false }
                                      showAdHUD(.marked(seconds: range.length))
                                      Task { await loadSkipMarkers() }
                                  })
                        .frame(width: winW, height: winH)
                }
                gestureHUD
                boostLayer
                infoLayer
                playbackStatsLayer
                skipLayer
                stallNotice
            }
            .frame(width: winW, height: winH)
            .offset(x: winX, y: winY)
        }
        // 竖滑音量用的隐藏系统音量视图：不挂它就改不动系统音量。
        .background {
            MusicVolumeSlider.HiddenVolumeView(system: systemVolume)
                .frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
        }
        .frame(width: colW, height: colH)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .task(id: channel.map { $0.url.absoluteString }) { await loadSubtitles() }
        .task(id: itemIdentity) { await tracksTask() }
        // ⛔ 原来这里还有两个 `.onChange(of: upscalesVideo|smoothsVideo) { prepareEnhancer() }`，
        //    用来补「播放中打开开关」的创建时机。enhancer 改成会话所有后**不需要了** ——
        //    它随会话建好，与开关状态无关；开关的开关效果由消费端 `if let enhancer,
        //    VideoEnhancement.enabled`（`:455`）与 `makeEngineIfNeeded()` 的惰性建管线负责。
        .task(id: skipKey) { await loadSkipMarkers() }
        // 锁屏 / 控制中心：接上遥控键，并在状态变化时重写信息。
        // `initial: true` 覆盖「进页面时就已经在播」这一常见情形。
        .onAppear {
            attachClock()
            if let session { nowPlaying.start(session) }
            // ★ 锁定态必须从 `PlayerOrientation` 回读，不能靠本地 @State 初值。
            //
            // `locked` 是 `@State`，而控件层在**每次形态切换**时都会被重建
            // （折叠 / 展开 / 转屏 / 进出全屏都会换窗口尺寸、换 `winW×winH`）。
            // 重建后它回到 `false`，可 `PlayerOrientation.isLocked` 仍是 `true`：
            //   · 画面上看是「未锁定」—— 顶栏、播放键、进度条全部回来且**可点**；
            //   · 方向其实还钉死着，于是按键响应了、画面不动；
            //   · 而且这时不再画 `unlockButton`，用户**没有任何入口解锁**，
            //     只能退出页面再进 —— 正是用户报的「锁定后切形态就乱了 / 解不开」。
            // 回读一次让两者始终是同一事实。
            locked = PlayerOrientation.isLocked
        }
        // 会话是异步来的（先有 channel，再有 player），两个时刻都要重新挂看门狗。
        // 广告被自动跳过时弹一下提示。
        //
        // `lastSkippedAd` 在 `PlaybackSession` 里只赋值、界面从来没读过，
        // 所以用户完全不知道刚才那一下卡顿是「跳过广告」而不是播放故障。
        // 这里把它接成 HUD，跳完给 2 秒反馈再自己消失。
        .onChange(of: session?.lastSkippedAd?.id) { _, newID in
            guard newID != nil, let ad = session?.lastSkippedAd else { return }
            showAdHUD(.skipped(seconds: ad.duration))
        }
        // 手标区间被跳过时也要给反馈。
        //
        // 上面那条只认指纹命中（`lastSkippedAd`）。手标段走的是另一条路，
        // 以前那条路**什么都不弹** —— 用户手标了一段，跳过时画面只是"跳了一下"，
        // 分不清是自己标对了还是播放故障。
        .onChange(of: session?.lastSkippedAdRange?.id) { _, newID in
            guard newID != nil, let ad = session?.lastSkippedAdRange else { return }
            showAdHUD(.skipped(seconds: ad.length))
        }
        .onChange(of: session != nil) { _, ready in if ready { attachClock() } }
        .onChange(of: channel?.url) { _, _ in attachClock() }
        .onChange(of: nowPlayingState, initial: true) { _, _ in
            if let session { nowPlaying.update(title: channel?.name, session: session) }
        }
        .onChange(of: nowPlayingArtwork, initial: true) { _, artwork in
            if let session { nowPlaying.show(artwork, session: session) }
        }
        .onChange(of: duration > 0) { _, known in if known { Task { await loadSkipMarkers() } } }
        .onChange(of: subtitleStyle) { _, _ in saveSubtitleStyle() }
        .onChange(of: subtitlePositions) { _, _ in
            if let blob = try? JSONEncoder().encode(subtitlePositions) { subtitlePositionsData = blob }
        }
        .sheet(item: externalBinding) { handoff in
            Mi3sExternalPlayerMenu(stream: handoff.url, headers: channel?.headers ?? [:])
        }
        // ⛔ 这两个 sheet 此前**根本没有挂**。
        //
        // `showsSeries` / `showsSkip` 只被菜单条目置 true，没有任何 `.sheet` 消费它们 ——
        // 于是「更多本剧」和「跳过片头片尾」点了什么都不发生。用户报
        // 「控件没有实现完整」，这是最典型的形态：条目在、动作写了、界面没接上。
        // 现在挂上与上游 `CatalogPlaybackActions` 同一对视图，行为一致。
        .sheet(isPresented: $showsSeries) {
            if let channel { SeriesSuggestionSheet(channel: channel) }
        }
        .sheet(isPresented: $showsSkip) {
            if let session { EpisodeSkipSettingsView(session: session) }
        }
        // 手标广告起止点。此前只有「标注广告」一条路——它靠抓帧猜边界，
        // 猜歪了用户无从纠正，抓不到帧时更是连猜都没有。这一页让用户直接给两个时间点。
        .sheet(isPresented: $showsAdRange) {
            if let session {
                AdRangeEditor(session: session) { _ in
                    Task { await loadSkipMarkers() }
                }
            }
        }
        // 弹幕列表：旧播放器一直有，One 页此前没有入口，只能看飘过的、找不到刚才那条。
        .sheet(isPresented: $showsDanmakuList) {
            if let session {
                DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                    .danmakuListPresentation()
            }
        }
        .onChange(of: fullScreen) { _, full in
            // 进全屏：先亮出控件，几秒后自动收起，画面才干净；
            // 退全屏：恢复常驻（选集页必须能一直看到返回）。
            if full { revealChrome(schedule: true) } else { cancelHide(); chromeHidden = false }
            // ⛔ 「更多」面板必须随全屏切换一起收起。
            //
            // `morePanel` 的显示条件是 `if showsMore, !fullScreen, ...` —— 进全屏时它被条件
            // 藏起来，但 `showsMore` 仍是 true。等用户退出全屏回到选集页，条件重新成立，
            // 面板会**自己弹出来**盖在画面上，用户没点过任何东西。
            // 状态与可见性必须同时收，否则就是「隐藏了但没关」。
            if showsMore { closeMore() }
        }
        // `morePanel` 的显示条件里还有一个 `showsTransport`（换集/切源时它会短暂变 false）。
        // 面板会因此消失，但 `showsMore` 还留着 true —— 新集就绪后它**自己弹回来**。
        // 与 fullScreen / locked 同族，这里一并收掉。
        .onChange(of: showsTransport) { _, ready in
            if !ready, showsMore { showsMore = false }
        }
        // 广告拦截开关变了要**当场**生效，不能等下一集（见 `adBlockingDidChange`）。
        .onChange(of: skipsAds) { _, enabled in
            session?.adBlockingDidChange(enabled: enabled)
        }
        .onChange(of: playing) { _, isPlaying in
            // 暂停就留着控件，继续播再开始倒计时 —— 与上游播放器一致。
            if isPlaying, chromeHidden == false { scheduleHide() } else { cancelHide() }
        }
        // [mi3s] 二开：应用外小窗**只在视频里手动触发**（控件里的画中画按钮）。
        //
        // 这里原来绑了 scenePhase：background → `startFloating()`，active → `stopFloating()`。
        // 「切屏就走、回来就收」听着合理，实际有两个问题：
        //   1) 锁屏、下拉通知中心、切换 App 都会进 background/inactive，用户只是看一眼通知，
        //      浮窗就自己飞出来了；
        //   2) 折叠 / 转向时图层会被重挂，AVKit 与我们的判定都可能把它当成「离开 App」。
        // 现在整段删掉，PiP 只由 `kit.pip.toggle()` 那一个按钮起停。
        .onDisappear {
            cancelHide(); tapTask?.cancel()
            // 控件层在每次形态切换时会被重建，`showsMore` 随 @State 归零；
            // 但同一次构建内离页再回来（sheet 关闭等）不一定重建，显式清一次。
            showsMore = false
            // 语音字幕是长任务：离页必须取消，否则识别在后台跑完也无人接收。
            speechTask?.cancel(); speechTask = nil
            // 锁屏信息随页面一起撤掉；不撤的话离开播放页后锁屏还停在上一集。
            nowPlaying.stop()
            clock.detach()
            // 竖滑改的是整机亮度，离开时必须还原，否则用户回到桌面发现屏幕被压暗。
            if let before = brightnessBefore { screen?.brightness = before }
        }
    }

    // MARK: - 顶部动作行

    private var topBar: some View {
        HStack(spacing: 0) {
            // [mi3s] 二开（2026-11-11）：**选集页的「退出」不再画在这里**。
            //
            // 用户的诉求：退出按钮要离开视频窗口、落到界面上，而且从它退出**不进小窗**。
            // 这一层（`OneSkinChrome`）被 `pictureColumn` 用
            // `.frame(winW, winH).offset(winX, winY)` 锁在**画面窗口**里 —— 所以画在这里
            // 的键无论怎么放都在窗口内。选集页那颗已迁到页面的 `watchPageExitButton`。
            //
            // 这里只保留**全屏态**那一颗：全屏时画面铺满整屏、窗口＝屏幕，
            // 它本来就已经落在「界面上」；而全屏里需要的是「退全屏」而不是「退出页面」，
            // 语义不同、不能合到页面那颗上去（页面那颗一律退出页面）。
            if fullScreen {
                iconButton("chevron.left", label: L10n.text("Exit Full Screen")) {
                    // 用控件层**自己**的 `fullScreen` 判断，不读页面状态：
                    // 两个状态一旦不同步，返回就会被解释成「离开页面」。
                    onExitFullScreen()
                }
            }
            // 转屏：**受布局控制**，不再是硬编码。
            //
            // 原来这一颗无条件画在返回键右边，`PlayerControl.rotate` 明明在枚举里、
            // 设置页也列得出、也能拖进「更多」—— 但顶栏这一颗永远在，
            // 于是「拖进更多」等于白拖（还多一份），「隐藏」更是不可能。
            //
            // 现在：用户把它排进顶栏 → 由 `topSlotRow` 按槽位画，这里不再兜底；
            // 排进「更多」→ 只在更多里出现；两处都没有（老配置没这一项）→ 才画这颗兜底，
            // 免得升级上来的用户失去转屏入口。
            // ⛔ 不能再带 `!fullScreen`。
            //
            // 全屏态三处都不给转屏入口：这里被 `!fullScreen` 关掉、`morePanel` 全屏不画、
            // `barControls` 又把 `.rotate` 排除在设置页之外 —— 于是**全屏里根本无法转屏**，
            // 只能先退全屏。而原先是无条件画这颗的，那是本批改出来的回归。
            // 全屏是最需要转屏的场景（横过来看宽银幕），这里必须留。
            if !controlsRotateElsewhere {
                iconButton("rectangle.landscape.rotate", label: L10n.text("Rotate")) { onRotate() }
            }
            // ⛔ 这里**不能**再套一层 `if !fullScreen`。
            //
            // `topSlotRow` 自己就是 `fullScreen ? layout.fullSurfaced : layout.watchSurfaced`。
            // 原来外面又包一层 `if !fullScreen`，于是全屏时这段整个不画 ——
            // `fullSurfaced` 分支**永远不可达**，设置页那张「Shown in Full Screen」
            // 勾选表对 One 皮肤是纯粹的谎：勾什么都看不到。
            //
            // 按**槽位**画：空槽保留一个热区宽度，控件才会落在用户排的那一格上。
            ForEach(Array(topSlotRow.enumerated()), id: \.offset) { _, control in
                if let control {
                    controlButton(control)
                } else {
                    Color.clear.frame(width: m.hit, height: m.hit)
                }
            }

            Spacer(minLength: 0)

            // 锁定：**兜底**结构位。
            //
            // 锁定后 `morePanel` / 顶栏控件全都不画（见 body 里的 `locked` 分支），
            // 所以它必须有一个「锁上之后仍然画得出来」的入口。
            // 老版本里它是无条件画在这里的 —— 那意味着用户永远动不了它。
            // 现在：用户把 `.lock` 排进顶栏并勾上可见，就按他的槽位画（`topSlotRow`
            // 不再过滤它），这里**不再重复补一颗**；哪都没排才补这颗兜底。
            if !topSlotRow.contains(.lock) {
                iconButton(locked ? "lock.fill" : "lock.open",
                           label: L10n.text(locked ? "Unlock Controls" : "Lock Controls")) {
                    // 锁定同样要先收面板：`morePanel` 在 `locked` 时不画，但 `showsMore` 还留着 true，
                    // 一解锁面板就自己弹出来。
                    if showsMore { closeMore() }
                    locked.toggle()
                    if locked { PlayerOrientation.lock() } else { PlayerOrientation.unlock() }
                }
            }
            // ⛔ 全屏态收掉「更多」菜单：它弹出的选集 / 画质 / 音轨 / 字幕 / 倍速 /
            // 外播 / 视频信息都是选集页的选项，全屏里点出来会叠在画面上，
            // 且命中区盖住下方的播放控制 —— 正是「全屏还夹带选集页菜单」的根因。
            // 上游全屏只留播放器自己的 transport（返回退全屏 / 播放 / 进度），
            // 没有任何页级菜单。
            if fullScreen {
                // ★ 全屏态：**不画完整菜单键**（`:739-743` 的上游语义），
                //   只在「确实有溢出」时画一颗**极小圆点**当出口。
                //
                // 全屏横（951）顶栏放 19 格、可用集 22 项里顶栏只需放 17 ⇒ 溢出 0
                //   ⇒ 这颗圆点**根本不出现**，界面与上游一致。
                // 全屏竖（669）顶栏只有 12 格 ⇒ 溢出 5（`speechSubtitles` / `adBlock` /
                //   `autoPlayNext` / `skipIntroAuto` / `skipIntroManual`）⇒ 圆点出现。
                //
                // 尺寸：视觉 12pt、热区 32pt。12pt 圆点约只占 16pt 宽，
                // 塞得进顶栏剩余边距，不挤掉任何一颗真控件。
                if fullScreenNeedsEntry {
                    Button { showsMore.toggle() } label: {
                        Circle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 12, height: 12)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.text("Playback Options")))
                }
            } else {
                // ⛔ 只留**一个**「更多」菜单。
                //
                // 原来这里并排两个：`moreMenu`（本页自己那套）与
                // `CatalogPlaybackActions`（上游那套）。两个按钮在 AX 里都叫
                // "Playback Options"，用户点到哪个全看运气，而且内容不一样 ——
                // 这就是「控件重复、功能重复」最直接的形态。
                //
                // 现在上游那四项（自动连播 / 更多本剧 / 自动跳片头片尾 / 跳过片头片尾）
                // 已经收进 `PlayerControl` 枚举，由 `moreItem` 统一渲染，
                // 顺带获得「在设置页里决定出不出现」的能力。
                moreMenu
            }
        }
        // 边距在 frame 之内：先缩内容再定宽，左右才真正贴窗口边缘。
        // 额外让开左右刘海 —— 横屏时它在左边，最左那颗返回键会整个陷进去。
        .padding(.leading, barLeading)
        .padding(.trailing, barTrailing)
        .frame(width: winW, height: m.barHeight)
        // 中心不能只按比例给：小窗（winH≈206）时 0.072×206≈15，
        // 半个 26pt 热区会顶出窗口上沿，图标看起来「缺了一条边」。
        // 贴屏幕顶时还要让开状态栏 —— 见 `topBarY`。
        .position(x: winW / 2, y: topBarY)
    }

    /// 顶栏留给用户控件的格数。
    ///
    /// 原来写死 `2`：用户在「设置 › 播放控件」里把画质 / 音轨 / 外播摆到顶栏，
    /// 第 3 颗起直接被 `.prefix(2)` 丢掉 —— 设置页勾了、顶栏上没有，
    /// 而且被丢掉的那颗**不报错**，看起来就是「设置不起作用」。
    ///
    /// 现在按**实际可用宽度**算：结构位（返回 / 全屏 / 旋转 / 合拢 / 锁定 / 更多）
    /// 先各占一个热区，剩下的宽度能塞几颗就放几颗，再把控件清单按用户排布过滤后取前 N 个。
    /// 窗口窄（小窗 / 折叠竖持）时 N 自然变小，不会挤成一团。
    private var topSurfaceCapacity: Int {
        // 结构位**不含返回键了**（2026-11-11 起选集页的退出键已移到页面层）。
        //
        // 实地清点 `topBar`（:667-765）真正画出的结构键，共 4 颗，各有独立门控：
        //   :679-680  `if fullScreen`                     退全屏
        //   :701-702  `if !controlsRotateElsewhere`        旋转
        //   :729-730  `if !topSlotRow.contains(.lock)`     锁定
        //   :744-755  `if !fullScreen`                     更多
        //
        // ⇒ 全屏 = 退全屏 + 旋转 = **2**（更多不画）
        //    非全屏 = 旋转 + 更多 +（锁定，除非锁已排进槽位）= **3 或 4**
        //
        // ⛔ 这里多减一个（非全屏一律按 4），顶栏就空出一个用不上的槽 ——
        //    用户把控件排进顶栏时会发现「勾了 3 颗只画出 2 颗」，且没有任何提示
        //    （正是本项目反复出现的「设置里排好了、播放器里是空槽」那一类）。
        //    用户的要求是「**尽量**显示全集」，所以锁已进槽时必须按 3 算。
        //
        // ⚠️ 旧注释写「旋转 + 合拢 + 更多 + 选集聚合 + 锁定 = 5 → 4」与代码不符：
        //    顶栏里**没有**合拢键、也**没有**选集聚合键（那两颗不在这段里）。已改准。
        //
        // `topSlotRow` 依赖 `layout`，而 `layout` 在用户从未配置时走标准布局
        // （`:449` `current` → `rawStored` → 空则 `standard`），所以这里不必特判
        // `hasOwnConfiguration`。
        let structural = fullScreen
            ? 2                                    // 退全屏 + 旋转
            : (topSlotRow.contains(.lock) ? 3 : 4) // 旋转 + 更多 +（锁定）
        let spare = winW - barLeading - barTrailing - CGFloat(structural) * m.hit
        return max(0, Int(spare / m.hit))
    }

    /// 顶栏的**槽位行**（含空槽），不是「过滤后的控件清单」。
    ///
    /// ⛔ 这里返回 `[PlayerControl?]` 而不是 `[PlayerControl]` 是关键：
    /// 原来用 `layout.top`（`compactMap` 之后）再 `ForEach`，**空槽被压掉了** ——
    /// 用户把「画质」放在第 7 格、第 1–6 格空着，播放器里它紧贴着左边第一颗出现。
    /// 设置页的预览按格画（有空格），播放器里却左移，用户看到的就是
    /// 「槽位调了没用 / 对不上」。现在空格照样占一个热区的宽度。
    ///
    /// 可见性仍由两个集合决定（设置页可改）：
    /// · 选集页 → `layout.watchSurfaced`
    /// · 全屏态 → `layout.fullSurfaced`
    /// 但**不再**把 `.lock` 滤掉：用户把它排进顶栏就按他的位置画
    /// （没排才补结构位那颗，见 `topBar`）。
    private var topSlotRow: [PlayerControl?] {
        let slots = Array(layout.topSlots.prefix(topSurfaceCapacity))
        // 末尾的空格不占位：只在「最后一个有内容的格子」之前保留空位，
        // 否则窄窗口里会被一串无意义的空格把控件挤出可视区。
        let end = (slots.lastIndex { $0 != nil } ?? -1) + 1
        return slots.prefix(end).map { slot in
            guard let control = slot, available(control), allowedHere(control) else { return nil }
            return control
        }
    }

    /// 全屏态顶栏放不下的那些（决定那颗小圆点画不画）。
    ///
    /// 与 `topOverflow` 同源，但多一道「全屏可用集」过滤 —— 因为
    /// `layout.top` 里可能排着全屏下不该出现的页级控件（它们已被 `allowedHere` 滤掉，
    /// 不该算进「溢出」，否则圆点会因为一项永远不显示的东西而常驻）。
    private var fullScreenNeedsEntry: Bool {
        guard fullScreen else { return false }
        // ⛔ 判据**不是**「顶栏有没有溢出」。
        //
        // 标准布局的 `layout.top` 只排了 2 项（`airPlay` / `episodes`），全屏滤掉
        // `episodes` 后只剩 1 项 —— 顶栏永远不溢出，按「顶栏溢出」判会让圆点**永不出现**，
        // 而 `layout.more` 里那 18 项（画质/音轨/字幕/倍速/弹幕/…）就**全部没有入口**。
        //
        // 正确判据：**抽屉里有没有东西要装**。有，就必须给入口。
        return !moreList.isEmpty
    }

    /// 顶栏**放不下**的控件 —— 自动收进「更多」，而不是被静默丢掉。
    ///
    /// 这是「一份排布适配三种形态」的关键：外屏顶栏只放得下 3–4 颗，
    /// 内屏横持能放 7 颗。用户只排一次，超出的部分在窄屏上出现在「更多」里，
    /// 到了宽屏又自动回到顶栏 —— 不需要为每个形态各排一遍。
    ///
    /// ⛔ 以前这里是 `prefix(capacity)` 直接截断，被截掉的控件不报错、不出现、
    /// 也找不到：用户看到的正是「设置里排好了，播放器里没有」。
    private var topOverflow: [PlayerControl] {
        layout.topSlots.dropFirst(topSurfaceCapacity)
            .compactMap { $0 }
            .filter(available)
    }

    /// 转屏这一项是否已经由用户摆在别处（顶栏槽位或「更多」里）。
    ///
    /// 用来决定顶栏那颗**兜底**转屏键要不要画 —— 只有当用户在哪都没排它时
    /// （典型是从旧版升上来、配置串里没有 rotate 这一项）才补一颗，
    /// 免得「升级后突然不能转屏了」。
    private var controlsRotateElsewhere: Bool {
        // 三处都要看。原来只看 top / more，于是用户把转屏摆到**底栏**时
        // 顶栏那颗兜底仍然画 —— 上下各一颗，顶栏那颗还删不掉。
        // `moreList` 含「放不下被收进更多」的那些：它们也能点到。
        layout.top.contains(.rotate) || layout.bottom.contains(.rotate) || moreList.contains(.rotate)
    }

    /// 底栏**槽位行**（含空槽）—— 与顶栏同一套「绝对定位」口径。
    ///
    /// ⛔ 这里曾经是 `layout.bottom`（`compactMap` 之后的清单），空槽被压掉：
    /// 用户把「播放暂停」排到第 9 格，它照样紧贴着左边第一颗 → 「槽位调了没用」。
    ///
    /// ⛔ 也曾经完全不读 `bottomSlots`（硬编码「时间码 + 进度条 + 剩余时间 + 全屏键」），
    /// 用户在设置页拖下来的控件一个都不出现。那一条已修，这里保持读槽位。
    private var bottomSlotRow: [PlayerControl?] {
        _ = layoutRaw
        let slots = layout.bottomSlots
        let end = (slots.lastIndex { $0 != nil } ?? -1) + 1
        return slots.prefix(end).map { slot in
            // `.lock` 例外：它锁上之后其它控件全不画，入口必须常在 ——
            // 底栏这颗只上锁不解锁（底栏在锁定态也不画），所以不让它进来。
            guard let control = slot, control != .lock, available(control),
                  allowedHere(control) else { return nil }
            return control
        }
    }

    /// 落在画面中央那一组的控件种类。
    ///
    /// One 的画面中间是「上一集 / 后退 10 / 播放 / 前进 10 / 下一集」，
    /// 底栏贴着进度条。这两处原来各自独立：中心是**硬编码**一组，
    /// 底栏又按 `bottomSlots` 画同一批 —— 屏幕上两颗播放键，
    /// 用户把播放键拖到别处，中间那颗也不动，也就是「视频播放器的控件调不了」。
    ///
    /// 现在统一：**传输类走中心的槽位行，其余（全屏 / 画质 / 转屏…）走底栏边缘**。
    /// 两处都保持用户排的槽位顺序与空格，任何一个控件都有明确的家。
    // 成员资格与设置页共用 `PlayerControl.centerControls`：那边把控件摘出顶栏时
    // 要按同一张表判断「它是回到中央、还是进更多」。
    private static var centerControlSet: Set<PlayerControl> { PlayerControl.centerControls }

    /// **全屏态下不出现**的控件。
    ///
    /// 依据 `:739-743` 那段设计（照上游 One）：全屏只留播放器自己的 transport，
    /// 页级菜单不许叠在画面上。下面这些要么是页级弹层、要么是进度行专用槽位：
    ///
    ///   · `episodes` / `moreInSeries` —— 打开选集/本剧列表（页级浮层，盖画面+盖控制）
    ///   · `anotherPlayer` —— 切到别的播放器 App（离开本页的页级动作）
    ///   · `markAd` —— 标注要帧比对 + 拖时间轴，必须在窗口态做
    ///   · `videoInfo` —— 它是左上角浮层（`infoLayer`），会叠在画面上
    ///   · `timecode` / `progressBar` / `remaining` —— 进度行专用，本来就不是按钮
    ///
    /// ⛔ `lock` 不在此列：它是 `fixedKeys`，本来就不进任何栏位与抽屉。
    ///
    /// 剔除这 8 项后，全屏可用集只剩 22 项 —— 全屏横（951）顶栏放 19 格、**溢出 0**；
    /// 全屏竖（669）顶栏只有 12 格、**溢出 5**（`speechSubtitles` / `adBlock` /
    /// `speechSubtitles` / `adBlock` / `autoPlayNext` / `skipIntroAuto` / `skipIntroManual`，
    /// 按默认布局顺序）。所以全屏竖仍需一个出口，见 `fullScreenOverflowDot`。
    ///
    /// ⛔ `videoInfo` **不排除**（2026-11-18 用户裁决：「语音字幕没有视频信息重要」）。
    ///
    /// 它虽是左上角浮层（`infoLayer`，会叠在画面上，本属该排除的那类），但用户明确
    /// 认为它比 `speechSubtitles` 重要，所以按**价值排序**保留它、让它进前 12 颗直接可点，
    /// 代价是 `speechSubtitles` 落到溢出位——仍可从抽屉点到，不是不可达。
    ///
    /// 先前一轮反向的取舍（排除 videoInfo 换 speechSubtitles 进前 12）已按用户裁决撤销。
    private static let fullScreenHidden: Set<PlayerControl> = [
        .episodes, .moreInSeries, .anotherPlayer, .markAd,
        .timecode, .progressBar, .remaining,
    ]

    /// 这个控件在当前形态下是否允许出现。
    private func allowedHere(_ control: PlayerControl) -> Bool {
        !(fullScreen && Self.fullScreenHidden.contains(control))
    }

    /// 中央那一组里的**实际控件**（已去空槽，保持用户排序）。
    ///
    /// ⛔ 这是 `centerSlotRow` 与中间排溢出**唯一共用的序列**。
    ///
    /// 曾经有过一个真 bug：`centerSlotRow` 在**含空槽**的序列上 `prefix(capacity)`，
    /// 而溢出计算在**去空槽**的序列上 `dropFirst(capacity)` —— 同一颗控件在两个
    /// 不同序列里取第 n 个，索引对不上。用户在两颗中间控件之间留了空槽时，
    /// 结果是「本该显示的少了一颗」+「本该在更多的被提前丢掉」/重复。
    ///
    /// 现在两者都从这里取，`prefix` / `dropFirst` 天然对齐。
    /// **空槽的占位语义仍然保留在 `centerSlotRow` 里**（那是布局，不是容量）——
    /// 用户留空槽是有意的（见 `topSlotRow` 那段「空槽照样占一个热区的宽度」）。
    private var centerItems: [PlayerControl] {
        bottomSlotRow.compactMap { $0 }.filter { Self.centerControlSet.contains($0) }
    }

    private var centerSlotRow: [PlayerControl?] {
        let mapped = bottomSlotRow.map {
            $0.flatMap { Self.centerControlSet.contains($0) ? $0 : nil }
        }
        // 末尾的空格**不占位**：`bottomSlotRow` 里还有时间码 / 进度条 / 剩余时间那几格，
        // 它们映射成 nil 后若留在末尾，中央这一组会被硬生生推偏半个屏。
        let end = (mapped.lastIndex { $0 != nil } ?? -1) + 1
        let trimmed = Array(mapped.prefix(end))
        // ⛔ 截断必须按「**含 N 个非空元素的最短前缀**」，不能直接 `.prefix(N)`。
        //
        // `trimmed` 里**保留着空槽**（用户留空槽是有意的，见 `topSlotRow` 那段），
        // 而 `centerSlotsToShow` 数的是**实际控件**。若直接 `.prefix(centerSlotsToShow)`，
        // 空槽会白占名额 ⇒ 画出的实际控件少于 `centerSlotsToShow`，
        // 而 `centerOverflow` 只 drop 掉 `centerSlotsToShow` 个 ⇒ 中间那几颗
        // **既没画出来、也没进更多**，等于凭空丢失。
        //
        // 正确：走到「第 centerSlotsToShow 个非 nil」为止（含它），空槽照样保留。
        var shown = 0
        var cut = 0
        for (i, slot) in trimmed.enumerated() {
            if slot != nil {
                shown += 1
                if shown == centerSlotsToShow { cut = i + 1; break }
            }
        }
        return cut == 0 ? [] : Array(trimmed.prefix(cut))
    }

    /// 中央那一组**实际画出来**的控制器数（= 共用的 show 数）。
    ///
    /// `centerSlotRow` 用它截断、`centerOverflow` 用它 dropFirst，**同一个数**。
    private var centerSlotsToShow: Int { min(centerItems.count, centerCapacity) }

    /// 中间排放不下、必须收进「更多」的那些。
    ///
    /// 与 `centerSlotRow` 严格互补：`centerItems.prefix(centerSlotsToShow)` 在栏上画，
    /// `centerItems.dropFirst(centerSlotsToShow)` 进更多 ⇒ 一颗不漏、一颗不重。
    private var centerOverflow: [PlayerControl] {
        Array(centerItems.dropFirst(centerSlotsToShow))
    }

    /// 底栏那一行里**真的画出来**的控件（按槽位顺序）。
    ///
    /// 进度条是**弹性宽度**（吃掉剩余空间），其余每件占一个热区。固定宽度的
    /// 件数超过 `edgeCapacity` 时，多出来的收进「更多」—— 它们不会凭空消失。
    ///
    /// 时间码 / 剩余时间 / 进度条本身就是这张表里的三项（`PlayerControl.timecode`
    /// 等），所以「进度条也能挪位置、也能删」不是特例，而是同一套槽位规则。
    private var bottomItems: [PlayerControl] {
        var fixedCount = 0
        var result: [PlayerControl] = []
        for control in bottomSlotRow.compactMap({ $0 }) where !Self.centerControlSet.contains(control) {
            if control == .progressBar { result.append(control); continue }
            // 全屏键是**结构位兜底**：即使排不下也要画（否则全屏就没有出口了）。
            // 它在这里占一格，但不因超编被丢进「更多」——否则底栏会同时出现
            // 「更多」里的全屏条目和右端那颗兜底键，等于两个入口。
            if control == .fullScreen { result.append(control); fixedCount += 1; continue }
            guard fixedCount < edgeCapacity else { continue }
            fixedCount += 1
            result.append(control)
        }
        return result
    }

    /// 中心那一组最多站得下几格。窗口越窄越少，多出来的收进「更多」。
    private var centerCapacity: Int {
        let usable = max(0, winW - 2 * m.edge)
        return max(1, Int(usable / max(m.stepHit, 1)))
    }

    /// 底栏进度条左侧最多站得下几颗。
    ///
    /// 要预留：时间码 + 剩余时间（两段等宽数字）+ 进度条最窄 120pt + 全屏兜底键。
    /// 扣完还剩几颗就画几颗，剩下的收进「更多」。
    private var edgeCapacity: Int {
        let reserve = m.caption * 15 + m.hit + 120
        let usable = max(0, winW - barLeading - barTrailing - reserve)
        return max(1, Int(usable / max(m.hit, 1)))
    }

    /// 底栏放不下、被收进「更多」的控件（中心与边缘两处合并）。
    private var bottomOverflow: [PlayerControl] {
        let all = bottomSlotRow.compactMap { $0 }
        let edge = all.filter { !Self.centerControlSet.contains($0) }
        let shown = Set(bottomItems)
        // 中间排的溢出走 `centerOverflow`（与 `centerSlotRow` 严格互补的共用序列），
        // 这里只再补上「边缘那些没被 `bottomItems` 收下的」。
        return centerOverflow + edge.filter { !shown.contains($0) }
    }

    /// 「更多」面板此刻真正要列出的控件 = 用户放进去的 + 各处放不下自动收进来的。
    ///
    /// 顺序保持用户排的先后，重复项去掉（同一个控件不会既在顶栏又在更多）。
    private var moreList: [PlayerControl] {
        var seen = Set<PlayerControl>()
        // 固定键（锁定）不进「更多」：它已经在右上角常驻，再列一条就是同一动作两个入口。
        return (layout.more + topOverflow + bottomOverflow)
            .filter { !PlayerControl.fixedKeys.contains($0) }
            // 全屏态：页级控件不进抽屉（`fullScreenHidden` 已解释）。
            .filter { allowedHere($0) }
            .filter { seen.insert($0).inserted }
    }

    /// 中央槽位行里每一格分到的宽度。控件多、窗口窄时按比例收，
    /// 免得一排小圆点挤出画面（`winW` 只有两百多的坞状小窗时确实会发生）。
    private var centerSlotWidth: CGFloat {
        let count = max(1, centerSlotRow.count)
        return min(m.playHit, max(m.stepHit, (winW - 2 * m.edge) / CGFloat(count)))
    }

    /// 当前上下文是否用得上这个控件（与 `MobilePlayerView.available` 同一套判断）。
    private func available(_ control: PlayerControl) -> Bool {
        guard let session else { return false }
        switch control {
        case .airPlay: return true
        case .episodes: return channel?.historyContext != nil
        // 这里只回答「这个皮肤有没有 PiP 这项能力」（= 平台支持 + 画面层已接 pip）。
        // 「此刻能不能点」是另一件事，由各自的 `.disabled` 读 `canToggle` 决定 ——
        // 见下面三处按钮：`supported` 恒真但 `possible` 还没就绪时，
        // 以前按钮是**亮着但点了没反应**（`startCurrent()` 的 guard 直接返回）。
        case .pictureInPicture: return kit.pip.supported
        case .miniPlayer, .pictureSize, .videoInfo, .anotherPlayer: return true
        // 广告标注：得真的在播（抓得到帧）、有时间轴、不是直播。
        case .markAd: return canMarkAd
        // 广告拦截是**总开关**，不依赖这条片源：任何时候都能开/关，
        // 关着的时候也能打开。所以它永远可用，不做内容守卫。
        case .adBlock: return true
        case .lock, .rotate: return true
        case .danmaku: return !session.danmaku.isEmpty
        case .quality: return session.qualities.count > 1
        case .audio: return session.audioChoices.count > 1 || (kit.tracks.audio?.options.count ?? 0) > 1
        case .subtitles: return !subtitleTracks.isEmpty || !(kit.tracks.legible?.options.isEmpty ?? true)
        case .speed: return !session.isLive
        case .speechSubtitles: return speechLanguage != nil
        case .backTen, .forwardTen: return seekable
        case .playPause, .fullScreen: return true
        // 进度行三件：时间码随时可显示；进度条与剩余时间依赖时间轴（直播没有）。
        case .timecode: return true
        case .progressBar, .remaining: return session.hasTimeline
        case .previousEpisode: return step(back: true) != nil
        case .nextEpisode: return step(back: false) != nil
        // 这四项来自上游那套菜单，收进枚举后一并给出可用性判据。
        case .autoPlayNext: return channel.flatMap { store.catalog(for: $0) } != nil
        case .moreInSeries: return channel?.historyContext != nil
        // 同 `MobilePlayer`：没有 `skipScope` 时 `applySkipSettings` 静默返回，
        // 开关点了会弹回，不如不显示。
        case .skipIntroAuto, .skipIntroManual: return !session.isLive && session.canPersistSkipSettings
        }
    }

    // MARK: - 中央播放组

    private var centerTransport: some View {
        let slots = centerSlotRow
        let slotW = centerSlotWidth
        let needsFallbackPlay = !slots.contains(.playPause) && !topSlotRow.contains(.playPause)
        return HStack(spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, control in
                Group {
                    if let control {
                        centerSlot(control)
                    } else {
                        // 空格照占一格 —— 否则「排在第 7 格」会被左移成第 1 颗。
                        Color.clear
                    }
                }
                .frame(width: slotW, height: m.playHit)
            }
            // 播放键兜底：顶栏与底栏槽位都没排它时，中间这一颗是唯一入口。
            if needsFallbackPlay {
                bigCircle(playing ? "pause.fill" : "play.fill") { session?.togglePlayback() }
                    .frame(width: slotW, height: m.playHit)
            }
        }
        .frame(width: winW, height: m.playHit)
        .position(x: winW / 2, y: winH * 0.496)
    }

    /// 中央一格里画什么。
    ///
    /// 传输类保持 One 的「中号小圆 / 大号播放键」两档；用户把别的控件
    /// （画质、字幕…）排进底栏槽位时，走与顶栏同一套 `controlButton`，
    /// 不会出现「排进去是一颗点不动的空白」。
    @ViewBuilder private func centerSlot(_ control: PlayerControl) -> some View {
        switch control {
        case .playPause:
            bigCircle(playing ? "pause.fill" : "play.fill") { session?.togglePlayback() }
        case .backTen:
            smallCircle("gobackward.10") { seek(by: -10) }
        case .forwardTen:
            smallCircle("goforward.10") { seek(by: 10) }
        case .previousEpisode:
            if let previous = step(back: true) {
                smallCircle("backward.end.fill") { previous.go() }
                    .disabled(previous.busy)
            }
        case .nextEpisode:
            if let next = step(back: false) {
                smallCircle("forward.end.fill") { next.go() }
                    .disabled(next.busy)
            }
        default:
            controlButton(control)
        }
    }

    // MARK: - 底部进度条

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // 按槽位顺序画：时间码 / 进度条 / 剩余时间 / 全屏 / 画质 / 转屏 …
            // 传输类（播放 / ±10 / 上下集）在画面中央那一行，见 `centerSlotRow`。
            ForEach(Array(bottomItems.enumerated()), id: \.offset) { _, control in
                bottomItem(control)
            }
            // ★ 只有在用户**哪里都没排**全屏键时才画这颗兜底键。
            //   排进去了就由槽位那一行按他的位置画，这里再画一颗
            //   就是「同一个功能两个按钮、还删不掉其中一颗」。
            if !bottomItems.contains(.fullScreen),
               !topSlotRow.contains(.fullScreen),
               !centerSlotRow.contains(.fullScreen) {
                iconButton(kit.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           label: kit.isFullScreen ? L10n.text("Exit Full Screen") : L10n.text("Full Screen")) {
                    kit.toggleFullScreen()
                }
            }
        }
        .font(.system(size: m.caption))
        .foregroundStyle(.white.opacity(0.82))
        // 与顶栏同一份边距、同一条对齐线（同样让开左右刘海）。
        .padding(.leading, barLeading)
        .padding(.trailing, barTrailing)
        .frame(width: winW, height: m.barHeight)
        // 同顶栏：小窗时 0.928 会把热区顶出下沿；
        // 窗口贴屏幕底时还要让开 Home 指示条 —— 见 `bottomBarY`。
        .position(x: winW / 2, y: bottomBarY)
    }

    /// 底栏一格里画什么。时间码 / 进度条 / 剩余时间各有专属形态，
    /// 其余控件走与顶栏同一套 `transportControl`。
    @ViewBuilder private func bottomItem(_ control: PlayerControl) -> some View {
        switch control {
        case .timecode:
            Text(clock(position)).monospacedDigit()
                .fixedSize()
                .padding(.trailing, 8)
        case .remaining:
            Text(remainText).monospacedDigit()
                .fixedSize()
        case .progressBar:
            seekTrack
        default:
            transportControl(control)
        }
    }

    /// 把进度行的一件放回底栏末尾。
    ///
    /// 直接写同一个 `@AppStorage` 键 —— 与设置页是同一份数据，
    /// 不需要为这一条动作单开一条通道。
    private func restoreToProgressRow(_ control: PlayerControl) {
        var updated = layout
        updated.setBottomOrder(updated.bottom + [control])
        layoutRaw = updated.stored
        if showsMore { closeMore() }
    }

    private var seekTrack: some View {
        GeometryReader { track in
            let barH = max(2, m.glyph * 0.18)
            let progress = scrubbing ? dragProgress : fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(height: barH)
                Capsule().fill(Color.white)
                    .frame(width: max(2, track.size.width * progress), height: barH)
                if scrubbing {
                    Circle().fill(Color.white)
                        .frame(width: barH * 3, height: barH * 3)
                        .offset(x: max(0, track.size.width * progress - barH * 1.5))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard seekable else { return }
                        scrubbing = true
                        dragProgress = min(max(v.location.x / max(track.size.width, 1), 0), 1)
                    }
                    .onEnded { _ in
                        defer { scrubbing = false }
                        guard seekable, duration > 0 else { return }
                        session?.seek(to: duration * dragProgress)
                    }
            )
        }
        .frame(maxWidth: .infinity, minHeight: m.hit, maxHeight: m.hit)
    }

    private var fraction: Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var remainText: String {
        guard duration.isFinite, duration > 0 else { return "" }
        return "-" + clock(max(duration - position, 0))
    }

    private var unlockButton: some View {
        Button {
            locked = false
            PlayerOrientation.unlock()
        } label: {
            Image(systemName: "lock.fill")
                // 以前写死 max(12, iconFont)，小窗时比所有图标都大一号 ——
                // 它只是「锁定」的另一副面孔，就该和锁定图标一样大。
                .font(.system(size: opticalSize("lock.fill", base: m.glyph), weight: .medium))
                .padding(.horizontal, m.glyph * 1.2).padding(.vertical, m.glyph * 0.8)
                .background(.black.opacity(0.55), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("Unlock Controls"))
        .frame(width: winW, height: winH, alignment: .topLeading)
        .padding(m.edge * 2)
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - 更多菜单

    private var moreMenu: some View {
        // ⛔ 这里**不用系统 `Menu`**，改成「一颗按钮 + 本层自绘面板」。
        //
        // 用户报的是：「更多里面会一直导致菜单刷新，按钮下滑不到可视范围，点不到」。
        // 根因不是某一条目的判定条件（上一轮把 `canMarkAd` 里的 position 拿掉只治了一半），
        // 而是**容器本身**：系统 `Menu` 的内容归 UIKit 管，而这一层 `body` 每秒都在
        // 因 `position` 变化重算 —— 每次重算都会重建一次 `Menu` 的内容树，
        // UIKit 于是把它当成「菜单内容变了」，把已经展开的那张表重新配置一遍。
        // 表现就是：表一直在跳、滚不到底、「标注广告」那种排在最后的条目点不中。
        //
        // 自绘面板没有这个问题：它就是本层的一个普通 `ScrollView`，
        // 父视图重算不会重置它的滚动位置，也不会把它收起来。
        Button {
            withAnimation(.easeOut(duration: 0.16)) { showsMore.toggle() }
        } label: {
            chromeIcon("ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("Playback Options"))
        .accessibilityIdentifier("player.oneskinOptions")
    }

    /// 「更多」面板本体 —— 挂在窗口坐标系里的一层，不进系统菜单。
    ///
    /// 为什么必须是**滚动**面板：控件表有十九项（`layout.more` 可以全部收在这里），
    /// 竖屏选集页的窗口只有 ~244pt 高，一屏放不下。系统菜单滑动会被上面的重绘打断；
    /// 自绘 `ScrollView` 不会。
    @ViewBuilder private var morePanel: some View {
        // 全屏也允许打开（入口是那颗小圆点，见顶栏）。页级控件已被
        // `fullScreenHidden` 滤掉，所以抽屉里只有「全屏下有意义」的那些。
        if showsMore, !locked, showsTransport {
            // 底部抽屉：从画面下沿升起，向上长高（`.bottom` 对齐）。
            ZStack(alignment: .bottom) {
                // 点空白处关闭。遮罩不做全黑：画面还要看得见。
                Color.black.opacity(0.24)
                    .contentShape(Rectangle())
                    .onTapGesture { closeMore() }
                    // 下滑关闭：抽屉的通用手势语言，比只点遮罩更直觉。
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                if value.translation.height > 44 { closeMore() }
                            }
                    )

                VStack(spacing: 0) {
                    // 标题行：左「更多」，右关闭键。
                    HStack(spacing: 0) {
                        Text(L10n.text("Playback Options"))
                            .font(.system(size: m.caption, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 6)
                        Button { closeMore() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: m.caption, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Close"))
                    }
                    .padding(.leading, 12).padding(.trailing, 2).padding(.top, 2)
                    Divider().overlay(Color.white.opacity(0.22))

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visibleMoreGroups.enumerated()), id: \.offset) { _, group in
                                // ⛔ 这一行原本是 `.white.opacity(0.45)`，压在
                                //    `.black.opacity(0.80)` 的半透明底上 —— 实测对比度
                                //    3.90:1（纯白画面）～4.48:1（中灰），**低于 WCAG AA
                                //    正文 4.5:1**。先把底色改成不透明近黑（底不再随帧变），
                                //    再把字提到 0.80：现在是 10.54:1，任何画面下一致。
                                Text(group.title.uppercased())
                                    .font(.system(size: max(11, m.caption), weight: .bold))
                                    .foregroundStyle(.white.opacity(0.80))
                                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                                ForEach(group.controls) { control in
                                    moreRow(control)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                // ★ 尺寸自适应（不写死高度）：
                //   · 宽度：窄窗（外屏竖持 winW=428）时吃满窗口、留边距；
                //           宽窗（全屏横 951 / 内屏竖持 673）时封顶，避免一行太长要横扫。
                //   · 高度：内容多则长，但不超过容器的 62%（留出上方画面，用户要看得见在播什么）。
                //   · 超出即滚：`ScrollView` 已在下面，`maxHeight` 只是给它一个上界。
                .frame(width: min(winW - m.edge * 2, max(300, winW * 0.72)))
                .frame(maxHeight: max(160, min(winH * 0.62, winH - m.edge * 2)))
                // 纯色底 + 细边：材质压在运动画面上每帧重绘，与 `PlaybackInfoPanel` 同理。
                // ⛔ 半透明底是「字看不清」的根：画面从后面透上来，
                //    底色随每一帧在变，细字既被抖糊、对比度也压不住。
                //    0.80 时白字 0.45 只有 3.90:1（低于 WCAG 正文 4.5:1）；
                //    0.90 时仍会透 10%，只是把问题减轻。⇒ 直接改成**不透明**近黑：
                //    底固定不动，字在任何画面下都是同一组对比度。
                // 底部抽屉：只圆上面两角（下沿贴屏幕边，圆角会让它看起来「浮着」）。
                .background(Color(white: 0.07),
                            in: UnevenRoundedRectangle(topLeadingRadius: max(12, m.glyph * 0.9),
                                                       topTrailingRadius: max(12, m.glyph * 0.9),
                                                       style: .continuous))
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: max(12, m.glyph * 0.9),
                                           topTrailingRadius: max(12, m.glyph * 0.9),
                                           style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
                // 只留顶部与左右内边距，**底边贴齐**（抽屉语义）。
                .padding(.horizontal, m.edge)
                .padding(.bottom, 0)
            }
            .frame(width: winW, height: winH)
        }
    }

    private func closeMore() {
        withAnimation(.easeOut(duration: 0.16)) { showsMore = false }
    }

    /// 「更多」里按分组切好的可见条目，已按 `moreList` 的先后排好序。
    ///
    /// 分组的**成员资格**来自 `PlayerControl.capabilityGroups` —— 与设置页调色板
    /// 同一张表。以前这里另有一份写死的表，两边一旦不同步就会出现
    /// 「设置里能摆、这里没有对应分支」的死条目。
    private var visibleMoreGroups: [(title: String, controls: [PlayerControl])] {
        let groups = PlayerControl.capabilityGroups.map { (title: $0.title, controls: $0.controls) }
        let order = moreList
        return groups.compactMap { title, members in
            let shown = members.filter { order.contains($0) }
                .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            return shown.isEmpty ? nil : (title: title, controls: shown)
        }
    }

    /// 「更多」里的**单条**控件。所有条目集中在这里，一处定义、一处改。
    ///
    /// 以前同样的功能在四个 `Section` 里各写一遍，和顶栏的槽位行
    /// 又是另一套 —— 同一个「倍速」有三处实现。现在只留这一份。
    /// 每个分支都自带「没有这个能力就不画」的守卫（直播没有倍速、单轨没有音轨菜单…），
    /// 因此空守卫不会留下死条目。
    @ViewBuilder private func moreItem(_ control: PlayerControl) -> some View {
        switch control {
        case .episodes:
            Button { kit.openEpisodes() } label: {
                Label(L10n.text("Episodes"), systemImage: "list.bullet.rectangle")
            }
        case .previousEpisode:
            if let previous = step(back: true) {
                Button { previous.go() } label: {
                    Label(L10n.text("Previous Episode"), systemImage: "backward.end.fill")
                }
                .disabled(previous.busy)
            }
        case .nextEpisode:
            if let next = step(back: false) {
                Button { next.go() } label: {
                    Label(L10n.text("Next Episode"), systemImage: "forward.end.fill")
                }
                .disabled(next.busy)
            }
        case .rotate:
            Button { onRotate() } label: {
                Label(L10n.text("Rotate"), systemImage: "rectangle.landscape.rotate")
            }
        case .lock:
            Button {
                // 与顶栏那颗锁定键同一处理：先收面板，否则解锁后它会自己弹回来。
                if showsMore { closeMore() }
                locked = true
                PlayerOrientation.lock()
            } label: {
                Label(L10n.text("Lock Controls"), systemImage: "lock")
            }
        case .pictureInPicture:
            Button { kit.pip.toggle() } label: {
                Label(kit.pip.active ? L10n.text("Leave Picture in Picture") : L10n.text("Picture in Picture"),
                      systemImage: kit.pip.active ? "pip.exit" : "pip.enter")
            }
            // 只在「此刻真能起浮」时可点（`possible || active`）：画面层还没登记完时
            // 按钮灰掉，而不是亮了却点不动。
            .disabled(!kit.pip.canToggle)
        case .miniPlayer:
            Button { kit.miniPlayer() } label: {
                Label(L10n.text("Mini Player"), systemImage: "rectangle.inset.bottomright.filled")
            }
        case .anotherPlayer:
            if let channel {
                Button { externalStream = OneSkinHandoff(url: channel.url) } label: {
                    Label(L10n.text("Open in Another Player"), systemImage: "play.rectangle.on.rectangle")
                }
            }
        case .markAd:
            // ── 广告标注 ──
            //
            // 只在**真的在播**时给入口：标注要抓这前后若干秒的画面算指纹，
            // 加载中/报错时抓不到有效帧。
            //
            // 交互刻意做成「从这里往回标 30 秒」而不是让用户拖区间：
            // 典型用法是「广告出现了 → 我发现了 → 往回标」，此时广告正好
            // 在身后这段。30 秒覆盖绝大多数贴片广告，太短抓不全、太长会带进正片。
            //
            // 它现在是枚举里的一项（`PlayerControl.markAd`），所以设置页里能隐藏、
            // 也能拖到控制栏 —— 原先写死在这个分支里，两头都做不到。
            // 主入口：直接在画面上剪（拖两根手柄，边拖边看那一帧）。
            if canMarkAd {
                Button {
                    closeMore()
                    showsAdTrim = true
                } label: {
                    Label(L10n.text("Trim the Ad Here"), systemImage: "timeline.selection")
                }
            }
            // 次要：需要精确敲时间码 / 管理本集已标段时用表单版。
            if canMarkAd {
                Button {
                    closeMore()
                    showsAdRange = true
                } label: {
                    Label(L10n.text("Mark Ad Range…"), systemImage: "megaphone")
                }
            }
            // 「快标」：确实什么都不想填的时候，退回原来那条猜边界的路。
            // 两条都在，是因为场景不同——广告刚开始、用户只想点一下就完事时
            // 让他填两个时间点是负担；猜歪了他再用上面那条纠。
            if canMarkAd {
                Button {
                    closeMore()
                    Task { await markAdHere() }
                } label: {
                    Label(markingAd ? L10n.text("Marking…") : L10n.text("Mark This as an Ad"),
                          systemImage: "megaphone.fill")
                }
                .disabled(markingAd)
            }
        case .quality:
            if let session, session.qualities.count > 1 {
                Menu { QualityPicker(session: session) } label: {
                    Label(L10n.text("Quality"), systemImage: "sparkles.tv")
                }
            }
        case .pictureSize:
            Menu {
                Picker(L10n.text("Picture Size"), selection: Binding(get: { scaling }, set: { scalingRaw = $0.rawValue })) {
                    ForEach(PictureScaling.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: { Label(L10n.text("Picture Size"), systemImage: "arrow.up.left.and.arrow.down.right") }
        case .audio:
            if session.map({ $0.audioChoices.count > 1 }) == true || (kit.tracks.audio?.options.count ?? 0) > 1 {
                Menu { audioPicker } label: { Label(L10n.text("Audio"), systemImage: "speaker.wave.2") }
            }
        case .subtitles:
            if !subtitleTracks.isEmpty || !(kit.tracks.legible?.options.isEmpty ?? true) {
                Menu { subtitlePicker } label: { Label(L10n.text("Subtitles"), systemImage: "captions.bubble") }
            }
        case .speed:
            if let session, !session.isLive {
                Menu {
                    // ── 常驻播放倍速：选了就一直生效，直到改回来 ──
                    Picker(L10n.text("Playback Speed"), selection: Binding(
                        get: { session.speed },
                        set: { session.setSpeed($0); persistedSpeed = Double($0) })) {
                        ForEach(Self.speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline)

                    Divider()

                    // ── 长按加速倍率：只在按住期间生效，松手复原 ──
                    //
                    // 与上面那项是**两套独立设置**，写不同的键：
                    //   · 播放倍速 → session.setSpeed，跟着会话走
                    //   · 长按倍率 → `SpeedBoost.key`，跟手势走
                    // 之前长按倍率只能去「设置 → 播放 → Touch and Hold Speed」改，
                    // 播到一半想调档要退出播放页，这里补上就地入口。
                    Picker(L10n.text("Touch and Hold Speed"), selection: $holdSpeed) {
                        ForEach(SpeedBoost.startRates, id: \.self) { rate in
                            Text(speedLabel(Float(rate))).tag(rate)
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Label(L10n.text("Playback Speed"), systemImage: "gauge.with.needle") }
            }
        case .danmaku:
            if session.map({ !$0.danmaku.isEmpty }) == true {
                Toggle(isOn: $danmakuOn) { Label(L10n.text("Danmaku"), systemImage: "text.bubble") }
                Picker(selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                .pickerStyle(.menu)
                Button { showsDanmakuList = true } label: {
                    Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle")
                }
            }
        case .speechSubtitles:
            Button { Task { await toggleSpeechSubtitles() } } label: {
                Label(L10n.text("Write Subtitles From the Sound"),
                      systemImage: speechState.generating ? "waveform.badge.mic" : "waveform")
            }
            .disabled(speechState.generating)
        case .videoInfo:
            Toggle(isOn: $showsInfo) {
                Label(L10n.text("Show Video Info"), systemImage: "info.circle")
            }
            // One 的 `showPlaybackStats` 与视频信息卡是**两个**开关：一个看码率/分辨率，
            // 一个只看起播四段耗时。并排放在同一组里，别混成一个。
            Toggle(isOn: $showsPlaybackStats) {
                Label("起播耗时", systemImage: "stopwatch")
            }
        case .airPlay:
            if let channel, let session {
                PlayOnButton(channel: channel, session: session, browser: playOn) { _ in }
            }
        case .autoPlayNext:
            Toggle(isOn: Binding(get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 })) {
                Label(L10n.text("Auto-play next episode"), systemImage: "play.circle")
            }
        case .moreInSeries:
            Button { showsSeries = true } label: {
                Label(L10n.text("More in This Series"), systemImage: "rectangle.stack")
            }
        case .skipIntroAuto:
            Toggle(isOn: Binding(
                get: { session?.skipSettings.enabled ?? false },
                set: { value in
                    guard let session else { return }
                    var settings = session.skipSettings
                    settings.enabled = value
                    session.applySkipSettings(settings)
                })) {
                Label(L10n.text("Automatically skip intro and outro"), systemImage: "forward.end.alt")
            }
        case .adBlock:
            // ── 广告拦截总开关 ──
            //
            // 与 `.markAd` 是两件事：那条是「把这一段记下来」，这条是
            // 「以后认出这类画面就自动跳过」。开关真身在 `AdSkip.key`
            //（`player.skipAds`），设置页与这里写的是同一个键，改一边两边同步。
            //
            // 它此前**只**在「设置 › 播放 › 广告跳过」里有入口 ——
            // `PlayerControl` 里没有这一项，所以播放器里根本摆不出这个按钮，
            // 用户看到的就是「广告拦截我设置不了」。
            Toggle(isOn: $skipsAds) {
                Label(skipsAds ? L10n.text("Ad Blocking On") : L10n.text("Ad Blocking Off"),
                      systemImage: skipsAds ? "shield.lefthalf.filled" : "shield.slash")
            }
            .toggleStyle(.switch)
        case .skipIntroManual:
            Button { showsSkip = true } label: {
                Label(L10n.text("Skip intro / outro"), systemImage: "forward.end")
            }
        case .timecode, .progressBar, .remaining:
            // 它们不是按钮，放进「更多」等于藏起来。给一条明确的回头路，
            // 而不是让用户只看到「拖进去就没了」。
            Button { restoreToProgressRow(control) } label: {
                Label(L10n.text("Show %@ on the Progress Row", control.title),
                      systemImage: control.symbol)
            }
        case .playPause, .backTen, .forwardTen:
            // 这三个是**传输类**控件，正常情况下由 `bottomBar` 独占渲染。
            // 但用户可以把它们拖进「更多」—— 那时必须给一条带文字的菜单项，
            // 否则就是「拖进更多 = 凭空消失」。原来这里一律 `EmptyView()`。
            Button {
                switch control {
                case .playPause: session?.togglePlayback()
                case .backTen: seek(by: -10)
                default: seek(by: 10)
                }
            } label: {
                Label(L10n.text(control.title), systemImage: control.symbol)
            }
        case .fullScreen:
            // 全屏键同理：全屏态本来就不画「更多」（菜单整个收掉），
            // 所以这一条只会在选集页出现，点它就是进全屏。
            Button { kit.toggleFullScreen() } label: {
                Label(L10n.text(control.title), systemImage: control.symbol)
            }
        }
    }

    /// 「更多」里的一行。自绘面板没有系统菜单的行样式，这里统一给。
    ///
    /// 只给**外观**，行为仍在 `moreItem` 里 —— 那样顶栏、底栏、更多三处
    /// 用的是同一份动作实现，不会因为「这里补了、那里没补」而分叉。
    @ViewBuilder private func moreRow(_ control: PlayerControl) -> some View {
        HStack(spacing: 8) {
            moreItem(control)
            Spacer(minLength: 0)
        }
        .font(.system(size: max(11, m.caption * 1.08)))
        .foregroundStyle(.white)
        .tint(.white)
        .frame(minHeight: 34)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    /// 这四项的图标形态：开/关两种状态直接反映在图标上，
    /// 顶栏、底栏、更多三处共用这一份判断。
    private func symbolFor(_ control: PlayerControl) -> String {
        switch control {
        case .autoPlayNext:
            return store.autoPlayNext ? "play.circle.fill" : "play.circle"
        case .moreInSeries:
            return "rectangle.stack"
        case .skipIntroAuto:
            return (session?.skipSettings.enabled ?? false) ? "forward.end.alt.fill" : "forward.end.alt"
        case .skipIntroManual:
            return "forward.end"
        default:
            return control.symbol
        }
    }

    /// 图标形态按下去做的事 —— 与「更多」里同名条目一一对应。
    private func perform(_ control: PlayerControl) {
        switch control {
        case .autoPlayNext:
            store.autoPlayNext.toggle()
        case .moreInSeries:
            showsSeries = true
        case .skipIntroAuto:
            guard let session else { return }
            var settings = session.skipSettings
            settings.enabled.toggle()
            session.applySkipSettings(settings)
        case .skipIntroManual:
            showsSkip = true
        default:
            break
        }
    }

    @ViewBuilder private func playerSection() -> some View {
        Section(L10n.text("Playback")) {
            Button { kit.openEpisodes() } label: { Label(L10n.text("Episodes"), systemImage: "list.bullet.rectangle") }
            if let previous = step(back: true) {
                Button { previous.go() } label: { Label(L10n.text("Previous Episode"), systemImage: "backward.end.fill") }
                    .disabled(previous.busy)
            }
            if let next = step(back: false) {
                Button { next.go() } label: { Label(L10n.text("Next Episode"), systemImage: "forward.end.fill") }
                    .disabled(next.busy)
            }
            Button { kit.pip.toggle() } label: {
                Label(kit.pip.active ? L10n.text("Leave Picture in Picture") : L10n.text("Picture in Picture"),
                      systemImage: kit.pip.active ? "pip.exit" : "pip.enter")
            }
            // 只在「此刻真能起浮」时可点（`possible || active`）：画面层还没登记完时
            // 按钮灰掉，而不是亮了却点不动。
            .disabled(!kit.pip.canToggle)
            Button { kit.miniPlayer() } label: {
                Label(L10n.text("Mini Player"), systemImage: "rectangle.inset.bottomright.filled")
            }
            // 投屏：DLNA 接收端一列 + AirPlay，与旧播放器同一个 `PlayOnButton`
            // （发送、失败提示、进度都在它内部，不在这里重写一遍）。
            if let channel, let session {
                PlayOnButton(channel: channel, session: session, browser: playOn) { _ in }
            }
            Button { onRotate() } label: { Label(L10n.text("Rotate"), systemImage: "rectangle.landscape.rotate") }
        }
    }

    @ViewBuilder private var pictureSection: some View {
        Section(L10n.text("Picture")) {
            if let session, session.qualities.count > 1 {
                Menu { QualityPicker(session: session) } label: { Label(L10n.text("Quality"), systemImage: "sparkles.tv") }
            }
            Menu {
                Picker(L10n.text("Picture Size"), selection: Binding(get: { scaling }, set: { scalingRaw = $0.rawValue })) {
                    ForEach(PictureScaling.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: { Label(L10n.text("Picture Size"), systemImage: "arrow.up.left.and.arrow.down.right") }

            if session.map({ !$0.danmaku.isEmpty }) == true {
                Toggle(isOn: $danmakuOn) { Label(L10n.text("Danmaku"), systemImage: "text.bubble") }
                Picker(selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                .pickerStyle(.menu)
                // 弹幕列表：找一条刚才飘过去的评论，只有列表能做到。
                Button { showsDanmakuList = true } label: {
                    Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle")
                }
            }
            // 画质增强：旧播放器与设置页都有，One 页此前没有入口。
            // 只在设备**真的支持**时出现（模拟器没有这些处理器，iOS 26 以下也没有）。
            if VideoEnhancement.canUpscale {
                Toggle(isOn: $upscalesVideo) { Label(L10n.text("Sharper Picture"), systemImage: "wand.and.sparkles") }
            }
            if VideoEnhancement.canSmooth {
                Toggle(isOn: $smoothsVideo) { Label(L10n.text("Smooth Motion"), systemImage: "square.3.layers.3d") }
            }
        }
    }

    @ViewBuilder private var soundSection: some View {
        Section(L10n.text("Sound and Subtitles")) {
            if let session, !session.isLive {
                Menu {
                    Picker(L10n.text("Playback Speed"), selection: Binding(get: { session.speed },
                                                                            set: { session.setSpeed($0); persistedSpeed = Double($0) })) {
                        ForEach(Self.speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label(L10n.text("Playback Speed"), systemImage: "gauge.with.needle") }
            }
            if session.map({ $0.audioChoices.count > 1 }) == true || (kit.tracks.audio?.options.count ?? 0) > 1 {
                Menu { audioPicker } label: { Label(L10n.text("Audio"), systemImage: "speaker.wave.2") }
            }
            if !subtitleTracks.isEmpty || !(kit.tracks.legible?.options.isEmpty ?? true) {
                Menu { subtitlePicker } label: { Label(L10n.text("Subtitles"), systemImage: "captions.bubble") }
            }
        }
    }

    @ViewBuilder private var linkSection: some View {
        if let channel {
            Section(L10n.text("Link")) {
                Button {
                    UIPasteboard.general.string = channel.url.absoluteString
                } label: { Label(L10n.text("Copy Video Link"), systemImage: "doc.on.doc") }
                Button { externalStream = OneSkinHandoff(url: channel.url) } label: {
                    Label(L10n.text("Open in Another Player"), systemImage: "play.rectangle.on.rectangle")
                }
            }
        }
    }

    @ViewBuilder private var audioPicker: some View {
        if let audio = kit.tracks.audio, audio.options.count > 1 {
            Picker(L10n.text("Audio"), selection: Binding(get: { kit.tracks.selected(in: audio) },
                                                        set: { kit.tracks.select($0, in: audio) })) {
                ForEach(audio.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } else if let session, session.audioChoices.count > 1 {
            Picker(L10n.text("Audio"), selection: Binding(get: { session.audioChoice },
                                                        set: { if let id = $0 { session.chooseAudio(id) } })) {
                ForEach(session.audioChoices) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
        }
    }

    @ViewBuilder private var subtitlePicker: some View {
        if !subtitleTracks.isEmpty {
            Picker(L10n.text("Subtitles"), selection: Binding(
                get: { chosenSubtitle },
                set: { new in
                    chosenSubtitle = new
                    subtitlesChosen = true
                }
            )) {
                Text(L10n.text("Off")).tag(String?.none)
                ForEach(subtitleTracks) { track in
                    Text(track.language.isEmpty ? track.name : "\(track.name) · \(track.language)")
                        .tag(Optional(track.id))
                }
            }
            .pickerStyle(.inline)
        } else if let legible = kit.tracks.legible, !legible.options.isEmpty {
            Picker(L10n.text("Subtitles"), selection: Binding(get: { kit.tracks.selected(in: legible) },
                                                            set: { kit.tracks.select($0, in: legible) })) {
                if legible.group.allowsEmptySelection { Text(L10n.text("Off")).tag(AVMediaSelectionOption?.none) }
                ForEach(legible.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        }
    }

    // MARK: - 字幕与片头片尾

    private var activeSubtitle: SubtitleTrack? {
        // 从没显式选过 → 不显示任何字幕（One 的默认是关，除非用户主动开）。
        guard subtitlesChosen else { return nil }
        guard let id = chosenSubtitle else { return nil }
        return subtitleTracks.first { $0.id == id }
    }

    @ViewBuilder private var subtitleLayer: some View {
        // 进画中画时自绘层进不去悬浮窗，字幕交还 AVPlayer 自己画（见 MobilePlayer 的同一条规则）。
        if !PictureInPicture.isActive {
            Mi3sSubtitleOverlay(track: activeSubtitle,
                                position: position,
                                style: $subtitleStyle,
                                positionKey: channel?.url.absoluteString,
                                memory: $subtitlePositions)
                .frame(width: winW, height: winH)
        }
    }

    private var itemIdentity: String {
        if let item = session?.player.currentItem { return String(ObjectIdentifier(item).hashValue) }
        return ""
    }
    private var skipKey: String {
        "\(channel?.url.absoluteString ?? ""):\(Int(duration))"
    }

    private func loadSubtitles() async {
        if let style = try? JSONDecoder().decode(Mi3sSubtitleStyle.self, from: subtitleStyleData) {
            subtitleStyle = style.sanitized
        }
        if let memory = try? JSONDecoder().decode(SubtitlePositionMemory.self, from: subtitlePositionsData) {
            subtitlePositions = memory
        }
        let remembered = subtitlePositions.position(for: channel?.url.absoluteString)
        subtitleStyle.centerX = remembered.x
        subtitleStyle.centerY = remembered.y

        let files = channel?.subtitles ?? []
        guard !files.isEmpty else { subtitleTracks = []; return }
        // 换集前记住用户的选择意图：选了具体字幕就按「语言」重定位到新集对应轨，
        // 语言稳定的（id 里 `name` 是文件名每集不同，`language` 才是跨集稳定的标识）。
        // 否则换集后 chosenSubtitle 还是旧集 id，`first{ id }` 匹配不到 → 字幕凭空消失。
        let wantedLanguage = subtitlesChosen ? chosenSubtitle.flatMap { id in
            subtitleTracks.first { $0.id == id }?.language
        } : nil
        let loaded = await SubtitleTrack.loadAll(files, headers: channel?.headers ?? [:])
        subtitleTracks = loaded
        if let wantedLanguage {
            chosenSubtitle = loaded.first { $0.language == wantedLanguage }?.id
        }
        // 自绘层在画的时候，播放器不能再画自己那份，否则双行。
        if !loaded.isEmpty, let group = kit.tracks.legible { kit.tracks.select(nil, in: group) }
    }

    private func saveSubtitleStyle() {
        if let blob = try? JSONEncoder().encode(subtitleStyle.sanitized) { subtitleStyleData = blob }
    }

    private func tracksTask() async {
        await kit.tracks.load(session?.player.currentItem)
    }

    /// 片头/片尾：只认「懂这个文件」的来源（用户自己的标记 + 文件章节）。
    private func loadSkipMarkers() async {
        skipSegment = nil
        skipCredits = nil
        guard let session, let channel, duration > 0 else { return }
        var intro: [SkipSegmentSources.Source: SkipSegmentSources.Segment] = [:]
        var credits: [SkipSegmentSources.Source: SkipSegmentSources.Segment] = [:]

        if store.skipSources.isActive(.manual), let scope = channel.skipScope {
            let settings = EpisodeSkipSettings.load(scope: scope)
            if settings.introEnd > 0 {
                intro[.manual] = .init(kind: .intro, start: 0, end: settings.introEnd)
            }
            if settings.outroLength > 0, duration > settings.outroLength {
                credits[.manual] = .init(kind: .credits, start: duration - settings.outroLength, end: duration)
            }
        }
        if store.skipSources.isActive(.mediaServer),
           let item = session.player.currentItem,
           let chapters = chapterSegment(of: item) {
            intro[.mediaServer] = chapters
        }
        if let chosen = store.skipSources.choose(kind: .intro, duration: duration, reported: intro) {
            skipSegment = chosen.segment
            skipFileLevel = chosen.source.isFileLevel
        }
        if let chosen = store.skipSources.choose(kind: .credits, duration: duration, reported: credits) {
            skipCredits = chosen.segment
            skipFileLevel = skipFileLevel || chosen.source.isFileLevel
        }
    }

    private func chapterSegment(of item: AVPlayerItem) -> SkipSegmentSources.Segment? {
        let groups = item.asset.chapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        guard groups.count >= 3, let first = groups.first else { return nil }
        let start = first.timeRange.start.seconds
        let length = first.timeRange.duration.seconds
        guard start.isFinite, length.isFinite, length > 3 else { return nil }
        return .init(kind: .intro, start: start, end: start + length)
    }

    private var currentSkipSegment: SkipSegmentSources.Segment? {
        if let credits = skipCredits, position >= credits.start, position < credits.end { return credits }
        return skipSegment
    }

    @ViewBuilder private var skipLayer: some View {
        if let segment = currentSkipSegment {
            VStack {
                Spacer(minLength: 0)
                SkipSegmentButton(segment: segment, position: position, isFileLevel: skipFileLevel) {
                    session?.seek(to: segment.end)
                }
                .padding(.bottom, max(m.hit * 0.7, winH * 0.16))
            }
            .frame(width: winW, height: winH)
            .allowsHitTesting(!locked)
        }
    }

    // MARK: - 卡顿看门狗

    /// 一条线悄悄死掉时不会报错，只是位置一秒都不再动 —— 只有看门狗能发现。
    ///
    /// 提示做成**压在画面下沿的一条细胶囊**，不是弹窗：画面还在，用户能自己判断；
    /// 进度一旦恢复它就自己消失。点它打开选集抽屉 —— 抽屉里有**这个源的全部线路**
    /// （带健康度），这才是「换一条线」真正能落地的地方。
    /// 旧播放器在这里写过「正在切换…」而背后没有任何代码，那条谎言不再复制。
    @ViewBuilder private var stallNotice: some View {
        if clock.stalled, showsTransport {
            VStack {
                Spacer(minLength: 0)
                Button { kit.openEpisodes() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: m.caption))
                        Text(L10n.text("This line has stopped. Choose another line"))
                            .font(.system(size: m.caption))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.66), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.bottom, max(m.hit * 1.4, winH * 0.18))
                .accessibilityIdentifier("player.stalled")
            }
            .frame(width: winW, height: winH)
            .allowsHitTesting(!locked)
            .animation(.easeOut(duration: 0.2), value: clock.stalled)
        }
    }

    /// 把看门狗挂到「真正在播」的那个 player 上。
    ///
    /// 会话是异步来的（先有 channel，再有 player），所以三处都会调它；
    /// 重复挂是安全的 —— `attach` 自己先 `detach`。
    private func attachClock() {
        guard let player = session?.player else { return }
        clock.attach(player)
    }

    // MARK: - 视频信息

    @ViewBuilder private var infoLayer: some View {
        // 全屏态不画视频信息面板：它的开关（moreMenu 的 Toggle / 顶栏 videoInfo chip）
        // 都挂在 `if !fullScreen` 里被收掉了，面板若还留着就既没入口关闭、又叠在
        // 满屏画面上 —— 「全屏残留信息卡」。
        if showsInfo, !fullScreen, let session {
            VStack {
                HStack {
                    PlaybackInfoPanel(session: session)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(max(m.hit * 0.4, winW * 0.02))
            .frame(width: winW, height: winH)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 起播耗时

    /// 起播耗时浮层，固定在**画面窗口右上角**。
    ///
    /// 与 `infoLayer`（左上角的视频信息卡）分开两条：One 的 `showPlaybackStats`
    /// 是独立的 `showPlaybackStats` 开关，也只关心四个时间戳，
    /// 混进码率/分辨率那张卡里会互相顶掉。
    ///
    /// 只在**这一次尝试结束**（拿到首帧）或**明确卡住**时画 —— 每帧刷一个变化中的
    /// 数字既扰眼又没有读数价值。`marks.stalledAt` 覆盖「永远没等到首帧」的情形，
    /// 那正是最需要看的时候。
    @ViewBuilder private var playbackStatsLayer: some View {
        if showsPlaybackStats, let line = playbackStatsLine {
            VStack {
                HStack {
                    Spacer(minLength: 0)
                    Text(line)
                        .font(.system(size: max(10, winW * 0.028), weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, winW * 0.024)
                        .padding(.vertical, winW * 0.012)
                        // 纯色底不用材质：材质压在运动画面上每帧重绘（与 PlaybackInfoPanel 同理）。
                        .background(.black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: winW * 0.02, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: winW * 0.02, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        }
                }
                Spacer(minLength: 0)
            }
            .padding(max(m.hit * 0.4, winW * 0.02))
            .frame(width: winW, height: winH)
            .allowsHitTesting(false)
        }
    }

    /// 「解析 0.42s · 就绪 0.18s · 首帧 1.06s · 共 1.66s · HLS」
    ///
    /// 数字全部来自 `PlaybackMarks` 的真实时间戳；缺哪一段就不写哪一段，
    /// 不补零也不估。整条都算不出来（还没开始）时返回 nil，整层不画。
    private var playbackStatsLine: String? {
        let marks = clock.marks
        var parts: [String] = []
        if let t = marks.resolutionLatency { parts.append("解析 \(Self.secondsText(t))") }
        if let t = marks.bufferingLatency { parts.append("就绪 \(Self.secondsText(t))") }
        if let t = marks.startLatency { parts.append("首帧 \(Self.secondsText(t))") }
        if let t = marks.timeToFirstFrame { parts.append("共 \(Self.secondsText(t))") }
        // 走的是 HLS 还是 mp4：看播放地址本身。`Remux.isSegmented` 就是
        // 「这条 URL 的分片已被重封成 HLS」的唯一判据，不另记一套状态。
        if let url = session?.player.currentItem?.asset as? AVURLAsset {
            parts.append(Remux.isSegmented(url.url) ? "HLS" : "mp4")
        }
        if parts.isEmpty, let stage = marks.stalledAt {
            // 没拿到首帧：报停在哪一段，这比一串空值有用。
            parts.append("停在\(Self.stageText(stage))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func secondsText(_ t: TimeInterval) -> String {
        t < 10 ? String(format: "%.2fs", t) : String(format: "%.1fs", t)
    }

    /// `PlaybackMarks.Stage` 的中文名。它是 `String` rawValue 的枚举
    /// （start / resolution / ready / firstFrame），没有现成的本地化文案。
    private static func stageText(_ stage: PlaybackMarks.Stage) -> String {
        switch stage {
        case .start: return "解析"
        case .resolution: return "就绪"
        case .ready: return "首帧"
        case .firstFrame: return "起播"
        }
    }

    /// 画面手势层。只做不会误触的五件事：
    /// 双击左右 ±10s、双击中间播放/暂停、横滑定位、竖滑左亮度右音量、长按 2×。
    /// 单击：**全屏时**收起/叫出控件（真全屏的常态），选集页里仍然什么都不做 ——
    /// One 的选集页控件是常驻的，单击隐藏会让用户找不到返回。
    ///
    /// 单击要等 0.26s 再执行：双击会先让单击识别器落一次，不等一下就会
    /// 「想跳 10 秒，结果控件被收起来了」。
    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: winW, height: winH)
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in doubleTap(at: value.location) }
            )
            // ⛔ 这里**只有一个交互手势**（`pressGesture`），单击/双击/长按/横滑全部
            //    由它按「按下时长 + 位移」自己判定。
            //
            // 走过的弯路（别再回去）：
            //   1. 四个 `simultaneousGesture` 平挂 → 长按被 TapGesture 抢先，一松手变单击；
            //   2. 把 `LongPressGesture().sequenced(before: DragGesture)` 提为主 `.gesture()`
            //      → 仍然不生效：`sequenced` 要等**整个序列结束**才走 `onEnded`，
            //      而 `.first(true)` 这个中间态在同时挂着 TapGesture 时常常收不到，
            //      `beginHold()` 从来没被调用过。
            //
            // 现在的做法：用 `DragGesture(minimumDistance: 0)` 自己计时。
            // 它按下即触发 `onChanged`，位移为 0 也能拿到 —— 时间由我们数，
            // 不依赖任何系统长按识别器，行为完全确定。
            .gesture(pressGesture)
            .allowsHitTesting(!locked)
    }

    /// 画面上的**唯一**交互手势：按下时长 + 位移决定是单击 / 双击 / 长按加速 / 横滑定位。
    ///
    /// 为什么自己计时而不是用 `LongPressGesture`：见 `gestureLayer` 的注释 ——
    /// `sequenced` 组合在 TapGesture 共存时收不到中间态，长按永远不触发。
    ///
    /// 时序：
    ///   · 按下 → 记录起点与时刻，起一个 0.45s 定时器
    ///   · 定时器到点仍在按 → `beginHold()` 进入加速
    ///   · 松手 → 若已加速则 `endedHold()`（恢复原速）；否则按位移判定横滑/单击
    ///   · 双击 → 由 `doubleTap` 自己处理，单击靠延迟 0.26s 让位
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // 已经在加速：位移用于改档（横滑）或保持（下滑）。
                if gestureState.isBoosting {
                    movedHold(value.translation)
                    return
                }
                // 首次按下：记时刻、起长按定时器。
                if gestureState.pressStartedAt == nil {
                    gestureState.pressStartedAt = Date()
                    let startLocation = value.startLocation
                    gestureState.holdTask?.cancel()
                    gestureState.holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        // ⛔ 这里不能写 `boost == nil`：`boost` 是 @State，
                        //    闭包捕获的是**创建时刻的值**（那时一定为 nil），
                        //    条件永远成立。要判断的是「现在还能不能加速」，
                        //    用 `canHoldSpeed` 现算。
                        guard !Task.isCancelled,
                              gestureState.pressStartedAt != nil,
                              canHoldSpeed else { return }
                        beginHold()
                    }
                    return
                }
                // 未进入加速但已经移动够远：交给横滑/竖滑。
                if hypot(value.translation.width, value.translation.height) >= 14 {
                    dragged(value)
                }
            }
            .onEnded { value in
                gestureState.holdTask?.cancel()
                gestureState.holdTask = nil
                let held = gestureState.pressStartedAt != nil ? Date().timeIntervalSince(gestureState.pressStartedAt!) : 0
                let moved = hypot(value.translation.width, value.translation.height)
                gestureState.pressStartedAt = nil

                if gestureState.isBoosting {
                    gestureState.isBoosting = false
                    endedHold()
                    return
                }
                // 没进入加速：位移大就是滑动手势的收尾，否则算点击。
                if moved >= 14 {
                    dragEnded()
                } else if held < 0.45 {
                    // 短按：可能是单击的第一下，也可能是双击的第一下。
                    // 交给双击判定窗口，0.26s 后仍没有第二下才算单击。
                    handleTap(at: value.location)
                }
            }
    }

    /// 单击 / 双击的统一入口。
    ///
    /// 不用 `SpatialTapGesture(count: 2)`：它和自定义的 pressGesture 抢事件，
    /// 而且双击的第二下会被 pressGesture 自己也收到一次。这里自己数时间间隔。
    private func handleTap(at location: CGPoint) {
        let now = Date()
        if let last = gestureState.lastTapAt, now.timeIntervalSince(last) < 0.30 {
            gestureState.lastTapAt = nil
            tapTask?.cancel(); tapTask = nil
            doubleTap(at: location)
            return
        }
        gestureState.lastTapAt = now
        tapTask?.cancel()
        tapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            gestureState.lastTapAt = nil
            singleTap()
        }
    }

    /// 手势的瞬时状态放在**引用类型**里，不直接用 @State 存 Date/Task。
    ///
    /// ⛔ 这是本次「长按仍然变单击」的真正原因：
    ///    `gestureState.pressStartedAt` / `gestureState.holdTask` 若直接用 @State，每次写入都会触发
    ///    视图重建 —— 而 `pressGesture` 是计算属性，重建时会产生一个新的
    ///    手势实例，旧的 `gestureState.holdTask` 随之被丢弃，450ms 后那个 `beginHold()`
    ///    永远等不到。表现为「按住不动、松手仍是单击」。
    ///
    ///    改成 `@State` 持有一个 class 实例：视图重建不会换掉这个对象，
    ///    内部的 Date/Task 也就不会丢。
    @State private var gestureState = GestureState()

    final class GestureState {
        var pressStartedAt: Date?
        var holdTask: Task<Void, Never>?
        var lastTapAt: Date?
        /// 是否已进入长按加速。放在引用类型里而不是读 @State 的 `boost`：
        /// 手势闭包捕获的 @State 是**创建时刻的值**，`onChanged` 里读到的
        /// `boost` 永远是 nil，横滑改档 / 松手恢复都不会生效。
        var isBoosting = false
    }

    /// 能不能加速：要真的在播、有时间轴、且没有别处占用（画中画 / 锁屏）。
    private var canHoldSpeed: Bool {
        // ⛔ 去掉 `showsTransport`：它等价于「会话已就绪且不在加载/报错」，
        //    与「控件栏此刻画没画出来」是两件事。原来带它，导致
        //    **全屏收起控件后长按完全没反应**（既不加档、也不快进）——
        //    而收起控件恰恰是最想长按加速看剧的时刻。
        //
        //    真正该拦的只有：锁了控件（用户明确要求别响应手势）、
        //    没有时间轴（直播）、暂停中（加速没意义）、画中画在跑（抢同一个 player）。
        !locked && seekable && session?.paused == false && !kit.pip.active
    }

    private func beginHold() {
        guard canHoldSpeed else { return }
        gestureState.isBoosting = true
        // 新手势接管上一次「下滑保持」的档位：除非再滑一次下去，否则松手就恢复。
        let started = SpeedBoost(rate: holdSpeed)
        boost = started
        session?.setBoost(Float(started.rate))
    }

    private func movedHold(_ translation: CGSize) {
        guard var moved = boost else { return }
        moved.moved(x: translation.width, y: translation.height)
        guard moved != boost else { return }
        if moved.rate != boost?.rate { session?.setBoost(Float(moved.rate)) }
        boost = moved
    }

    private func endedHold() {
        guard boost != nil else { return }
        // 下滑保持：`locked` 时档位留下，直到用户点一下顶部那颗倍速胶囊。
        if boost?.locked != true { endHold() }
    }

    private func endHold() {
        gestureState.isBoosting = false
        boost = nil
        session?.setBoost(nil)
    }

    private func doubleTap(at location: CGPoint) {
        // 双击已经成立，把挂在单击上的「收控件」取消掉。
        tapTask?.cancel(); tapTask = nil
        guard boost == nil else { return }
        guard let session else { return }
        // `seekable: false` 让 `zone(...)` 恒回 `.middle`（见 `PictureTaps.zone`）——
        // 关掉「双击跳过」后双击中间/左右都变成播放暂停，与原生皮肤同一语义。
        let zone = PictureTaps.zone(x: Double(location.x), width: Double(winW),
                                    seekable: seekable && doubleTapSkips)
        // ⛔ 不再走 `taps.tap(at:in:)`：那个方法内部自己数双击间隔，
        //    而 `handleTap` 已经数过一遍（0.30s 窗口）。两套计数叠加会让
        //    第二下双击被它判成「新的一次 streak 起点」，跳过永远不触发。
        //    这里直接按 zone 分派。
        switch zone {
        case .middle:
            session.togglePlayback()
        case .back, .forward:
            let seconds: Double = zone == .back ? -10 : 10
            let total = 10.0
            session.skip(seconds)
            withAnimation(.snappy(duration: 0.2)) { skipped = (seconds > 0, total) }
            skippedTask?.cancel()
            skippedTask = Task {
                try? await Task.sleep(for: .seconds(PictureTaps.streak + 0.1))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { skipped = nil } }
            }
        }
    }

    private func dragged(_ value: DragGesture.Value) {
        guard seekable else { return }
        if abs(value.translation.width) > abs(value.translation.height) {
            if swipeStart == nil {
                swipeStart = position
                swipeTarget = position
            }
            swipeTarget = PictureSeek.target(from: swipeStart ?? position,
                                            moved: value.translation.width,
                                            width: winW,
                                            duration: duration)
        } else if slidesLevels, PictureLevel.slides(fromY: value.startLocation.y, height: winH) {
            let volume = value.startLocation.x > winW / 2
            if level == nil {
                let start = volume ? Double(AVAudioSession.sharedInstance().outputVolume)
                                   : Double(screen?.brightness ?? 0)
                if !volume, brightnessBefore == nil { brightnessBefore = screen?.brightness }
                level = (volume, start)
            }
            guard var now = level else { return }
            now.value = PictureLevel.value(from: now.value,
                                           moved: value.translation.height,
                                           height: winH)
            level = now
            if now.volume { systemVolume.set(now.value) }
            else { screen?.brightness = CGFloat(now.value) }
        }
    }

    private func dragEnded() {
        if let target = swipeTarget, swipeStart != nil {
            session?.seek(to: target)
        }
        swipeStart = nil
        swipeTarget = nil
        if level != nil {
            levelTask?.cancel()
            levelTask = Task {
                try? await Task.sleep(for: .seconds(0.8))
                if !Task.isCancelled { level = nil }
            }
        }
    }

    private var screen: UIScreen? { UIApplication.shared.appWindowScene?.screen }

    // MARK: - 控件显隐（真全屏）

    /// 单击：只有全屏才管控件，且要等双击的判定窗口过去。
    private func singleTap() {
        // 长按加速进行中/刚结束：这一下是加速手势的收尾，不是单击。
        guard boost == nil else { return }
        guard fullScreen, !locked else { return }
        tapTask?.cancel()
        tapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            if chromeHidden { revealChrome(schedule: true) }
            else { withAnimation(.easeOut(duration: 0.2)) { chromeHidden = true }; cancelHide() }
        }
    }

    private func revealChrome(schedule: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { chromeHidden = false }
        if schedule { scheduleHide() } else { cancelHide() }
    }

    /// 播放中才倒计时；暂停时控件留着（否则用户没法点播放）。
    private func scheduleHide() {
        cancelHide()
        guard fullScreen, !locked, playing else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, playing, fullScreen, !locked else { return }
            withAnimation(.easeOut(duration: 0.25)) { chromeHidden = true }
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    @ViewBuilder private var gestureHUD: some View {
        ZStack {
            if let swipeTarget, let swipeStart {
                hudPill {
                    VStack(spacing: 3) {
                        Text("\(clock(swipeTarget)) / \(clock(duration))")
                            .font(.system(size: m.hudTitle, weight: .semibold).monospacedDigit())
                        Text((swipeTarget < swipeStart ? "−" : "+") + clock(abs(swipeTarget - swipeStart)))
                            .font(.system(size: m.caption).monospacedDigit())
                            .opacity(0.75)
                    }
                }
            } else if let adHUD {
                hudPill {
                    VStack(spacing: 3) {
                        Image(systemName: adHUD == .marked(seconds: 0) || isMarked(adHUD)
                              ? "megaphone.fill" : "megaphone.slash.fill")
                            .font(.system(size: opticalSize("megaphone", base: m.glyph * 1.6)))
                        Text(adHUDText(adHUD))
                            .font(.system(size: m.caption))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, winH * 0.12)
            } else if let skipped {
                hudPill {
                    VStack(spacing: 3) {
                        Image(systemName: skipped.forward ? "goforward.10" : "gobackward.10")
                            .font(.system(size: opticalSize(skipped.forward ? "goforward.10" : "gobackward.10",
                                                            base: m.glyph * 1.6)))
                        Text((skipped.forward ? "+" : "−") + "\(Int(skipped.total))s")
                            .font(.system(size: m.caption).monospacedDigit())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: skipped.forward ? .trailing : .leading)
                .padding(.horizontal, winW * 0.08)
            } else if let level {
                hudPill {
                    // 条长跟着比例尺走：写死 110 在竖屏小窗里比画面还宽。
                    let barW = m.glyph * 8
                    let barH = max(4, m.glyph * 0.4)
                    HStack(spacing: m.glyph * 0.9) {
                        Image(systemName: level.volume
                              ? (level.value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                              : "sun.max.fill")
                        Capsule().fill(.white.opacity(0.3)).frame(width: barW, height: barH)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: barW * level.value, height: barH)
                            }
                    }
                }
            } else if generatingSubtitles {
                // 听声写字幕要跑完整条音轨，期间必须让用户看到「在做事」。
                hudPill {
                    VStack(spacing: 3) {
                        Image(systemName: "waveform")
                            .font(.system(size: opticalSize("waveform", base: m.glyph * 1.4)))
                        Text("\(Int(subtitleProgress * 100))%")
                            .font(.system(size: m.caption).monospacedDigit())
                            .opacity(0.75)
                    }
                }
            } else if let speechNote {
                hudPill {
                    Text(speechNote)
                        .font(.system(size: m.caption))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: winW * 0.66)
                }
            }
        }
        .frame(width: winW, height: winH)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.16), value: level?.value)
    }

    /// 长按倍速的档位胶囊。
    ///
    /// 单独一层、**不复用 `gestureHUD`**：后者整层 `.allowsHitTesting(false)`（它只是提示），
    /// 而「下滑保持」之后这颗胶囊是要能点的（点一下回到原速）。塞进那层就永远点不到。
    @ViewBuilder private var boostLayer: some View {
        if let boost {
            // 连接跟不上时 session 会自动降档：`boostWanted` 是被要求的档位，划掉显示，
            // 用户才知道「不是没生效，是网速只到这里」。
            let rate = session?.boost ?? Float(boost.rate)
            VStack {
                Button { endHold() } label: {
                    HStack(spacing: 6) {
                        if boost.locked { Image(systemName: "lock.fill") }
                        Text(speedLabel(rate))
                        if let wanted = session?.boostWanted, wanted > rate {
                            Text(speedLabel(wanted)).strikethrough().opacity(0.55)
                        }
                        Image(systemName: "forward.fill")
                    }
                    .font(.system(size: m.hudTitle, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, m.glyph * 1.5).padding(.vertical, m.glyph * 0.9)
                    .background(.black.opacity(0.62), in: Capsule())
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // 只有「保持」的档位可以点掉；临时加速松手就没了，不需要按钮。
                .allowsHitTesting(boost.locked)
                .accessibilityLabel(L10n.text("Back to Normal Speed"))
                Spacer(minLength: 0)
            }
            .padding(.top, topBarY + m.hit * 0.6)
            .frame(width: winW, height: winH)
            .animation(.easeOut(duration: 0.16), value: boost.rate)
        }
    }

    private func hudPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: m.hudTitle, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, m.glyph * 1.5).padding(.vertical, m.glyph * 0.9)
            .background(.black.opacity(0.62), in: Capsule())
    }

    // MARK: - 动作

    private func seek(by seconds: Double) {
        guard seekable else { return }
        session?.skip(seconds)
    }

    private func step(back: Bool) -> PlayerStep? {
        guard let channel, let session else { return nil }
        return store.step(back: back, from: channel, session: session)
    }

    // MARK: - 广告标注

    @State private var markingAd = false

    /// 能不能标注。
    ///
    /// ⛔ 这里**绝不能读 `session.position`**。
    ///
    /// `canMarkAd` 决定菜单条目出不出现，而 `position` 每秒都被
    /// `updateSkipping` 改写 —— 一旦把它读进来，SwiftUI 就认为
    /// 「更多」菜单的内容每帧都变了，列表会持续重绘：
    /// 用户看到的是「菜单一直在刷新、点不中、下拉选不了」。
    /// 这是菜单抖动的根因。
    ///
    /// ⛔ 也不能要求 `player.rate > 0`：
    /// 暂停时用户最想标注（正好停在那支广告上），
    /// 而 `AVAssetImageGenerator` 离线抓帧本来就不需要正在播放。
    private var canMarkAd: Bool {
        guard let session, session.hasTimeline, !session.isLive else { return false }
        // 只读时长（离散、加载后不再变），不读逐秒变化的 position / rate。
        return session.duration > 60
    }

    /// 把「当前播放位置」标成广告，边界由算法自己找。
    ///
    /// 用户只要在广告播放期间点一下，前后各 30 秒都会被扫一遍，
    /// `AdBoundary` 从标记点往两侧扩，相似度掉下去的位置就是广告真正的起止。
    /// 短广告只吃到它自己那几秒，长广告能扩到几十秒 —— 不用用户量长度。
    private func markAdHere() async {
        guard let session, !markingAd else { return }
        markingAd = true
        defer { markingAd = false }
        let marker = session.position
        await session.markAd(at: marker)
        // 用实际入库的长度回报，而不是候选窗口的 30 秒 ——
        // 用户看到的就是「这支广告有多长」。
        let learned = await AdSignatureLibrary.shared.all().max { $0.createdAt < $1.createdAt }
        showAdHUD(.marked(seconds: learned?.duration ?? 0))
    }

    /// 广告提示的两种状态：刚标记成功 / 刚自动跳过。
    ///
    /// 这两种反馈以前只赋值不渲染（`showedAdMarked` 写完就没人读），
    /// 用户点完「标记为广告」看不到任何确认，也不知道广告真的被跳过了。
    @State private var adHUD: AdHUD?
    @State private var adHUDTask: Task<Void, Never>?

    enum AdHUD: Equatable {
        case marked(seconds: Double)
        case skipped(seconds: Double)
    }

    private func isMarked(_ hud: AdHUD) -> Bool {
        if case .marked = hud { return true }
        return false
    }

    private func adHUDText(_ hud: AdHUD) -> String {
        switch hud {
        case .marked(let seconds):
            return L10n.text("Ad marked (%@)", EpisodeSkipSettings.formatTime(seconds))
        case .skipped(let seconds):
            return L10n.text("Ad skipped (%@)", EpisodeSkipSettings.formatTime(seconds))
        }
    }

    /// 弹一下广告提示，2.2 秒后自动消失。
    private func showAdHUD(_ state: AdHUD) {
        adHUDTask?.cancel()
        withAnimation(.snappy(duration: 0.18)) { adHUD = state }
        adHUDTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { adHUD = nil }
        }
    }

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private var externalBinding: Binding<OneSkinHandoff?> {
        Binding(get: { externalStream }, set: { externalStream = $0 })
    }

    // MARK: - 控件呈现（One 风格：白线，不用玻璃球）

    /// `enabled` 默认 true；给 false 时按钮灰掉且点不动。
    /// 画中画那颗用它：画面层还没登记完（`PictureInPicture.current == nil`）时
    /// 以前是「亮着但点了没反应」，现在直接灰掉，状态与能力一致。
    /// 底栏一个传输控件。One 的底栏只有一行图标，所以这里统一用小号 chrome 图标；
    /// 非传输类控件（用户从顶栏拖下来的）按同一尺寸渲染，行为走各自分支。
    @ViewBuilder private func transportControl(_ control: PlayerControl) -> some View {
        switch control {
        case .backTen:
            iconButton("gobackward.10", label: L10n.text("Back 10 seconds"), enabled: seekable) {
                session?.skip(-10)
            }
        case .forwardTen:
            iconButton("goforward.10", label: L10n.text("Forward 10 seconds"), enabled: seekable) {
                session?.skip(10)
            }
        case .playPause:
            iconButton(playing ? "pause.fill" : "play.fill",
                       label: playing ? L10n.text("Pause") : L10n.text("Play")) {
                session?.togglePlayback()
            }
        case .previousEpisode:
            if let previous = step(back: true) {
                iconButton("backward.end.fill", label: L10n.text("Previous Episode"), enabled: !previous.busy) {
                    previous.go()
                }
            }
        case .nextEpisode:
            if let next = step(back: false) {
                iconButton("forward.end.fill", label: L10n.text("Next Episode"), enabled: !next.busy) {
                    next.go()
                }
            }
        default:
            // 非传输类控件（用户从顶栏拖到底栏的）走顶栏那套渲染，
            // 一个分支都不另写 —— 曾经这里是 `EmptyView()`，于是把「画质」「字幕」
            // 拖到底栏得到的是一个**空槽**：设置里排好了，播放器里什么都没有。
            //
            // ⚠️ 这里**必须**是 `controlButton` 而不是 `moreItem`：
            // `moreItem` 的 `.lock` 分支是「只上锁、不解锁」（菜单里点完就关了，合理），
            // 而顶栏/底栏那颗是常驻开关，必须能来回切 —— `controlButton(.lock)` 就是 toggle 语义。
            controlButton(control)
        }
    }

    private func iconButton(_ symbol: String, label: String,
                            width: CGFloat? = nil, height: CGFloat? = nil, font: CGFloat? = nil,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chromeIcon(symbol, width: width, height: height, font: font)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func chromeIcon(_ symbol: String, width: CGFloat? = nil,
                            height: CGFloat? = nil, font: CGFloat? = nil) -> some View {
        Image(systemName: symbol)
            .font(.system(size: font ?? opticalSize(symbol, base: m.glyph), weight: .medium))
            .frame(width: width ?? m.hit, height: height ?? m.hit)
            .contentShape(Rectangle())
    }

    /// 把一个符号在 `base` 字号下的**墨迹高度**归一到全排同一个值。
    ///
    /// 统一字号并不等于统一大小：实测 11pt 时 `chevron.left` 只画出 9.6pt 高，
    /// 而 `rectangle.landscape.rotate` 画出 14.1pt、`arrow.up.left.and.arrow.down.right`
    /// 画出 13.5pt —— 同一排里差 1.5 倍，用户看到的就是「有的图标大、有的小」。
    /// 表里是各符号在 100pt medium 下的墨迹高度 ÷ 100（AppKit 实测，见文件尾注释）。
    private func opticalSize(_ symbol: String, base: CGFloat) -> CGFloat {
        guard let ratio = ChromeMetrics.inkRatio[symbol] else { return base }
        // 目标墨迹 = 基准字号的 0.98：归一后整排的「视觉高度」就等于 `glyph`，
        // 这样「字号」和「看起来多大」终于是同一个数，调档位时不用再靠猜。
        let factor = min(max(0.98 / ratio, 0.75), 1.35)
        return (base * factor * 2).rounded() / 2   // 半磅取整，避免子像素抖动
    }

    /// 中央两侧的 ±10s / 上下集：「中一号」。
    private func smallCircle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: opticalSize(symbol, base: m.stepGlyph), weight: .medium))
                .frame(width: m.stepHit, height: m.stepHit)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 中央播放键：「大一号」，且是整组里唯一带 symbolEffect 的。
    private func bigCircle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: opticalSize(symbol, base: m.playGlyph), weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: m.playHit, height: m.playHit)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 顶栏里的一颗用户控件。
    @ViewBuilder private func controlButton(_ control: PlayerControl) -> some View {
        switch control {
        case .timecode, .progressBar, .remaining:
            // 这三件属于进度行（`bottomItem` 有专属形态）。设置页也不让它们进顶栏，
            // 万一旧配置里有，这里画成只读图标而不是一颗点不动的空白。
            chromeIcon(control.symbol).allowsHitTesting(false)
        case .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual:
            // ⛔ 此前这四项是 `EmptyView()`，理由写的是「只做菜单条目，顶栏不放它们」。
            //    但它们**在 `barControls` 里**，设置页的「直接显示」表会列出来、
            //    也能被拖进顶栏槽位 —— 于是用户在设置里排好，顶栏上是一颗**空位**。
            //    现在给出与「更多」同源的图标形态（开/关两态），摆哪都能用。
            iconButton(symbolFor(control), label: L10n.text(control.title)) {
                perform(control)
            }
        case .airPlay:
            // AVRoutePickerView 自带一圈内边距，塞进和别人一样大的框里，
            // 字形永远比邻居小一圈 —— 这是「看起来大小不一致」里最明显的一个。
            // 把它的 tint 清空，再用同一颗 `chromeIcon` 盖上去：
            // 点的是系统按钮（路由选择器照常弹），看到的是同一号字形。
            ZStack {
                AirPlayButton(transparent: true)
                chromeIcon("airplayvideo").allowsHitTesting(false)
            }
            .frame(width: m.hit, height: m.hit)
            .contentShape(Rectangle())
        case .episodes:
            iconButton("list.bullet.rectangle", label: L10n.text("Episodes")) { kit.openEpisodes() }
        case .pictureInPicture:
            iconButton(kit.pip.active ? "pip.exit" : "pip.enter",
                       label: L10n.text("Picture in Picture"),
                       enabled: kit.pip.canToggle) { kit.pip.toggle() }
        case .danmaku:
            iconButton(danmakuOn ? "text.bubble.fill" : "text.bubble", label: L10n.text("Danmaku")) {
                danmakuOn.toggle()
            }
        case .subtitles:
            // ⛔ 顶栏这颗必须弹菜单，不能「盲选第一条」。
            //
            // 原来写的是 `chosenSubtitle = subtitleTracks.first?.id`：
            //   · 只有内嵌字幕轨（`kit.tracks.legible`）、没有外挂 .srt 时，
            //     `subtitleTracks` 是空的 → 点一下**什么都不会发生**（按钮亮着、无反应）；
            //   · 有外挂字幕时它直接跳到第一条，用户既看不到列表、也关不掉。
            // 与画质 / 音轨那两颗不一致（它们都弹 `Menu`），
            // 正是用户说的「有的控件有效、有的无效」。
            if !subtitleTracks.isEmpty || !(kit.tracks.legible?.options.isEmpty ?? true) {
                Menu { subtitlePicker } label: { chromeIcon("captions.bubble") }
                    .buttonStyle(.plain)
                    .frame(width: m.hit, height: m.hit)
                    .accessibilityLabel(L10n.text("Subtitles"))
            }
        case .speed:
            iconButton("gauge.with.needle", label: L10n.text("Playback Speed")) { cycleSpeed() }
        case .pictureSize:
            iconButton("arrow.up.left.and.arrow.down.right", label: L10n.text("Picture Size")) { cycleScaling() }
        case .videoInfo:
            iconButton(showsInfo ? "info.circle.fill" : "info.circle",
                       label: L10n.text("Show Video Info")) { showsInfo.toggle() }
        case .miniPlayer:
            iconButton("rectangle.inset.bottomright.filled", label: L10n.text("Mini Player")) { kit.miniPlayer() }
        // 以下几颗此前落到 `default: EmptyView()` —— 用户把它们摆到顶栏，
        // 换来的是一颗**点不动的空白占位**（设置里勾了却什么都没有）。
        case .quality:
            Menu { if let session { QualityPicker(session: session) } } label: {
                chromeIcon("sparkles.tv")
            }
            .buttonStyle(.plain)
            .frame(width: m.hit, height: m.hit)
            .accessibilityLabel(L10n.text("Quality"))
        case .audio:
            Menu { audioPicker } label: { chromeIcon("speaker.wave.2") }
                .buttonStyle(.plain)
                .frame(width: m.hit, height: m.hit)
                .accessibilityLabel(L10n.text("Audio"))
        case .anotherPlayer:
            iconButton("play.rectangle.on.rectangle", label: L10n.text("Open in Another Player")) {
                if let channel { externalStream = OneSkinHandoff(url: channel.url) }
            }
        case .markAd:
            // 顶栏形态：打开手标区间那一页。
            //
            // 顶栏是「一下就点」的位置，而标广告需要两个时间点，所以这里是**入口**，
            // 不是动作本身 —— 打开后起点默认就是当前播放位置，用户只需补终点。
            // （原来这里直接跑 `markAdHere()` 猜边界，猜歪了没有任何纠正手段。）
            iconButton("timeline.selection", label: L10n.text("Trim the Ad Here")) {
                showsAdTrim = true
            }
        case .adBlock:
            // 顶栏形态：一下切换广告拦截总开关。图标直接反映当前状态
            // （拦着 = 实心盾；关掉 = 带斜线的空盾），不需要再点进菜单确认。
            iconButton(skipsAds ? "shield.lefthalf.filled" : "shield.slash",
                       label: skipsAds ? L10n.text("Ad Blocking On") : L10n.text("Ad Blocking Off")) {
                skipsAds.toggle()
            }
        case .lock:
            iconButton(locked ? "lock.fill" : "lock.open",
                       label: L10n.text(locked ? "Unlock Controls" : "Lock Controls")) {
                locked.toggle()
                if locked { PlayerOrientation.lock() } else { PlayerOrientation.unlock() }
            }
        case .rotate:
            iconButton("rectangle.landscape.rotate", label: L10n.text("Rotate")) { onRotate() }
        case .fullScreen:
            iconButton(kit.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: kit.isFullScreen ? L10n.text("Exit Full Screen") : L10n.text("Full Screen")) {
                kit.toggleFullScreen()
            }
        case .backTen:
            iconButton("gobackward.10", label: L10n.text("Back 10 seconds")) { seek(by: -10) }
        case .forwardTen:
            iconButton("goforward.10", label: L10n.text("Forward 10 seconds")) { seek(by: 10) }
        case .playPause:
            iconButton(playing ? "pause.fill" : "play.fill", label: L10n.text("Play / Pause")) {
                session?.togglePlayback()
            }
        case .previousEpisode:
            // 没有上一集时 `step` 为 nil —— 此时按钮本就该隐藏（见 `available`），
            // 这里再兜一层，避免出现「点了没反应」的灰键。
            if let previous = step(back: true) {
                iconButton("backward.end.fill", label: L10n.text("Previous Episode")) { previous.go() }
                    .disabled(previous.busy)
            }
        case .nextEpisode:
            if let next = step(back: false) {
                iconButton("forward.end.fill", label: L10n.text("Next Episode")) { next.go() }
                    .disabled(next.busy)
            }
        case .speechSubtitles:
            // 语音字幕：生成管线在 `SpeechSubtitles`（TVCore），见 `speechState`。
            iconButton(speechState.generating ? "waveform.badge.mic" : "waveform",
                       label: L10n.text("Write Subtitles From the Sound")) {
                Task { await toggleSpeechSubtitles() }
            }
            .disabled(speechState.generating)
        }
    }

    private func cycleSpeed() {
        guard let session else { return }
        let index = Self.speeds.firstIndex(where: { abs($0 - session.speed) < 0.01 }) ?? 2
        let next = Self.speeds[(index + 1) % Self.speeds.count]
        session.setSpeed(next)
        persistedSpeed = Double(next)   // 双轨同步（见 persistedSpeed 注释）
    }

    private func cycleScaling() {
        let all = PictureScaling.allCases
        let index = all.firstIndex(of: scaling) ?? 0
        scalingRaw = all[(index + 1) % all.count].rawValue
    }

    // MARK: - 锁屏 / 控制中心

    /// 决定「现在播放信息该不该重写」的那几个量。渲染每秒都在重绘，
    /// 但 `nowPlayingInfo` 只在状态真的变了才需要下发。
    private var nowPlayingState: NowPlayingState {
        NowPlayingState(paused: session?.paused ?? true,
                        live: session?.isLive ?? false,
                        timeline: session?.hasTimeline ?? false,
                        boost: session?.boost)
    }

    /// 锁屏封面：目录里的海报优先，其次是历史记录里带的那张。
    private var nowPlayingArtwork: PlaybackArtwork {
        let catalog = channel.flatMap { store.catalog(for: $0) }
        return PlaybackArtwork(poster: catalog?.video.poster ?? channel?.historyContext?.poster,
                               headers: catalog?.video.posterHeaders ?? channel?.historyContext?.posterHeaders ?? [:])
    }

    // MARK: - 语音字幕

    /// 认哪种语言：设置页选的优先，其次系统语言，再退回本机装了的模型。
    /// 本机没有对应离线模型时返回 nil —— 那颗键就不出现，而不是点了才发现没模型。
    private var speechLanguage: String? {
        SpeechSubtitles.preferredLanguage(stored: speechLanguageCode)
    }

    /// 念的进度 / 正在念 / 上一次的错。`controlButton` 的图标与禁用态读这里。
    private var speechState: (available: Bool, generating: Bool) {
        (speechLanguage != nil, generatingSubtitles)
    }

    /// 听声写字幕：整条音轨跑一遍 `SpeechSubtitles`，产出一个 `SubtitleTrack`，
    /// 追加进本页的字幕清单并选中它 —— 与 `MobilePlayer.generateSubtitles` 同一套动作。
    ///
    /// 请求头必须带上：需要 Referer 的片源会把错误页当「静音」喂给识别器，
    /// 结果是「什么都没识别出来」，比报错更难查。
    @MainActor private func toggleSpeechSubtitles() async {
        guard !generatingSubtitles, let language = speechLanguage, let channel else { return }
        generatingSubtitles = true
        subtitleProgress = 0
        speechNote = nil
        let headers = channel.headers
        let asset = AVURLAsset(url: channel.url,
                               options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let name = L10n.text("Subtitles From the Sound")
        let hint = channel.name
        let track = await withCheckedContinuation { (continuation: CheckedContinuation<SubtitleTrack?, Never>) in
            // 句柄留在 `speechTask` 上：离开页面时 `onDisappear` 取消它，
            // 而不是让识别在没人看的后台跑到底（旧播放器踩过这条）。
            speechTask = Task {
                do {
                    let result = try await SpeechSubtitles().transcribe(asset: asset, language: language, name: name,
                                                                        hint: [hint]) { value in
                        Task { @MainActor in subtitleProgress = value }
                    }
                    continuation.resume(returning: result)
                } catch {
                    await MainActor.run { speechNote = Self.describe(error) }
                    continuation.resume(returning: nil)
                }
            }
        }
        generatingSubtitles = false
        guard let track else { return }
        subtitleTracks.removeAll { $0.id == track.id }
        subtitleTracks.append(track)
        chosenSubtitle = track.id
    }

    private static func describe(_ error: any Error) -> String {
        guard let failure = error as? SpeechSubtitles.Failure else { return error.localizedDescription }
        switch failure {
        case .languageUnavailable(let language): return L10n.text("No on-device speech model for %@.", language)
        case .notAuthorized: return L10n.text("Allow Speech Recognition in Settings to write subtitles.")
        case .noAudio: return L10n.text("This video has no sound track to read.")
        case .empty: return L10n.text("Nothing was recognised in this video's sound.")
        case .cancelled: return L10n.text("Cancelled.")
        case .failed(let reason): return reason
        }
    }
}

/// 决定「锁屏信息要不要重写」的几个量。
/// `MobilePlayer` 里那份是嵌套在那个 View 内部的私有类型，跨文件用不了，所以这里独立一份
/// （只保留 One 页真的会变的那几项 —— 速率上限、时长这些 `update` 自己会从 session 读）。
private struct NowPlayingState: Equatable {
    var paused: Bool
    var live: Bool
    var timeline: Bool
    var boost: Float?
}

// MARK: - 尺寸表

/// One 播放控件的**唯一尺寸表**。
///
/// 迁移控件时每个控件各算一套数：顶栏图标宽取 `winW * 0.062`、高取 `winH * 0.105`，
/// 字形再按宽度乘 0.34 并夹到 9…13；中央播放键取 `winW * 0.051` 夹到 30；
/// 时间码取 `winH * 0.030` 夹到 7…14；底栏那颗全屏键单独传 `winW * 0.040`
/// 加小一号的字；解锁键干脆写死 12。四套夹逼叠在一起，竖屏选集页里
/// 时间码 7pt、解锁键 12pt、播放键 14.9pt 同框并排 —— 就是「大小不一致」。
///
/// 现在只有一个比例尺，其余全是它的倍数。要调大小，只改这里。
private struct ChromeMetrics {
    let winW: CGFloat
    let winH: CGFloat

    /// 比例尺。One 设计稿窗口高 558px，按 300pt 归一；夹在 0.82…1.4：
    /// 小窗不至于糊成一团（下限 11pt 字形），全屏也不至于夸张成一块砖。
    /// ⚠️ 上下限只夹比例尺本身，**不要再对单个控件二次夹逼** —— 那正是原来
    /// 「有的控件被夹住、有的没被夹住」的来源。
    var scale: CGFloat { min(max(winH / 300, 0.82), 1.4) }

    /// 工具栏图标的字形边长。顶栏、底栏、更多菜单、锁定/解锁全用这个值，没有例外。
    var glyph: CGFloat { (13 * scale).rounded() }

    /// 图标方形**热区**。字形负责好看，热区负责按得中，两者不是一个数。
    ///
    /// ⛔ 下限必须 44pt —— 这是用户报「点不开、点不动」的直接根因。
    ///
    /// 原式 `min(40, max(26, glyph*1.8))` 在**所有**比例尺下都低于 44：
    ///   scale=0.82 → glyph=10.7 → hit=26
    ///   scale=1.00 → glyph=13.0 → hit=26
    ///   scale=1.40 → glyph=18.2 → hit=33
    /// 也就是说无论窗口多大，整排图标（返回 / 旋转 / 更多 / 弹幕 / 画质 / 音轨）
    /// 的可点区都只有 26–33pt，比苹果最小可点 44pt 小一大截；
    /// 而这些图标在 `topBar` 里还各贴着 `.frame(height: m.hit)` 排成一排，
    /// 相邻两颗热区之间没有余量，手指必然落到缝里 —— 落进缝里的点被
    /// 铺满整个画面的 `gestureLayer` 吃掉，变成「单击显示/隐藏控件」，
    /// 用户看到的就是「明明点到了却没反应」。
    ///
    /// 现在：热区取 44 的规范值，字形不变（视觉大小不动，只放大可点范围）。
    /// 上限放宽到 52 让大窗时热区跟着长，但不无限膨胀，免得多颗热区互相侵占。
    var hit: CGFloat { min(52, max(44, (glyph * 1.8).rounded())) }

    /// 顶栏 / 底栏的**条高**。
    ///
    /// ⛔ 必须独立于 `hit`：以前两处都用 `m.hit` 当 frame 高度，
    /// 热区一旦放大到 44，整条也跟着变高、把画面压掉一块；
    /// 反过来若条高小于热区，`Button` 的热区会被父 frame **裁掉超出部分**，
    /// 放大了也白放。这里让条高始终 ≥ 热区，热区才真的可点。
    var barHeight: CGFloat { max(hit, m_glyphLineHeight) }

    private var m_glyphLineHeight: CGFloat { (glyph * 2.2).rounded() }

    /// 窗口内边距。顶栏与底栏必须用同一个数，否则两侧对不齐。
    var edge: CGFloat { max(4, winW * 0.012) }

    /// 中央播放键：唯一的「大一级」。
    var playGlyph: CGFloat { (glyph * 1.75).rounded() }
    var playHit: CGFloat { playGlyph * 1.7 }
    /// 中央 ±10s / 上下一集：「中一级」。
    var stepGlyph: CGFloat { (glyph * 1.2).rounded() }
    var stepHit: CGFloat { stepGlyph * 1.9 }
    /// 时间码、HUD 副标题这类小正文。
    var caption: CGFloat { (glyph * 0.9).rounded() }
    /// HUD 主标题。
    var hudTitle: CGFloat { (glyph * 1.3).rounded() }

    /// 「字号 → 视觉大小」的换算表：各符号在 **100pt / medium** 下的**墨迹高度** ÷ 100。
    ///
    /// 用 AppKit 逐个渲染后扫 alpha 包围盒实测（2026-11-09），不是估的。
    /// 只收本文件用到的符号；表里没有的按 1:1 处理。新增控件时如果发现哪颗
    /// 明显偏大/偏小，把它的数补进来即可（脚本见交付报告）。
    static let inkRatio: [String: CGFloat] = [
        "chevron.left": 0.87,
        "rectangle.expand.vertical": 1.20,
        "rectangle.compress.vertical": 1.23,
        "rectangle.landscape.rotate": 1.28,
        "sidebar.right": 0.91,
        "airplayvideo": 0.94,
        "list.bullet.rectangle": 0.91,
        "text.bubble": 1.03,
        "text.bubble.fill": 1.03,
        "captions.bubble": 1.03,
        "gauge.with.needle": 1.01,
        "arrow.up.left.and.arrow.down.right": 0.94,
        "arrow.down.right.and.arrow.up.left": 0.94,
        "info.circle": 1.01,
        "info.circle.fill": 1.01,
        "rectangle.inset.bottomright.filled": 0.91,
        "lock.open": 0.98,
        "lock.fill": 0.98,
        "pip.enter": 1.05,
        "pip.exit": 1.05,
        "backward.end.fill": 0.78,
        "forward.end.fill": 0.78,
        "gobackward.10": 1.10,
        "goforward.10": 1.10,
        "play.fill": 0.85,
        "pause.fill": 0.84,
    ]
}

/// 外播地址包一层，`URL` 不是 `Identifiable`（与 MobilePlayer 里的 HandoffStream 同因）。
struct OneSkinHandoff: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
#endif
