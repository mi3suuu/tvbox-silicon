#if os(iOS)
import SwiftUI
import AVFoundation
import AVKit
import TVCore

// MARK: - 换皮开关（原版 / One / 哔哩哔哩）

/// 观看页用哪一套外观。
///
/// 三态，不是布尔：原版（上游）、One 皮肤、哔哩哔哩皮肤。两套皮肤各自独立，
/// 关掉任意一套不会把另一套带出来。开关存 `playSkin`；旧版只有
/// `oneSkinEnabled` 一个布尔，首次读到空值时按它迁移，老用户不会因为升级掉皮肤。
// `PlaySkin` 已下沉到 TVCore（`OneSkinShared.swift`）：三平台设置页都要读写它，
// 留在这个 iOS-only 文件里会让 macOS/tvOS 的 SettingsPlayback 找不到类型。
// （原来的 `enum PlaySkin { ... }` 整块已迁走，这个闭合括号是迁移残留，已删。）

// MARK: - 配色

/// 哔哩哔哩的调色板。
///
/// 数值全部来自包内的 `BiliColor.json`（`dark` 组），不是在截图里估的：
/// 页面底 `Wh0` #17181A、更深一档 `Ga0` #101011、卡片与分割线 `Ga2` #2F3134、
/// 次要文字 `Ga5` #757A81、正文 `Ga7` #A2A7AE、强调蓝 `Lb5` #00AEEC（暗态 #0087BD）。
enum BiliPalette {
    /// 整页底（Wh0 dark）。
    static let page = Color(biliHex: 0x17181A)

    /// 弹出面板底。**实测是 #2B2E35（43,46,53）**，比整页底亮一档 ——
    /// 面板浮在画面上要靠这个差异分层。用 `page` 会让面板糊进背景。
    // MARK: 浅色（详情页 / 抽屉 / 面板）
    //
    // 截图取色实测（vphone 1398×2034，`/tmp/pick.swift`）：
    //   详情页内容区、选集抽屉底  → `#FEFEFE`（近纯白）
    //   次级行 / 缩略图占位        → `#F0F0F2`
    //   分隔线                     → `#E9EBEF`
    //   抽屉遮罩                   → `#000000`（**完全不透明**，不是 0.28 半透明）
    //
    // ⚠️ 之前整个详情页用深色 `#17181A` 是最大的一处不等价：
    // 哔哩哔哩详情页是**白底**，深色只用于播放器画面与全屏 chrome。
    static let lightPage = Color(biliHex: 0xFEFEFE)
    /// 抽屉 / 面板底：与页面同色，靠圆角与遮罩区分。
    static let lightPanel = Color(biliHex: 0xFEFEFE)
    /// 次级行、缩略图占位、按压态。
    static let lightFill = Color(biliHex: 0xF0F0F2)
    /// 分隔线。
    static let lightLine = Color(biliHex: 0xE9EBEF)
    /// 浅色底上的主文字（正文黑）。
    static let lightPrimary = Color(biliHex: 0x18191C)
    /// 浅色底上的次级文字。
    static let lightSecondary = Color(biliHex: 0x61666D)
    /// 浅色底上的三级文字（日期、时长、播放量）。
    static let lightTertiary = Color(biliHex: 0x9499A1)

    // MARK: 视频弹窗（操作菜单）—— 实测
    //
    // 截图取色（`/tmp/popup.png`，竖屏 466×678）：
    //   y=0.38    #000000   播放器画面
    //   y=0.400   #C8CCD0   分界线（弹窗上沿）
    //   y=0.42    #F7F7F9   **弹窗底色（近白）**
    //   y=0.44    #F7F7F9   同色
    //   y=0.46    #3382EB   **蓝色元素**
    //   y=0.48    #3480F3   蓝
    //   y=0.52 内 #F6F7F8 / #FEFEFE / #63666A（图标灰）
    //
    // ⚠️ 用户明确指出：「播放器弹出页是有底色的，我们没有」。
    // 之前把操作菜单做成透明覆盖在画面上，实测是**一整块 #F7F7F9 的白色面板**，
    // 上沿有 #C8CCD0 分界线，与上方黑色画面清晰分开。
    static let popupSurface = Color(biliHex: 0xF7F7F9)
    /// 弹窗上沿分界线。
    static let popupEdge = Color(biliHex: 0xC8CCD0)
    /// 弹窗里的主图标色（实测图标是 #63666A 灰，不是白）。
    static let popupIcon = Color(biliHex: 0x63666A)
    /// 弹窗里的强调蓝（实测 #3382EB / 横屏 #3182E8）。
    static let popupAccent = Color(biliHex: 0x3382EB)

    // MARK: 横屏弹窗（实测，与竖屏同类但几何不同）
    //
    // 截图 `/tmp/pop2.png`（2034×1398，678×466pt）逐点采样：
    //   上沿      y≈0.405  #000000 → **硬切换**到面板色
    //   面板底    y=0.41~0.44  #F4F7F8
    //   行区      y=0.70  #F4F7F8（整行底色，略灰于纯白）
    //   左边界    x≈0.20（0.10 黑，0.25 面板色）
    //   右边界    x≈0.87（0.75 面板色，0.90 `#7F807F` 灰）
    //   纯白处    y=0.60 / 0.90  #FEFEFE（图标区本身是白）
    //
    // 关键：**横屏面板不是整宽**，左侧约 20% 和右侧约 13% 都不是面板色；
    // 而且行区底色 #F4F7F8 比纯白略灰 —— 竖屏那里是 #F7F7F9，两者差 3 个灰阶。
    static let popupSurfaceLandscape = Color(biliHex: 0xF4F7F8)
    /// 横屏面板右侧那条灰（实测 #7F807F）。
    static let popupTrailingGrey = Color(biliHex: 0x7F807F)

    // MARK: 全屏「更多」弹窗（**深色**，与详情页弹窗相反）
    //
    // 截图 `/tmp/fs.png`（2034×1398，678×466pt）逐点采样：
    //   左边界  x≈0.63（x=0.60 是 #000000 画面，x=0.65 已是面板色）
    //   右边界  铺到屏幕右缘（x=0.98 仍 #212326）
    //   上沿    y≈0.11~0.12，有一道 `#3D3F43` 分界线
    //   面板底  **#212326**（深灰）
    //   分隔线  y=0.410 `#D8D9DC`（亮线，把段落分开）
    //
    // ⚠️ 关键反差：
    //   详情页弹窗 = **白色** `#F7F7F9`
    //   全屏弹窗   = **深色** `#212326`
    // 两者不能共用一套配色。深色只用于全屏，浅色只用于详情页。
    static let fullscreenPopup = Color(biliHex: 0x212326)
    /// 全屏弹窗上沿/段落之间的亮线。
    static let fullscreenPopupLine = Color(biliHex: 0xD8D9DC)
    /// 全屏弹窗上沿那道稍暗的边（实测 #3D3F43）。
    static let fullscreenPopupEdge = Color(biliHex: 0x3D3F43)

    static let panel = Color(biliHex: 0x2B2E35)

    /// 选中态强调色。**实测 #FF7EA9（255,126,169）**，不是品牌粉 #FB7299，
    /// 也不是强调蓝 —— 面板里的选中项用的是这个偏亮的粉。
    static let panelActive = Color(biliHex: 0xFF7EA9)
    /// 更深一档的底（Ga0 dark），画面下方的信息区用它压住。
    static let base = Color(biliHex: 0x101011)
    /// 最深的底（Ga1 dark），全屏播放时画面外的空白用它。
    static let deep = Color(biliHex: 0x0A0B0C)
    /// 卡片 / 输入框 / 已选中的胶囊（Ga2 dark）。
    static let card = Color(biliHex: 0x2F3134)
    /// 分割线（Ga3 dark）。
    static let line = Color(biliHex: 0x46494D)
    /// 三级文字（Ga5 dark）：时间、集数、「共 12 集」。
    static let tertiary = Color(biliHex: 0x757A81)
    /// 二级文字（Ga7 dark）：简介、UP 主名。
    static let secondary = Color(biliHex: 0xA2A7AE)
    /// 主文字（浅色组的 Ga1，#F1F2F3）。
    static let primary = Color(biliHex: 0xF1F2F3)
    /// 强调蓝。播放器的一切强调都用它：进度条、选中态、倍速徽标。
    static let accent = Color(biliHex: 0x00AEEC)
    /// 强调蓝的暗态，压在深底上不至于刺眼。
    static let accentDim = Color(biliHex: 0x0087BD)
    /// 品牌粉：点赞、收藏的实心态。
    static let pink = Color(biliHex: 0xFB7299)
    /// 警示（Re6 dark）。
    static let warn = Color(biliHex: 0xD9615F)
    /// 成功（Gr5 dark）。
    static let good = Color(biliHex: 0x1FA251)
}

extension Color {
    /// `#RRGGBB` 直接进 Color。只在本文件里用，别扩散出去。
    init(biliHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - 播放器扩展状态（原生播放器没有、哔哩哔哩有的那几项）

/// 哔哩哔哩播放器里、我们的 `PlaybackSession` 还没有的三件事：定时关闭、镜像翻转、后台听视频。
///
/// 做成单例而不是 `@State`：Duo 合拢 / 展开会把观看页整个撕掉重建，
/// `@State` 每次都归零 —— 定时关闭会静默消失、镜像会自己翻回去。
/// 单例的字段跨重建存活，页面出现时把 `onSleep` 重新挂上就行。
@MainActor @Observable final class BiliPlayerExtras {
    static let shared = BiliPlayerExtras()

    /// 镜像翻转（左右）。存 `UserDefaults`，跨页面、跨启动保持。
    static let mirrorKey = "biliMirror"
    /// 后台听视频。关闭时进后台就暂停；开启时只出声不出画。
    static let backgroundAudioKey = "biliBackgroundAudio"

    var mirror: Bool {
        didSet { UserDefaults.standard.set(mirror, forKey: Self.mirrorKey) }
    }
    var backgroundAudio: Bool {
        didSet { UserDefaults.standard.set(backgroundAudio, forKey: Self.backgroundAudioKey) }
    }

    /// 定时关闭的到点时刻。nil = 没设。
    private(set) var sleepDeadline: Date?
    /// 到点时做什么。页面每次出现重新挂 —— 会话会被重建，闭包不能长期持有旧的。
    @ObservationIgnored var onSleep: (@MainActor () -> Void)?

    @ObservationIgnored private var ticker: Task<Void, Never>?

    private init() {
        mirror = UserDefaults.standard.bool(forKey: Self.mirrorKey)
        // 默认开：`UIBackgroundModes` 里有 audio，会话也是 `.playback` 类别，
        // 本来就能后台出声；这一项只是让用户可以关掉它。
        backgroundAudio = UserDefaults.standard.object(forKey: Self.backgroundAudioKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.backgroundAudioKey)
    }

    /// 定时关闭的档位，与哔哩哔哩一致。
    static let sleepChoices: [(minutes: Int, title: String)] = [
        (15, L10n.text("In 15 minutes")),
        (30, L10n.text("In 30 minutes")),
        (60, L10n.text("In 1 hour")),
        (90, L10n.text("In 1.5 hours")),
        (120, L10n.text("In 2 hours")),
    ]

    /// 现在还剩多少秒；nil = 没设。
    var sleepRemaining: TimeInterval? {
        guard let deadline = sleepDeadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    /// 「还剩 12:34」。
    var sleepBadge: String? {
        guard let left = sleepRemaining else { return nil }
        let total = Int(left.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func startSleep(minutes: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepDeadline = deadline
        Diagnostics.shared.record(.info, "bili", "sleep timer armed for \(minutes) min")
        arm()
    }

    /// 把已存的到点时刻重新挂上（页面重建后用）。
    func resumeSleepIfNeeded() {
        guard sleepDeadline != nil else { return }
        arm()
    }

    func cancelSleep() {
        ticker?.cancel(); ticker = nil
        sleepDeadline = nil
    }

    private func arm() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let deadline = self.sleepDeadline else { return }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 {
                    self.sleepDeadline = nil
                    self.ticker = nil
                    Diagnostics.shared.record(.info, "bili", "sleep timer fired")
                    self.onSleep?()
                    return
                }
                // 一秒一查：剩下的秒数要能显示在徽标上，粗粒度只会让它跳。
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

// MARK: - 画面层

/// 哔哩哔哩的画面：一条 `AVPlayerLayer`，支持左右镜像。
///
/// 不用 `AVPlayerViewController`：AVKit 自己接管布局，无视 SwiftUI 的 frame，
/// 也没法让画面单独镜像（它镜像会连播放器自绘的字幕一起翻）。
/// 弹幕和字幕是 SwiftUI 层，压在它上面，镜像只作用于画面本身 —— 与哔哩哔哩一致。
struct BiliSkinPicture: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var mirrored: Bool = false
    /// 色彩滤镜（二进制实证哔哩哔哩有 `color_filter` 设置项）。
    var colorFilters: [Any] = []
    /// 画中画控制器。给了才把这条 `AVPlayerLayer` 登记成 PiP 的内容源。
    ///
    /// ⛔ 这是「哔哩哔哩皮肤完全开不出小窗」的修复点。
    /// 此前本结构体**没有 pip 参数**，于是 `PictureInPicture.current` 恒为 nil：
    ///   · 全屏右缘那颗 `pip` 键 → `startCurrent()` 第一行 `guard let controller = current` 直接返回；
    ///   · `RootView` 的 `pipPossible: PictureInPicture.current != nil` 恒 false
    ///     → `PlaybackExit` 走 ③b 返回 `.keep`，离开 App 既不浮窗也不登出，音频在后台空转。
    /// 照 `OneSkinFixedPlayerLayer` 的写法接上即可，注意 `shouldRender` 闸：
    /// 一个 `AVPlayer` 同时只能驱动一条 `AVPlayerLayer`，PiP 在跑时内嵌层不得再抢 player。
    var pip: PictureInPicture? = nil

    func makeUIView(context: Context) -> BiliPictureView {
        let view = BiliPictureView()
        // PiP 已在跑时，内嵌层不挂 player（否则悬浮窗只剩声音）。
        let renders = pip?.shouldRender(view.playerLayer) ?? true
        view.apply(player: renders ? player : nil,
                   gravity: gravity,
                   mirrored: mirrored)
        view.applyColorFilter(colorFilters)
        pip?.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: BiliPictureView, context: Context) {
        let renders = pip?.shouldRender(view.playerLayer) ?? true
        view.apply(player: renders ? player : nil,
                   gravity: gravity,
                   mirrored: mirrored)
        view.applyColorFilter(colorFilters)
        // ⛔ 折叠 / 展开 / 转屏 / 进出自绘页都会换 layer，必须重新登记：
        // 旧 layer 的宿主被销毁后 controller 仍指着不存在的画面，
        // `isPictureInPicturePossible` 会变 false，浮窗再也起不来。
        // 这里**不因 shouldRender 为 false 就跳过 attach** —— 那正是
        // 「PiP 活跃时折叠一次，退出小窗后 PiP 按钮永久灰掉」的成因。
        pip?.attach(view.playerLayer)
    }
}

/// 只画一条 `AVPlayerLayer` 的视图。
final class BiliPictureView: UIView {
    let playerLayer = AVPlayerLayer()

    override class var layerClass: AnyClass { CALayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // ⚠️ **必须关掉用户交互**。
        // 这个 UIView 铺满整个播放器区域，默认 `isUserInteractionEnabled = true`，
        // 会把落在它上面的触摸全部吃掉 —— SwiftUI 叠在上层的按钮（返回/播放/全屏/更多）
        // 因此**一个都点不动**（真机实测：详情页除抽屉和 tab 外全部无响应）。
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关掉隐式动画：旋转 / 折叠时 layer 尺寸每帧都在变，带动画会拖出一条残影。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    /// 施加色彩滤镜。`CALayer.filters` 在 iOS 上是私有 API 但长期可用；
    /// 这里只做视觉微调，取不到 CIFilter 时静默跳过，不影响播放。
    func applyColorFilter(_ filters: [Any]) {
        let want = filters.isEmpty ? nil : filters
        let cur = playerLayer.filters as? [Any] ?? []
        // 粗略比较数量与首个滤镜名，避免每帧重建
        if cur.count != (want?.count ?? 0)
            || (cur.first as? CIFilter)?.name != (want?.first as? CIFilter)?.name {
            playerLayer.filters = want
        }
    }

    /// `player` 传 nil 表示「这一帧不该由我渲染」——PiP 在跑时内嵌层必须让出 player，
    /// 否则悬浮窗只剩声音（一个 `AVPlayer` 只能驱动一条 `AVPlayerLayer`）。
    func apply(player: AVPlayer?, gravity: AVLayerVideoGravity, mirrored: Bool) {
        if playerLayer.player !== player { playerLayer.player = player }
        if playerLayer.videoGravity != gravity { playerLayer.videoGravity = gravity }
        // 镜像用 layer 的仿射变换：只翻画面，不翻压在它上面的 SwiftUI 控件与字幕。
        let wanted = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        if playerLayer.affineTransform() != wanted {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.setAffineTransform(wanted)
            CATransaction.commit()
        }
    }
}

// MARK: - 时间格式

enum BiliClock {
    /// `1:02:03` / `02:03`。
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

#endif
