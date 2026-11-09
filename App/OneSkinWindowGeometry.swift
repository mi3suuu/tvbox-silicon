import Foundation
import CoreGraphics
import SwiftUI
import AVFoundation
import QuartzCore

/// 画面窗口的**唯一几何来源**。
///
/// 为什么要有这个类型：`pictureColumn`（画画面）和 `pictureControls`（画按钮）
/// 各自算过一遍 `winX / winY / winW / winH`。两份代码在 R10 那次改动里只同步
/// 了一处，结果按钮画在画面之外 —— 靠注释里写「两处必须保持一致」维持的不变式
/// 迟早会破。所有窗口几何必须从这里取。
struct OneSkinWindowGeometry {
    let colW: CGFloat
    let colH: CGFloat
    let inset: CGFloat
    let winX: CGFloat
    let winY: CGFloat
    let winW: CGFloat
    let winH: CGFloat

    /// 顶部/底部 padding —— 必须与 `stage` 真正施加的一致。
    /// `stage` 用的是：
    ///   `.padding(.top,    landscape ? 8 : 0)`
    ///   `.padding(.bottom, landscape ? layout.margin : 28)`
    /// 其中 `margin = max(10, 列宽 × 0.0147)`（**不是**列高的比例）。
    // ===== 版式常量（One 1.7.0 逐像素实测）=====
    //
    // 这些数字原先散落在 8 个地方各写一遍：
    //   0.0333 ×4、0.0236 ×3、0.5334 ×4、0.4499 ×2、0.0167 ×2、0.091 ×3、466.0 ×1
    // 改一处不同步一处就会错位（R10 那次只改了 pictureColumn 的 winY，
    // 按钮立刻画到画面外）。现在**只在这里定义**，别的地方一律引用。
    enum Metrics {
        /// 横屏左列宽 / 间隙 / 右栏宽（合计 1.0）
        static let columnLeft: CGFloat = 0.5334
        static let columnGap: CGFloat = 0.0167
        static let columnRight: CGFloat = 0.4499
        /// 画面窗口的水平内缩（相对列宽）
        static let insetLandscape: CGFloat = 0.0333
        static let insetPortrait: CGFloat = 0.0236
        /// 竖屏画面窗口顶部起点（相对列高）
        static let portraitTop: CGFloat = 0.091
        /// 横屏窗口垂直中心（相对可用高度）
        static let landscapeCentre: CGFloat = 0.455
        /// 字号缩放基准列高
        static let fontBaseHeight: CGFloat = 466
        /// 画面窗口最小高度
        static let minPictureHeight: CGFloat = 120
        /// **画面窗口的版式比例（固定，不随片源变）**。
        /// One 实测 1015×558 px = 1.819。窗口尺寸必须恒定 ——
        /// 一旦由片源比例决定，初始兜底值（0.4）会把 winH 算成 842pt
        /// 超出屏幕、画面被裁到看不见，用户点「填充」才看得到；
        /// 等 presentationSize 轮询读到真值，窗口又跳一次。
        /// 片源不匹配时由 `videoGravity`(.resizeAspect) 在**窗口内部** letterbox。
        static let windowAspect: CGFloat = 1.819
    }

    /// 横屏内容区上方的内缩量。
    ///
    /// 原来 8pt —— 对应 `stage` 上的 `.padding(.top, 8)`。两者必须同步：
    /// 那个 padding 已经删掉（它让屏幕最上沿露出 8pt 黑条），这里也必须归零，
    /// 否则 `usableH` 少算 8、窗口会凭空上移 8pt，顶栏跟着一起偏。
    static let topPaddingLandscape: CGFloat = 0
    static let bottomPaddingPortrait: CGFloat = 28
    static func margin(forColumnWidth width: CGFloat) -> CGFloat {
        max(10, width * 0.0147)
    }

    /// - Parameters:
    ///   - size: 这一列的尺寸
    ///   - landscape: 由容器决定，**不要**用 `colW > colH` 反推
    ///     （双列时左列是 361×466 的窄高矩形，反推会永远判成竖屏）
    ///   - fullScreen: 全屏态铺满可用空间并 letterbox 居中
    ///
    /// ⚠️ 片源比例**不参与窗口几何**，所以不再有 `aspectRatio` 参数。
    /// 2026-11-09 之前 `winH = innerW / ratio`（ratio 取片源 presentationSize）：
    /// 竖屏片源 0.56 会把窗口算成列高的近两倍，用户看到的正是
    /// 「播放竖屏时播放器被拉高、画面糊满整列」；等轮询读到真比例，
    /// 窗口还会再跳一次。片源比例只决定 `videoGravity` 在窗口内部怎么留黑边。
    @MainActor
    init(size: CGSize, landscape: Bool, fullScreen: Bool) {
        let colW = size.width
        let colH = size.height
        self.colW = colW
        self.colH = colH

        let inset = landscape ? colW * Metrics.insetLandscape : colW * Metrics.insetPortrait
        // ⚠️ 只作旧版式记录，**不参与任何窗口几何计算**。
        // 外壳满宽后这两个比例只剩史料价值；谁再拿它去减 winW 就是把边距带回来。
        self.inset = inset

        if fullScreen {
            // 全屏：窗口铺满整列，由 `.resizeAspect` 在内部 letterbox。
            //
            // 之前这里也按片源比例算 `winH = colW / ratio`：初始兜底 ratio 是 0.4，
            // 算出的高度再被 `min(·, colH)` 夹住 —— 表面上「看得见」，
            // 但真比例到达后 `winH` 会跳一次，正是用户报的「播放器大小会变化」。
            // 全屏要的本来就是「铺满」，比例交给 videoGravity 就够了。
            self.winW = colW
            self.winH = colH
            self.winX = 0
            self.winY = 0
        } else {
            // ★ 播放器外壳**满宽**（用户明确要求）：
            //   · 竖屏播放态：占满整个屏幕宽度；
            //   · 横屏双栏：占满整个左列宽度（winX = 0）。
            let innerW = max(colW, 1)

            // ⛔ 竖屏与横屏**独立定义**（用户明确：不能共用一个公式）。
            //
            // 越界根因：竖屏的 `colH` 是 `pictureHeightOf` 算出的「画面区高度」，
            // 它**已经包含**窗口高度（= screenH*0.091 + winH + screenH*0.04）。
            // 旧代码又用 `colH*0.091` 当 winY、用 `colH` 当 maxH 基准 ——
            // 对「含窗口高的高度」再套一次「顶部留白比例 + 窗口高」，双重计算。
            // 屏幕较矮时 colH 被 0.72 夹住，winY + winH 就超出 colH，
            // 窗口底部压进 detailColumn —— 用户报的「越界」。
            //
            // 正解：竖屏窗口几何直接用**屏幕尺寸**（离散值，不随动画变），
            // 与 colH/picH 完全解耦：
            //   winW = 屏幕宽（满宽）
            //   winH = 屏幕宽 ÷ 1.819（固定版式比例，不夹 maxH）
            //   winY = 屏幕高 × 0.091（顶部留白，基于屏幕高）
            // 窗口底 = 屏幕高×0.091 + 屏宽÷1.819，天然 ≤ 屏幕高（屏宽÷1.819 < 屏高）。
            let raw = OneSkin.fixedScreenSize()
            let screenW = min(raw.width, raw.height)
            let screenH = max(raw.width, raw.height)

            if landscape {
                // 横屏：窗口在左列内，winW=左列宽、winH=winW/1.819、中心 45.5%。
                let usableH = max(
                    colH - Self.topPaddingLandscape - Self.margin(forColumnWidth: colW),
                    1
                )
                let fittedH = max(
                    min(innerW / Metrics.windowAspect, usableH * 0.91),
                    min(Metrics.minPictureHeight, colH)
                )
                self.winW = innerW
                self.winH = fittedH
                self.winX = 0
                self.winY = usableH * Metrics.landscapeCentre - fittedH / 2
            } else {
                // 竖屏：独立定义，用屏幕尺寸，不经过 picH 双重计算。
                self.winW = innerW
                self.winH = max(innerW / Metrics.windowAspect, min(Metrics.minPictureHeight, screenH))
                self.winX = 0
                self.winY = screenH * Metrics.portraitTop
            }
        }
    }

    /// 窗口内归一化坐标 → 列坐标
    func x(_ fx: CGFloat) -> CGFloat { winX + winW * fx }
    func y(_ fy: CGFloat) -> CGFloat { winY + winH * fy }
}

// MARK: - ⛔ 选集页播放器样式（LOCKED · 不随通用播放器样式改动）
//
// 这段刻意和 `OneSkin.swift` / `MobilePlayer.swift` / `OneStylePlayerSurface.swift`
// 分开存放：那几个文件近期被并行改动过多次，而选集页的播放器一旦被带跑，
// 表现就是「有些资源点进去看不了」，竖屏片源最先中招。
//
// 已经踩过的两个坑（都不要再改回去）：
//  ① 通用播放器把画面换成 `AVPlayerViewController` 之后，选集页那个 8×8 离屏
//     隐藏 `PlaybackView` 也会创建一个 AVKit 控制器，和这里的 `AVPlayerLayer`
//     抢同一个 `AVPlayer`。AVKit 在离屏小视图里会停掉视频输出；而
//     `pictureBox(.source, aspect:)` 还会按片源比例把视图压扁 —— 竖屏片源 0.56
//     会把 8×8 压成约 4.5pt 宽的一条，输出直接失效。
//  ② 四档「适应/填充/铺满/拉伸」里按片源比例做的 `scaleEffect`：
//     竖屏片源在 1.819 的横向窗口里被放大 1.819÷0.5625 ≈ 3.2 倍，
//     画面只剩中间一条，看起来完全没内容。横屏片源比例接近窗口所以无感。
//
// 固定规则（锁定，勿改）：
//   · 窗口尺寸只从 `OneSkinWindowGeometry` 取（1.819，与片源无关）；
//   · 画面只有 `.resizeAspect` / `.resizeAspectFill` 两档，切换不改变窗口尺寸；
//   · 不读 `presentationSize`、不做 `aspectRatio` / `scaleEffect` 或任何按片源比例的变换；
//   · 同一个 `AVPlayer` 在选集页只允许有这一个渲染宿主。
enum OneSkinPlayerStyle {
    static let windowAspect: CGFloat = OneSkinWindowGeometry.Metrics.windowAspect

    /// 「填充」只切裁切方式。窗口几何完全不读它。
    static func gravity(fill: Bool) -> AVLayerVideoGravity {
        fill ? .resizeAspectFill : .resizeAspect
    }
}

/// 选集页窗口内的固定画面：海报同色虚化底 + 一个 AVPlayerLayer。
/// `fill` 是唯一可变项，且只影响画面在窗口里怎么画。
///
/// ⛔ 2026-11-09 越界修复：`UIViewRepresentable` 的宿主 UIView 在 SwiftUI
/// 里会被父级提议撑大（只给 `.frame` 不保证它的 bounds 就等于那个值），
/// 而 `layoutSubviews` 原本直接 `playerLayer.frame = bounds`，于是竖屏片源
/// 按**整列**尺寸 letterbox，画面从窗口顶部一直铺到列底 —— 用户看到的
/// 「竖屏和横屏播放器尺寸不一样 / 明显越界」。现在 layer 尺寸只认传进来的
/// `size`（= winW×winH），并加 `.clipped()` 兜底，窗口之外一笔都不画。
struct OneSkinFixedPicture: View {
    let player: AVPlayer
    let fill: Bool
    let poster: UIImage?
    let size: CGSize
    /// 画中画控制器。给了才把这条 `AVPlayerLayer` 登记给它；不给就只是普通画面。
    var pip: PictureInPicture? = nil

    var body: some View {
        // ⛔ 虚化底必须用 `.background` 挂在画面层**之下**，不能和
        // `OneSkinFixedPlayerLayer` 同处一个 ZStack：
        // UIViewRepresentable 的 UIView 是 UIKit 子视图，它和 SwiftUI 层的
        // 合成顺序不受 ZStack 声明序控制。实测同层时海报虚化把视频盖得
        // 只剩窗口顶部一条横带（用户报「视频源内容没有正确在播放器中」）。
        // `.background` 由 SwiftUI 明确排在宿主视图之后，层级确定。
        OneSkinFixedPlayerLayer(player: player,
                                videoGravity: OneSkinPlayerStyle.gravity(fill: fill),
                                size: size,
                                pip: pip)
            .frame(width: size.width, height: size.height)
            .background { OneSkinPosterWash(image: poster) }
            .clipped()
    }
}

/// 只画 `AVPlayerLayer` 的透明宿主。不用 `AVPlayerViewController`：
/// AVKit 会自己接管布局，无视 SwiftUI 给的 frame，也无视 `clipsToBounds`。
struct OneSkinFixedPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity
    /// 锁定的窗口尺寸（winW×winH），layer 的 frame 只认它。
    let size: CGSize
    /// 画中画：把这条 layer 登记成内容源。nil 时不碰 PiP。
    var pip: PictureInPicture? = nil

    func makeUIView(context: Context) -> OneSkinFixedPlayerView {
        let view = OneSkinFixedPlayerView()
        view.backgroundColor = .clear
        // 宿主 bounds 在 SwiftUI 里不可信（实测会被压成约 28pt 高的一条），
        // 但它只是 layer 的容器：让它不裁子层，layer 画满锁定的窗口尺寸，
        // 越出部分由外层窗口的 `.clipped()` 统一裁掉。
        view.clipsToBounds = false
        view.isUserInteractionEnabled = false
        view.fixedSize = size
        view.attach(player: player, gravity: videoGravity)
        // 只登记一次；`attach` 内部会判断「PiP 已在跑 / 已有 controller」。
        pip?.attach(view.renderLayer)
        return view
    }

    func updateUIView(_ view: OneSkinFixedPlayerView, context: Context) {
        view.fixedSize = size
        view.update(player: player, gravity: videoGravity)
        // ⚠️ 一个 AVPlayer 同时只能驱动一条 AVPlayerLayer：PiP 悬浮窗在跑的时候，
        // 这条内嵌 layer 再抢 player，悬浮窗就只剩声音。`shouldRender` 是那只闸。
        if let pip, !pip.shouldRender(view.renderLayer) {
            view.update(player: nil, gravity: videoGravity)
        } else {
            view.update(player: player, gravity: videoGravity)
            pip?.attach(view.renderLayer)
        }
    }
}

final class OneSkinFixedPlayerView: UIView {
    private let playerLayer = AVPlayerLayer()
    /// 由 SwiftUI 每次 update 写入；变化时立刻重新布局。
    var fixedSize: CGSize = .zero {
        didSet { if oldValue != fixedSize { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    }
    #if DEBUG
    private var lastLogged = ""
    #endif

    /// `UIViewRepresentable` 会问宿主「你想要多大」。不回答的话它按父级
    /// 贪婪提议给一个很扁的 bounds（实测窗口高 185pt、宿主只拿到约 28pt），
    /// 画面就被压成顶部一条。这里明确回报锁定的窗口尺寸。
    override var intrinsicContentSize: CGSize { fixedSize }
    override func sizeThatFits(_ size: CGSize) -> CGSize { fixedSize }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }

    func update(player: AVPlayer?, gravity: AVLayerVideoGravity) {
        if playerLayer.player !== player { playerLayer.player = player }
        playerLayer.videoGravity = gravity
        setNeedsLayout()
    }

    /// 给画中画控制器当内容源用的那条 layer。
    var renderLayer: AVPlayerLayer { playerLayer }

    /// SwiftUI 只改 frame 不重绘时（旋转 / 片源就绪 / 展开横屏），
    /// layer 会停在旧尺寸上，所以每次布局都重算。
    ///
    /// **绝不能直接用 `bounds`，也不能拿它做上限**：宿主 bounds 由 SwiftUI
    /// 决定，实测在双列页只有约 28pt 高，用它 letterbox 出来的竖屏画面会
    /// 缩成窗口顶部一条。layer 的 frame 只认锁定的 `fixedSize`（winW×winH），
    /// 起点 (0,0) 与窗口的 `.offset(winX, winY)` 对齐，超出部分交给窗口裁切。
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.setDisableActions(true)
        playerLayer.frame = CGRect(x: 0, y: 0,
                                   width: max(fixedSize.width, 1),
                                   height: max(fixedSize.height, 1))
        #if DEBUG
        let line = "fixedLayer view=\(Int(bounds.width))x\(Int(bounds.height)) fixed=\(Int(fixedSize.width))x\(Int(fixedSize.height)) layer=\(Int(playerLayer.frame.width))x\(Int(playerLayer.frame.height)) videoRect=\(Int(playerLayer.videoRect.width))x\(Int(playerLayer.videoRect.height)) gravity=\(playerLayer.videoGravity.rawValue)"
        if line != lastLogged { lastLogged = line; oneSkinLog(line) }
        #endif
    }
}
