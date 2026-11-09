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

    var onBack: () -> Void = {}
    /// 明确「退出全屏」——不是切换。
    ///
    /// `onBack` 的语义是「离开这一页」，它自己会按页面的 `fullScreen` 分流；但页面那份
    /// 状态和皮肤这份镜像（`fullScreenNow`）是两个变量，任一侧读到过期值，返回就会
    /// 落到 `dismiss()` 上 —— 用户看到的就是「全屏里点返回直接回主页」。
    /// 所以全屏下的返回走这条单向通道：只退全屏，绝不离开页面。
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

    /// 控件锁：手势与遮挡层全部失效（只有「解锁」还能点）。
    @State private var locked = false
    /// 全屏下控件自动收起后的状态。选集页（非全屏）始终常驻 —— One 的版式就是那样，
    /// 收起会让用户找不到返回；全屏则相反，画面要干净，点一下再叫出来。
    @State private var chromeHidden = false
    @State private var hideTask: Task<Void, Never>?
    /// 单击与双击的仲裁：单击延迟 0.26s 执行，双击一落就取消它。
    @State private var tapTask: Task<Void, Never>?
    @State private var showsInfo = false
    /// 「更多本剧」与「跳过片头片尾」两个 sheet 的开关。
    /// 这两项原属上游 `CatalogPlaybackActions`，收进枚举后在 One 页里自己持有。
    @State private var showsSeries = false
    @State private var showsSkip = false
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
    /// 画质增强的处理器：每页一份，绑到当前 player 上（见 `prepareEnhancer`）。
    /// 两个开关都关着时为 nil —— 空闲的 `AVSampleBufferDisplayLayer` 被反复挂上摘下
    /// 在 Duo 折展时是 use-after-free 风险（`VideoEnhancement.enabled` 的注释记着这条）。
    @State private var enhancer: VideoEnhancer?

    private var session: PlaybackSession? { kit.session }
    private var channel: Channel? { kit.channel }
    private var layout: PlayerControlsLayout { PlayerControlsLayout(stored: layoutRaw) }
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
        return max(design, cleared)
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
        // 窗口底边在列坐标系里 = winY + winH。屏幕底边 = colH。
        // 落到窗口内部的安全区高度 = max(0, safeBottom - (colH - winY - winH))。
        let spaceBelowWindow = max(0, colH - winY - winH)
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
        // 窗口右缘在列内的位置 = winX + winW；列宽 = colW。
        // 窗口右侧还剩多宽？这段里有多少被安全区占掉？
        let spaceRightOfWindow = max(0, colW - winX - winW)
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
                gestureHUD
                boostLayer
                infoLayer
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
        .task(id: itemIdentity) { await tracksTask(); prepareEnhancer() }
        .task(id: skipKey) { await loadSkipMarkers() }
        // 锁屏 / 控制中心：接上遥控键，并在状态变化时重写信息。
        // `initial: true` 覆盖「进页面时就已经在播」这一常见情形。
        .onAppear { attachClock(); if let session { nowPlaying.start(session) } }
        // 会话是异步来的（先有 channel，再有 player），两个时刻都要重新挂看门狗。
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
            // [mi3s] 二开：返回键**任何状态都在**，而且全屏时只退全屏。
            // 原来只在全屏里画，且点了直接 dismiss 整页；选集页里反而没有返回，
            // 只能靠屏幕边缘右滑。现在：
            //   全屏 → `onExitFullScreen()`：退全屏，回到选集页继续播（画面、进度、选集都在）；
            //   选集页 → `onBack()`：正常返回上一页。
            // 这里用控件层**自己**的 `fullScreen`（就是它正在画的那一版）判断，不读页面状态：
            // 两个状态一旦不同步，返回就会被解释成「离开页面」。
            iconButton("chevron.left", label: L10n.text("Back")) {
                if fullScreen { onExitFullScreen() } else { onBack() }
            }
            // ⛔ 已删「伪全屏」按钮（rectangle.expand.vertical）。
            //    它在 OneSkin 路径下只是把窗口铺满整列，真正的全屏由底部胶囊条/手势承担；
            //    留在顶栏第二位只造成「这里一个全屏、那里一个全屏」的混淆。
            //    全屏进出的唯一入口现在是控制栏里的 fullScreen 控件（若设为可见）+ 系统手势。
            iconButton("rectangle.landscape.rotate", label: L10n.text("Rotate")) { onRotate() }
            // 全屏里没有「合拢/展开」这回事（画面已占满整屏），把它收掉免得占位。
            if !fullScreen {
                // ⛔ 已删「选集抽屉」按钮（sidebar.right）。
                //    选集面板由底部胶囊条的「选集」chip 打开，顶栏再放一个同功能按钮
                //    会让两个入口抢同一块状态（showsEpisodes vs showsSeries）。
                ForEach(surfacedControls, id: \.self) { control in
                    controlButton(control)
                }
            }

            Spacer(minLength: 0)

            iconButton(locked ? "lock.fill" : "lock.open",
                       label: L10n.text(locked ? "Unlock Controls" : "Lock Controls")) {
                locked.toggle()
                if locked { PlayerOrientation.lock() } else { PlayerOrientation.unlock() }
            }
            // ⛔ 全屏态收掉「更多」菜单：它弹出的选集 / 画质 / 音轨 / 字幕 / 倍速 /
            // 外播 / 视频信息都是选集页的选项，全屏里点出来会叠在画面上，
            // 且命中区盖住下方的播放控制 —— 正是「全屏还夹带选集页菜单」的根因。
            // 上游全屏只留播放器自己的 transport（返回退全屏 / 播放 / 进度），
            // 没有任何页级菜单。
            if !fullScreen {
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
        .frame(width: winW, height: m.hit)
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
        // 返回、全屏、旋转（全屏态到此为止）
        // + 合拢、更多、选集聚合（仅选集页）+ 锁定。
        let structural = fullScreen ? 2 : 5
        let spare = winW - barLeading - barTrailing - CGFloat(structural) * m.hit
        return max(0, Int(spare / m.hit))
    }

    /// 控制栏里**直接显示**的控件。
    ///
    /// 现在由两个独立集合决定（设置页可改）：
    /// · 选集页 → `layout.watchSurfaced`
    /// · 全屏态 → `layout.fullSurfaced`
    /// 同一个控件可以同时出现在两边，互不冲突。列表顺序仍按 `layout.top` 的槽位顺序，
    /// 这样用户在设置里调过位置后，两种状态里的相对次序保持一致。
    private var surfacedControls: [PlayerControl] {
        let allowed = Set(fullScreen ? layout.fullSurfaced : layout.watchSurfaced)
        return Array(layout.top
            .filter { $0 != .fullScreen && $0 != .rotate && $0 != .lock }
            .filter { allowed.contains($0) }
            .filter(available)
            .prefix(topSurfaceCapacity))
    }

    /// 当前上下文是否用得上这个控件（与 `MobilePlayerView.available` 同一套判断）。
    private func available(_ control: PlayerControl) -> Bool {
        guard let session else { return false }
        switch control {
        case .airPlay: return true
        case .episodes: return channel?.historyContext != nil
        case .pictureInPicture: return kit.pip.supported
        case .miniPlayer, .pictureSize, .videoInfo, .anotherPlayer: return true
        case .lock, .rotate: return true
        case .danmaku: return !session.danmaku.isEmpty
        case .quality: return session.qualities.count > 1
        case .audio: return session.audioChoices.count > 1 || (kit.tracks.audio?.options.count ?? 0) > 1
        case .subtitles: return !subtitleTracks.isEmpty || !(kit.tracks.legible?.options.isEmpty ?? true)
        case .speed: return !session.isLive
        case .speechSubtitles: return speechLanguage != nil
        case .backTen, .forwardTen: return seekable
        case .playPause, .fullScreen: return true
        case .previousEpisode: return step(back: true) != nil
        case .nextEpisode: return step(back: false) != nil
        // 这四项来自上游那套菜单，收进枚举后一并给出可用性判据。
        case .autoPlayNext: return channel.flatMap { store.catalog(for: $0) } != nil
        case .moreInSeries: return channel?.historyContext != nil
        case .skipIntroAuto, .skipIntroManual: return !session.isLive
        }
    }

    // MARK: - 中央播放组

    private var centerTransport: some View {
        HStack(spacing: m.playGlyph * 0.72) {
            if let previous = step(back: true) {
                smallCircle("backward.end.fill") { previous.go() }
                    .disabled(previous.busy)
            }
            smallCircle("gobackward.10") { seek(by: -10) }
            bigCircle(playing ? "pause.fill" : "play.fill") { session?.togglePlayback() }
            smallCircle("goforward.10") { seek(by: 10) }
            if let next = step(back: false) {
                smallCircle("forward.end.fill") { next.go() }
                    .disabled(next.busy)
            }
        }
        .frame(width: winW, height: m.playHit)
        .position(x: winW / 2, y: winH * 0.496)
    }

    // MARK: - 底部进度条

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // 左侧时间码同理：按文字实际宽度占位，不再吃 10.8% 窗口宽。
            // 两侧都收紧后，中间的 seekTrack 才能真正撑满剩余空间，
            // 进度条才「占满整个宽度」。
            Text(clock(position)).monospacedDigit()
                .fixedSize()
                .padding(.trailing, 8)
            // 进度条吃掉中间剩余宽度。以前写死 0.60×winW，两侧再各让 0.108/0.171，
            // 加起来只有 0.919，差的那 3.8% 没人占 —— 右端全屏键永远比顶栏往里缩一截。
            seekTrack
            // 剩余时间：给一个**够用就停**的宽度，不按 winW 比例切。
            //
            // 原来写死 `winW * 0.171`（竖屏 444 宽时 = 76pt），
            // 而 "-1:39" 五个字符在 caption 字号下只要 40pt 左右 ——
            // 多出来的 36pt 全变成「全屏键前面的一片空白」，
            // 于是按钮永远落不到窗口右下角。用户报的「没占满整个宽度」
            // 一半是这个框撑的（另一半是 barTrailing 掺了列宽，已另修）。
            // 用 fixedSize 让它按真实文字宽度占位，右侧只留一点点间隙。
            Text(remainText).monospacedDigit()
                .fixedSize()
            // 这里以前单独传 `winW * 0.040` 和小一号的字，是同一排里唯一
            // 「框更窄、字形更小」的图标。现在与顶栏同一套：同一颗图标、同一个热区。
            iconButton(kit.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: kit.isFullScreen ? L10n.text("Exit Full Screen") : L10n.text("Full Screen")) {
                kit.toggleFullScreen()
            }
        }
        .font(.system(size: m.caption))
        .foregroundStyle(.white.opacity(0.82))
        // 与顶栏同一份边距、同一条对齐线（同样让开左右刘海）。
        .padding(.leading, barLeading)
        .padding(.trailing, barTrailing)
        .frame(width: winW, height: m.hit)
        // 同顶栏：小窗时 0.928 会把热区顶出下沿；
        // 窗口贴屏幕底时还要让开 Home 指示条 —— 见 `bottomBarY`。
        .position(x: winW / 2, y: bottomBarY)
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
        Menu {
            // ★ 严格按 `layout.more` 渲染，但**保留语义分组**（分组壳子固定，条目受控）。
            //
            // 以前的写法是四个硬编码 Section，完全不看 `layout.more` ——
            // 于是设置页里把控件拖进「更多」／拖出来，播放器的更多菜单一点不变，
            // 用户报的「设置改了没反应」就是这个。
            //
            // 现在：每条控件的**是否出现**由 `layout.more.contains` 决定，
            // **左右顺序**按用户在设置页里拖出来的 `layout.more` 顺序排
            // （组内排序 = `more` 数组里的相对次序）。
            // 空组自动隐藏，不会留下一排标题。
            ForEach(Array(visibleMoreGroups.enumerated()), id: \.offset) { _, group in
                Section(group.title) {
                    ForEach(group.controls) { control in
                        moreItem(control)
                    }
                }
            }
        } label: {
            chromeIcon("ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("Playback Options"))
        .accessibilityIdentifier("player.oneskinOptions")
    }

    /// 「更多」里按分组切好的可见条目，已按 `layout.more` 的先后排好序。
    ///
    /// 分组的**成员资格**是写死的语义（倍速/字幕归「播放」，画面比例归「画面」…），
    /// 但**哪些出现、以什么顺序出现**全部来自 `layout.more`。
    private var visibleMoreGroups: [(title: String, controls: [PlayerControl])] {
        // 语义分组：只决定「这个控件属于哪个标题」，不决定它出不出现。
        let groups: [(String, [PlayerControl])] = [
            (L10n.text("Playback"), [.episodes, .previousEpisode, .nextEpisode, .rotate, .lock,
                                     .pictureInPicture, .miniPlayer, .anotherPlayer]),
            (L10n.text("Picture"), [.quality, .pictureSize]),
            (L10n.text("Sound"), [.audio, .subtitles, .speed, .danmaku, .speechSubtitles]),
            (L10n.text("Series"), [.autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual]),
            (L10n.text("Info"), [.videoInfo, .airPlay])
        ]
        // 只有进了 `layout.more` 的才出现；组内顺序跟随 `more` 的数组顺序。
        let order = layout.more
        return groups.compactMap { title, members in
            let shown = members.filter { order.contains($0) }
                .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            return shown.isEmpty ? nil : (title: title, controls: shown)
        }
    }

    /// 「更多」里的**单条**控件。所有条目集中在这里，一处定义、一处改。
    ///
    /// 以前同样的功能在四个 `Section` 里各写一遍，和顶栏的 `surfacedControls`
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
            .disabled(!kit.pip.supported)
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
                Label(L10n.text("Automatically skip intro and outro"), systemImage: "forward.to.end.alt")
            }
        case .skipIntroManual:
            Button { showsSkip = true } label: {
                Label(L10n.text("Skip intro / outro"), systemImage: "forward.end")
            }
        case .playPause, .backTen, .forwardTen, .fullScreen:
            // 这四个属于底栏传输区，由 `bottomBar` 独占，不进「更多」。
            EmptyView()
        }
    }

    @ViewBuilder private var playerSection: some View {
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
            .disabled(!kit.pip.supported)
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

    /// 画质增强的处理器：只有开关真的开着才建（见 `enhancer` 的说明）。
    /// 换集后 `player.currentItem` 变了，增强器自己跟着 item 走，不需要重建。
    private func prepareEnhancer() {
        guard VideoEnhancement.enabled, let player = session?.player else { return }
        if enhancer == nil { enhancer = VideoEnhancer(player: player) }
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

    // MARK: - 手势

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
            .simultaneousGesture(
                TapGesture()
                    .onEnded { singleTap() }
            )
            // ⛔ 手势顺序与「独占」是关键：
            //
            // 原来四个手势全部 `simultaneousGesture` 平挂，`DragGesture(minimumDistance: 14)`
            // 又要求移动 14pt 才成立 —— 于是「按住不动 0.45 秒」这段时间里，
            // 长按识别器还没完成、拖动识别器也还没成立，**只剩 TapGesture 能赢**，
            // 手一松就成了单击（用户报的「长按快进变成了单击快进」）。
            //
            // 现在把长按加速放在 `.gesture()` 里做**主手势**：SwiftUI 会先让它识别，
            // 按住满 0.45 秒即进入加速态，此时其它 simultaneous 手势被 `boost != nil` 门控忽略。
            // 拖动改成 `minimumDistance: 24` 并保留 simultaneous —— 够大的位移才抢，
            // 避免手抖把「长按」判成「拖动」。
            .gesture(holdSpeedGesture)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        // 正在长按加速时不接管：横向位移用于改档（已由 movedHold 处理）。
                        if boost != nil { return }
                        dragged(value)
                    }
                    .onEnded { _ in
                        if boost != nil { return }
                        dragEnded()
                    }
            )
            .allowsHitTesting(!locked)
    }

    /// 长按加速 → 不松手继续拖：横滑改档、下滑保持（与旧播放器同一套 `SpeedBoost` 规则）。
    ///
    /// 为什么不用 `onLongPressGesture`：它只在按下/抬起两个时刻回调，
    /// 中间没有位移可读，于是「横滑改档」「下滑保持」在 One 页根本无从实现 ——
    /// 这也正是这里此前只有固定 2× 的原因。
    private var holdSpeedGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginHold()
                case .second(true, let drag):
                    if let drag { movedHold(drag.translation) }
                default:
                    break
                }
            }
            .onEnded { _ in endedHold() }
    }

    /// 能不能加速：要真的在播、有时间轴、且没有别处占用（画中画 / 锁屏）。
    private var canHoldSpeed: Bool {
        !locked && seekable && showsTransport && session?.paused == false && !kit.pip.active
    }

    private func beginHold() {
        guard canHoldSpeed else { return }
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
        boost = nil
        session?.setBoost(nil)
    }

    private func doubleTap(at location: CGPoint) {
        // 双击已经成立，把挂在单击上的「收控件」取消掉。
        tapTask?.cancel(); tapTask = nil
        guard boost == nil else { return }
        guard let session else { return }
        let zone = PictureTaps.zone(x: Double(location.x), width: Double(winW), seekable: seekable)
        switch taps.tap(at: ProcessInfo.processInfo.systemUptime, in: zone) {
        case .toggleControls:
            break
        case .togglePlayback:
            session.togglePlayback()
        case .skip(let seconds, let total, _):
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
        } else if PictureLevel.slides(fromY: value.startLocation.y, height: winH) {
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

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private var externalBinding: Binding<OneSkinHandoff?> {
        Binding(get: { externalStream }, set: { externalStream = $0 })
    }

    // MARK: - 控件呈现（One 风格：白线，不用玻璃球）

    private func iconButton(_ symbol: String, label: String,
                            width: CGFloat? = nil, height: CGFloat? = nil, font: CGFloat? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chromeIcon(symbol, width: width, height: height, font: font)
        }
        .buttonStyle(.plain)
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
        case .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual:
            // 这四项只做菜单条目，没有图标形态（顶栏不放它们）。
            EmptyView()
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
                       label: L10n.text("Picture in Picture")) { kit.pip.toggle() }
        case .danmaku:
            iconButton(danmakuOn ? "text.bubble.fill" : "text.bubble", label: L10n.text("Danmaku")) {
                danmakuOn.toggle()
            }
        case .subtitles:
            iconButton("captions.bubble", label: L10n.text("Subtitles")) {
                chosenSubtitle = subtitleTracks.first?.id
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

    /// 图标方形热区。字形负责好看，热区负责按得中，两者不是一个数。
    var hit: CGFloat { min(40, max(26, (glyph * 1.8).rounded())) }

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
