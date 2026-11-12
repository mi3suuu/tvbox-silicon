import Foundation

/// 坞里多个迷你播放器时，**声音怎么分**。
///
/// ## 背景
/// ----
/// iOS 的 `AVAudioSession` 是**进程级单例**，一个 App 只有一个会话。多个 `AVPlayer`
/// 共享它，所以「同一时刻多路同时出声」需要额外造一条混音链路
/// （`AVAudioEngine` + `MTAudioProcessingTap` 把每路 PCM 抽出来再混），
/// 代价见 `Docs/duo/多路音频可行性查证-20261112.md`。
///
/// 用户要求「这些都做成设置里可选」。所以这里把三种策略都实现：
///
/// | 策略 | 体验 | 代价 |
/// |---|---|---|
/// | `.focused` | 只有选中那张出声，其余静音 | 无。与 YouTube / Safari 多标签一致 |
/// | `.dimmed` | 选中 100%，其余降到 15% | 无（只改 `player.volume`） |
/// | `.mixed` | 全部出声，音量按路数均分 | 无（同样只改 `volume`） |
///
/// ⚠️ 关于 `.mixed` 的**诚实边界**：`AVPlayer.volume` 是**播放器级**音量，
/// 不是混音总线。多路各自把 `volume` 设为非零时，iOS 会不会真的同时输出，
/// 取决于 `AVAudioSession` 是否把它们都当成活跃播放器（多个 `AVPlayer` 共享
/// 一个会话时，系统通常只让最后起播的那一路输出）。所以 `.mixed` 的效果**必须在真机确认**；
/// 若不成立，正确做法是走 `MTAudioProcessingTap` 那条重链路，而不是在这里假装。
/// 这一点写进设置页的说明文字，不骗用户。
public enum DockAudioPolicy: String, CaseIterable, Sendable {
    /// 全部静音。坞照常播（画面、进度都在），但一点声音都不出。
    ///
    /// 为什么需要这一档：坞是常驻浮层，用户可能在开会/睡前挂着几个任务「先放着」，
    /// 这时既要它们继续播（回来能接上），又不想有任何声音。
    /// `.focused` 做不到这件事 —— 它总有一个在出声。
    case silent
    /// 只有选中的那个出声（默认）。
    case focused
    /// 选中 100%，其余 15% 背景音。
    case dimmed
    /// 全部出声，音量按路数均分。
    case mixed

    public static let key = "player.dockAudio"

    /// 从偏好读出，未设置时为 `.focused`。
    public static var current: DockAudioPolicy {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .focused }
        return DockAudioPolicy(rawValue: raw) ?? .focused
    }

    /// 非活跃那几路应该被压到多少音量（0…1）。`focused` / `silent` 直接静音。
    public var backgroundVolume: Float {
        switch self {
        case .silent, .focused: 0
        case .dimmed: 0.15
        case .mixed: mixedVolume(forTasks: PlaybackCapacity.dock)
        }
    }

    /// `.mixed` 时每一路的音量：路数越多越低，最小值 0.1 免得听不见。
    ///
    /// 用 `1 / n` 而不是固定值：两路各 100% 会直接削波（总和 200%），
    /// 均分才是「都能听见且不失真」的唯一直觉答案。
    public func mixedVolume(forTasks count: Int) -> Float {
        guard count > 0 else { return 1 }
        return max(0.1, min(1, 1 / Float(count)))
    }

    /// 坞里有 `count` 个任务时，第 `index` 个（是否活跃）该设的音量。
    ///
    /// 抽成纯函数是为了能被单元测试锁住 —— 音量算错只会表现为「声音不对」，
    /// 极难在评审里看出来。
    public func volume(isActive: Bool, taskIndex: Int, taskCount: Int) -> Float {
        if isActive {
            // 活跃那一路在 `.mixed` 下也要均分，否则总音量超标。
            return self == .mixed ? mixedVolume(forTasks: taskCount) : 1
        }
        switch self {
        case .silent: return 0
        case .focused: return 0
        case .dimmed: return 0.15
        case .mixed: return mixedVolume(forTasks: taskCount)
        }
    }

    /// 是否需要在切活跃卡片时改音量（`.focused` 只用 `isMuted`，不必动 volume）。
    public var adjustsVolume: Bool { self != .focused }
}

/// **单张卡片**自己的声音设定，覆盖全局档位。
///
/// 用户明确要求「在迷你播放器的窗口上可以单独小窗的声音设定」：
/// 坞里挂着三个任务时，他可能只想要其中一个大声、另一个完全静音、
/// 第三个跟着全局走。全局三档做不到这种逐卡控制。
///
/// 优先级是**具体压通用**：卡片上设过就听卡片的，没设过才看全局档位。
public enum DockTaskAudio: Hashable, Sendable {
    /// 这一张完全静音（不管全局是什么、也不管它是不是当前选中的那张）。
    case muted
    /// 这一张固定在这个音量（0…1）。
    case level(Float)
}

/// 一张卡片最终该怎么出声。
///
/// `isMuted` 与 `volume` 分开报，是因为两者在 `AVPlayer` 上语义不同：
/// 静音是确定生效的；音量在共享 `AVAudioSession` 的多路场景下不一定都能听见。
/// 只报一个数会让调用方无从表达「确定要静音」这件事。
public struct DockTaskOutput: Equatable, Sendable {
    public var isMuted: Bool
    public var volume: Float

    public init(isMuted: Bool, volume: Float) {
        self.isMuted = isMuted
        self.volume = volume
    }

    public static let muted = DockTaskOutput(isMuted: true, volume: 0)
}

extension DockAudioPolicy {
    /// 算出某一张卡片最终该出的声。
    ///
    /// - Parameters:
    ///   - isActive: 它是不是坞里当前选中的那一张。
    ///   - taskIndex / taskCount: 坞里的位置与总数（`.mixed` 按路数均分要用）。
    ///   - override: 这张卡片自己的设定；nil 表示跟随全局。
    ///
    /// 判定顺序（**具体压通用**）：
    ///   1. 卡片设了 `.muted` → 静音，哪怕它是当前选中那张、哪怕全局是「全部出声」；
    ///   2. 卡片设了 `.level(x)` → 就按 x 出声，同样不看全局、不看是否选中；
    ///   3. 没设过 → 按全局档位（`.silent` 时全静音）。
    ///
    /// 纯函数，便于单元测试 —— 这类「谁该出声」的规则一旦写错，
    /// 表现只是「声音不对」，代码评审很难看出来。
    public func output(isActive: Bool, taskIndex: Int, taskCount: Int,
                       override: DockTaskAudio?) -> DockTaskOutput {
        switch override {
        case .muted:
            return .muted
        case .level(let level):
            let clamped = min(max(level, 0), 1)
            // 拖到 0 等同于静音：留一个 volume=0 却 isMuted=false 的状态没有意义，
            // 而且会让人误以为它还在出声。
            return clamped <= 0.001 ? .muted : DockTaskOutput(isMuted: false, volume: clamped)
        case nil:
            break
        }
        if self == .silent { return .muted }
        // `.focused` 的非活跃那几路用 isMuted 表达，比 volume=0 更可靠。
        if self == .focused, !isActive { return .muted }
        return DockTaskOutput(isMuted: false,
                              volume: volume(isActive: isActive, taskIndex: taskIndex, taskCount: taskCount))
    }
}
