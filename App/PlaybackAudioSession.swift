import AVKit
import Foundation
import TVCore

/// 进程级音频会话的**引用计数**。
///
/// ## 为什么需要它（这是「多迷你播放器互顶」的头号成因）
/// ------------------------------------------------
/// `AVAudioSession.sharedInstance()` 是**整个 App 唯一一个**会话。上游（以及此前的二开）
/// 只考虑「同时最多一集在播」，所以 `PlaybackSession.stop()` 里直接写：
///
/// ```swift
/// try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
/// ```
///
/// 单任务时代这是对的：停掉唯一那一路，本来就该把音频焦点还给系统。
///
/// 多任务迷你播放器（`VideoTaskCenter`）上线后，同一时刻可能有好几路 `AVPlayer`
/// 共用这一个会话。此时上面那句的语义变成了**「把所有人的音频一起停掉」**：
///
///   · 用户按坞里某张卡片的 ✕ → 只该停那一路，结果**其余全哑**；
///   · 坞里超过上限触发 `trim()` 逐出最老的那个 → 同上；
///   · 长按同一个海报第二次（`VideoTaskCenter.add` 的去重分支会 `stop()` 掉
///     刚建出来的重复会话）→ 用户什么都没关，声音却全没了。
///
/// 而恢复它们的 `setActive(true)` 只在 `PlaybackSession.configure()`（即 `start()`）里跑，
/// 所以**坏掉之后不会自愈**，必须重新起播一次才能听见声音。
///
/// ## 做法
/// ----
/// 进出各登记一次，只在「最后一个参与者离开」时才真的 `setActive(false)`。
/// 这样「停掉其中一路」对别的路是完全无声的操作，与单任务时的行为一致。
///
/// ⚠️ 只按**活跃**计数，不按「会话对象存在」计数：一个已 `stop()` 但对象还没释放的
/// `PlaybackSession` 不该把会话撑在活跃态（那会让 App 退到后台后音频焦点还不还给别人）。
@MainActor enum PlaybackAudioSession {
    /// 正在参与音频会话的会话对象，弱引用 —— 一个会话被释放就等于离开。
    ///
    /// 用表而不是整数计数：整数一旦有某条路径漏了 `leave`（异常、提前 return、
    /// 对象被 dealloc）就会永久泄漏，之后**再也停不掉**音频会话。表可以按对象身份去重，
    /// 同一个对象重复 `enter` 不会多加一份，重复 `leave` 也不会多减一份。
    private static let members = NSHashTable<PlaybackSession>.weakObjects()

    /// 现在有几路真的在占用音频会话（活跃 + 已登记）。
    static var activeCount: Int { members.allObjects.filter(\.audioIsLive).count }

    /// 这一路开始要出声了。幂等。
    ///
    /// - Parameter session: 发起的那一路；为 nil 时只确保会话被激活（不分属谁）。
    static func enter(_ session: PlaybackSession?) {
        if let session { members.add(session) }
        #if !os(macOS)
        do {
            let shared = AVAudioSession.sharedInstance()
            if shared.category != .playback || shared.mode != .moviePlayback {
                try shared.setCategory(.playback, mode: .moviePlayback)
            }
            // 幂等：已经 active 时再调一次不会打断任何正在播的声音。
            try shared.setActive(true)
        } catch {
            Diagnostics.shared.failure("player", "audio session activate", error)
        }
        #endif
        session?.audioIsLive = true
    }

    /// 这一路停了。**只有最后一路离开时才真的停用会话。**
    static func leave(_ session: PlaybackSession?) {
        if let session {
            session.audioIsLive = false
            members.remove(session)
        }
        // 还有别人在播（或还在加载、马上要出声）：绝不能停用会话，
        // 否则那一路的画面还在、声音没了，而且不会自愈。
        //
        // 判据走 `PlaybackAudioSessionPolicy`（TVCore），那里有单元测试锁住 ——
        // 「只差一个 if」的错误在评审里极难看出来，必须靠测试。
        guard PlaybackAudioSessionPolicy.shouldDeactivate(liveCountAfterLeaving: activeCount) else { return }
        #if !os(macOS)
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { Diagnostics.shared.failure("player", "audio session deactivate", error) }
        #endif
    }
}
