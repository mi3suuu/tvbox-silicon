import Foundation

// MARK: - 坞的解码预算

/// 「坞里挂了 8 个，到底哪几个在解码」的唯一判定。
///
/// ## 为什么需要它
///
/// 坞的上限从 4 放宽到 8，但**同时解码**不能跟着涨：每个任务是一路 `AVPlayer`
/// 加一条已建立的流，五六路之后解码与网络开始互相抢（本项目源多为单线程 HLS），
/// 画面会一起卡。原来的写法是把上限卡在「卡片数」上，用户于是被挡住只能挂 4 部剧。
///
/// 正确的位置是把限制落在**解码**这一层：
///   · 卡片可以有 8 个（用户的观看队列）；
///   · 同时只解码 `budget` 个，其余暂停；
///   · 用户切到哪一路，哪一路就在预算内 —— **最近被切到的优先**。
///
/// ## 判据为什么是「最近使用」而不是「谁在播」
///
/// 用户的心智是「我刚点的那一个要能放」。如果按「谁在播」排，暂停的几路永远排在后面，
/// 想切到一个暂停的反而要先关掉别的 —— 那就退回「只能 4 个」的体验了。
/// 所以按**最近激活序**（`order` 里靠前的优先），谁被点过谁是热的。
public enum DockDecodingBudget {

    /// 给定坞里全部任务（**按最近激活排序，热的在前**）与预算，
    /// 返回「应该解码」的那几个 id。
    ///
    /// 纯函数：不读播放器、不看视图，可以直接断言。
    public static func decodeSet(order: [UUID], budget: Int) -> Set<UUID> {
        guard budget > 0 else { return [] }
        return Set(order.prefix(budget))
    }

    /// 这一路该不该解码。
    public static func shouldDecode(_ id: UUID, order: [UUID], budget: Int) -> Bool {
        decodeSet(order: order, budget: budget).contains(id)
    }

    /// 坞里有几个会因为超预算而被暂停。
    ///
    /// 管理器用它显示「N 个已暂停」—— 用户要能看出「不是坏了，是被挂起了」。
    public static func suspendedCount(order: [UUID], budget: Int) -> Int {
        max(0, order.count - max(0, budget))
    }

    /// 按**卡片在坞里的位置**判它是否被挂起。
    ///
    /// 卡片视图拿得到 `taskIndex`（与 `tasks` 同序），拿不到整张 order 表 ——
    /// 而 `decodeSet` 的定义就是「order 的前 budget 个」，所以按位置判与按 id 判等价。
    /// 抽出来是为了让「第几个开始挂起」这条规则只有一处，卡片与 `applyMuting` 不会走散。
    public static func isSuspended(index: Int, budget: Int) -> Bool {
        index >= max(0, budget)
    }
}

// MARK: - 画质增强的准入

/// 「这次到底该不该开画质增强」的唯一判定。
///
/// ## 为什么必须有一个进程级的闸
///
/// `PlaybackSession` **每一路都持有一个 `VideoEnhancer`**（`let enhancer`，`init` 里建），
/// 而增强开关是全局 `UserDefaults`。于是「坞里挂 N 个窗、设置里开着 sharper」时，
/// 每一路的 250 ms 刷新都会去 `makeEngineIfNeeded()` —— 建一条 Metal 管线 +
/// VideoToolbox 超分管线。20 个窗就是 20 条。
///
/// 真机那次 OOM（2700 MB，「bilibili m3u8 + sharper + 弹幕」）就是这么来的：
/// 小窗只有 320 pt 宽，超分到那么大毫无意义，却按全尺寸吃了显存与中间缓冲。
///
/// 所以准入条件只有三条，而且都必须是**能力/资源**判据，不是偏好：
///   1. 这一路**有画面在屏上**（`attachedLayer != nil`）—— 坞卡片用的是普通
///      `AVPlayerLayer`，从来不会 attach，天然被排除；
///   2. 坞里没有别的路在解码 —— 前台 + 小窗同时解，增强是压垮内存的最后一根；
///   3. 系统没在给内存压力 / 没发热 / 没省电 / 没在 AirPlay。
///
/// 关掉时不是「黑掉」：`apply` 会把增强层 `isHidden = true`，露出的正是 AVKit 自己的画面。
public enum EnhancementBudget {

    public enum Decision: Equatable, Sendable {
        case on
        case off(String)

        public var isOn: Bool { self == .on }
        public var reason: String { if case .off(let why) = self { return why }; return "on" }
    }

    /// 坞里最多允许几路在解码时还开着增强。
    ///
    /// ⛔ 不是 0：单条管线的开销是可接受的，把「开一个迷你小窗就丢掉画质增强」
    ///    当成修法，用户体感就是「增强坏了」。真正的倍数是「20 个窗各建一条管线」，
    ///    那个已经由 `hasSurface` 挡掉；这里管的是「唯一那条管线 + 很多路解码」
    ///    这种叠加压力 —— 3 路以上就让路，2 路以内照旧。
    public static let otherDecodingCeiling = 2

    /// - Parameters:
    ///   - hasSurface: 这一路是否已经把视频层交给增强器（只有屏上的那个播放页会）。
    ///   - otherDecoding: 除这一路之外，还有几路在解码（坞里的活跃窗）。
    ///   - memoryPressure: 系统是否在给内存压力（warning / critical）。
    ///   - constrained: 发热严重或低电量模式。
    ///   - externalPlayback: 是否正在 AirPlay 到别的屏幕。
    public static func decide(hasSurface: Bool, otherDecoding: Int,
                              memoryPressure: Bool, constrained: Bool,
                              externalPlayback: Bool) -> Decision {
        if !hasSurface { return .off("no surface") }
        if externalPlayback { return .off("airplay") }
        if memoryPressure { return .off("memory pressure") }
        if constrained { return .off("thermal or low power") }
        if otherDecoding > otherDecodingCeiling {
            return .off("\(otherDecoding) other window(s) decoding")
        }
        return .on
    }
}

/// 进程级「现在有几路在解码 / 内存紧张吗」。
///
/// 只有 `VideoTaskCenter`（写解码路数）和 `VideoEnhancer`（读）碰它，
/// 所以是一个带锁的小对象，而不是 `@Observable` —— 增强器每 250 ms 读一次，
/// 不需要也不可能靠观察刷新。
public final class PlaybackLoad: @unchecked Sendable {
    public static let shared = PlaybackLoad()

    private let lock = NSLock()
    /// 坞里**正在解码**的路数（不含前台）。
    private var dockDecoding = 0
    private var pressure = false

    public init() {}

    public var dockDecodingCount: Int { lock.withLock { dockDecoding } }
    public var memoryPressure: Bool { lock.withLock { pressure } }

    public func setDockDecoding(_ count: Int) {
        let value = max(0, count)
        let changed = lock.withLock { () -> Bool in
            let old = dockDecoding
            dockDecoding = value
            return old != value
        }
        if changed { Diagnostics.shared.record(.debug, "enhance", "dock decoding now \(value)") }
    }

    public func setMemoryPressure(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            let old = pressure
            pressure = value
            return old != value
        }
        if changed {
            Diagnostics.shared.record(.warning, "enhance",
                "system memory pressure \(value ? "began" : "ended") — enhancement \(value ? "suspended" : "may resume")")
        }
    }

    /// 起一次内存压力监听。`start()` 幂等，由 App 启动时调用。
    ///
    /// ⛔ 这不是「优化」：20 个窗 + 增强那条路一旦进 `.critical`，
    /// 系统是先杀进程再弹「App 意外退出」，我们连降级的机会都没有。
    /// 有了它，压力一到就把增强让出去，画面还在。
    public func startMemoryPressureMonitor() {
        let started = lock.withLock { () -> Bool in
            if monitorStarted { return false }
            monitorStarted = true
            return true
        }
        guard started else { return }
        #if os(iOS) || os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal], queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [source, weak self] in
            // `.normal` 是压力解除的唯一信号 —— 只听 warning/critical 会让增强永久关着。
            let event = source.data
            let severe = event.contains(.warning) || event.contains(.critical)
            self?.setMemoryPressure(severe)
        }
        source.resume()
        lock.withLock { memorySource = source }
        #endif
    }

    private var monitorStarted = false
    private var memorySource: AnyObject?
}

