import Foundation

// MARK: - 选集面板的尺寸档

/// 选集/线路面板的**尺寸档**：由「可用宽度」决定，不认机型、不碰方向枚举。
///
/// ⛔ 为什么需要它（2026-11-13 第 20 项）：
/// 面板此前只有一个布尔 `compact`（`playerLayout == .inline`），它描述的是
/// **播放器在页面里的位置**，不是**屏幕有多宽**。于是：
///   · 外屏 466pt 与内屏竖持 669pt 拿到同一个 `compact=false`；
///   · 内屏横持 951pt 也是 `false`；
///   · 但 951pt 上列宽 92 的网格会铺出 10 列、封面 108pt 显得很小，
///     线路 chip 横排挤在一行 —— 与外屏观感完全不同，用户看到的就是
///     「只有外屏做了款式，内屏没做」。
///
/// 这里按**内容宽度**分三档（外屏 / 内屏竖持 / 内屏横持与全屏），
/// 全部尺寸只从这一处取，面板内不再有裸字面量，各形态自然统一。
public enum PickerMetrics: Equatable {
    /// 面板外边距基准（与 App 层 `Spacing.panel` 同一个值；此处自带一份，
    /// 免得 TVCore 反向依赖 App 的 DesignSystem）。
    public static let panel: CGFloat = 28
    /// 封面色块圆角基准（与 App 层 `Radius.card` 同值）。
    public static let cardRadius: CGFloat = 12

    /// 外屏（≈430–480pt），也就是此前唯一被认真调过的那一档。
    case outer
    /// 内屏竖持（≈640–700pt）：比外屏宽，但仍是单列观感。
    case innerPortrait
    /// 内屏横持 / 全屏（≥820pt）：横向空间充裕，允许更宽的封面与更多列。
    case innerLandscape

    /// 由可用宽度选档。阈值刻意留出余量，避免旋转动画中途反复跳档。
    public static func forWidth(_ width: CGFloat) -> PickerMetrics {
        if width >= 820 { return .innerLandscape }
        if width >= 600 { return .innerPortrait }
        return .outer
    }

    /// 面板外边距。
    ///
    /// ⛔ 三档同样取 `PickerMetrics.panel`：横持时 ×1.4（39pt）会再吃掉一列的空间，
    /// 而 951pt 上 28pt 的边距已经足够，不需要「宽屏就留更宽的白」。
    public var panelPadding: CGFloat { PickerMetrics.panel }

    /// 区块之间的竖向间距。
    public var blockSpacing: CGFloat {
        switch self {
        case .outer: return PickerMetrics.panel
        case .innerPortrait: return PickerMetrics.panel * 1.2
        case .innerLandscape: return PickerMetrics.panel * 1.2
        }
    }

    /// 封面在网格单元里的显示尺寸（宽, 高）。
    ///
    /// 外屏沿用实测过的 108×162；内屏两档放大，否则在 951pt 宽上
    /// 一排十来个 108pt 封面会碎成「贴纸墙」，与 One 的观感不符。
    public var coverSize: (CGFloat, CGFloat) {
        switch self {
        case .outer: return (108, 162)
        case .innerPortrait: return (124, 186)
        case .innerLandscape: return (144, 216)
        }
    }

    /// 网格最小列宽。
    ///
    /// ⛔ 三档**都是 92**，这是刻意的，不是漏改。
    ///
    /// 这一格装的是集数文字（「第01集」），不是封面 —— 它最宽只需要约 65pt。
    /// 第一版按「宽屏就把格子放大」写了 92/108/128，真机后果是**列数倒退**：
    ///   951pt 可用 895pt，旧版（固定 92）排 9 列，放大到 128 后只剩 6 列，
    ///   格宽被撑到 135pt —— 一屏能看到的集数少了一半，而文字周围全是空白。
    /// 宽屏的正确形态是**放更多列**，不是把同一格撑大。
    ///
    /// 保持 92 后三种形态自然得到：外屏 4 列 / 竖持 6 列 / 横持 9 列，
    /// 格宽稳定在 92–101pt，与旧版一致（旧版这一维度本来就是对的）。
    public var gridMinColumn: CGFloat { 92 }

    /// 网格间距。
    public var gridSpacing: CGFloat {
        switch self {
        case .outer: return 8
        case .innerPortrait: return 10
        case .innerLandscape: return 12
        }
    }

    /// 封面圆角。
    public var coverRadius: CGFloat {
        switch self {
        case .outer, .innerPortrait: return PickerMetrics.cardRadius
        case .innerLandscape: return PickerMetrics.cardRadius * 1.15
        }
    }
}
