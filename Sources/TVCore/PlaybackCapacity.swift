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
/// | 解密流（CENC，含红果） | **4** | `CENCStreams.swift` `CENCStreamStore.add` |
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
    /// ## 2026-11-16：4 → 8，但**只有「在播」的才真解码**
    ///
    /// 原来写 4 的理由是「每个任务都是一路独立 `AVPlayer` + 一条已建立的流，
    /// 五六个之后解码与网络互相抢带宽」。那个理由对**同时解码**成立，
    /// 但它错在把「坞里有几个卡片」和「有几个在解码」当成同一件事。
    ///
    /// 用户报「只能播四个」——他要的是「能挂着七八部剧随手切」，不是
    /// 「八个同时解码」。这两件事必须分开：
    ///   · **卡片数**（收藏夹式的存在）：放宽到 8，用户能挂住自己的观看队列；
    ///   · **同时解码**：仍只允许 `decoding` 个，其余暂停（`DockDecodingBudget`）。
    ///
    /// 暂停的那几个不占解码器、不占带宽，只保留已缓冲的一小段 —— 切过去再起播。
    /// 内存代价只在**真正在播**的那几路上，与改动前同量级。
    ///
    /// ## 2026-11-17：8 → 20（用户要「10 个 20 个迷你小窗一起挂」）
    ///
    /// 卡片数涨到 20 之后，**同时解码**绝不能跟着涨到 20 —— 那不是一个数字取舍，
    /// 是硬件的墙：iOS 同时能开的视频解码会话有上限，超了不是变慢，而是
    /// **有些窗永远黑屏**（`AVPlayerItem` 起播后没有可用解码器）。
    ///
    /// 所以两件事分开（与 2026-11-16 那次同一个思路，只是这次到 20）：
    ///   · **卡片**（挂着的观看队列）= 20；
    ///   · **同时解码** = `decoding`（按机型 4–8，见下），其余**挂起**：
    ///     `rate = 0` + 画面层让出 `AVPlayer`（`DockPlayerLayer`），卡片下露出海报。
    ///
    /// 挂起的那几个**看起来仍是一部剧**（海报 + 「已挂起」角标），点一下立刻回到预算内
    /// 并自动续播 —— 而不是给用户 12 块黑玻璃。
    public static let dock = 20

    /// 同时**解码**的上限。
    ///
    /// ## 2026-11-16：用户明确要求「就要同时解码」，改为等于卡片上限
    ///
    /// 上一版给的是 4（按「解码 + 网络开始互相抢」的经验拐点），代价是挂 8 部时
    /// 第 5–8 路被暂停，切过去要现场起播（约一秒缓冲）。用户不接受这个取舍。
    ///
    /// 于是取消挂起：**卡片上限即解码上限**。
    ///
    /// ⚠️ 这次不是「把数字改大就完事」，配套做了两件事，否则 8 路会一起卡：
    ///   1. **小窗限制解码分辨率**（`DockDecodeResolution`）。坞卡片只有 120–320pt 宽，
    ///      以前却让 AVPlayer 按源分辨率全解（1080p / 4K），8 路一起解必爆。
    ///      按卡片实际宽度取档之后，单路解码量降到约 1/6。
    ///   2. **流槽位仍按 2 倍余量**（`streamSlots`），换集时新旧两路短暂并存不会被踢。
    ///
    /// 若真机上仍出现整片卡顿，先看 `DockDecode` 探针里每路的实际解码档，
    /// 再考虑下调本值 —— 而不是直接改回去，那会让第 5–8 路又变成「点了要等」。
    ///
    /// ## 2026-11-17：不再等于 `dock`，改为按机型分档
    ///
    /// 卡片涨到 20 之后「解码 = 卡片」不成立：**iOS 的视频解码会话数有硬上限**，
    /// 20 路同时解必然有一部分拿不到解码器（表现就是黑屏，且不会自愈）。
    /// 这个上限不公开、随机型与分辨率变化，所以这里按**设备内存**给一个保守档位，
    /// 并且仍然遵守「最近点的那一路优先解码」。
    ///
    /// ⛔ 分档的判据只能是「能不能真的跑起来」，不能是「用户希望多少路」——
    ///    20 路里的第 9 个不是被我们拒绝，是被系统拒绝，硬上只会得到黑屏。
    public static var decoding: Int { decodingBudget(cards: dock, memoryBytes: ProcessInfo.processInfo.physicalMemory) }

    /// 给定「要挂几张卡」与「设备有多少内存」，同时解码几路。
    ///
    /// 纯函数，供测试直接钉住；也供以后按实际失败率下调（`dock > decoding` 是正常形态）。
    ///
    /// 档位依据：实测 6 GB 机型 8 路（480p 档）能同时跑；4 GB 机型 6 路开始互相抢；
    /// 3 GB 机型 4 路是安全线。卡片本身不占解码器，所以**卡片数不参与**这个判定。
    public static func decodingBudget(cards: Int, memoryBytes: UInt64) -> Int {
        let gb = Double(memoryBytes) / Double(1 << 30)
        let ceiling: Int
        if gb <= 3.5 { ceiling = 4 }
        else if gb <= 4.5 { ceiling = 6 }
        else { ceiling = 8 }
        return max(1, min(cards, ceiling))
    }

    /// 前台那一集（观看页 / 全屏播放器）。iOS 的呈现现实：前台只能有一个。
    public static let foreground = 1

    /// 一路播放可能同时占用**不止一个**流槽位：
    /// 云盘直链会先登记一条 `tvbox-cloud` 流，若判定为 MKV 还要再开一个转封装会话；
    /// 换集时新旧两条会短暂并存（`upcoming` 预取 + 正在播的那一集）。
    /// 所以给每一路留 2 个槽位，再算上换集时的重叠。
    public static let streamsPerTask = 2

    /// 底层流存储（云盘 / 转封装 / DASH 清单 / 红果）应持有的槽位数。
    ///
    /// = (坞 + 前台) × 每路 2 个槽位 = 42（坞 20 之后）。
    ///
    /// ⚠️ **内存影响必须写清楚**：槽位只决定「谁会被逐出」，**不决定缓存上限**。
    /// 缓存由 `CloudBufferPlan` 按设备预算算，`budget=320 MB` 时单路理论上能吃到 160 个
    /// 2 MB 块 —— 20 路照着这个上限跑就是 6 GB，必然被系统杀掉。
    /// 所以 2026-11-17 起 `CloudBufferPlan` 的预算要**按当前存活的云流数均分**
    /// （`CloudStreamStore.count`），槽位多不等于内存多。
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
