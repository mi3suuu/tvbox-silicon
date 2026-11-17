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
}
