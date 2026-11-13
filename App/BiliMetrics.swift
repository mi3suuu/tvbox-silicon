// 导入留在**守卫外**：本文件是混合文件 —— 上半段（`BiliMetrics` / `BiliSettingsFocus`）
// 只在 iOS 存在，下半段（`BiliDanmakuSpeed` / `BiliDanmakuFilter`）被**跨平台**的
// `DanmakuView` 使用，必须在 tvOS / macOS 上也编译。
// 曾经的写法把 import 关进 `#if os(iOS)`，于是下半段在 tvOS 上没有任何导入，
// 24 个「cannot find type 'CGFloat' / 'CIFilter' / 'AVLayerVideoGravity'」全从这里来。
import SwiftUI
import AVFoundation
import CoreImage
import TVCore

#if os(iOS)

// MARK: - 哔哩哔哩实测设计常量（唯一来源）

/// 本文件所有数值都来自 **真机实测**，不是估的。
///
/// 采集方法：把 9.18.0 本体装进 vphone guest 跑起来，用 `vphoned` 的
/// `ui.tree` 读无障碍树的 `frame`（x / y / width / height，单位 pt）。
/// 四个态（竖屏详情 / 竖屏全屏 / 横屏展开 / 横屏全屏）各测一遍，
/// 三个弹出面板（操作菜单 / Speed+Timer 设置 / 右缘竖条设置）各测一遍。
///
/// ⚠️ 采样口径：竖屏 **466×678pt**、横屏 **678×466pt**，@3x。
/// 换机型或换系统版本必须重测，不要沿用。
enum BiliMetrics {

    // MARK: 顶栏（三态共用的部分）

    /// 返回键。竖屏与横屏**都是 54×44**，且 `x = 0`（贴左物理边缘，无 left inset）。
    static let backWidth: CGFloat = 54
    static let backHeight: CGFloat = 44
    /// 顶栏整体高 44pt，y 从 24 起（含状态栏留白）。
    static let topBarHeight: CGFloat = 44
    static let topBarTop: CGFloat = 24
    /// 全屏顶栏右侧并排按钮各 44×44（竖屏全屏实测 Like/Share/更多）。
    static let topButton: CGFloat = 44

    /// iPhone Duo 竖屏的前置摄像头避让区宽度。
    ///
    /// 实测（466 宽的竖屏播放器顶栏）：最右按钮 `More operations` 在 x=336、宽 46，
    /// 右边界 382；屏幕 466 → **右侧留 84pt 不给任何控件**。
    /// 底部行不避让（`Full screen` 右边界正好 466）。
    ///
    /// ⛔ 这个 84pt 是**外屏专属**的：它存在的前提是那块屏的右上角有摄像头挖孔。
    /// 内屏（669 / 951）**没有挖孔**，照搬会让顶栏右端凭空空出 84pt，
    /// 右上三个按钮整体左移 —— 这正是「展开后顶栏按钮位置错乱」的成因。
    /// 所以取值一律走 `cameraInset(forWidth:)`，不要直接用这个常量。
    static let duoCameraInset: CGFloat = 84

    /// 按屏宽给出摄像头避让宽度：只有外屏（≈466）需要，内屏返回 0。
    ///
    /// 阈值取 560：外屏 466 与内屏 669 之间，两边都留足余量，
    /// 不会因为旋转动画里的中间尺寸来回跳。
    static func cameraInset(forWidth width: CGFloat) -> CGFloat {
        width > 0 && width < 560 ? duoCameraInset : 0
    }

    /// 全屏顶栏标题的最大宽度。
    /// 实测竖屏全屏（466 宽）：title 占 `54,24 180×44`（x 54→234），Like 从 234 起。
    /// 不约束的话长标题会把右侧三个按钮挤出屏幕。
    ///
    /// 内屏要放宽：951 宽时再只给 180，标题会被截成「第一集…」而右边一大片空白。
    /// 按屏宽比例给，外屏 466×0.386≈180 保持实测值，内屏 951 得到约 367。
    static let fullscreenTitleFraction: CGFloat = 0.386
    static func fullscreenTitleMaxWidth(forWidth width: CGFloat) -> CGFloat {
        // 下限 180 = 外屏实测值；上限 420 避免长标题把右侧按钮挤掉。
        guard width > 0 else { return 180 }
        return min(max(width * fullscreenTitleFraction, 180), 420)
    }

    /// 竖屏详情页播放器高度（**外屏实测值**）。
    /// 实测：`Progress 0,250 466×22` → 播放器占 y 0~250，整宽 466。
    /// 屏宽 466 × 9/16 = 262 也接近，但以实测 250 为准（哔哩哔哩留了 12pt 黑边）。
    ///
    /// ⛔ 展开竖持（669 宽）不能再给 250：16:9 片源 `resizeAspect` 后只剩 444×250，
    /// 左右各留 112pt 黑边，观感是「小画 + 大黑框」。
    /// 一律走 `portraitHeight(width:aspectRatio:screenHeight:)`。
    static let portraitPlayerHeight: CGFloat = 250

    /// 按屏宽与片源比例算竖屏播放器高度。
    ///
    /// 外屏（<560）保持实测 250pt —— 那是哔哩哔哩在 466 宽上的真实版式，
    /// 按片源算反而会偏离实测。内屏按「整宽 + 片源比例」推导：
    /// 669×9/16 ≈ 376，画面撑满宽度，不再有大黑边。
    /// 上限 0.62 屏高，避免超宽片源把详情区挤没。
    /// 竖屏播放器高度 = **容器宽 ÷ 片源比例**，与二进制同比。
    ///
    /// ⚠️ 旧实现有 `guard width >= 560 else { return portraitPlayerHeight }`，
    /// 而 Duo 外屏宽只有 466 —— 于是**永远返回写死的 250pt，完全不看片源比例**。
    /// 实测（466×678，片源 16:9）：画面层被 AVPlayerLayer 按 16:9 撑到 262.3pt，
    /// 但容器只给 250pt → 画面与容器错位 12.3pt（底栏压在画面上、进度条位置偏移）。
    ///
    /// 二进制对应关系（`swift-section objc dump`）：
    ///   `BBPlayerRenderContainerWidget` 有 `double _ratio` 与
    ///   `-[... setViewRatio:]` / `-[... adjustVideoConstraints:]`，
    ///   即「比例是**数据**，宽高由它算」，不是写死常量。
    static func portraitHeight(width: CGFloat,
                               aspectRatio: CGFloat,
                               screenHeight: CGFloat) -> CGFloat {
        let ratio = (aspectRatio.isFinite && aspectRatio > 0.2 && aspectRatio < 6) ? aspectRatio : 16.0 / 9.0
        let fitted = width / ratio
        // 上限仍保留：竖屏画面最多占屏幕 62%，避免把详情挤没。
        let cap = screenHeight > 0 ? screenHeight * 0.62 : fitted
        return min(max(fitted, 180), cap)
    }

    // MARK: 竖屏详情页（466 宽）

    /// 进度条：**独立整宽元素**，466×22，贴在 tab 行之上。
    static let portraitProgressHeight: CGFloat = 22
    /// tab 行高 40（半屏是 36）。
    static let portraitTabHeight: CGFloat = 40
    /// 头像 54×54（半屏只有 26–30）。
    static let avatarSize: CGFloat = 54
    /// 互动五行：每个 88.3×40，5 个铺满 466（左右各 12 内缩）。
    static let actionWidth: CGFloat = 88.3
    static let actionHeight: CGFloat = 40
    static let pageInset: CGFloat = 12
    /// 标题行的「更多」是 16×16 图标，贴右缘 x=438。
    static let moreIcon: CGFloat = 16

    // MARK: 半屏 / 横屏展开（678 宽）

    /// tab 行高 36。
    static let halfTabHeight: CGFloat = 36
    /// 选集入口条：通栏、高约 16pt、三段式（系列名 | N/M | chevron）。
    static let seriesRowHeight: CGFloat = 26
    /// 横屏展开的选集面板：左侧 63.3% 是画面，右侧 36.7% 是面板。
    /// 实测边界 x=1288/2034 = 0.6333。
    static let landscapePanelFraction: CGFloat = 1 - 0.6333

    // MARK: 全屏

    /// 全屏底栏的三个文字按钮在右侧（Subtitles / Speed / Auto）。
    static let fullscreenBarButton: CGFloat = 44

    // MARK: 弹出层：操作菜单（两行按钮）

    /// 第一行 7 个，每个 **64×77**，步长 64。
    static let menuRow1Item = CGSize(width: 64, height: 77)
    /// 第二行 6 个，每个 **64×102**，步长 64。
    static let menuRow2Item = CGSize(width: 64, height: 102)
    /// 两行 y 间距 **81pt**（横屏 300.6→381.6、竖屏 295.1→376.1 一致）。
    static let menuRowGap: CGFloat = 81
    /// 横屏时菜单整块从 x≈262 起（贴右半屏）。
    static let menuLandscapeOriginX: CGFloat = 262
    /// 竖屏时菜单从 x≈26 起（几乎整宽）。
    static let menuPortraitOriginX: CGFloat = 26

    // MARK: 弹出层：Speed / Timer（竖屏设置）

    /// 竖屏设置里的 Speed chip：**62×51**，步长 62.5。
    static let speedChipLarge = CGSize(width: 62, height: 51)
    /// 竖屏操作菜单里的 Speed chip：**57×21**，步长 57.5。
    static let speedChipSmall = CGSize(width: 57, height: 21)
    /// Timer chip：**86.8×51**，步长 87.3。
    static let timerChip = CGSize(width: 86.8, height: 51)
    /// 分区标题高 17，左 16。
    static let sectionTitleHeight: CGFloat = 17
    static let sectionInset: CGFloat = 16
    /// 开关本体 40.9×18.2，贴右 x=392。
    static let switchSize = CGSize(width: 40.9, height: 18.2)
    /// 开关行的文字左内缩 60（比分区标题多 44）。
    static let switchTextInset: CGFloat = 60

    /// 竖屏全屏设置面板：实测整宽可点行 434x52，左右各 16pt（434 = 466 - 32）。
    static let sheetRowWidth: CGFloat = 434
    static let sheetRowHeight: CGFloat = 52

    // MARK: 弹出层：右缘竖条设置（横屏全屏）

    /// 竖条左边界 x=615，屏宽 678 → 可视宽 63pt。
    /// 但无障碍报的内容固有宽会右溢到 757/935，**不要按那个建布局**。
    static let railInsetX: CGFloat = 615
    static let railTextInset: CGFloat = 659
    /// 竖条里的 See Original 大按钮 85×102。
    static let railHeroButton = CGSize(width: 85, height: 102)
    /// 底部 Aspect Ratio 行 320×51（内容宽，实际被裁）。
    static let railFooterHeight: CGFloat = 51

    // MARK: 选集列表（三态共用行高）

    /// 单集行距：竖屏内联 **100.3pt**、半屏面板 ≈100pt，取 100。
    static let episodeRow: CGFloat = 100
    /// 竖屏缩略图约 130×73（标题从 x=155 起，故缩略图 x=12 宽约 130）。
    static let portraitThumb = CGSize(width: 130, height: 73)
    /// 半屏抽屉缩略图 62×40（第 9 节实测）。
    static let drawerThumb = CGSize(width: 62, height: 40)
    /// 竖屏标题**单行截断**（高 20）；半屏**两行**。
    /// 实测（竖屏展开态，44 元素）：标题占两行、高 40（`155,333 299x40`）。
    /// 之前写 1 行是错的 —— 那 20 高是**收起后**残留，展开后是 2 行。
    static let portraitTitleLines = 2
    /// 展开态标题行高度（两行合计）。
    static let portraitTitleHeight: CGFloat = 40
    static let drawerTitleLines = 2
    /// 每行「更多」16×16（竖屏特有）。
    static let rowMoreIcon: CGFloat = 16

    // MARK: 播放模式（四态，来自 Assets.car 图标名）

    /// `bbhd2_playmodesetting_actionloop / actionnextloop / actionnext / actionquit`
    /// 四个图标都是 132×132 @3x = **44pt**。
    static let playModeIcon: CGFloat = 44
}

// MARK: - 播放模式（四态，不是三态）

/// 哔哩哔哩的播放模式是**四态**，证据是 `Assets.car` 里四个并列图标：
/// `actionloop`（单集循环）/ `actionnextloop`（列表循环）/ `actionnext`（自动连播）
/// / `actionquit`（播完停止）。
///
/// 此前做成三档（漏了 quit）是错的。
enum BiliPlayMode: String, CaseIterable, Identifiable {
    case loop      // 单集循环
    case nextLoop  // 列表循环
    case next      // 自动连播
    case quit      // 播完停止

    var id: String { rawValue }

    /// 图标名，与 `Assets.car` 里的资产一一对应。
    var assetName: String {
        switch self {
        case .loop:     return "bbhd2_playmodesetting_actionloop"
        case .nextLoop: return "bbhd2_playmodesetting_actionnextloop"
        case .next:     return "bbhd2_playmodesetting_actionnext"
        case .quit:     return "bbhd2_playmodesetting_actionquit"
        }
    }

    var title: String {
        switch self {
        case .loop:     return L10n.text("Single Loop")
        case .nextLoop: return L10n.text("List Loop")
        case .next:     return L10n.text("Auto-Play Next")
        case .quit:     return L10n.text("Play Once")
        }
    }

    var detail: String {
        switch self {
        case .loop:     return L10n.text("Plays this episode again.")
        case .nextLoop: return L10n.text("Goes on to the next episode.")
        case .next:     return L10n.text("Keeps going through the list.")
        case .quit:     return L10n.text("Stops at the end of this episode.")
        }
    }

    /// 落回仅有的两个真实状态。`loop` 与 `quit` 都关掉连播，差别只在单集循环。
    var loopsCurrent: Bool { self == .loop }
    var autoAdvances: Bool { self == .nextLoop || self == .next }

    /// 从两个布尔反推当前档位（用于初始化）。
    static func from(loops: Bool, advances: Bool) -> BiliPlayMode {
        if loops { return .loop }
        return advances ? .next : .quit
    }
}

// MARK: - 面板形态

/// 哔哩哔哩有**三个互不相同**的弹出面板，实测它们的条目集都不一样：
///
/// | 面板 | 触发 | 形态 |
/// |---|---|---|
/// | `actionMenu` | 详情页 More operations | 两行横向按钮 |
/// | `settings` | 竖屏全屏齿轮 | 底部覆盖（Speed/Timer/开关） |
/// | `rail` | 横屏全屏三点 | 右缘竖条 |
///
/// 此前把它们当成一个面板是错的 —— 这是「更多」与「设置」风格不同的原因。
/// 设置面板里的分区。实测底栏三个文字按钮打开的是**同一个**面板，
/// 区别只在滚到哪一节 —— 所以需要这个用于定位落点。
enum BiliSettingsFocus: String {
    case speed
    case subtitles
    case quality
    case timer
    /// 全屏底栏的 `Episodes` 也落到同一个面板的这一段。
    case episodes
    /// 画面比例（二进制实证 5 种）。
    case aspect
    /// 色彩滤镜（二进制实证 `color_filter`）。
    case colorFilter
    /// 菜单项自定义（二进制实证 `optionsedit`）。
    case menuEditor
}

enum BiliPanel: String, Identifiable {
    case actionMenu
    case settings
    case rail
    /// 选集。**之前漏了这个分支** —— `biliShowEpisodes` 只写不读，
    /// 全屏与横屏的选集按钮点了完全没反应（静默失效）。
    case episodes
    /// 设置面板里四个整宽可点行各自的子面板（之前是空回调，点了没反应）。
    case subtitleSettings
    case danmuSettings
    case moreSettings
    case notes
    var id: String { rawValue }
}
#endif
// MARK: - 全屏底部弹窗（以「画质」框为基准款式）
//
// 用户指定：全屏底栏 Subtitles / Episodes / Speed / Auto 四个按钮，
// **统一套用画质弹出框的款式**。
//
// 实测（竖屏 466×678，OCR 归一化）：
//   Resolution          0.594, 0.034   → y≈403, x≈16
//   Advanced Settings   0.596, 0.706   → y≈404, x≈329（右对齐）
//   Auto (720P HD)      0.667, 0.065   → y≈452, x≈30
//   720P HD             0.759, 0.065   → y≈515
//   480P SD             0.848, 0.065   → y≈575
//   360P Smooth         0.940, 0.065   → y≈637
//
// 横屏（678×466）：
//   Resolution 454,98 · Advanced Settings 541.7,98
//   Auto 454,130 · 720P 454,192 · 480P 454,254 · 360P 454,316   均 208×54
//
// → 行距竖屏 ≈61、横屏 62；横屏宽 208、贴右缘；竖屏整宽、上沿 59.4%。
enum BiliPopupMetrics {
    /// 竖屏上沿占屏高的比例（实测 0.594）。
    static let portraitTopFraction: CGFloat = 0.594
    /// 横屏面板宽度（实测 454→662 = 208）。
    static let landscapeWidth: CGFloat = 208
    /// 选项行高（竖屏 61 / 横屏 62，取 61）。
    static let rowHeight: CGFloat = 61
    /// 选项左侧缩进（实测 x≈30，相对面板左缘 14）。
    static let rowInset: CGFloat = 14

    /// 竖屏全屏底栏高度（BBPlayerPortraitScreenBottomWidget 的实测高度）。
    /// 时间/播放/弹幕/画质 全部按这个高度做相对定位。
    static let portraitBottomBarHeight: CGFloat = 200
    /// 标题行高度。
    static let headerHeight: CGFloat = 48
}

// MARK: - 画面比例（二进制实证：哔哩哔哩有 5 种）
//
// 来源：`哔哩哔哩_9.18.0` 主二进制 `strings -a` 提取的
// `bbplayer_playersetting_*` 标识：
//
//   ratio16_9           16:9
//   ratio4_3            4:3
//   ratioadjustcontent  适应内容（跟随片源，等同原先的 Fit）
//   ratioadjustscreen   适应屏幕（拉伸铺满，等同原先的 Fill）
//   ratiocentercrop     居中裁剪
//
// 我们之前只有一个 Fit/Fill 布尔开关，缺 4 种。
enum BiliAspectMode: String, CaseIterable, Identifiable {
    case ratio16x9
    case ratio4x3
    case adjustContent
    case adjustScreen
    case centerCrop

    var id: String { rawValue }

    /// UserDefaults 键名。**必须与 `OneSkin.fitModeKey` 同值**（"oneSkinFitMode"）。
    ///
    /// 为什么在这里再写一份：`OneSkin` 属 OneSkin 文件簇（整体只在 iOS 编译），
    /// 而 `biliAspectMode` 这个 `@State` 在 tvOS 也要存在，其初始化器不能引用 OneSkin。
    /// 收口到本枚举后，两处引用同一常量，改键名只需改这一处。
    static let storageKey = "oneSkinFitMode"

    /// 落盘用的键值（复用 `OneSkin.fitModeKey`，扩展取值）。
    var stored: String { rawValue }

    var label: String {
        switch self {
        case .ratio16x9:        return "16:9"
        case .ratio4x3:         return "4:3"
        case .adjustContent:    return "Adjust to Content"
        case .adjustScreen:     return "Adjust to Screen"
        case .centerCrop:       return "Center Crop"
        }
    }

    /// 该模式对应的视频 gravity。
    ///
    /// ⚠️ 旧实现把 `.adjustScreen` 与 `.centerCrop` 都映射成 `.resizeAspectFill`，
    /// 两者**完全无法区分** —— 用户切到其中之一没有任何视觉变化。
    ///
    /// 按二进制语义（`bbplayer_playersetting_ratioadjustscreen` vs `ratiocentercrop`，
    /// 是 `_videoContentMode` 的两个不同枚举值）拆分：
    ///   · `adjustScreen`  铺满容器（可能变形）→ `.resize`（宽高各自撑满）
    ///   · `centerCrop`    等比放大到铺满、超出裁掉 → `.resizeAspectFill`
    /// 固定比例 16:9 / 4:3 与 `adjustContent` 都是等比完整显示 → `.resizeAspect`
    var gravity: AVLayerVideoGravity {
        switch self {
        case .ratio16x9, .ratio4x3, .adjustContent: return .resizeAspect
        case .adjustScreen:                          return .resize
        case .centerCrop:                            return .resizeAspectFill
        }
    }

    /// 固定比例模式的宽高比；`.adjustContent` / `.adjustScreen` / `.centerCrop` 返回 nil（跟随片源）。
    var fixedAspect: CGFloat? {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3:  return 4.0 / 3.0
        default:         return nil
        }
    }

    /// 画面容器应采用的宽高比。
    ///
    /// 固定比例模式返回写死的 16:9 / 4:3；其余三种跟随片源。
    /// ⚠️ 这个属性此前**定义了却无人使用** —— 于是用户选「16:9」「4:3」
    /// 时容器尺寸不动，看图像什么也没发生。现在三个页面统一走它。
    static func effectiveAspect(sourceRatio: CGFloat, mode: BiliAspectMode? = nil) -> CGFloat {
        let m = mode ?? current
        if let fixed = m.fixedAspect { return fixed }
        let r = sourceRatio
        return (r.isFinite && r > 0.2 && r < 6) ? r : 16.0 / 9.0
    }

    /// 当前生效的模式（直接读 `UserDefaults`，供三个页面共用，
    /// 避免每页各存一份 @State 导致不同步）。
    static var current: BiliAspectMode {
        // 用本枚举的 storageKey（与 OneSkin.fitModeKey 同值）；OneSkin 只在 iOS 编译。
        fromStored(UserDefaults.standard.string(forKey: storageKey))
    }

    static func fromStored(_ v: String?) -> BiliAspectMode {
        guard let v else { return .adjustContent }
        // 兼容旧值："fit" → 适应内容，"fill" → 适应屏幕
        if v == "fit" { return .adjustContent }
        if v == "fill" { return .adjustScreen }
        return BiliAspectMode(rawValue: v) ?? .adjustContent
    }
}

// MARK: - 色彩滤镜（二进制实证存在，之前整项缺失）
//
// 来源：`bbplayer_playersetting_color_filter` 标识 + Objective-C 方法
// `-[BFCPlayerControllerV2 setColorFilterType:]`（`setColorFilterType:%ld`，
// 说明是整型枚举）。具体取值不在字符串表里，所以这里只实现**可确定语义**的几种，
// 全部通过 `CALayer.filters` 的私有 `CAFilter` 组合实现 —— 不引入第三方依赖。
enum BiliColorFilter: String, CaseIterable, Identifiable {
    case none
    case vivid       // 鲜艳：提高饱和度
    case soft        // 柔和：降对比、提亮
    case warm        // 暖色
    case cool        // 冷色
    case mono        // 黑白

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:  return "Original"
        case .vivid: return "Vivid"
        case .soft:  return "Soft"
        case .warm:  return "Warm"
        case .cool:  return "Cool"
        case .mono:  return "Mono"
        }
    }

    /// 给 `AVPlayerLayer` 装配的 Core Animation 滤镜数组。
    /// 返回空数组表示不做任何处理。
    func caFilters() -> [Any] {
        switch self {
        case .none:
            return []
        case .vivid:
            return Self.saturation(1.45)
        case .soft:
            return Self.saturation(0.85) + Self.brightness(0.06)
        case .warm:
            return Self.colorMatrix(red: 1.08, green: 1.0, blue: 0.92)
        case .cool:
            return Self.colorMatrix(red: 0.92, green: 1.0, blue: 1.10)
        case .mono:
            return Self.saturation(0)
        }
    }

    private static func saturation(_ v: Double) -> [Any] {
        guard let f = CIFilter(name: "CIColorControls") else { return [] }
        f.setValue(v, forKey: kCIInputSaturationKey)
        return [f]
    }

    private static func brightness(_ v: Double) -> [Any] {
        guard let f = CIFilter(name: "CIColorControls") else { return [] }
        f.setValue(v, forKey: kCIInputBrightnessKey)
        return [f]
    }

    /// 简单的通道增益矩阵（不做色域转换，纯视觉微调）。
    private static func colorMatrix(red: Double, green: Double, blue: Double) -> [Any] {
        guard let f = CIFilter(name: "CIColorMatrix") else { return [] }
        f.setValue(CIVector(x: CGFloat(red), y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: CGFloat(green), z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: CGFloat(blue), w: 0), forKey: "inputBVector")
        return [f]
    }

    static var current: BiliColorFilter {
        BiliColorFilter(rawValue: UserDefaults.standard.string(forKey: "biliColorFilter") ?? "") ?? .none
    }
}

// MARK: - 弹幕扩展设置（二进制实证）
//
// 来源：`strings -a bili-universal` 命中
//   danmaku_speed        弹幕速度
//   danmaku_opacity      透明度（已有）
//   danmaku_area         显示区域（已有）
//   danmaku_filter       屏蔽词
//   danmaku_block_switch 屏蔽开关
//   danmaku_block_sync_rotation  跟随旋转
//
// 我们已有：开关 / 区域 / 字号 / 透明度。
// 缺：**速度**、**屏蔽词**。这里补齐。

/// 弹幕滚动速度（对应 `danmaku_speed`）。
/// `DanmakuLayout` 的 `scrollDuration` 是「一条弹幕横穿屏幕所需秒数」，
/// 越小越快 —— 与 B 站「慢/中/快」语义相反，所以这里显式换算。
enum BiliDanmakuSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slow:   return "Slow"
        case .normal: return "Normal"
        case .fast:   return "Fast"
        }
    }

    /// 横穿秒数。基准 9 秒（`DanmakuLayout` 默认值）。
    var scrollDuration: Double {
        switch self {
        case .slow:   return 13
        case .normal: return 9
        case .fast:   return 6
        }
    }

    static let key = "biliDanmakuSpeed"

    static var current: BiliDanmakuSpeed {
        BiliDanmakuSpeed(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .normal
    }
}

/// 弹幕屏蔽词（对应 `danmaku_filter` + `danmaku_block_switch`）。
/// 支持**普通词**与 `/正则/` 两种写法；空列表 = 不屏蔽。
enum BiliDanmakuFilter {
    static let wordsKey = "biliDanmakuBlockWords"

    /// 当前屏蔽词（逗号或换行分隔）。
    static var words: [String] {
        let raw = UserDefaults.standard.string(forKey: wordsKey) ?? ""
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func setWords(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: wordsKey)
    }

    /// 一条弹幕是否被屏蔽。
    static func isBlocked(_ text: String) -> Bool {
        let list = words
        guard !list.isEmpty else { return false }
        for w in list {
            // `/pattern/` 走正则，其余走包含匹配
            if w.count > 2, w.hasPrefix("/"), w.hasSuffix("/") {
                let pattern = String(w.dropFirst().dropLast())
                if let re = try? NSRegularExpression(pattern: pattern),
                   re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    return true
                }
            } else if text.localizedCaseInsensitiveContains(w) {
                return true
            }
        }
        return false
    }
}
