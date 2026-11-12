import Foundation

/// 同时能播多少路 —— **全项目唯一的并发预算常量**。
///
/// ## 为什么必须集中到一个地方
/// ------------------------
/// 「多任务迷你播放器」上线时，坞（`VideoTaskCenter`）的上限定成 4，但那只是
/// **坞里**的卡片数量。真正被占用的是底下每一路播放各自的**流资源**：
///
/// | 资源 | 原容量 | 位置 |
/// |---|---|---|
/// | 坞里卡片 | 4 | `App/VideoTasks.swift` `VideoTaskCenter.capacity` |
/// | 云盘字节流 | **3** | `CloudStreams.swift` `CloudStreamStore.add` |
/// | 转封装会话（MKV/AVI…） | **3** | `Remux.swift` `RemuxStore.add` |
/// | DASH 生成清单 | **4** | `DashStreams.swift` `PlaylistStore.add` |
/// | 红果解密流 | **4** | `HongguoStreams.swift` `HongguoStreamStore.add` |
///
/// 四张表里没有一个引用坞的上限，全是各自文件里的字面量。于是「坞 4 个 + 前台 1 个 = 5」
/// 必然超过「流按 3 个逐出」—— 而逐出策略是**淘汰最老的**（`order.removeFirst()`），
/// 淘汰动作是**直接 `clear()` / `close()`**，没有任何回滚。
///
/// 用户看到的现象因此非常固定，也正是他报的「互顶」：
///   · **先开的那个**黑屏/无声，后开的完好（FIFO 淘汰最早的那个）；
///   · 只在坞里 ≥2 个任务时出现，单任务永不出现（容量 3、4 都大于 1）；
///   · 坏掉的那个无法自愈，必须重新点海报起播（token 已从 Store 删掉，
///     `PlaylistLoader` 只会回一句 “This playback has expired”）。
///
/// 集中到这里之后，容量只有一处需要改，也不可能再出现「坞涨了、流没涨」。
public enum PlaybackCapacity {

    /// 坞里同时能挂几个迷你播放器。
    ///
    /// 不是随手设的上限：每个任务都是一路独立 `AVPlayer` + 一条已建立的流，五六个之后
    /// 解码与网络就开始互相抢带宽（本项目源多为单线程 HLS），画面会一起卡。
    /// 四个既能兑现「同时多个」的诉求，又不至于把播放全部拖死。
    public static let dock = 4

    /// 前台那一集（观看页 / 全屏播放器）。iOS 的呈现现实：前台只能有一个。
    public static let foreground = 1

    /// 一路播放可能同时占用**不止一个**流槽位：
    /// 云盘直链会先登记一条 `tvbox-cloud` 流，若判定为 MKV 还要再开一个转封装会话；
    /// 换集时新旧两条会短暂并存（`upcoming` 预取 + 正在播的那一集）。
    /// 所以给每一路留 2 个槽位，再算上换集时的重叠。
    public static let streamsPerTask = 2

    /// 底层流存储（云盘 / 转封装 / DASH 清单 / 红果）应持有的槽位数。
    ///
    /// = (坞 + 前台) × 每路 2 个槽位 = 10。
    ///
    /// ⚠️ **内存影响必须写清楚**：`CloudByteStream` 每路最多缓存
    /// `cacheChunks × chunkSize` = 24 × 2 MB = 48 MB。10 个槽位是理论上限，
    /// 实际并发只会有「坞里真正在播的那几个」（用户上限 4）+ 前台 1 + 换集重叠 1~2 个。
    /// 空槽位（已停止但未逐出的）不再持有缓存 —— `stop()` 会 `clear()` 掉。
    /// 因此稳态内存与改动前同量级，只是不再「一超过 3 路就把正在播的那一路踢掉」。
    public static let streamSlots = (dock + foreground) * streamsPerTask

    /// 把某个存储的 `while order.count > limit` 上限统一取这里。
    /// 留成函数而不是让各处直接读 `streamSlots`，是为了将来若要按平台分档只改一处。
    public static var streamLimit: Int { streamSlots }
}

/// 进程级音频会话的进退场判定。
///
/// ## 为什么需要一个纯函数
/// --------------------
/// `AVAudioSession` 是**进程级单例**，整个 App 只有一个。上游只考虑「同时最多一集在播」，
/// 所以 `PlaybackSession.stop()` 里直接 `setActive(false)` —— 单任务时代完全正确。
///
/// 多任务迷你播放器上线后，同一时刻有好几路 `AVPlayer` 共用它。此时那句话的语义变成了
/// **「把所有人的音频一起停掉」**：
///
///   · 用户按坞里某张卡片的 ✕ → 只该停那一路，结果其余全哑；
///   · 坞里超出上限触发 `trim()` 逐出最老的那个 → 同上；
///   · 长按同一个海报第二次（去重分支会 `stop()` 掉刚建出来的重复会话）→
///     用户什么都没关，声音却全没了。
///
/// 恢复它们的 `setActive(true)` 只在 `start()` 里跑，所以**坏掉之后不会自愈**。
///
/// 判定逻辑抽在这里（而不是只写在 App 层的 `PlaybackAudioSession` 里），
/// 是为了它能被单元测试锁住 —— 这类「只差一个 if」的错误在代码评审里极难看出来。
public enum PlaybackAudioSessionPolicy {

    /// 某一路停下之后，**是否应该真的把进程音频会话停用**。
    ///
    /// - Parameter liveCountAfterLeaving: 它离开之后，还有几路在占用会话。
    /// - Returns: `true` 表示这时可以 `setActive(false)`。
    ///
    /// 只有一个正确答案：**还有别人在播时，绝不能停用**。
    public static func shouldDeactivate(liveCountAfterLeaving: Int) -> Bool {
        liveCountAfterLeaving <= 0
    }

    /// 登记一次进出之后，这一路是否算「占用中」。
    ///
    /// `enter` 幂等、`leave` 幂等，所以同一个会话重复进出不会把计数算错。
    public static func isOccupying(afterEntering entered: Bool, liveElsewhere: Bool) -> Bool {
        entered || liveElsewhere
    }
}
