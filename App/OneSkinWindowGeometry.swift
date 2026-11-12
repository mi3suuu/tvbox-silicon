import Foundation
import CoreGraphics
import SwiftUI
import AVFoundation
import QuartzCore
import TVCore


/// 画面窗口的**唯一几何来源**。
///
/// 为什么要有这个类型：`pictureColumn`（画画面）和 `pictureControls`（画按钮）
/// 各自算过一遍 `winX / winY / winW / winH`。两份代码在 R10 那次改动里只同步
/// 了一处，结果按钮画在画面之外 —— 靠注释里写「两处必须保持一致」维持的不变式
/// 迟早会破。所有窗口几何必须从这里取。
/// 播放器窗口几何 —— **定义已移入 TVCore**（`TVCore/OneSkinWindowGeometryCore.swift`）。
///
/// 为什么搬走：这里的每一行都是纯算术，而「转屏时窗口越界」正是这类算术最容易错的
/// 地方。留在 App target 里就写不了单测（App 不可被测试目标 import），
/// 那些边界条件只能靠真机试出来 —— 而真机试不出的场景（极端容器尺寸）就一直漏着。
///
/// 现在几何由 `OneSkinWindowGeometryTests` 用矩阵式断言钉住：
/// 任意宽高组合、横竖两个分支，窗口都必须完整落在容器内。
typealias OneSkinWindowGeometry = TVCore.OneSkinWindowGeometry

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
        // ⚠️ 一个 AVPlayer 同时只能驱动一条 AVPlayerLayer：PiP 悬浮窗在跑的时候，
        // 这条内嵌 layer 再抢 player，悬浮窗就只剩声音。`shouldRender` 是那只闸。
        let renders = pip?.shouldRender(view.renderLayer) ?? true
        view.update(player: renders ? player : nil, gravity: videoGravity)
        // ⛔ **无论是否渲染都必须 attach**。
        //
        // 原来「不渲染就不 attach」，于是 PiP 活跃时折叠一次 →
        // 新的内嵌 layer 从没登记过 → 用户退出 PiP 时 `rebind()` 拿到的
        // 还是**已销毁的旧 layer**（`self.layer` 是弱引用）→ 新 controller 绑到死图层
        // → `isPictureInPicturePossible` 恒 false，PiP 按钮永久灰掉，要再切一次页面才自愈。
        // attach 只是登记内容源，PiP 在跑时它自己会走「adopt / 改 contentSource」分支，
        // 不会抢画面；真正抢画面的是 `player`，那一层已经由 `renders` 拦住了。
        pip?.attach(view.renderLayer)
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


