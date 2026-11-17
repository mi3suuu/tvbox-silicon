import SwiftUI
import AVKit
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import TVCore

/// Sharper and smoother video with Apple's own machine-learning frame processors (VideoToolbox, OS 26):
/// super resolution upscales a picture smaller than the screen, and frame interpolation lifts 24–30 fps
/// to 60. AVPlayer still decodes and keeps time. Frames come out of an AVPlayerItemVideoOutput, go
/// through the processors on a queue of their own, and are drawn by a sample-buffer layer above AVKit's
/// picture (under danmaku and the controls), on the item's own timebase so sound stays in sync. When
/// there is nothing to improve (HDR, AirPlay, a hot device, a picture already big and fast enough, an
/// older system) that layer steps aside and AVKit's own picture shows.
enum VideoEnhancement {
    static let upscaleKey = "videoUpscale"
    static let smoothKey = "videoSmoothMotion"

    static var upscaleNote: String { L10n.text("Upscales video smaller than your screen with on-device machine learning.") }
    static var smoothNote: String { L10n.text("Adds in-between frames so 24–30 fps video plays at 60 fps. Uses more battery, and films can look like TV soap operas.") }
    /// Both notes, for a settings group that explains its switches underneath.
    static var note: String { [canUpscale ? upscaleNote : nil, canSmooth ? smoothNote : nil].compactMap { $0 }.joined(separator: " ") }

    /// Whether the viewer has switched either enhancement on. The device may be *capable* (`canUpscale` /
    /// `canSmooth`) while the switches stay off; only a switched-on setting needs the pipeline, its layer and
    /// its background queue. Building all of that when both switches are off only leaves an idle
    /// `AVSampleBufferDisplayLayer` being added to and removed from the layer tree across a Duo fold/unfold,
    /// which is a use-after-free hazard the two-column scene teardown has crashed on (SIGSEGV / SIGILL).
    // [mi3s] 二开：总开关。上游只有 canUpscale / canSmooth 两个能力判定，
    // 没有「用户把画质增强关掉」这一层 —— 这里补上，读取两个独立的 UserDefaults 键。
    static var enabled: Bool {
        canUpscale && UserDefaults.standard.bool(forKey: upscaleKey)
            || canSmooth && UserDefaults.standard.bool(forKey: smoothKey)
    }

    /// Whether this device can upscale: OS 26 on a real device (the Simulator has no processors).
    static let canUpscale: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(macOS 26, iOS 26, tvOS 26, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
        #endif
    }()

    static let canSmooth: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(macOS 26, iOS 26, tvOS 26, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
        return false
        #endif
    }()
}

struct VideoEnhancementOptions: Equatable, Sendable {
    var upscale = false
    var smooth = false
    /// The picture's size on screen, in pixels.
    var target = CGSize.zero
    /// QA: a block stepping along the bottom once per drawn frame, proving the processed frames are on screen.
    var mark = false
    /// The grid smoothed frames are drawn on: the screen's refresh rate while smoothing.
    var outputRate = 60.0
}

/// A frame format handed from the pipeline's queue to the main actor; format descriptions are immutable.
struct VideoFormatBox: @unchecked Sendable { let format: CMFormatDescription }

struct VideoEnhancementStatus: Equatable, Sendable {
    var upscaling = false
    var smoothing = false
    /// The source's frames per second, to the hundredth; 0 until two frames have been seen.
    var sourceRate = 0.0
    var active: Bool { upscaling || smoothing }
}

private protocol EnhancementEngine: AnyObject, Sendable {
    func setOutput(_ output: AVPlayerItemVideoOutput?)
    func setOptions(_ options: VideoEnhancementOptions)
    func setTimebaseReady(_ ready: Bool)
    func discontinuity()
}

/// One per playback session: follows the player's item and owns the layer the surfaces show.
@MainActor @Observable final class VideoEnhancer {
    /// What is on screen now: processed frames drawn over AVKit's picture.
    private(set) var status = VideoEnhancementStatus()
    /// A line for logs and QA: the processors running, frame counts and timing.
    private(set) var summary = "off"

    /// 当前这次 `refresh()` 是否**由 `layoutSubviews` 触发**。
    ///
    /// ⛔ 存在的理由（真机 7 份崩溃报告里 6 份都是它）：
    ///   `SurfaceView.layoutSubviews` → `setDisplaySize` → `refresh()`
    ///   → `report()` → `apply()` 写 `@Observable status`
    ///   → SwiftUI 观察追踪重算 body → 重新布局 → 又进 `layoutSubviews` …… 闭环。
    ///
    ///   上一版把 `refresh()` 改成 `Task { @MainActor in … }`，只是把
    ///   **同步闭环变成异步闭环**；`apply()` 里 `self.status = status` 照旧写，
    ///   所以 `0x8BADF00D` 仍在（实测 6/7 份，CPU 96%、5s 跑不完一次布局）。
    ///   根因不是「在事务里写」，而是**在布局驱动的路径上写可观察状态**。
    @ObservationIgnored private var layoutDrivenRefresh = false
    /// 宿主 `SurfaceView` 注入的 backing layer（`layerClass` 范式）。
    ///
    /// ⛔ 2026-11-17 结构改造（a2 审计定案）：原来这里是
    ///    `@ObservationIgnored let layer = AVSampleBufferDisplayLayer()` —— 手工建层，
    ///    由 `SurfaceView.init` `addSublayer` 塞进宿主，再在 `layoutSubviews` 里
    ///    `layer.frame = bounds`。真机 `TVBox-iOS-2026-11-17-170140.ips`（build 1283）帧 0–8：
    ///
    ///      layoutSubviews → -[CALayer setFrame:] → -[AVSampleBufferDisplayLayer setBounds:]
    ///      → CA::Layer::set_bounds → CA::Layer::property_did_change
    ///      → -[CALayer setNeedsLayout] → CA::Layer::set_needs_update_   ← 闭环点
    ///
    ///    即「给**子层**赋 frame 会让该子层被标 needsLayout，而它正在父级布局链上
    ///    （帧 15 `layoutBelowIfNeeded` → 帧 12 `layoutSublayers`）→ CA 再排一轮 → 重入」。
    ///
    ///    改为 `layerClass` 后，宿主 view 的 backing layer **就是**这条视频层，
    ///    UIKit 在布局末尾自动同步 bounds —— **不存在「给子层赋 frame」这个动作**，
    ///    环在结构上消失（不是被压制）。项目内 4 处不崩的播放器全是这个范式：
    ///    `ExternalDisplay.swift:249` / `MobilePlayer.swift:2479` / `VideoTasks.swift:1155`
    ///    / `BiliSkin.swift:309`。
    @ObservationIgnored private var attachedLayer: AVSampleBufferDisplayLayer?
    /// 还没有宿主时的占位层。
    ///
    /// 存在的理由：`refresh()` 与 `apply()` 会碰 `layer.*`（timebase / flush / isHidden /
    /// videoGravity），而它们可能在 `SurfaceView` 注入之前就被调用（`init` 里的
    /// `itemObservation` 回调、250ms 定时器首拍）。给一个真实对象比处处判 nil 安全。
    @ObservationIgnored private let placeholderLayer = AVSampleBufferDisplayLayer()
    /// 当前生效的那条视频层。**全文件所有 `layer.` 用法都必须走它。**
    @ObservationIgnored var currentLayer: AVSampleBufferDisplayLayer { attachedLayer ?? placeholderLayer }
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var engine: (any EnhancementEngine)?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var options = VideoEnhancementOptions()
    @ObservationIgnored private var displaySize = CGSize.zero
    /// 宿主实例号（仅用于 `ATTACH-*` 日志区分是谁）。
    private let attachID: Int = VideoEnhancer.nextAttachID()
    private static var attachIDCounter = 0
    private static func nextAttachID() -> Int { attachIDCounter += 1; return attachIDCounter }

    /// 宿主 `SurfaceView` 把自己的 backing layer 交给 enhancer。
    ///
    /// ## 先到先得，**拒绝抢占**（captain 2026-11-17 裁定采纳）
    ///
    /// 不用 `claimAndBind` 那套「新宿主抢走旧的」：那是「同一个 player 只需一条渲染层、
    /// 新宿主理应赢」的语义；这里 `engine` 已经用 `currentLayer.sampleBufferRenderer`
    /// **绑定了那条层的渲染器**（见 `makeEngineIfNeeded`），换层 = 重建引擎 =
    /// 打断正在播放的渲染。所以第二个宿主必须**被拒绝**，而不是抢。
    ///
    /// - Returns: 是否拿到（`false` = 已被别的宿主持有，调用方应自行降级/重试）
    @discardableResult
    func attach(displayLayer: AVSampleBufferDisplayLayer) -> Bool {
        if let existing = attachedLayer {
            if existing === displayLayer {
                // ⛔ **幂等命中不打日志**。
                //
                // `retryAttachIfNeeded` 挂在 `updateUIView`/`updateNSView` 上，
                // 那两个是 SwiftUI 每次 body 变化都走的路径（转屏时每帧一次）。
                // 而 `oneSkinLog` 无节流无去重（`OneSkin.swift:47` 直接落盘），
                // 在这里打日志会把 `Documents/oneskin.log` 刷爆 ——
                // 后果不是性能，是**验收被毁**：`ATTACH-REJECT` / `ATTACH-TAKEOVER`
                // 这两个关键信号会被淹没，无法判断宿主换代竞态是否真修好。
                //
                // 首次接管（下面那条 ATTACH-OK）才打一次，异常路径（REJECT/TAKEOVER）照打。
                return true
            }
            // ── A（兜底接管）──────────────────────────────────────
            // 旧层**已经离开图层树**（`superlayer == nil`）说明那个宿主真的被拆了，
            // 只是它的同步释放点没走到我们这儿。此时接管新层是安全的：
            // 旧层已不参与渲染，不会出现「两条层同时驱动」。
            //
            // ⛔ 只做 A 不够：旧层 `superlayer != nil` 时（新宿主先 init、旧宿主还没拆）
            //    接管条件不成立，必须靠 B（`dismantleUIView` 同步释放点）先把旧的放掉。
            if existing.superlayer == nil {
                oneSkinLog("enhancer ATTACH-TAKEOVER enhancer=\(attachID) from=\(UInt(bitPattern: ObjectIdentifier(existing).hashValue) % 100000) why=stale-superlayer-nil")
                attachedLayer = nil
                existing.controlTimebase = nil
                engine = nil
                // 落到下面正常接管
            } else {
                oneSkinLog("enhancer ATTACH-REJECT enhancer=\(attachID) holder=\(UInt(bitPattern: ObjectIdentifier(existing).hashValue) % 100000) why=already-held")
                return false
            }
        }
        attachedLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.isHidden = true
        displayLayer.backgroundColor = nil
        // 换成新层后，渲染器/时间表都要重建到这条层上。
        engine = nil
        oneSkinLog("enhancer ATTACH-OK enhancer=\(attachID) layer=\(UInt(bitPattern: ObjectIdentifier(displayLayer).hashValue) % 100000)")
        return true
    }

    /// 宿主被拆解时归还。只有**当前持有者**归还才生效，避免把新宿主误清。
    func detach(displayLayer: AVSampleBufferDisplayLayer) {
        guard attachedLayer === displayLayer else { return }
        attachedLayer = nil
        engine = nil
        displayLayer.controlTimebase = nil
        displayLayer.flush()
        oneSkinLog("enhancer DETACH enhancer=\(attachID) layer=\(UInt(bitPattern: ObjectIdentifier(displayLayer).hashValue) % 100000)")
    }

    /// 只读曝光给 `SurfaceView.layoutSubviews` 做「值没变就别往下传」的闸。
    var displayPixelSize: CGSize { displaySize }
    /// The frames' format, for asking the TV for a display mode.
    @ObservationIgnored private var format: CMFormatDescription?
    @ObservationIgnored private var announced: String?
    @ObservationIgnored private var displayState = ""
    /// Called when what the screen should do changes: smoothing, its rate, or the first known format.
    @ObservationIgnored var onDisplayChange: (() -> Void)?

    /// Smoothed frames need the screen at `rate`; nil when the screen should follow the video as usual.
    var displayRequest: (rate: Double, format: CMFormatDescription)? {
        guard status.smoothing, let format else { return nil }
        return (options.outputRate, format)
    }

    /// The grid for smoothed frames. 25 fps doubles to 50 when the TV follows the video's rate (Match Frame
    /// Rate), so every new frame sits exactly halfway; otherwise 60 Hz (59.94 for the 1000/1001 rates), where
    /// 24 and 25 fps need uneven in-between positions.
    static func outputRate(source: Double, matching: Bool) -> Double {
        if matching, abs(source - 25) < 0.3 { return 50 }
        if abs(source - 30000 / 1001) < 0.02 || abs(source - 24000 / 1001) < 0.02 { return 60000 / 1001 }
        return 60
    }

    init(player: AVPlayer) {
        self.player = player
        currentLayer.videoGravity = .resizeAspect
        currentLayer.isHidden = true
        currentLayer.backgroundColor = nil
        // ⛔ 这里**不再** `guard VideoEnhancement.enabled else { return }`。
        //
        // 原来那样写有三个连锁后果（用户可感知）：
        //   ① 增强关着时 `return` 在 `engine` 创建**之前**（原 :131 vs :134），
        //      连下面的 `itemObservation` 和 250ms 刷新定时器都一起没建；
        //   ② 于是播放中把开关打开 → `refresh()` 首行 `guard let engine` 直接返回，
        //      **永远不会生效**；用户看到的是「开了没反应」；
        //   ③ 全仓零处 `onChange(of: upscalesVideo|smoothsVideo)`，没有任何重建入口。
        //   ⇒ 唯一出路是退出重进（那时才会以 enabled=true 重建）。
        //
        // 但原来那个 guard 不是没理由的，注释写明：空闲的 layer/pipeline 在 Duo
        // 折叠/展开时是 use-after-free 隐患（SIGSEGV / SIGILL on scene teardown）。
        //
        // 折中：**监听照建，pipeline 惰性建**。
        //   · `itemObservation` 与刷新定时器无条件建立（它们本身不持有 GPU 资源）；
        //   · `engine` 保持 nil 直到 `refresh()` 发现「开关真的开着且设备支持」才创建
        //     （见 `makeEngineIfNeeded()`）——那个时刻与「关着就建」的场景不同，
        //     是用户明确打开之后才付出代价，也就绕开了折叠期空闲 pipeline 的隐患。
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // Settings, the device's temperature and AirPlay change while playing; so does the item's timebase.
        // (No strong reference across the sleep, or the session would never be released.)
        Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The surface's size in pixels, which decides how much to upscale.
    func setDisplaySize(_ size: CGSize) {
        // Layout can hand us sub-pixel sizes that flicker between passes; only react to a real change,
        // otherwise layout -> refresh -> report -> observed state -> layout loops forever.
        guard abs(size.width - displaySize.width) > 0.5 || abs(size.height - displaySize.height) > 0.5 else { return }
        displaySize = size
        // ⛔⛔ 这里**不许每帧建 `Task`**（真机 2026-11-17 18:45 崩溃，build 1300）：
        //
        //   VideoEnhancer.setDisplaySize(_:)
        //     → Task<>.init(name:priority:operation:)
        //       → swift_task_create_commonImpl → malloc / _Block_copy → 崩溃
        //
        // 上一版为了「把 refresh 挪出 CA 布局事务」写了
        // `Task { @MainActor in refresh() }`，**那是把同步问题换成了每帧堆分配问题**：
        // `layoutSubviews` 在转屏/开合期间被高频调用，`displaySize` 每次真变都会走到这行
        // （0.5pt 阈值挡不住真实尺寸变化），于是每帧 malloc 一个 Task 对象 + _Block_copy
        // 一块闭包 —— 堆压力直接顶满，配合 CA 布局事务就是 0x8BADF00D / 崩溃。
        //
        // ⛔ 2026-11-17：**不再在这里排任何 refresh**（原「合并式延迟」已删）。
        //
        // 为什么删（a2 审计结论，captain 采纳）：上一版写的是
        //   `if !refreshScheduled { refreshScheduled = true;
        //     DispatchQueue.main.async { refreshScheduled = false; refresh() } }`
        // 但 `DispatchQueue.main.async` 的块在**同一 runloop 周期末尾**就执行，
        // 首行又把 flag 复位成 false ⇒ 下一帧进来时 flag 已是 false
        // ⇒ **每帧仍排一个新任务，合并等于没做**。
        // 代价很实：每帧一次 `refresh()` 全流程（2 次 `UserDefaults.bool(forKey:)`
        // 同步 IPC + 选项构造 + `allowed()` 判 externalPlayback），
        // 正好对应真机实测 CPU 37–50%（在做实际工作，不是空转）。
        //
        // 现在：**尺寸只记下来，refresh 交给 250ms 定时器统一驱动**。
        // 定时器本来就在跑（`init` 的 `while !Task.isCancelled { refresh(); sleep(250ms) }`），
        // 它会读到最新 `displaySize`。这样 layout 路径上**一次 refresh 都不排**，
        // 且总频率被钉在 4Hz。
    }

    /// 按需创建增强管线。
    ///
    /// 只有「开关真的开着 + 设备支持」才建，且只在第一次需要时建一次。
    /// 这样 `init` 不必因为开关关着就整个提前返回（那会让运行期开启永远无效），
    /// 又不会在没有增强需求时长期持有一条空闲管线（Duo 折叠期的 use-after-free 隐患）。
    /// 把已挂到 item 上的 output 与观察者全部拆除。
    ///
    /// 抽出来给两处共用：
    ///   · `refresh()` 的常规换 item 路径
    ///   · `makeEngineIfNeeded()` 的「增强被关掉」路径 —— 那条路径会 `return`，
    ///     走不到 `refresh()` 的清理段，所以必须自己调一次。
    private func detachOutput() {
        if let item, let output { item.remove(output) }
        // ⛔ 不能写 `if let jumpObserver { ...; jumpObserver = nil }` ——
        //    `if let jumpObserver` 会引入同名的**局部常量**，遮蔽属性，
        //    于是那行赋值对 `let` 报错（编译期就抓到）。
        if let observer = jumpObserver {
            NotificationCenter.default.removeObserver(observer)
            jumpObserver = nil
        }
        currentLayer.controlTimebase = nil
        output = nil
        item = nil
    }

    private func makeEngineIfNeeded() {
        // ⛔ 先处理「开关被关掉」：**必须把 engine 释放回 nil**。
        //
        // 原来只做了「从没开过就不建」，漏了另一半 —— `engine` 一旦创建就**永不释放**
        // （无 `engine = nil`、`VideoEnhancer` 也无 deinit），所以「开过一次再关掉」
        // 会永久持有一条空闲 pipeline 跨 Duo 折叠/展开，
        // 正是 `init` 原注释要避免的 use-after-free 场景。
        // 复核（fix-reviewer ③）指出这一点，成立。
        if !VideoEnhancement.enabled {
            if engine != nil {
                engine = nil
                currentLayer.flush()
                // ⛔ 必须**自己拆干净**，不能只置 nil 就 return。
                //
                // `refresh()` 主体（下方 `if current !== item ...` 那段）是原来唯一做
                // teardown 的地方：`item.remove(output)`、移除 `jumpObserver`、
                // `layer.controlTimebase = nil`。而 `makeEngineIfNeeded()` 里一旦 `return`，
                // `refresh()` 紧接着的 `guard let engine` 必失败 ⇒ **那些清理永远到不了**。
                //
                // 第一版就是这么错的（复核 R0 指出）：把「关掉时拆干净」
                // 换成了「只置 nil 就撒手」。而**改前 `3dd8dbc` 关掉时其实是拆干净的**
                // —— 因为 `current` 为 nil、`output` 为 nil，`nil !== item` 成立，进了清理分支。
                detachOutput()
                Diagnostics.shared.record(.info, "enhance", "pipeline released (enhancement off)")
            }
            return
        }
        // ⛔⛔ **准入闸**（2026-11-17，20 小窗那一轮）。
        //
        // `PlaybackSession` 每一路都持有一个 `VideoEnhancer`（坞里 20 个窗 = 20 个），
        // 而增强开关是全局的。原写法只判「开关开着」就建管线 ⇒ 20 个窗各建一条
        // Metal + VideoToolbox 超分管线，每条按**全尺寸**吃显存与中间缓冲。
        // 真机 OOM（2700 MB）就是这个形态，而且坞卡片只有 320 pt 宽 —— 超分过去毫无意义。
        //
        // 判据见 `EnhancementBudget`：有画面层（只有屏上的播放页会 attach）、
        // 没有别的路在解码、系统没给内存压力。任一条不满足就**把管线还给系统**，
        // 不是「先留着不用」—— 留着就是真机崩的那个 2700 MB。
        let load = PlaybackLoad.shared
        let decision = EnhancementBudget.decide(
            hasSurface: attachedLayer != nil,
            otherDecoding: load.dockDecodingCount,
            memoryPressure: load.memoryPressure,
            constrained: isConstrained,
            externalPlayback: player?.isExternalPlaybackActive ?? false)
        guard decision.isOn else {
            if engine != nil {
                engine = nil
                currentLayer.flush()
                detachOutput()
                Diagnostics.shared.record(.debug, "enhance",
                    "pipeline released (\(decision.reason)) enhancer=\(attachID)")
            }
            return
        }
        guard engine == nil else { return }
        #if !targetEnvironment(simulator)
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            engine = EnhancementPipeline(renderer: currentLayer.sampleBufferRenderer) { [weak self] status, summary, note, format in
                Task { @MainActor [weak self] in self?.apply(status, summary: summary, note: note, format: format) }
            }
        }
        #endif
    }

    /// 发热严重或处于低电量模式 —— 这时不该再让 GPU 多做功。
    private var isConstrained: Bool {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return true
        }
        #if !os(tvOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        #endif
        return false
    }

    private func refresh(fromLayout: Bool = false) {
        // 这一路根本没有画面层（坞里的 20 张卡片都不会 attach）：**什么也不必算**。
        //
        // ⛔ 加这一行不是为了省一点点 CPU，是为了别让 20 个窗各自每 250 ms 读两次
        //    `UserDefaults`（跨进程 IPC）+ 构造选项 + 判 AirPlay。20 路时那是每秒 160 次
        //    无意义同步，卡的不是网络，是主线程。
        guard attachedLayer != nil else { return }
        // 开关可能是在播放中途打开的（设置页 / 播放器内开关），所以每次刷新都先补建管线。
        makeEngineIfNeeded()

        // layout 驱动的那一次：只同步内部渲染参数，**不许写 @Observable 状态**。
        // 标记在 `apply` 里消费。
        layoutDrivenRefresh = fromLayout
        guard let engine, let player else { return }
        let defaults = UserDefaults.standard
        var next = VideoEnhancementOptions(upscale: VideoEnhancement.canUpscale && defaults.bool(forKey: VideoEnhancement.upscaleKey),
                                           smooth: VideoEnhancement.canSmooth && defaults.bool(forKey: VideoEnhancement.smoothKey),
                                           target: displaySize)
        if !allowed(player) { next.upscale = false; next.smooth = false }
        #if DEBUG
        next.mark = defaults.bool(forKey: "qaEnhanceHUD")
        #endif
        let current = (next.upscale || next.smooth) ? player.currentItem : nil
        if current !== item || (current != nil && output == nil) {
            // 与「增强被关掉」那条路径共用同一份拆除逻辑（见 `detachOutput`）。
            // 注意顺序：先 `engine.setTimebaseReady(false)`，再拆 output ——
            // 反过来的话引擎可能还在等一个已被移除的 output 的时刻表。
            engine.setTimebaseReady(false)
            detachOutput()
            item = current
            output = nil
            if let current {
                let made = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
                    kCVPixelBufferMetalCompatibilityKey as String: true])
                current.add(made)
                output = made
                jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: current, queue: .main) { [weak engine] _ in
                    engine?.discontinuity()
                }
            }
            engine.setOutput(output)
        }
        // Frames wait for their time on the item's own clock; until it exists they would show at once.
        if let item, currentLayer.controlTimebase == nil, let timebase = item.timebase {
            currentLayer.controlTimebase = timebase
            engine.setTimebaseReady(true)
        }
        #if os(tvOS)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        let matching = window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false
        displayState = window == nil ? "no window" : "match \(matching) switching \(window!.avDisplayManager.isDisplayModeSwitchInProgress)"
        #else
        let matching = false
        #endif
        next.outputRate = Self.outputRate(source: status.sourceRate, matching: matching)
        if next != options {
            options = next
            engine.setOptions(next)
        }
        announceDisplay()
    }

    private func announceDisplay() {
        let key = displayRequest.map { "\($0.rate)" }
        guard key != announced else { return }
        announced = key
        onDisplayChange?()
    }

    /// Not while AirPlay shows the video elsewhere, the device is hot, or it is saving power.
    private func allowed(_ player: AVPlayer) -> Bool {
        if player.isExternalPlaybackActive { return false }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return false }
        #if !os(tvOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        #endif
        return true
    }

    private func apply(_ status: VideoEnhancementStatus, summary: String, note: String?, format: VideoFormatBox?) {
        if let note { Diagnostics.shared.record(.info, "enhance", note) }
        if let format { self.format = format.format }
        // Nothing changed in what the view observes: return before touching any @Observable state, so a
        // report fired from layout (layoutSubviews -> setDisplaySize -> refresh -> report) cannot mutate
        // observed state inside a layout pass and start a SwiftUI feedback loop (watchdog 0x8BADF00D).
        // ⛔ layout 驱动的那次 refresh **一律不写可观察状态** —— 闭环在此断开。
        //
        // 只写 `status` 会让 SwiftUI 观察追踪把它算成依赖变化 → 重算 body
        // → 重新布局 → `layoutSubviews` → 再来一遍。转屏时 status 里的
        // 分辨率/帧率字段必然变化，所以下面那句 `guard status != self.status`
        // **拦不住它** —— 那正是「每次转屏都卡死」的机制。
        // 内部渲染参数已由 setDisplaySize/refresh 自己同步好，诊断数字留给 250ms 定时器。
        if layoutDrivenRefresh {
            layoutDrivenRefresh = false
            return
        }
        guard status != self.status else { return }
        #if DEBUG
        let frame = currentLayer.frame, host = currentLayer.superlayer
        self.summary = summary + " · layer \(Int(frame.width))x\(Int(frame.height)) hidden \(currentLayer.isHidden) hosted \(host != nil) timebase \(currentLayer.controlTimebase != nil) · grid \(options.outputRate) \(displayState) request \(displayRequest.map { "\($0.rate)" } ?? "none")"
        #else
        self.summary = summary
        #endif
        self.status = status
        currentLayer.isHidden = !status.active
        announceDisplay()
    }
}

#if os(tvOS)
/// In-between frames need the TV at 60 Hz, but AVKit's automatic display matching would switch it to the film's
/// own 24 Hz and drop them, and AVKit refuses to turn that off once playback has begun. So on an Apple TV that can
/// smooth, the player applies the display criteria itself: the video's own, as AVKit would, and while smoothing
/// none, which leaves the TV in the mode chosen in Settings (normally 60 Hz).
@MainActor final class DisplayCriteriaKeeper {
    private weak var controller: AVPlayerViewController?
    private weak var enhancer: VideoEnhancer?
    private var observation: NSKeyValueObservation?
    private var applying: Task<Void, Never>?

    init(controller: AVPlayerViewController, player: AVPlayer, enhancer: VideoEnhancer) {
        self.controller = controller
        self.enhancer = enhancer
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        observation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.apply() }
        }
        enhancer.onDisplayChange = { [weak self] in self?.apply() }
    }

    /// Back to the TV's own mode when the player goes away, as AVKit does after full-screen playback.
    func reset() {
        applying?.cancel()
        observation = nil
        controller?.view.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    private func apply() {
        applying?.cancel()
        // Smoothing: the rate the frames are drawn at. Otherwise the video's own criteria, as AVKit would.
        let request = enhancer?.displayRequest
        let wanted = request.map { AVDisplayCriteria(refreshRate: Float($0.rate), formatDescription: $0.format) }
        let asset = request == nil ? controller?.player?.currentItem?.asset : nil
        applying = Task { [weak self] in
            var criteria = wanted
            if let asset { criteria = try? await asset.load(.preferredDisplayCriteria) }
            // The HDR mode the player switched to before the item opened stays until it stops.
            // ⚠️ 原写的是 `HDRDisplay.requested` —— `HDRDisplay`（Sources/TVCore）**没有**这个成员；
            //    正确的是本方法开头已取到的 `request`（= `enhancer?.displayRequest`）。
            //    闭包里 `self` 是弱引用可选值，故直接用捕获到的 `request`，不再经 self 取一次。
            if criteria == nil, request != nil { return }
            // The controller joins its window a moment after it is made.
            for _ in 0..<20 {
                guard !Task.isCancelled, let self else { return }
                if let manager = self.controller?.view.window?.avDisplayManager {
                    manager.preferredDisplayCriteria = criteria
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
#endif

/// Where the enhanced picture is drawn: the session's layer, sized to the player's own picture.
struct EnhancedVideoSurface: View {
    let enhancer: VideoEnhancer
    /// How the picture meets its box: the viewer's size pick, not a per-shape guess.
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// Which safe-area edges AVKit's picture runs under. On a screen of its own it runs under every
    /// edge (`.all`); at the top of an iPhone watch page the picture keeps to its frame vertically but
    /// bleeds sideways so the Duo's asymmetric outer notch/corner inset doesn't leave a strip of page
    /// showing beside the picture. Passing `.all` mirrors the old `bleeds: true`, `[]` mirrors `false`.
    var bleeds: Edge.Set = .all
    var body: some View {
        if VideoEnhancement.enabled {
            // The same area as AVKit's own picture: inside the safe area (under the Mac's title bar) the fitted
            // picture came out smaller than AVKit's, and under the status bar above a watch page's player it came out
            // taller and higher; either way AVKit's picture showed around its edges.
            Host(enhancer: enhancer, gravity: gravity).ignoresSafeArea(edges: bleeds).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    #if os(macOS)
    private struct Host: NSViewRepresentable {
        let enhancer: VideoEnhancer
        let gravity: AVLayerVideoGravity
        func makeNSView(context: Context) -> SurfaceView { SurfaceView(enhancer: enhancer) }
        func updateNSView(_ view: SurfaceView, context: Context) {
            view.displayLayer?.videoGravity = gravity
            // **重试接管**（补齐「attach 只在 init 调一次、拒绝后无重试」这条残留路径）。
            //
            // `init` 里那次 attach 若被 REJECT（旧宿主还挂着），这条 view 会一直画不出东西。
            // `updateNSView` 是 SwiftUI 每次 body 变化都会走的幂等钩子：这里再试一次，
            // 一旦旧宿主被拆（槽位空 / 旧层 superlayer==nil），立刻接管。
            // `attach` 自身幂等（同层 repeated 直接返回 true，**不打日志**，
            // 见 attach 里那段注释），所以这里每帧调也不会刷爆日志。
            if let layer = view.displayLayer { view.retryAttachIfNeeded(layer) }
        }
        /// **同步**释放点（B）。
        ///
        /// 这里是 SwiftUI 给 representable 的**唯一同步拆解回调**（`deinit` 不是它，
        /// `deinit` 只保证对象终结，不保证时机）。把释放放这里，是为了让「旧宿主放手」
        /// 与「新宿主 attach」处在**同一个同步序列**里 —— 而 `deinit` + `Task { @MainActor }`
        /// 必然把释放排到后面的 runloop 轮次，与新宿主的同步 `attach` 竞争。
        ///
        /// ⚠️ 我不声称 dismantle 一定早于新宿主的 `makeNSView`（那是框架实现细节，
        /// 静态无法证明）。**两种顺序都被下面两条一起覆盖**：
        /// - 若 dismantle 先到 → 槽位已空 → 新宿主 `attach` 直接 OK；
        /// - 若 make 先到（旧的还没拆）→ 走 `attach` 里的 **A 兜底**：旧层
        ///   `superlayer == nil`（view 已离层级）时接管；仍非 nil 时才 REJECT。
        /// ⇒ 只有「旧宿主还挂在图层树上且已被替换」这一种才会 REJECT，
        /// 而那正是**不该**接管的情况（两条层同时驱动会抢帧）。
        static func dismantleNSView(_ view: SurfaceView, coordinator: ()) {
            view.releaseLayerSynchronously()
        }
    }

    /// macOS 分支：同 iOS 一样改成 **backing layer 就是视频层**。
    ///
    /// 原来这里是 `layer?.addSublayer(enhancer.layer)` + `place()` 里
    /// `enhancer.layer.frame = bounds` —— 与 iOS 完全同型的环
    /// （给子层赋 frame → 子层 setNeedsLayout → 重入）。
    /// 现在 `makeBackingLayer()` 直接返回 `AVSampleBufferDisplayLayer`，
    /// 它成为 view 的 backing layer，`NSView` 在布局末尾自动同步 bounds，
    /// **不再有「给子层赋 frame」这个动作**，`place()` 整个删除。
    final class SurfaceView: NSView {
        private let enhancer: VideoEnhancer
        private(set) var displayLayer: AVSampleBufferDisplayLayer?
        init(enhancer: VideoEnhancer) {
            self.enhancer = enhancer
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func makeBackingLayer() -> CALayer {
            // 先建层并注入给 enhancer；被别的宿主持有时 attach 返回 false，
            // 我们仍然返回这条层（它只是这次没人用），并打 ATTACH-REJECT。
            let video = AVSampleBufferDisplayLayer()
            displayLayer = video
            enhancer.attach(displayLayer: video)
            return video
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            // ⛔ 只做「尺寸通知」，不碰任何 layer 几何。
            let scale = window?.backingScaleFactor ?? 2
            let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if enhancer.displayPixelSize != px { enhancer.setDisplaySize(px) }
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2
            let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if enhancer.displayPixelSize != px { enhancer.setDisplaySize(px) }
        }
        /// **同步**归还层（B）。
        ///
        /// 由 `Host.dismantleNSView` 调用 —— 那是 SwiftUI 给的唯一同步拆解回调，
        /// 早于下一个宿主的创建。不能再靠 `deinit` + `Task`：那会把释放排到后面的
        /// runloop 轮次，与新宿主的同步 attach 竞争。
        func releaseLayerSynchronously() {
            guard let layer = displayLayer else { return }
            enhancer.detach(displayLayer: layer)
            displayLayer = nil
        }

        /// 幂等重试接管。
        ///
        /// 直接调 `attach`：它内部对「同层 repeated」是 O(1) 判等后**静默**返回 true
        /// （不打日志，避免挂在 `update` 路径上把 oneskin.log 刷爆）；
        /// 对「别层持有」也不会改绑。这里**不重复加判**——加了反而容易与
        /// `attach` 的判定分叉（两处判据不同步是本项目反复踩过的坑）。
        func retryAttachIfNeeded(_ layer: AVSampleBufferDisplayLayer) {
            enhancer.attach(displayLayer: layer)
        }
    }
    #else
    private struct Host: UIViewRepresentable {
        let enhancer: VideoEnhancer
        let gravity: AVLayerVideoGravity
        func makeUIView(context: Context) -> SurfaceView { SurfaceView(enhancer: enhancer) }
        func updateUIView(_ view: SurfaceView, context: Context) {
            view.displayLayer.videoGravity = gravity
            // **重试接管** —— 理由见 macOS 分支同名处的注释，完全相同。
            view.retryAttachIfNeeded(view.displayLayer)
        }
        /// **同步**释放点（B）—— 见 macOS 分支同名方法的注释，理由完全相同。
        static func dismantleUIView(_ view: SurfaceView, coordinator: ()) {
            view.releaseLayerSynchronously()
        }
    }

    /// iOS 分支：**backing layer 就是视频层**（`layerClass` 范式）。
    ///
    /// ## 这一改断的是什么环（真机 `TVBox-iOS-2026-11-17-170140.ips`，build 1283，帧 0–8）
    ///
    /// 改前：
    /// ```
    /// SurfaceView.layoutSubviews()                    ← 我们自己写的方法
    ///  → -[CALayer setFrame:]                          ← enhancer.layer.frame = bounds
    ///    → -[AVSampleBufferDisplayLayer setBounds:]
    ///      → -[CALayer setBounds:] → CA::Layer::set_bounds
    ///        → CA::Layer::property_did_change
    ///          → -[CALayer setNeedsLayout]
    ///            → CA::Layer::set_needs_update_       ← 闭环点
    /// ```
    /// 即「在父视图的布局方法里给**子层**赋 frame，会让这个子层自己被标 needsLayout，
    /// 而它正在父级布局链上（帧 15 `layoutBelowIfNeeded` → 帧 12 `layoutSublayers`）」
    /// ⇒ CA 再排一轮 ⇒ 重入。
    ///
    /// 改后：`view.layer` **就是** `AVSampleBufferDisplayLayer`，UIKit 在布局末尾
    /// 自动把 `view.layer.bounds` 同步成 view 的 bounds。**代码里不存在
    /// "给子层赋 frame" 这个动作**，因此上面那条链的第一环就没有了 ——
    /// 环是**结构性消失**，不是被压制或延迟。
    ///
    /// 也没有 `addSublayer`：不再有「remove + insert → mark_visible」，
    /// 因此也不会因抢层而反复触发可见性回调。
    ///
    /// ## 为什么可以省掉 `isHidden` / `videoGravity` 的每次设置
    ///
    /// 它们在 `VideoEnhancer.attach(displayLayer:)` 里设一次；`updateUIView` 只改 gravity。
    final class SurfaceView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        /// 强类型取用 backing layer；`layerClass` 已保证类型。
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

        private let enhancer: VideoEnhancer
        init(enhancer: VideoEnhancer) {
            self.enhancer = enhancer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            // 把 backing layer 交给 enhancer（先到先得，被占用时 enhancer 打 ATTACH-REJECT）。
            enhancer.attach(displayLayer: displayLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // ⛔ 只做「尺寸通知」，**不碰任何 layer 几何**。
            //    没有 addSublayer、没有 frame/bounds 赋值 —— 环的入口不存在。
            let scale = traitCollection.displayScale
            let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if enhancer.displayPixelSize != px { enhancer.setDisplaySize(px) }
        }

        /// **同步**归还层（B）。
        ///
        /// 由 `Host.dismantleUIView` 调用。`SurfaceView` 的 backing layer 不能被换掉，
        /// 所以这里只把**所有权**还给 enhancer（`attachedLayer = nil` + 停 timebase），
        /// 层对象本身随 view 一起释放。
        ///
        /// ⛔ 不要改回 `deinit` + `Task { @MainActor }`：
        ///     ① 竞态——排队晚于新宿主的同步 `attach`，新宿主被 REJECT 后画面回落占位层；
        ///     ② 同源——本项目 `setDisplaySize` 的注释已记着「每帧建 Task → malloc/_Block_copy → 崩溃」
        ///       （`N-184520.ips` 就是这么崩的），低频不代表可以留。
        func releaseLayerSynchronously() {
            enhancer.detach(displayLayer: displayLayer)
        }

        /// 幂等重试接管 —— 理由见 macOS 同名方法（不重复加判，静默幂等）。
        func retryAttachIfNeeded(_ layer: AVSampleBufferDisplayLayer) {
            enhancer.attach(displayLayer: layer)
        }
    }
    #endif
}

#if !targetEnvironment(simulator)
/// The frame pipeline. Everything below runs on `queue`; session starts (which load ML models and can
/// take longer than a frame) run on `setup` so playback never waits for them.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class EnhancementPipeline: EnhancementEngine, @unchecked Sendable {
    /// How far ahead of the clock frames are pulled, so processing finishes before they are due.
    private static let lookahead = 0.08

    private struct Frame {
        let buffer: CVPixelBuffer
        let time: CMTime
        /// A smaller copy for the interpolator, when the picture is bigger than it can keep up with.
        var work: CVPixelBuffer? = nil
        /// A frame of the video itself, not one made in between.
        var real = true
    }

    private let queue = DispatchQueue(label: "com.tvbox.video-enhancement", qos: .userInteractive)
    private let setup = DispatchQueue(label: "com.tvbox.video-enhancement.setup", qos: .userInitiated)
    private let renderer: AVSampleBufferVideoRenderer
    private let report: @Sendable (VideoEnhancementStatus, String, String?, VideoFormatBox?) -> Void

    private var timer: DispatchSourceTimer?
    private var output: AVPlayerItemVideoOutput?
    private var options = VideoEnhancementOptions()
    private var timebaseReady = false
    private var status = VideoEnhancementStatus()
    private var previous: Frame?
    /// Seconds between source frames.
    private var interval: Double?
    private var hdr = false
    private var scaler: Stage?
    private var interpolator: Stage?
    private var wanted: (scale: String?, smooth: String?) = (nil, nil)
    private var starting: Set<String> = []
    /// When the work size last changed (unfold / rotation). Rebuilding a processor's ML session while the
    /// size is still settling tears down and restarts `VTFrameProcessor` back-to-back, which can crash
    /// (SIGSEGV) inside VideoToolbox. Hold off the teardown until the size has held steady for a moment.
    private var sizeChangedAt = 0.0
    private var builtSize: (width: Int, height: Int)?
    /// Configurations that failed or ran too slowly, not tried again for this item.
    private var refused: Set<String> = []
    private var slow = 0
    /// The most pixels interpolated per frame. 1080p takes about 90 ms a frame on an M1 Pro against 15 ms
    /// for 720p, so bigger pictures are interpolated from a 720p copy; 540p when even that is too slow.
    private var workBudget = 1280 * 720
    private var shrinker: VTPixelTransferSession?
    private var counts = (frames: 0, shown: 0, late: 0, failed: 0, busy: 0.0, lead: 0.0, cuts: 0)
    private var lastReport = 0.0
    /// Frames drawn per second over the last report, against the source's own rate.
    private var shownAtReport = 0
    private var drawnRate = 0.0
    private var lastFormat: CMVideoFormatDescription?
    /// Where the output grid starts: a source frame, so at 2x every other drawn frame is an original.
    private var gridOrigin = 0.0
    private var changeMax = (histogram: 0.0, difference: 0.0)
    /// QA (with `mark`): new pictures the layer actually showed per second, read back from the marker, and how
    /// far each in-between frame is from its two neighbours (a copy of either would read 0).
    private var probe = (slot: -1, changes: 0, since: 0.0, rate: 0.0)
    private var distance = (previous: 0.0, current: 0.0, between: 0.0, count: 0)
    private var brightness = (previous: 0.0, middle: 0.0, current: 0.0, range: "")
    private var inspection: (CVPixelBuffer, CVPixelBuffer, CVPixelBuffer)?
    /// Frames wait here and are handed to the layer one at a time, as each falls due, marked to display at
    /// once: given them ahead of time with their timestamps, the layer showed only about 25 of 60 a second.
    private let presenter = DispatchQueue(label: "com.tvbox.video-enhancement.present", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: [(sample: CMSampleBuffer, real: Bool)] = []
    /// Paused on an in-between frame, the picture would stay on it; the latest real frame replaces it.
    private var latestReal: CMSampleBuffer?
    private var showingReal = true
    private var presentTimer: DispatchSourceTimer?
    /// The marker is read on a queue of its own: `queue` is busy for most of each frame while processing.
    private let probeQueue = DispatchQueue(label: "com.tvbox.video-enhancement.probe", qos: .userInteractive)
    private var probeTimer: DispatchSourceTimer?

    /// Keeps still parts of in-between frames (subtitles, logos, background) at the video's own sharpness.
    private var stillRegions: StillRegions?
    /// Seconds spent per step since the item started (QA).
    private var timing = (shrink: 0.0, interpolate: 0.0, compose: 0.0, scale: 0.0)

    init(renderer: AVSampleBufferVideoRenderer, report: @escaping @Sendable (VideoEnhancementStatus, String, String?, VideoFormatBox?) -> Void) {
        self.renderer = renderer
        self.report = report
        // Compiling the shader takes a moment: off the frame queue.
        setup.async { [weak self] in
            let regions = StillRegions()
            self?.queue.async { [weak self] in self?.stillRegions = regions }
        }
    }

    deinit { timer?.cancel(); probeTimer?.cancel(); presentTimer?.cancel() }

    private func flush(removingImage: Bool = false) {
        pendingLock.lock(); pending.removeAll(); latestReal = nil; showingReal = true; pendingLock.unlock()
        if removingImage { renderer.flush(removingDisplayedImage: true, completionHandler: nil) } else { renderer.flush() }
    }

    /// Every 2 ms: the newest frame whose time has come (a few ms early, for the next refresh) goes to the layer.
    private func present() {
        let due = CMTimebaseGetTime(renderer.timebase).seconds + 0.004
        let paused = CMTimebaseGetRate(renderer.timebase) == 0
        pendingLock.lock()
        var ready: (sample: CMSampleBuffer, real: Bool)?
        var skipped = 0
        while let first = pending.first, CMSampleBufferGetPresentationTimeStamp(first.sample).seconds <= due {
            if ready != nil { skipped += 1 }
            ready = pending.removeFirst()
            if ready?.real == true { latestReal = ready?.sample }
        }
        if let ready { showingReal = ready.real }
        // Paused on an in-between frame: show the real one it came from instead (sharper, and what AVKit would show).
        var still: CMSampleBuffer?
        if ready == nil, paused, !showingReal, let latestReal { still = latestReal; showingReal = true }
        pendingLock.unlock()
        if skipped > 0 { queue.async { [self] in counts.late += skipped } }
        if let ready { renderer.enqueue(ready.sample) }
        if let still { renderer.enqueue(still) }
    }

    func setOutput(_ output: AVPlayerItemVideoOutput?) {
        queue.async { [self] in
            self.output = output
            timebaseReady = false
            previous = nil; interval = nil; hdr = false; slow = 0; workBudget = 1280 * 720
            scaler = nil; interpolator = nil; refused = []
            counts = (0, 0, 0, 0, 0, 0, 0); timing = (0, 0, 0, 0)
            flush(removingImage: true)
            update(VideoEnhancementStatus())
            if output == nil { presentTimer?.cancel(); presentTimer = nil }
            else if presentTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: presenter)
                timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
                timer.setEventHandler { [weak self] in self?.present() }
                timer.resume()
                presentTimer = timer
            }
            if output == nil { timer?.cancel(); timer = nil }
            else if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                timer.resume()
                self.timer = timer
            }
        }
    }

    func setOptions(_ options: VideoEnhancementOptions) {
        queue.async { [self] in self.options = options }
    }

    func setTimebaseReady(_ ready: Bool) {
        queue.async { [self] in timebaseReady = ready }
    }

    /// A seek: frames already queued belong to the old position, and the next one has no neighbour.
    func discontinuity() {
        queue.async { [self] in
            previous = nil
            flush()
        }
    }

    // MARK: Frames

    private func tick() {
        guard let output else { return }
        if options.mark, probeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: probeQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(3), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.sampleDisplayed() }
            timer.resume()
            probeTimer = timer
        }
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { flush() }
        let now = CACurrentMediaTime()
        let ahead = output.itemTime(forHostTime: now + Self.lookahead)
        guard ahead.isValid, output.hasNewPixelBuffer(forItemTime: ahead) else { return }
        let pulled = output.pixelBufferAndDisplayTime(forItemTime: ahead)
        guard let readOnly = pulled.pixelBuffer, pulled.itemTimeForDisplay.isValid else { return }
        // The processors take a CVPixelBuffer; this one is only read, by them and by the layer.
        nonisolated(unsafe) var pixels: CVPixelBuffer?
        readOnly.withUnsafeBuffer { pixels = $0 }
        guard let buffer = pixels else { return }
        handle(Frame(buffer: buffer, time: pulled.itemTimeForDisplay), output: output)
    }

    private func handle(_ frame: Frame, output: AVPlayerItemVideoOutput) {
        guard options.upscale || options.smooth else { return update(VideoEnhancementStatus()) }
        if Self.isHDR(frame.buffer) {
            // Processing is 8-bit SDR; HDR keeps AVKit's own picture and the TV's HDR mode.
            if !hdr { hdr = true; update(VideoEnhancementStatus(), note: "hdr source, left to AVKit") }
            return
        }
        counts.frames += 1
        let width = CVPixelBufferGetWidth(frame.buffer), height = CVPixelBufferGetHeight(frame.buffer)
        if let last = previous {
            let gap = frame.time.seconds - last.time.seconds
            if gap <= 0 || gap > 0.25 || CVPixelBufferGetWidth(last.buffer) != width || CVPixelBufferGetHeight(last.buffer) != height {
                previous = nil
                if gap <= 0 { flush() }
            } else if let known = interval, abs(gap - known) < known * 0.2 {
                interval = known * 0.9 + gap * 0.1
            } else {
                interval = gap
            }
        }
        let work = workSize(width: width, height: height)
        prepare(width: width, height: height, work: work, format: CVPixelBufferGetPixelFormatType(frame.buffer))
        if previous == nil { gridOrigin = frame.time.seconds }

        let started = CACurrentMediaTime()
        var current = frame
        // A big picture is interpolated from a smaller copy: only the in-between frames are drawn at that size.
        let shrinks = work != (width, height)
        let shrinking = CACurrentMediaTime()
        if shrinks, let interpolator { current.work = shrink(frame.buffer, with: interpolator) }
        timing.shrink += CACurrentMediaTime() - shrinking
        var frames = [current]
        let smoothing = interpolator != nil && smoothable
        if smoothing, let interpolator, let last = previous, !shrinks || (last.work != nil && current.work != nil) {
            // Across a cut the two frames show different shots, and morphing one into the other gives a
            // scrambled mix of both: hold each shot instead, as TVs do.
            let change = Self.sceneChange(last.work ?? last.buffer, current.work ?? current.buffer)
            let cut = change.cut
            if cut { counts.cuts += 1 }
            changeMax = (max(changeMax.histogram, change.histogram), max(changeMax.difference, change.difference))
            if let made = interpolate(from: last, to: current, with: interpolator, cut: cut) { frames = made }
            else { failed(interpolator) }
        }
        let upscaling = scaler != nil
        if let scaler {
            frames = frames.map { source in
                guard scaler.accepts(source.buffer) else { return source }
                if let scaled = scale(source, with: scaler) { return scaled }
                failed(scaler)
                return source
            }
        }
        let spent = CACurrentMediaTime() - started
        counts.busy += spent
        if counts.frames % 15 == 0 { inspect() } else { inspection = nil }
        previous = current
        update(VideoEnhancementStatus(upscaling: upscaling, smoothing: smoothing, sourceRate: interval.map { (100 / $0).rounded() / 100 } ?? 0))
        budget(spent)
        guard status.active, timebaseReady else { return }
        enqueue(frames, now: output.itemTime(forHostTime: CACurrentMediaTime()).seconds)
    }

    /// Whether the source is slow enough to gain from in-between frames (24–30 fps, up to 47).
    private var smoothable: Bool {
        guard let interval, let shown = shownInterval else { return false }
        return shown > 1 / 47.0 && interval < 1 / 18.0
    }

    /// Seconds between source frames on screen: played faster, they come closer together, and 30 fps at 2x already
    /// fills a 60 Hz screen. Above 2x the frame times read from the output also jump between one and three frames
    /// apart, so the media interval alone switched smoothing on and off many times a second and the picture
    /// flashed between AVKit's and this layer's (#223).
    private var shownInterval: Double? {
        guard let interval else { return nil }
        let rate = CMTimebaseGetRate(renderer.timebase)
        return rate > 1 ? interval / rate : interval
    }

    private func enqueue(_ frames: [Frame], now: Double) {
        for (index, frame) in frames.enumerated() {
            // A frame already past its turn would only flash; the last one still shows the newest picture.
            if frame.time.seconds < now - 1 / options.outputRate, index < frames.count - 1 { counts.late += 1; continue }
            // isReadyForMoreMediaData is advice for a source that could run ahead; frames here arrive at
            // playback speed, at most a few dozen milliseconds early, so the queue stays short.
            var buffer = frame.buffer
            if options.mark {
                // A source frame is shared with AVKit's own picture, so it is marked on a copy.
                if !status.upscaling, let copy = markCopy(buffer) { buffer = copy }
                if status.upscaling || buffer !== frame.buffer { Self.mark(buffer, index: counts.shown) }
            }
            do {
                let format = try CMVideoFormatDescription(imageBuffer: buffer)
                let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
                let sample = try CMSampleBuffer(imageBuffer: buffer, formatDescription: format, sampleTiming: timing)
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
                    attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
                }
                pendingLock.lock(); pending.append((sample, frame.real)); pendingLock.unlock()
                lastFormat = format
                counts.shown += 1
                counts.lead += frame.time.seconds - now
            } catch { counts.failed += 1 }
        }
    }

    /// QA only: a private copy of a frame to draw the marker on.
    private func markCopy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if shrinker == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            shrinker = session
        }
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetPixelFormatType(buffer),
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()] as CFDictionary, &copy)
        guard let shrinker, let copy, VTPixelTransferSessionTransferImage(shrinker, from: buffer, to: copy) == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, copy)
        return copy
    }

    private func sampleDisplayed() {
        let now = CACurrentMediaTime()
        if let shown = renderer.displayedPixelBuffer(), let slot = Self.markSlot(shown), slot != probe.slot {
            probe.slot = slot; probe.changes += 1
        }
        if now - probe.since >= 1 {
            probe.rate = probe.since > 0 ? Double(probe.changes) / (now - probe.since) : 0
            probe.changes = 0; probe.since = now
        }
    }

    /// Which of the 60 marker positions the buffer shows, if any.
    private static func markSlot(_ buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let size = max(8, height / 24), step = (width - size) / 60
        let line = base + (height - size * 2 + size / 2) * row
        var x = 0
        while x + size <= width {
            if line[x] == 235, line[x + size - 1] == 235, line[x + size / 2] == 235 { return x / max(1, step) }
            x += 1
        }
        return nil
    }

    private static func meanLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 6) { for x in stride(from: 0, to: width, by: 6) { total += Int(p[y * row + x]); count += 1 } }
        return Double(total) / Double(max(1, count))
    }

    private static func fourCC(_ buffer: CVPixelBuffer) -> String {
        let code = CVPixelBufferGetPixelFormatType(buffer)
        return String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
    }

    /// A scene change between two frames of the same size: their brightness histograms differ a lot, or the
    /// pictures differ a lot and the histograms clearly. A pan or fast motion moves the picture but keeps
    /// its histogram, so it is still interpolated. Reads about 15,000 luma samples.
    private static func sceneChange(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (cut: Bool, histogram: Double, difference: Double) {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else { return (true, -1, -1) }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) else { return (false, -2, -2) }
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let width = CVPixelBufferGetWidthOfPlane(a, 0), height = CVPixelBufferGetHeightOfPlane(a, 0)
        let step = max(4, Int((Double(width * height) / 15_000).squareRoot()))
        var ha = [Int](repeating: 0, count: 32), hb = [Int](repeating: 0, count: 32)
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let va = Int(pa[y * ra + x]), vb = Int(pb[y * rb + x])
                ha[va >> 3] += 1; hb[vb >> 3] += 1
                total += abs(va - vb); count += 1
            }
        }
        guard count > 0 else { return (false, -3, -3) }
        let histogram = Double(zip(ha, hb).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(count)   // 0...2
        let difference = Double(total) / Double(count)
        return (histogram > 0.5 || (difference > 30 && histogram > 0.25), histogram, difference)
    }

    /// Mean luma difference on a sparse grid.
    private static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let width = min(CVPixelBufferGetWidthOfPlane(a, 0), CVPixelBufferGetWidthOfPlane(b, 0))
        let height = min(CVPixelBufferGetHeightOfPlane(a, 0), CVPixelBufferGetHeightOfPlane(b, 0))
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 5) { for x in stride(from: 0, to: width, by: 5) {
            total += abs(Int(pa[y * ra + x]) - Int(pb[y * rb + x])); count += 1
        } }
        return count > 0 ? Double(total) / Double(count) : -1
    }

    private static func mark(_ buffer: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let size = max(8, height / 24), slots = 60, step = (width - size) / slots
        let left = (index % slots) * step, top = height - size * 2
        for y in top..<(top + size) { memset(base + y * row + left, 235, size) }
    }

    /// The source frame's slots on the 60 Hz grid between the previous frame and this one, each the
    /// nearer source frame or an interpolated one: 30 fps gets one new frame between two, 24 fps
    /// alternates two and three.
    private func interpolate(from last: Frame, to frame: Frame, with stage: Stage, cut: Bool) -> [Frame]? {
        let start = last.time.seconds, end = frame.time.seconds, span = end - start
        var slots: [(time: CMTime, phase: Float)] = []
        let rate = options.outputRate, origin = gridOrigin
        var index = ((start - origin) * rate + 0.0005).rounded(.down) + 1
        while origin + index / rate <= end + 0.0005 {
            // The exact position: the processor takes any phase (it resolves about an eighth of a frame), and
            // rounding to quarters made 25 fps move in uneven steps on a 60 Hz screen.
            let raw = (origin + index / rate - start) / span
            let phase = Float(raw < 0.03 ? 0 : raw > 0.97 ? 1 : (raw * 1000).rounded() / 1000)
            slots.append((CMTime(seconds: origin + index / rate, preferredTimescale: 90_000), phase))
            index += 1
        }
        let phases = Array(Set(slots.map(\.phase).filter { $0 > 0 && $0 < 1 })).sorted()
        var made: [Float: CVPixelBuffer] = [:]
        if cut {
            return slots.map { Frame(buffer: $0.phase < 0.5 ? last.buffer : frame.buffer, time: $0.time) }
        }
        if !phases.isEmpty {
            guard let source = VTFrameProcessorFrame(buffer: frame.work ?? frame.buffer, presentationTimeStamp: frame.time),
                  let prior = VTFrameProcessorFrame(buffer: last.work ?? last.buffer, presentationTimeStamp: last.time) else { return nil }
            var buffers: [CVPixelBuffer] = [], destinations: [VTFrameProcessorFrame] = []
            for phase in phases {
                guard let buffer = stage.makeBuffer(),
                      let destination = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(seconds: start + Double(phase) * span, preferredTimescale: 90_000))
                else { return nil }
                buffers.append(buffer); destinations.append(destination)
            }
            guard let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: source, previousFrame: prior, interpolationPhase: phases, destinationFrames: destinations),
                  timed(&timing.interpolate, { stage.run(parameters) }) else { return nil }
            // Made from a smaller copy, an in-between frame blurs subtitles and still detail (24 against 35 dB on
            // burned-in subtitles): where the two real frames agree, their own pixels are used instead.
            let composing = CACurrentMediaTime()
            #if DEBUG
            let still = UserDefaults.standard.bool(forKey: "qaNoStill") ? nil : stillRegions
            #else
            let still = stillRegions
            #endif
            let kept = still?.compose(previous: last.buffer, next: frame.buffer, made: buffers, phases: phases) ?? buffers
            timing.compose += CACurrentMediaTime() - composing
            for (phase, buffer) in zip(phases, kept) {
                CVBufferPropagateAttachments(frame.buffer, buffer)
                made[phase] = buffer
            }
            if options.mark, let middle = buffers.first {
                inspection = (last.work ?? last.buffer, middle, frame.work ?? frame.buffer)
            }
        }
        return slots.map { slot in
            let made = slot.phase <= 0 || slot.phase >= 1 ? nil : made[slot.phase]
            return Frame(buffer: made ?? (slot.phase < 0.5 ? last.buffer : frame.buffer), time: slot.time, real: made == nil)
        }
    }

    /// QA only, every 15th source frame and outside the time budget: how the in-between frame compares.
    private func inspect() {
        guard let (before, middle, after) = inspection else { return }
        inspection = nil
        distance.previous += Self.difference(middle, before); distance.current += Self.difference(middle, after)
        distance.between += Self.difference(before, after); distance.count += 1
        brightness = (Self.meanLuma(before), Self.meanLuma(middle), Self.meanLuma(after),
                      "\(Self.fourCC(before))/\(Self.fourCC(middle)) \((CVBufferCopyAttachments(middle, .shouldPropagate) as? [String: Any])?[kCVImageBufferYCbCrMatrixKey as String] as? String ?? "no-matrix")")
    }

    private func timed(_ total: inout Double, _ work: () -> Bool) -> Bool {
        let began = CACurrentMediaTime()
        defer { total += CACurrentMediaTime() - began }
        return work()
    }

    private func shrink(_ buffer: CVPixelBuffer, with stage: Stage) -> CVPixelBuffer? {
        if shrinker == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            shrinker = session
        }
        guard let shrinker, let small = stage.makeBuffer(), VTPixelTransferSessionTransferImage(shrinker, from: buffer, to: small) == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, small)
        return small
    }

    private func scale(_ frame: Frame, with stage: Stage) -> Frame? {
        guard let buffer = stage.makeBuffer(),
              let source = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.time),
              let destination = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: frame.time),
              stage.run(VTLowLatencySuperResolutionScalerParameters(sourceFrame: source, destinationFrame: destination)) else { return nil }
        CVBufferPropagateAttachments(frame.buffer, buffer)
        return Frame(buffer: buffer, time: frame.time, real: frame.real)
    }

    // MARK: Processors

    /// Starts the processors this source needs and drops the ones it no longer does.
    private func prepare(width: Int, height: Int, work: (width: Int, height: Int), format: OSType) {
        let factor = options.upscale ? Self.scaleFactor(width: width, height: height, target: options.target) : nil
        let scaleKey = factor.map { "scale \(width)x\(height) x\($0)" }
        let tooFast = shownInterval.map { $0 <= 1 / 47.0 } ?? false
        let smoothKey = options.smooth && !tooFast && Self.interpolationFits(width: work.width, height: work.height)
            ? "smooth \(work.width)x\(work.height)\(work != (width, height) ? " from \(width)x\(height)" : "")" : nil
        wanted = (scaleKey, smoothKey)
        // The work size decides which processor we build. When it changes (unfold, rotation) the size often
        // flickers across a few values in quick succession; tearing down and restarting the ML session for
        // each one crashes VideoToolbox (SIGSEGV). While the size is still settling, drop the processors and
        // skip rebuilding — AVKit's own picture shows — then build once the size has held steady for 0.25 s.
        if builtSize.map({ $0 != work }) ?? true {
            builtSize = work
            sizeChangedAt = CACurrentMediaTime()
            scaler = nil
            interpolator = nil
        }
        let settling = CACurrentMediaTime() - sizeChangedAt < 0.25
        if !settling {
            if scaler?.key != scaleKey { scaler = nil }
            if interpolator?.key != smoothKey { interpolator = nil }
        }
        if let scaleKey, let factor, scaler == nil, !settling {
            start(scaleKey) {
                let configuration = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor)
                guard configuration.supportedPixelFormats.contains(format) else { throw StageError.format }
                return try Stage(key: scaleKey, configuration: configuration, destination: configuration.destinationPixelBufferAttributes, source: (width, height),
                                 width: Int((Float(width) * factor).rounded()), height: Int((Float(height) * factor).rounded()), format: format)
            }
        }
        if let smoothKey, interpolator == nil, !settling {
            start(smoothKey) {
                // Two: exact phases come back at about an eighth of a frame either way, and three cost ~5 ms more a frame (M1 Pro).
                guard let configuration = VTLowLatencyFrameInterpolationConfiguration(frameWidth: work.width, frameHeight: work.height, numberOfInterpolatedFrames: 2)
                else { throw StageError.unsupported }
                guard configuration.supportedPixelFormats.contains(format) else { throw StageError.format }
                return try Stage(key: smoothKey, configuration: configuration, destination: configuration.destinationPixelBufferAttributes, source: work,
                                 width: work.width, height: work.height, format: format)
            }
        }
    }

    private func start(_ key: String, make: @escaping @Sendable () throws -> Stage) {
        guard !refused.contains(key), !starting.contains(key) else { return }
        starting.insert(key)
        setup.async { [weak self] in
            let began = CACurrentMediaTime()
            let result = Result { try make() }
            let took = Int((CACurrentMediaTime() - began) * 1000)
            self?.queue.async { [weak self] in
                guard let self else { return }
                starting.remove(key)
                switch result {
                case .success(let stage):
                    if wanted.scale == key { scaler = stage }
                    else if wanted.smooth == key { interpolator = stage }
                    else { return }
                    note("\(key) started in \(took) ms")
                case .failure(let error):
                    refused.insert(key)
                    note("\(key) unavailable: \(Diagnostics.describe(error))")
                }
            }
        }
    }

    /// A processor that keeps failing (some systems accept a size at start and then refuse every frame) is dropped.
    private func failed(_ stage: Stage) {
        counts.failed += 1
        stage.failures += 1
        guard stage.failures >= 10 else { return }
        refused.insert(stage.key)
        if scaler === stage { scaler = nil }
        if interpolator === stage { interpolator = nil }
        note("\(stage.key) dropped after repeated failures")
    }

    /// When the work takes most of a frame's time, the device can't keep up: give up upscaling first, then smoothing.
    private func budget(_ spent: Double) {
        let allowance = (interval ?? 1 / 30.0) * 0.92
        slow = spent > allowance ? slow + 1 : max(0, slow - 1)
        guard slow > 45 else { return }
        slow = 0
        if let scaler {
            refused.insert(scaler.key); self.scaler = nil
            note("\(scaler.key) too slow (\(Int(spent * 1000)) ms a frame), dropped")
        } else if let interpolator {
            refused.insert(interpolator.key); self.interpolator = nil
            if workBudget > 960 * 540 {
                workBudget = 960 * 540
                note("\(interpolator.key) too slow (\(Int(spent * 1000)) ms a frame), trying 540p")
            } else {
                note("\(interpolator.key) too slow (\(Int(spent * 1000)) ms a frame), dropped")
            }
        }
    }

    /// The size the interpolator works at: the picture itself, or a copy within `workBudget`.
    private func workSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width * height > workBudget else { return (width, height) }
        let scale = (Double(workBudget) / Double(width * height)).squareRoot()
        return (Int(Double(width) * scale) / 16 * 16, Int(Double(height) * scale) / 2 * 2)
    }

    /// Upscale any picture drawn larger than it is, by the processor's factor nearest the gap. Below 1.5x the
    /// layer shrinks the result to fit and keeps the detail: 720p in a 1613-pixel-wide window (a 1x monitor)
    /// needs only 1.1x, and a 1.4x floor left it unprocessed.
    private static func scaleFactor(width: Int, height: Int, target: CGSize) -> Float? {
        guard target.width > 0, target.height > 0, width > 0, height > 0 else { return nil }
        let need = Float(min(target.width / CGFloat(width), target.height / CGFloat(height)))
        guard need > 1.05 else { return nil }
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).filter { $0 > 1 }.sorted()
        return factors.min { abs($0 - need) < abs($1 - need) }
    }

    /// OS 27 reports the interpolator's size limit. OS 26 has no query, and above 1280×720 its sessions
    /// start and then fail every frame (reported by other developers), so stay within that there.
    private static func interpolationFits(width: Int, height: Int) -> Bool {
        guard let limit = interpolationLimit else { return max(width, height) <= 1280 && width * height <= 1280 * 720 }
        return max(width, height) <= limit.side && width * height <= limit.pixels
    }

    /// The SDK marks the size query 27.0, but iOS 27.0 lacks its Swift wrappers: calling them jumped to address 0
    /// (crash report e8d4f2a2b133). The Objective-C methods are asked for by selector instead, once; 0 means unsupported.
    private static let interpolationLimit: (side: Int, pixels: Int)? = {
        guard #available(macOS 27, iOS 27, tvOS 27, *) else { return nil }
        let type = VTLowLatencyFrameInterpolationConfiguration.self
        guard type.responds(to: #selector(VTLowLatencyFrameInterpolationConfiguration.__maximumDimension(forSpatialScaleFactor:))),
              type.responds(to: #selector(VTLowLatencyFrameInterpolationConfiguration.__maximumPixelCount(forSpatialScaleFactor:)))
        else { return nil }
        return (type.__maximumDimension(forSpatialScaleFactor: 1), type.__maximumPixelCount(forSpatialScaleFactor: 1))
    }()

    private static func isHDR(_ buffer: CVPixelBuffer) -> Bool {
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]
        guard let transfer = attachments?[kCVImageBufferTransferFunctionKey as String] as? String else { return false }
        return transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    }

    // MARK: Reporting

    private func update(_ next: VideoEnhancementStatus, note: String? = nil) {
        let now = CACurrentMediaTime()
        guard next != status || note != nil || now - lastReport > 1 else { return }
        if next != status, !next.active { flush(removingImage: true) }
        if now - lastReport > 0.5 {
            drawnRate = lastReport > 0 ? Double(counts.shown - shownAtReport) / (now - lastReport) : 0
            shownAtReport = counts.shown
            lastReport = now
        }
        status = next
        report(next, summary, note, lastFormat.map(VideoFormatBox.init))
    }

    private func note(_ text: String) { update(status, note: text) }

    /// What the layer itself reports: its status, the frame it shows now, and its clock against the item's.
    private var rendererState: String {
        #if !DEBUG
        return ""
        #else
        var text = " · renderer \(renderer.status.rawValue)"
        if let error = renderer.error { text += " error \((error as NSError).code)" }
        if let shown = renderer.displayedPixelBuffer() { text += " showing \(CVPixelBufferGetWidth(shown))x\(CVPixelBufferGetHeight(shown))" }
        else { text += " showing nothing" }
        if let timebase = renderer.timebase as CMTimebase?, let output {
            let clock = CMTimebaseGetTime(timebase).seconds, item = output.itemTime(forHostTime: CACurrentMediaTime()).seconds
            text += String(format: " clock %.2f item %.2f rate %.1f", clock, item, CMTimebaseGetRate(timebase))
        }
        return text
        #endif
    }

    private var summary: String {
        let average = counts.frames > 0 ? counts.busy / Double(counts.frames) * 1000 : 0
        let parts = [scaler?.key, interpolator?.key, hdr ? "hdr" : nil].compactMap { $0 }
        return (parts.isEmpty ? "idle" : parts.joined(separator: ", "))
            + String(format: " · %.1f → %.1f fps", interval.map { 1 / $0 } ?? 0, drawnRate)
            + rendererState
            + (options.mark ? String(format: " · displayed %.1f fps · mid-prev %.1f mid-next %.1f prev-next %.1f", probe.rate,
                                     distance.previous / Double(max(1, distance.count)), distance.current / Double(max(1, distance.count)),
                                     distance.between / Double(max(1, distance.count)))
                           + String(format: " · luma prev %.1f mid %.1f next %.1f ", brightness.previous, brightness.middle, brightness.current) + brightness.range : "")
            + String(format: " · shrink %.1f interp %.1f compose %.1f ms", timing.shrink / Double(max(1, counts.frames)) * 1000,
                            timing.interpolate / Double(max(1, counts.frames)) * 1000, timing.compose / Double(max(1, counts.frames)) * 1000)
            + String(format: " · in %d shown %d late %d failed %d cuts %d (max %.2f/%.0f) · %.1f ms, lead %.0f ms", counts.frames, counts.shown, counts.late,
                            counts.failed, counts.cuts, changeMax.histogram, changeMax.difference, average, counts.shown > 0 ? counts.lead / Double(counts.shown) * 1000 : 0)
    }
}

private enum StageError: Error { case unsupported, format, pool }

/// Where the two real frames around an in-between one agree (subtitles, logos, a still background), the nearer real
/// frame's own full-resolution pixels; where they differ, the in-between frame (made from a smaller copy for big
/// pictures). Two Metal passes: a half-resolution map of what moves, once per interval, then a blend per frame.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class StillRegions: @unchecked Sendable {
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // 1 where the two real frames differ (anything moving, with a margin), 0 where they agree.
    kernel void motion(texture2d<float, access::read> prev [[texture(0)]], texture2d<float, access::read> next [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]], constant float &threshold [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        int2 last = int2(prev.get_width(), prev.get_height()) - 1;
        float d = 0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            uint2 p = uint2(clamp(int2(gid) * 2 + int2(dx, dy) * 2, int2(0), last));
            d = max(d, abs(prev.read(p).r - next.read(p).r));
        }
        out.write(float4(smoothstep(threshold, threshold * 2.5, d)), gid);
    }
    kernel void compose(texture2d<float, access::read> prev [[texture(0)]], texture2d<float, access::read> next [[texture(1)]],
                        texture2d<float, access::sample> made [[texture(2)]], texture2d<float, access::sample> moving [[texture(3)]],
                        texture2d<float, access::write> out [[texture(4)]], constant float &phase [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(out.get_width(), out.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        constexpr sampler linear(filter::linear, coord::normalized, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(size);
        float4 real = phase < 0.5 ? prev.read(gid) : next.read(gid);
        out.write(mix(real, made.sample(linear, uv), moving.sample(linear, uv).r), gid);
    }
    """
    /// Below this difference (0...1) a pixel counts as still: above compression noise, below real motion.
    private static let threshold: Float = 0.04

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let motion: MTLComputePipelineState
    private let blend: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var pool: (width: Int, height: Int, pool: CVPixelBufferPool)?
    private var map: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let motion = library.makeFunction(name: "motion").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let blend = library.makeFunction(name: "compose").flatMap({ try? device.makeComputePipelineState(function: $0) }) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device; self.queue = queue; self.motion = motion; self.blend = blend; self.cache = cache
    }

    /// All the in-between frames of one interval in a single GPU submission; nil when any of it fails.
    func compose(previous: CVPixelBuffer, next: CVPixelBuffer, made: [CVPixelBuffer], phases: [Float]) -> [CVPixelBuffer]? {
        let width = CVPixelBufferGetWidth(previous), height = CVPixelBufferGetHeight(previous)
        guard CVPixelBufferGetPlaneCount(previous) == 2, CVPixelBufferGetWidth(next) == width, CVPixelBufferGetHeight(next) == height,
              let map = motionMap(width: (width + 1) / 2, height: (height + 1) / 2),
              let commands = queue.makeCommandBuffer() else { return nil }
        var textures: [CVMetalTexture] = []   // kept until the GPU is done
        var planes: [[MTLTexture]] = []
        for plane in 0...1 {
            guard let prev = texture(previous, plane, &textures), let nextTexture = texture(next, plane, &textures) else { return nil }
            planes.append([prev, nextTexture])
        }
        guard let encoder = commands.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(motion)
        encoder.setTexture(planes[0][0], index: 0); encoder.setTexture(planes[0][1], index: 1); encoder.setTexture(map, index: 2)
        var threshold = Self.threshold
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: map.width, height: map.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        var outputs: [CVPixelBuffer] = []
        encoder.setComputePipelineState(blend)
        for (buffer, phase) in zip(made, phases) {
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  let out = makeBuffer(width: width, height: height, format: CVPixelBufferGetPixelFormatType(previous)) else { encoder.endEncoding(); return nil }
            for plane in 0...1 {
                guard let madeTexture = texture(buffer, plane, &textures), let target = texture(out, plane, &textures) else { encoder.endEncoding(); return nil }
                for (index, item) in [planes[plane][0], planes[plane][1], madeTexture, map, target].enumerated() { encoder.setTexture(item, index: index) }
                var value = phase
                encoder.setBytes(&value, length: MemoryLayout<Float>.size, index: 0)
                encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            CVBufferPropagateAttachments(previous, out)
            outputs.append(out)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        return commands.status == .completed ? outputs : nil
    }

    private func motionMap(width: Int, height: Int) -> MTLTexture? {
        if let map, map.width == width, map.height == height { return map }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        map = device.makeTexture(descriptor: descriptor)
        return map
    }

    private func texture(_ buffer: CVPixelBuffer, _ plane: Int, _ keep: inout [CVMetalTexture]) -> MTLTexture? {
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, plane == 0 ? .r8Unorm : .rg8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &made)
        guard let made, let texture = CVMetalTextureGetTexture(made) else { return nil }
        keep.append(made)
        return texture
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool?.width != width || pool?.height != height {
            var made: CVPixelBufferPool?
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferPixelFormatTypeKey as String: format,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
                                             kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
            pool = made.map { (width, height, $0) }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool, &buffer)
        return buffer
    }
}

/// One running processor and the pool its output frames come from.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class Stage: @unchecked Sendable {
    let key: String
    var failures = 0
    /// The size of the frames it takes.
    let source: (width: Int, height: Int)
    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool

    init(key: String, configuration: any VTFrameProcessorConfiguration, destination: [String: Any], source: (width: Int, height: Int),
         width: Int, height: Int, format: OSType) throws {
        self.key = key
        self.source = source
        var attributes = destination
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw StageError.pool }
        self.pool = pool
        try processor.startSession(configuration: configuration)
    }

    deinit { processor.endSession() }

    func accepts(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(buffer) == source.width && CVPixelBufferGetHeight(buffer) == source.height
    }

    func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// Runs one request and waits for it: this queue does nothing else meanwhile.
    func run(_ parameters: any VTFrameProcessorParameters) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        processor.process(parameters: parameters) { _, error in
            outcome.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.5) == .success else { return false }
        return outcome.error == nil
    }

    private final class Outcome: @unchecked Sendable { var error: Error? }
}
#endif
