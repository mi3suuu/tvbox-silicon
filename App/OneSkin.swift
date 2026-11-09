import SwiftUI
import AVFoundation
import QuartzCore
import TVCore

// MARK: - One 皮肤（独立层，不改动上游任何文件）

/// [mi3s] 二开：One 风格的观看页皮肤。
///
/// 与上游 `VideoDetailView` 完全并存 —— 上游原版一行未改，这里只提供一套可开关的外观。
/// 开关落在 `UserDefaults`，跨页面、跨启动都记得；关掉就回到上游原样。
///
/// 外观数值取自 One 1.7.0 的实机截图（1398×2034，3× 屏）折算成 pt：
/// 底色 #080808、卡片 #181010、主文字 #F8F8F8、左内边距 16pt、播放键直径 62pt、
/// 主按钮高 50pt / 圆角 13pt、控件胶囊高 33pt。
enum OneSkin {

    /// 开关本体。`@AppStorage` 直连，任何页面读写都是同一份值。
    static let enabledKey = "oneSkinEnabled"

    /// 控制条上三个开关，同样是界面级偏好。
    static let speedKey = "oneSkinSpeed"
    static let loopKey = "oneSkinLoop"
    static let fillKey = "oneSkinFill"
    /// 画面填充模式（适应/填充/铺满/拉伸）。旧 `fillKey` 布尔仍兼容读取。
    static let fitModeKey = "oneSkinFitMode"

    /// 双列 / 合拢开关。One 用的是 `@AppStorage("one.actor.twoColumn", store: UserDefaults)`
    /// 的 Bool —— 即这是**用户手动切换并持久化的偏好**，不按屏幕尺寸自动判断。
    /// 出处：`sub_10001cda0` 里 `AppStorage(wrappedValue:store:)` 构造 + 字符串 "one.actor.twoColumn"。
    static let twoColumnKey = "oneSkinTwoColumn"

    /// 真实 key window 尺寸。
    ///
    /// 2026-11-08 修正：**用 `window.bounds`，不用 `screen.bounds` + interfaceOrientation 换算**。
    /// 那套换算的前提是「screen.bounds 恒为竖屏原生值」，在 Fig-clone 上不成立：
    /// 实测 screen.bounds 报 466×678（已是竖屏逻辑值），再按 interfaceOrientation
    /// 做 max/min 交换，横屏下反而算成 466 宽 × 678 高 —— 横竖直接反了，
    /// 布局走进竖屏分支，画面窗口被摆到顶部（实测 y160 vs One 的 y357）。
    ///
    /// `window.bounds` 是 UIKit 已按当前方向摆好的坐标系，横屏时 width>height，
    /// 不需要任何换算。旋转动画中间态由 `stage` 的尺寸闸门吸收（<200 丢弃）。
    /// 屏幕的**逻辑尺寸**（pt）。
    ///
    /// 用所有 window 里面积最大的那个（排除键盘/浮层之类的小窗）。
    /// 虽然 VM 上它报 951×669（比截图口径 678×466 大 1.40 倍），
    /// 但布局的自洽性依赖于「同一个来源」——混用不同来源会让
    /// 列宽基准与渲染坐标打架（试过 nativeBounds / UIScreen.bounds / 硬编码常量，
    /// 三者都会把双列布局打散成 45 个元素、窗口跑到 x1879）。
    /// 设备当前是否横屏。以 `UIWindowScene.interfaceOrientation` 为准 ——
    /// window bounds 在虚拟设备上可能给出旋转前的尺寸（实测横屏报 466×678）。
    @MainActor static func screenIsLandscape() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene, ws.activationState == .foregroundActive
            else { continue }
            switch ws.interfaceOrientation {
            case .landscapeLeft, .landscapeRight: return true
            case .portrait, .portraitUpsideDown: return false
            default: break
            }
        }
        let b = UIScreen.main.bounds
        return b.width > b.height
    }

    /// 这次布局真正可用的尺寸：保留 proxy 的横竖，只在它被父容器撑大时**等比**缩回。
    ///
    /// ⚠️ 历史上这里写的是「每个方向各取一次较小值」：
    ///   width  = min(max(proxy.w, proxy.h), max(screen.w, screen.h))
    ///   height = min(min(proxy.w, proxy.h), min(screen.w, screen.h))
    /// 两个方向来源不同，结果恒为「长边当宽、短边当高」—— 一个永远横着的包围盒。
    /// 于是 `landscapeNow` 恒真（永远双列），Duo 展开也等不到竖屏单列；
    /// 全屏时这块横包围盒又被铺到竖屏上，画面/控件全按横屏坐标落位（「伪全屏」）。
    /// 修法：只等比缩放，绝不交换宽高。
    /// 当前 window **所在屏幕**的静态 bounds。`UIScreen.bounds` 在整个进程里
    /// 不随旋转变化，而 `windowSize()`（keyWindow.bounds）在旋转动画里每帧都不同。
    /// `availableSize` 只需要短边做等比缩放上限；一旦这个上限跟着 keyWindow 抖，
    /// avail 就被一个变化的缩放因子扰动，窗口 winX/winY 与整层控件坐标
    /// 会持续漂移 —— 2026-11-09 用户报的「控件坐标一直漂移」正是这条链路。
    ///
    /// ⚠️ 不能用 `UIScreen.main.bounds`：iPhone Duo 双屏时 main 是**外屏**
    /// （466×678），App 却跑在 669×951 的内屏上，短边上限会被取成 466，
    /// 把整个展开宽屏连同控件错误缩到 70% 宽（实测只占左半边）。
    /// `appWindowScene?.screen` 指向 App 实际所在的那块屏，且仍是静态值。
    @MainActor static func fixedScreenSize() -> CGSize {
        UIApplication.shared.appWindowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
    }

    /// 量化到 0.5pt：旋转 / 折叠动画里的亚点抖动不该触发整页重排。
    private static func quantize(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * 2).rounded() / 2,
               height: (size.height * 2).rounded() / 2)
    }

    @MainActor static func availableSize(proxy: CGSize, screen: CGSize, fullScreen: Bool = false) -> CGSize {
        guard proxy.width > 1, proxy.height > 1 else {
            return quantize(screen.width > 1 && screen.height > 1 ? screen : proxy)
        }
        // ⛔ 伪全屏修复：全屏态侧栏已隐藏、proxy 就是真实可视区，不再拿
        // `screen`（VM 上报告错误的外屏值）去做短边上限缩放，否则全屏窗口
        // 会被缩成一小块、四周巨黑边。直接铺满 proxy。
        if fullScreen { return quantize(proxy) }
        // ★ 只夹**宽度**，不夹高度，也不做等比缩放。
        //
        // 原来这一段的写法是：
        //   shortSide = min(proxy.w, proxy.h);  limit = min(screen.w, screen.h)
        //   若 shortSide > limit*1.12 → 整页等比缩到 limit
        // 它的初衷是「防侧栏把内容区撑宽」（横屏双列时 proxy 报 951 宽）。
        // 但在**竖屏**下它是灾难：
        //   实测 proxy=577×576、screen=466×678 → shortSide=576、limit=466
        //   576 > 466×1.12=522 → 成立 → scale=466/576=0.809
        //   → 整页被压成 467×466，而屏幕高 678。
        // 后果就是用户报的那一串：画面列只剩 309pt 高、控件全挤在上半截、
        // 底栏全屏键落在错误位置点不到、旋转后几何又基于这个假尺寸抖动。
        //
        // 正确语义：**只有宽度需要被屏幕约束**（侧栏/分栏只会加宽，不会加高）。
        // 高度永远用 proxy 自己的 —— 它是系统真正分给这个视图的空间。
        // 而且不再等比缩放：等比会把高度也一起拖下水。
        let limit = screen.width > 1 ? screen.width : proxy.width
        // 留 12% 余量再判定，避免 1pt 的正常误差触发夹取。
        guard limit > 0, proxy.width > limit * 1.12 else { return quantize(proxy) }
        // 宽度超限：只压宽度，高度保持 proxy 原值（不乘比例）。
        return quantize(CGSize(width: limit, height: proxy.height))
    }

    @MainActor static func windowSize() -> CGSize {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene, ws.activationState == .foregroundActive
            else { continue }
            let sizes = ws.windows.map(\.bounds.size).filter { $0.width > 1 && $0.height > 1 }
            if let biggest = sizes.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                return biggest
            }
        }
        return UIScreen.main.bounds.size
    }

    static let defaultSpeed: Float = 1
    /// One 那行给出的是 1x，倍速档位按常见投屏器惯例给齐。
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    static func label(_ speed: Float) -> String {
        let text = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)
        return "\(text)x"
    }

    /// 外部播放器的 URL Scheme。One 实测内置 4 家 + 自定义；
    /// 这里做成可配置，`{url}` 会被替换成已编码的播放地址。
    /// 出处：One 二进制字符串「选「自定义」：填播放器的 URL Scheme，其中 {url} 会换成视频地址（已编码）」
    /// 放在 `OneSkin` 里而不是 `OneSkinStage`：后者是泛型类型，Swift 不允许泛型类型有静态存储属性。
    static let externalPlayers: [(name: String, scheme: String)] = [
        ("Infuse", "infuse://x-callback-url/play?url={url}"),
        ("SenPlayer", "senplayer://play?url={url}"),
        ("VLC", "vlc-x-callback://x-callback-url/stream?url={url}"),
        ("nPlayer", "nplayer-http://{url}"),
    ]

    /// 把播放地址填进播放器的 URL Scheme。占位符 `{url}` 用**已编码**地址替换
    /// （One 原话：「{url} 会换成视频地址（已编码）」）。
    static func externalURL(_ scheme: String, _ url: URL) -> URL? {
        let encoded = url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: scheme.replacingOccurrences(of: "{url}", with: encoded))
    }
}

/// One 的配色。全部来自截图取色，不是估的。
/// One 的字号一律走 `@ScaledMetric(relativeTo: .body)`，跟随系统动态字体。
/// 出处：`sub_10008b728` 的 `_$s7SwiftUI12ScaledMetricV12wrappedValue10relativeToACyxGx_AA4FontV9TextStyleOtcfC`
///       + `Font.TextStyle.body`。我们原来全是固定 `.font(.system(size:))`。
enum OneSkinType {
    /// 标题
    static let title: CGFloat = 17
    /// 正文
    static let body: CGFloat = 13
    /// 次要说明
    static let caption: CGFloat = 12
    /// 极次要（集数、时长）
    static let micro: CGFloat = 11
}

enum OneSkinPalette {
    /// #080808 —— 页底
    static let stage = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    /// #0E0C0D —— 整页底色（One 实测左列 14,12,13）。
    ///
    /// 为什么和 `stage` 并存：`stage` 是早期从主题里借的近似值，
    /// 真正逐像素对过的是这一个。整页铺底、条带补色都用它，别再写裸字面量。
    static let pageBase = Color(red: 0.055, green: 0.047, blue: 0.051)
    /// #181010 —— 卡片
    static let card = Color(red: 24 / 255, green: 16 / 255, blue: 16 / 255)
    /// #F8F8F8 —— 主文字
    static let primary = Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255)
    /// 次级文字：主文字 62%（原来 42% 在深底上发灰，看不清）
    static let secondary = Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255).opacity(0.62)
    /// 三级文字：主文字 34%
    static let tertiary = Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255).opacity(0.34)
    /// One 的强调绿
    static let accent = Color(red: 53 / 255, green: 199 / 255, blue: 89 / 255)
    /// 主按钮底
    static let button = Color(red: 79 / 255, green: 77 / 255, blue: 77 / 255)  // One 继续播放按钮实测 #4F4D4D
    /// One「自动全屏」开启态的蓝字（实测 #1A6CC7）
    static let autoBlue = Color(red: 0x1A/255, green: 0x6C/255, blue: 0xC7/255)
    /// 「自动全屏」开启态的深蓝底（实测 #000D1C）
    static let autoBlueDeep = Color(red: 0x00/255, green: 0x0D/255, blue: 0x1C/255)
    /// 主按钮描边
    static let buttonStroke = Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255).opacity(0.16)
}

// MARK: - 诊断日志

/// 开发期诊断输出。
///
/// **不能用 `print`** —— 它走 stdout，`devicectl --console` 捕获不到，
/// 日志里只会出现 `[webcast]` 那类 NSLog 行（实测：埋了 7 个 print，
/// --console 一行都没收到）。也不能用 `NSLog`：本项目全局禁用了可变参数版本。
/// stderr 是唯一稳定被 console 收走的通道。
@inline(__always)
func oneSkinLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    // os_log 是唯一能被 `devicectl device console` 收走的通道。
    // 实测：Swift 的 `print` 走 stdout、`FileHandle.standardError` 走 stderr，
    // 两者在 iOS 上都不进 console 管道（日志里只会看到 NSLog 产生的行）。
    OneSkinLogSink.log("[OneSkin] " + message())
    #endif
}

#if DEBUG
/// 日志落到 App 自己的 Documents/oneskin.log。
///
/// 试过的三条通道都不可靠（实测）：
///  · `print` → stdout，`devicectl --console` 收不到；
///  · `FileHandle.standardError` → stderr，同样收不到；
///  · `os.Logger` → 进系统日志，`devicectl device console` 也只吐几行。
/// 写文件是唯一能确定取到的：`guest pull` 直接拉出来看。
private enum OneSkinLogSink {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("oneskin.log")
    }()
    static let queue = DispatchQueue(label: "oneskin.log")

    static func log(_ s: String) {
        queue.async {
            let line = s + "\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)   // 首次创建
            }
        }
    }
}
#endif

/// RootView 侧也能用的日志入口（与 oneSkinLog 同一后端）。
enum OneSkinProbe {
    static func log(_ s: String) { oneSkinLog(s) }
}

/// 一条线路的测速样本。
struct OneSkinLineSample: Equatable {
    var url: URL
    var headers: [String: String] = [:]
}

// MARK: - 画面填充模式

/// 播放器画面在窗口内的呈现方式 —— One 的「适应 / 填充 / 铺满 / 拉伸」四档。
///
/// **只改画面在窗口里怎么画，绝不改窗口几何**。窗口恒为 1.819 的横向容器
/// （见 `OneSkinWindowGeometry.Metrics.windowAspect`），这样切换模式时
/// 播放器尺寸一动不动。
///
/// 前两档是 `AVLayerVideoGravity` 原生能力；后两档（铺满/拉伸）原生没有，
/// 用「按模式换算一个显示用比例」喂给 `AVPlayerLayer` 之外的一层缩放来实现。
enum OneSkinFitMode: String, CaseIterable, Identifiable {
    case fit        // 适应：完整画面 + 上下/左右黑边（resizeAspect）
    case fill       // 填充：铺满窗口、裁掉溢出（resizeAspectFill）
    case cover      // 铺满：等比放大到窗口短边贴满，超出裁切
    case stretch    // 拉伸：不留黑边、不裁切，比例可能变形

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: "适应"
        case .fill: "填充"
        case .cover: "铺满"
        case .stretch: "拉伸"
        }
    }

    /// 交给 `AVPlayerLayer` 的重力。铺满与拉伸都先按 fill 画满，
    /// 再由外层的 `scaleEffect` 做等比/非等比微调。
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill, .cover, .stretch: .resizeAspectFill
        }
    }

    /// 外层等比缩放。只有「铺满」需要在 fill 之后再放大一档
    /// （fill 已铺满，这里给 1 表示不额外放大）；拉伸走非等比，
    /// 由 `scaleX`/`scaleY` 分别表达。
    var scaleX: CGFloat { self == .stretch ? 1.0 : 1.0 }
    var scaleY: CGFloat { self == .stretch ? 1.0 : 1.0 }
}

/// 「拉伸」模式的实现：把画面按「窗口比例 ÷ 片源比例」做非等比缩放，
/// 填满窗口且不留黑边（代价是比例失真，这正是「拉伸」这一档的语义）。
///
/// 只在 `.stretch` 时生效；其余模式恒等变换，不引入任何额外缩放 ——
/// 否则会重演「点填充播放器尺寸变了」那类事故。
private struct OneSkinStretchModifier: ViewModifier {
    let mode: OneSkinFitMode
    let playerAspect: CGFloat
    let box: CGSize

    func body(content: Content) -> some View {
        if mode == .stretch, playerAspect > 0.01, box.width > 1, box.height > 1 {
            // fill 之后画面已铺满短边，只差长边那一段，这里把差值补上。
            let k = (box.width / box.height) / playerAspect
            content
                .scaleEffect(x: k > 1 ? k : 1, y: k < 1 ? 1 / k : 1)
                .clipped()
        } else {
            content
        }
    }
}

// MARK: - 开关面板

/// 设置里的「观看页外观」一节：一个总开关 + 三个控件开关。
///
/// 独立成文件，不挂进任何上游设置页。上游要接它只需在任意位置放 `OneSkinPreferencePanel()`；
/// 不接也不影响构建，开关仍可用（`oneSkinEnabled` 直接从 `UserDefaults` 读）。
struct OneSkinPreferencePanel: View {
    @AppStorage(OneSkin.enabledKey) private var enabled = true   // 与 VideoDetailView 保持一致，避免默认值冲突
    @AppStorage(OneSkin.loopKey) private var loop = false
    @AppStorage(OneSkin.speedKey) private var speed: Double = 1
    /// 画面填充模式。存字符串，重启后保持；旧版本写过的布尔 `oneSkinFill`
    /// 仍能被读到（`fill == true` 视为 `.fill`），不会把用户的选择丢掉。
    @AppStorage(OneSkin.fitModeKey) private var fitModeRaw = OneSkinFitMode.fit.rawValue
    @AppStorage(OneSkin.fillKey) private var legacyFill = false
    /// 当前模式；没有新值但有旧布尔值时按旧值映射。
    private var fitMode: OneSkinFitMode {
        get {
            if let m = OneSkinFitMode(rawValue: fitModeRaw), m == .fit || m == .fill { return m }
            return legacyFill ? .fill : .fit
        }
        nonmutating set { fitModeRaw = newValue.rawValue; legacyFill = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $enabled.animation(.smooth(duration: 0.2))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("One 观看页").font(.body)
                    Text(enabled ? "播放页用 One 的版式" : "播放页保持原版")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)

            if enabled {
                Divider().opacity(0.5)
                Group {
                    Picker("画面", selection: $fitModeRaw) {
                        ForEach([OneSkinFitMode.fit, .fill]) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.menu)
                    Toggle("循环播放", isOn: $loop)
                }
                .font(.body)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - 平台差异

private extension View {
    /// 状态栏只有 iOS/tvOS 有；macOS 上什么都不做。
    @ViewBuilder func oneSkinStatusBarHidden() -> some View {
        #if os(iOS)
        statusBarHidden(true)
        #else
        self
        #endif
    }
}

// MARK: - One 版观看页

/// One 的播放页版式：黑底、播放器在上、控制选项一行、标题与统计、主按钮、标签、选集。
///
/// 只负责「长什么样」和「按钮在哪」：画面由调用方作为 `picture` 传进来，
/// 跳转与播放全部通过闭包回调，所以这一层不认识播放引擎。
/// One 观看页的形态 —— **全站唯一的横竖 / 展开判据**。
///
/// ⚠️ 必须是离散枚举，不能退回「容器 width > height」：
///  · Duo 内屏横持时 `screen.bounds` 仍报原生竖屏值（2007×2853）；
///  · 根部 GeometryReader 在旋转动画里连续变化，宽高比会在临界点反复翻转，
///    于是「展开宽屏」和「展开横屏」来回落进同一个分支，窗口 winX/winY
///    和整层控件坐标每帧重算 —— 就是用户报的「界面控件坐标一直漂移」。
///
/// 判据在 `VideoDetailView.oneSkinShape` 里由三个**离散**信号合成：
/// `duoExpanded`(size class) / `sideways`(interfaceOrientation) / `landscapePage`(size class)。
/// 本文件内 `OneSkinStage.effectiveShape` 是这之后唯一的读取点。
enum OneSkinShape: Equatable {
    /// 折叠态 / 立式手机：单列，画面在上，详情在下。
    case column
    /// 展开横屏（Duo 摊开 + 横持）或手机横持：左右双列。
    case split
    /// 展开宽屏（Duo 摊开 + 竖持）：画面全出血铺满上半屏，详情收进下方抽屉。
    /// 这是「宽屏」不是「横屏」，所以 `isLandscape` 必须是 false。
    case fullBleed

    /// 只有 split 是横向双列。fullBleed 是竖持的宽屏，不要按横屏排版。
    var isLandscape: Bool { self == .split }

    var logName: String {
        switch self {
        case .column:    return "column/竖持手机·折叠"
        case .split:     return "split/展开横屏·手机横持"
        case .fullBleed: return "fullBleed/展开宽屏·竖持"
        }
    }
}

// MARK: - 纯 AVPlayerLayer 画面

/// 用 `AVPlayerLayer` 直接画播放器的画面。
///
/// 为什么不复用 `PlaybackView`：它内部是 `AVPlayerViewController`，AVKit 会
/// 自己接管布局、无视 SwiftUI 给的 frame（`clipped()`/`mask`/`clipsToBounds`
/// 都挡不住 CALayer），结果视频永远铺满整屏。One 的版式要把画面塞进一个
/// 由宽高比算出的小窗口里，只能自己画图层 —— `AVPlayerLayer` 完全听父视图的 frame。
struct OneSkinPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> OneSkinPlayerView {
        let view = OneSkinPlayerView()
        // 2026-11-09：宿主必须透明。`videoGravity = .resizeAspect` 时
        // AVPlayerLayer 只画视频像素，letterbox 区域是透明的 —— 宿主若是黑底，
        // 用户看到的就是「播放器内黑了这个屏幕」。透明后透出下面那层
        // `OneSkinPosterWash`（与海报同色的虚化）。
        view.backgroundColor = .clear
        view.clipsToBounds = true
        // 不接管触摸：UIView 默认会吞掉落在其矩形内的点击，
        // 上层 SwiftUI 的返回/播放/进度条会「看得见点不到」。
        view.isUserInteractionEnabled = false
        view.attach(player: player, gravity: videoGravity)
        return view
    }

    func updateUIView(_ view: OneSkinPlayerView, context: Context) {
        #if DEBUG
        oneSkinLog("updateUIView player=\(ObjectIdentifier(player)) layer=\(view.currentPlayerID) same=\(view.currentPlayer === player)")
        #endif
        view.update(player: player, gravity: videoGravity)
    }
}

/// 只画 AVPlayerLayer 的宿主视图。
///
/// ★ 2026-11-09：以前 `layer.frame` 只在 `makeUIView`/`updateUIView` 里赋一次。
/// SwiftUI 只改 frame 而不重绘时（旋转、抽屉展开、片源就绪），layer 会停在
/// 旧的大尺寸上，画面于是撑出窗口、看起来像「播放器被拉高铺满整列」。
/// 现在由 `layoutSubviews` 每次布局都把 layer 收回到宿主 bounds。
final class OneSkinPlayerView: UIView {
    private let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 与 makeUIView 同一条规则：透明宿主，让 letterbox 透出海报虚化底。
        backgroundColor = .clear
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }

    /// 当前图层挂着的 player 身份，供 DEBUG 日志对比。
    var currentPlayer: AVPlayer? { playerLayer.player }
    var currentPlayerID: String { playerLayer.player.map { "\(ObjectIdentifier($0))" } ?? "nil" }

    func update(player: AVPlayer, gravity: AVLayerVideoGravity) {
        #if DEBUG
        oneSkinLog("OneSkinPlayerView.update new=\(ObjectIdentifier(player)) old=\(currentPlayerID)")
        #endif
        if playerLayer.player !== player { playerLayer.player = player }
        playerLayer.videoGravity = gravity
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.setDisableActions(true)   // frame 变化不要带隐式动画
        playerLayer.frame = bounds
    }
}

/// One 播放页皮肤。/// One 播放页皮肤。
///
/// **不再是泛型视图**。它原先写成 `OneSkinStage<Picture: View>`，唯一的泛型来源
/// 就是那个从未被调用的 `picture` 闭包。泛型参数去掉之后有两个实际好处：
///   ① 调用方不必为一棵 never-rendered 的闭包付类型推断成本（曾因此编译失败）；
///   ② 泛型视图的构造参数变化不保证触发重绘 —— `isFullScreen` / `@AppStorage`
///      都需要额外的 `@State` 镜像才生效（见 fullScreenNow / foldedNow 的注释）。
///      非泛型后这类问题从根上少一层。
/// 「立即可用 + 可持久化」的布尔状态。
///
/// 为什么需要：`@AppStorage` 写在视图里时，值变了不保证触发重绘
///（本项目实测过两次：`twoColumn` 写进去了但 `stage` 不刷新）。
/// 这套「本地 @State 立即驱动 + 持久化只负责记住」的双写模式，
/// 原先在 `foldedNow` / `fullScreenNow` 两处各写一遍，公式一致但容易漏。
///
/// 用法：
/// ```
/// @State private var foldedFlag = SyncedFlag(persisted: UserDefaults...bool(forKey: key))
/// ...
/// if foldedFlag.value { ... }
/// foldedFlag.set(true, persist: { twoColumn = $0 })
/// ```
struct SyncedFlag {
    private(set) var value: Bool

    init(value: Bool) { self.value = value }

    /// 改本地值（立即驱动重绘），并把新值交给持久化闭包。
    mutating func set(_ next: Bool, persist: (Bool) -> Void) {
        value = next
        persist(next)
    }

    /// 只改本地值，不落盘（用于从构造参数镜像进来）。
    mutating func mirror(_ next: Bool) {
        value = next
    }
}

struct OneSkinStage: View {
    let video: Video
    /// 详情页补充回来的完整信息（简介、集数）。列表页拿到的 `video` 常常只有标题。
    var detail: Video?
    /// 当前这一集，没有就取第一集。
    var current: Episode?
    /// 这一页正在播放。
    var playing: Bool
    /// 正在向源站要地址。
    var busy: Bool
    /// 片源自己的宽高比；调用方给多少就画多少，缺省按 16:9。
    var aspectRatio: CGFloat = 16.0 / 9.0

    /// 画面填充模式（适应/填充/铺满/拉伸）。存字符串，重启后保持。
    /// 旧的布尔 `oneSkinFill` 仍能读到：真值映射为 `.fill`，不丢用户选择。
    /// **只改画面怎么画，窗口几何恒定**（1.819 横向容器）。
    @AppStorage(OneSkin.fitModeKey) private var fitModeRaw = OneSkinFitMode.fit.rawValue
    @AppStorage(OneSkin.fillKey) private var legacyFill = false

    /// 正在拖进度条 —— 拖动期间用 `dragProgress` 画，不读播放进度，
    /// 免得手指和播放器互相拉扯。
    @State private var isScrubbing = false
    @State private var dragProgress: Double = 0

    /// 当前模式；没有新值但有旧布尔值时按旧值映射。
    private var fitMode: OneSkinFitMode {
        get {
            if let m = OneSkinFitMode(rawValue: fitModeRaw), m == .fit || m == .fill { return m }
            return legacyFill ? .fill : .fit
        }
        nonmutating set { fitModeRaw = newValue.rawValue; legacyFill = false }
    }
    /// 三态之一，由调用方按上游 `splitsWatchPage` / `portraitExpanded` 算好传进来。
    var shape: OneSkinShape = .column

    /// 当前频道。字幕文件、请求头、片头片尾 scope、上下集都从它取。
    /// 之前 OneSkin 不认识 `Channel`，于是字幕/片头片尾/外播/上下集这些
    /// 「需要片源身份」的控件根本无从接线。
    var channel: Channel? = nil

    /// 直接给播放器实例：有它时用 `AVPlayerLayer` 自绘画面（完全听 frame），
    /// 没有再退回调用方传的 `picture` 闭包。One 的小窗口版式必须走前者，
    /// 否则 AVPlayerViewController 会铺满全屏。
    var avPlayer: AVPlayer? = nil

    /// 播放会话：画质/音轨选择从这里读 `qualities`/`audioChoices` 并调
    /// `choose(quality:)`/`chooseAudio(_:)`。nil（未开播）时画质/音轨 chip 隐藏。
    var session: PlaybackSession? = nil

    /// 已播秒数与总时长。One 的进度条两端是「已播 / 剩余」，
    /// 没有真值就画不出正确的进度，所以由调用方从 `PlaybackSession` 传入。
    var position: Double = 0
    var duration: Double = 0

    // 曾有一个 `@ViewBuilder var picture: () -> Picture` 参数，但全文件从未调用过它
    //（唯一出现是在注释里）。调用方为此白白构造了一棵 never-rendered 的视图树。
    // 真正让 PlaybackView 跑起来、触发 session.prepare 的，是 VideoDetailView 里
    // 挂在 oneSkinBody 上的 `.background(watchStage)`，与这个参数无关。
    // 已删除，别再加回来。

    var onBack: () -> Void
    /// 只退全屏、不离开页面。`onBack` 会按页面的 `fullScreen` 分流，而皮肤有一份自己的
    /// 镜像（`fullScreenNow`）；两份状态不同步时返回会被误判成「离开页面」。
    /// 全屏下的返回必须走这条单向通道。缺省值让老调用方不用改。
    var onExitFullScreen: () -> Void = {}
    var onPlay: (Episode) -> Void
    var onTogglePlay: () -> Void
    var onSeekBack: () -> Void
    var onSeekForward: () -> Void
    /// 拖进度条松手时回调，参数是 0…1 的目标位置。
    var onSeekTo: (Double) -> Void = { _ in }
    var onFullScreen: () -> Void
    var onEpisodes: () -> Void
    var onToggleSkin: () -> Void
    /// 下载当前集：弹上游的 DownloadPicker。
    var onDownload: () -> Void = {}
    /// 收藏/取消收藏当前视频。`isFavorite` 决定红心是空还是实心红。
    var onFavorite: () -> Void = {}
    /// 分享当前视频（One 是分享稳定链接，不是临时播放地址）。
    var onShare: () -> Void = {}
    var isFavorite: Bool = false
    /// 全部线路名（一条 flag 一条线，可能只有一条）。空则「线路」chip 隐藏。
    var lines: [String] = []
    /// 当前线路名。选集卡与「线路」chip 都按它过滤。
    var activeLine: String = ""
    /// 每条线路的测速样本（线路名 → 该线首集的播放地址与请求头）。
    ///
    /// 只有拿到**每条线路自己的地址**才谈得上「多线路分别测延迟」：
    /// 以前 `probeLatency` 只测当前这条线的 `streamURL`，其余线路永远是空，
    /// 线路菜单里也就没法比快慢、更没法据此切换。调用方按 flag 解析后传进来。
    var lineSamples: [String: OneSkinLineSample] = [:]
    /// 切换到某条线路。由调用方复用上游 `selectedFlag`/`activeEpisodes` 的换线逻辑。
    var onSelectLine: (String) -> Void = { _ in }
    /// 标题栏的横竖屏切换按钮。
    var onRotate: () -> Void = {}
    /// 收进应用内小窗（与上游播放器的 Mini Player 同一入口）。
    var onMiniPlayer: () -> Void = {}
    /// 详情区的合拢/展开切换按钮。
    var onFold: () -> Void = {}

    /// 当前播放地址。One 的 `•••` 菜单里「复制视频链接」「用外部播放器打开」
    /// 都吃这一个值；为 nil 时两项置灰，不假装能点。
    var streamURL: URL? = nil
    /// 当前播放地址对应的 HTTP 头（部分源需要 Referer/UA 才能拉流）。
    var streamHeaders: [String: String] = [:]

    /// 是否处于全屏播放态。
    ///
    /// One 的五态里有两态是全屏（横屏 / 竖屏）。此前 OneSkin **完全没读这个状态**：
    /// `VideoDetailView` 的 `fullScreen` 只影响上游 `upstreamWatchBody` 的 stageHeight，
    /// 皮肤层照样画双列 + 胶囊条，所以「点全屏」在皮肤下没有任何视觉变化。
    var isFullScreen: Bool = false

    /// 片源比例**只影响窗口内部怎么留黑边**（`videoGravity`），不影响窗口尺寸。
    /// 原先每 400ms 轮询 presentationSize 改这个 state，既没有消费者，
    /// 又会让整页在开播后反复重绘 —— 一并删除（见 OneSkinWindowGeometry）。
    @AppStorage(OneSkin.speedKey) private var speed: Double = 1
    @AppStorage(OneSkin.loopKey) private var loop = false
    /// 「填充」只切 AVPlayerLayer 的裁切方式，**不参与窗口几何**。
    /// OneSkinWindowGeometry 不读它，所以点填充永远不会改变窗口尺寸或位置。
    @State private var showsSpeedMenu = false
    /// One 第 5 颗「线路延迟」的展开态
    @State private var showsLineMenu = false
    /// 底部胶囊条是否折起。
    ///
    /// 「折起」= 只留一颗按钮，点开才展开全部 chip。
    /// 这跟上游 `MobilePlayer` 的做法一致：那里是 `moreControls` 非空时
    /// 才出现一颗 More 圆按钮，控制项按需折进去，而不是一直铺在画面上。
    /// 播放态画面是主角，倍速/循环/填充/线路不该一直占着底部。
    /// 默认**折起**：进入播放态时底部只留一颗按钮，不铺一横排 chip 压住画面。
    /// 胶囊控制条是否折起。
    ///
    /// 用户要求「这个东西不用隐藏、缩起，直接常驻」。原来默认 `true`，
    /// 每次进页面只看到一颗 ☰，要再点一下才展开 —— 多一次点击、也看不出有哪些功能。
    /// 现在恒为 false（常驻展开）。保留这个状态是为了别处 `if controlsCollapsed`
    /// 的分支不用同步删（折叠能力留着，只是不再默认折、也没有入口去折）。
    @State private var controlsCollapsed = false
    /// 画质选择展开态（One 没有画质 chip，这里是补上游有、One 没有的功能，UI 沿用 One chip 风格）。
    @State private var showsQualityMenu = false
    /// 音轨选择展开态。
    @State private var showsAudioMenu = false
    /// 当前线路延迟（ms）；nil 表示还没测出来
    @State private var lineLatency: Int? = nil
    /// 每条线路各自的延迟（线路名 → 毫秒）。nil 表示还没测完。
    ///
    /// One 只在 chip 上显示当前线路的数；但「自动」这件事本身需要比较，
    /// 所以线路菜单里每条都带自己的数，最快的标出来 —— 用户才能据此手动切。
    @State private var lineLatencies: [String: Int] = [:]
    /// 画中画控制器。绑在 OneSkin 自己那条 AVPlayerLayer 上（见 OneSkinFixedPicture 的 pip 参数）；
    /// 不能与播放器共用 —— 一个 AVPlayer 同时只驱动一层画面，第二层会把悬浮窗的
    /// 画面抢走，只剩声音（`PictureInPicture.sourceLayer` 那段注释记的就是这个坑）。
    @State private var pip = PictureInPicture()
    /// 音轨 / 内嵌字幕轨的读写口，与播放器同一套 AF API。
    @State private var tracks = MediaTracks()
    /// 控件排布：与播放器共用同一份 `@AppStorage`，设置页怎么排 One 页就怎么排。
    @AppStorage(PlayerControlsLayout.storageKey) private var controlsOrder = PlayerControlsLayout.standard.stored

    /// 正在测速。
    @State private var probingLines = false
    /// 当前线路序号的展示值
    @State private var lineIndex: Int = 1

    /// [mi3s] 背景由海报算出来，随集数变。取不到时退回纯黑。
    /// [mi3s] 海报原图。背景用它铺底 + 材质模糊，和 One 的 UIVisualEffectView 机制一致。
    @State private var posterImage: UIImage?
    /// `•••` 菜单的展开态（One 详情页右上角那一个）。
    @State private var showsMoreMenu = false
    /// 复制直链后的确认提示。
    @State private var copiedLink = false
    /// 最近一次视口尺寸，供 layout 常量取用。
    /// 详情列是否合拢。合拢后只留画面 + 控件条，详情列收起。
    /// One 的双列开关是持久化偏好，不是临时状态。
    /// 默认 true = 双屏（One 打开详情页就是双列），关掉即合拢。
    @AppStorage(OneSkin.twoColumnKey) private var twoColumn = true
    /// 立即驱动布局重建的本地状态；初值取持久化值（见 folded 的说明）。
    ///
    /// ⛔ 默认值必须和 `twoColumn`（`@AppStorage`，默认 **true** = 双列）一致。
    /// 原来写的是 `!UserDefaults.standard.bool(forKey:)` —— 而 `bool(forKey:)` 在
    /// **键从未写过**时返回 false，于是 `foldedNow` 初值是 **true**：
    /// 全新安装一进选集页就是「合拢」态，只剩画面铺满整页、没有详情也没有选集。
    /// 用户看到的就是一个「全屏播放」，而这时 `VideoDetailView.fullScreen` 是 false，
    /// 返回键按 `leavePlayer()` 的 else 分支走 `dismiss()` —— 一下退回主页。
    /// 用 `object(forKey:)` 判「有没有写过」，没写过才取默认的双列。
    @State private var foldedNow: Bool = !(UserDefaults.standard.object(forKey: OneSkin.twoColumnKey) as? Bool ?? true)
    /// 全屏态的本地镜像。
    ///
    /// 为什么需要：`isFullScreen` 是构造参数，而 `OneSkinStage` 是泛型视图 ——
    /// 实测上游 `setFullScreen` 改了 `fullScreen` 之后，这里的 `stage` **不会重新求值**，
    /// 于是「进全屏」有效（首次求值就是 true）但「退全屏」无效（参数变了不重建）。
    /// 用 onAppear/onChange 把它镜像进 @State，再用本地值驱动布局。
    @State private var fullScreenNow: Bool = false
    /// 形态镜像。`shape` 是构造参数，而 `OneSkinStage` 是泛型视图——实测旋转后
    /// 调用方改了 `shape`，这里的 `stage` **不重算**（与 fullScreenNow 同一个坑）：
    /// 布局停在旧形态上，窗口与控件按旧方向排，用户看到「旋转后 UI/控件漂移，
    /// 重启 App 才恢复」。用 onChange 把它镜像进 @State，再由本地值驱动布局。
    @State private var shapeNow: OneSkinShape = .column
    /// 冻结的布局盒（只存内存 @State，不跨启动持久化）。
    ///
    /// ⛔ 三次回归的教训，记全别再反复：
    ///   ① box 每帧由 `screen.bounds` 现算 → 旋转动画里 screen.bounds 连续变
    ///      （日志铁证：同 shape 报 466x678 与 951x669 两种），box 每帧变 =
    ///      「横竖屏切换控件疯狂推移」复发。
    ///   ② box 冻进 @State 但**写 UserDefaults 跨启动缓存** → 缓存把外屏旧值
    ///      带回内屏页面、或把旧方向 box 取回，形态变了仍读旧值。
    ///   ③ 正确做法：box 只在**离散事件**（onAppear / 形态切换）时重算一次，
    ///      存内存 @State，动画期间冻结；不写 UserDefaults，页面身份重建时
    ///      onAppear 按当前屏幕重新算（此时 screen 已稳定，不是动画中间态）。
    @State private var frozenBox: CGSize = .zero
    /// DEBUG：强制不进全屏，用于在双列态验证触摸链路（QA 用）。
    private var debugBlockFullScreen: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "qaNoFullScreen")
        #else
        return false
        #endif
    }
    /// QA 用：强制竖屏布局（不改设备方向，只让 layout 走竖屏分支）。
    @State private var portraitNow: Bool = false
    /// 切换合拢态：本地立即生效，同时写回持久化。
    private func toggleFold() {
        let next = !foldedNow
        withAnimation(.smooth(duration: 0.25)) { foldedNow = next }
        twoColumn = !next
    }

    /// 合拢 = 关掉双列。
    ///
    /// 这里曾经只读 `@AppStorage twoColumn`，但实测点击展开图标后
    /// `twoColumn` 写进去了、`stage` 却不重建（`@AppStorage` 的
    /// 变化通知在 `OneSkinStage` 这种泛型视图里不总是触发）。
    /// 现在用一对「本地 @State + AppStorage」双写：`foldedNow` 立即驱动重建，
    /// `twoColumn` 只负责持久化，两者在初始化时同步。
    /// 播放中是否临时折起右侧详情栏（复刻 `collapse` 按钮的行为）。
    ///
    /// 右侧那条竖排图标（返回/播放/搜索/音乐/选集/更多）一旦开始播放就会盖住
    /// 右栏内容，选集胶囊正好被压在屏幕最右缘点不到。详情栏合拢后竖条自然消失。
    ///
    /// 关键：**这是临时态，不写 `twoColumn`**。播放时自动折起，暂停/退出播放后
    /// 恢复到用户原本选的布局 —— 否则用户会因为「看了个视频」而永久丢掉双列偏好。
    ///
    /// [已删除] `autoCollapsedForPlayback`：那个「播放中临时折起」的状态早就连同驱动它的
    /// 逻辑一起删了（见 `folded` 的注释），只剩一个没有任何读写的 `@State`。
    /// 死状态比死代码更坏 —— 它让后来的人以为页面还会自己折起。

    private var folded: Bool {
        // ⛔ 播放中**不再**自动合拢。
        //
        // 原来这里有一句 `if playing && !foldedNow { return true }`：
        // 一开始播就把详情栏收起，理由是「右侧那条竖排图标会盖住右栏」。
        // 那条竖排图标就是系统的浮动标签栏。现在按用户要求，选集播放页
        // **保留这条菜单栏**（横屏竖屏一样，只有全屏播放才隐藏，见
        // `VideoDetailView.watchBody` 的 `.setBarVisibility(fullScreen ? …)`）。
        // 但播放中自动合拢依旧不恢复：它会让右栏和选集整块消失，
        // 展开态一按播放，右栏和选集整块消失，屏幕下半截留一大片空黑 ——
        // 用户报的「留黑」有一半是它，不是片源 letterbox。
        return foldedNow
    }

    /// 本次渲染的**唯一**形态来源。调用方（`VideoDetailView.oneSkinShape`）已经用
    /// 离散信号判好了三种形态，QA 开关只在这里做一次覆盖。
    ///
    /// ⛔ 禁止再在 `stage` / `makeLayout` / 控件层里写 `size.width > size.height`：
    /// 那些地方拿到的都是旋转动画中的连续尺寸，会在临界点反复翻转，
    /// 两种展开态因此混成一态，窗口与控件绝对坐标每帧重排。
    private var effectiveShape: OneSkinShape {
        let forcePortrait = UserDefaults.standard.bool(forKey: "qaOneSkinPortrait") || portraitNow
        let forceLandscape = !forcePortrait && UserDefaults.standard.bool(forKey: "qaOneSkinLandscape")
        if forcePortrait { return .column }
        if forceLandscape { return .split }
        return shapeNow
    }
    /// 是否走横向双列。fullBleed（展开宽屏）是**竖持**，必须返回 false。
    private var stageIsLandscape: Bool { effectiveShape.isLandscape }

    private var shown: Video { detail ?? video }
    /// 当前线路的集。线路为空（单线源）时退回全集，兼容没传 lines 的旧调用。
    private var episodes: [Episode] {
        if lines.isEmpty { return shown.episodes }
        let flag = activeLine.isEmpty ? (lines.first ?? "") : activeLine
        let filtered = shown.episodes.filter { $0.flag == flag }
        return filtered.isEmpty ? shown.episodes : filtered
    }
    private var playingEpisode: Episode? { current ?? episodes.first }

    /// 进度条比例。时长未知时给 0，不假装有进度。
    private var progress: CGFloat {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return CGFloat(min(max(position / duration, 0), 1))
    }

    /// One 左端显示「已播」，右端显示「−剩余」——实测样板是 `0:00:01` / `-1:58:04`。
    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    private var timeText: String { Self.clock(position) }
    private var remainText: String {
        guard duration.isFinite, duration > 0 else { return "" }
        return "-" + Self.clock(max(duration - position, 0))
    }

    var body: some View {
        // 尺寸来源只此一处：根部一个 GeometryReader 拿到**容器本身**的尺寸，
        // 直接用于排版。
        //
        // 走过的两条弯路（都记在这，别再回头）：
        //  ① 中间层 `OneSkinViewport` 先量尺寸、再把尺寸回传给 content 去布局 ——
        //     这是「子测父、父按子排版」的反馈环。实测在 VM 上发散到
        //     42017×23635 的越界图层（宽高比正好 16:9，是视频比例被反复放大）。
        //  ② `screen.bounds` + interfaceOrientation 换算 —— VM 上它报竖屏原生值
        //     (466×678)，而真实容器是横屏 678×466，导致 winY 按 678 算，
        //     画面窗口被推到屏幕中部（实测 y646 vs One 的 y357）。
        // 根部 GeometryReader 量的就是系统分给这个视图的空间，不会被骗，也不会自激。
        GeometryReader { proxy in
            // ★ 用**真实屏幕**而不是父容器。
            //
            // 实测（Fig-clone 678×466pt）：这里量到的是 951×669 —— 宽了 273pt，
            // 那正好是右侧 `.sidebarAdaptable` 边栏的宽度。播放页是 push 进
            // NavigationStack 的、仍在 TabView 里，边栏没折叠，把内容区撑大了。
            // 于是 colL 算成 951×0.5334=507（应为 361），播放器窗口 473×260
            // （One 基准 338×186），而且边栏直接压住右栏按钮 —— 用户报的
            // 「点不进去」和「尺寸不对」都是这一个原因。
            //
            // 父容器宽度不可信，就以屏幕为准：取 proxy 与屏幕的**较小值**，
            // 保证内容永远不超出真实可视区。屏幕比 proxy 大时（正常情况）仍用 proxy。
            // ★ 屏幕类 API 在这个 VM 上都不可信（实测全部报竖屏 466×678，
            // 而实际截图是横屏 2034×1398）。唯一可信的是「根视图被分配到的
            // 局部坐标空间」—— 它跟着父容器走，父容器若是横的，它就是横的。
            // 因此直接用 proxy.size，只做一次「谁是可视区」的安全夹取。
            let screen = OneSkin.fixedScreenSize()
            // ⛔ 伪全屏修复：`availableSize` 的短边上限缩放是给**双列态**防
            // 侧栏把内容区撑大用的（951×669 那个坑）。但全屏态侧栏已经
            // `.persistentSystemOverlays(.hidden)` 隐藏、proxy 本应就是真实可视区，
            // 再拿 `UIScreen.main.bounds`（VM 上报告错误的外屏竖屏值）去缩，
            // 全屏窗口就缩成一小块、四周巨黑边 —— 用户报的「伪全屏」。
            // 全屏态由 `fullScreen:` 参数跳过缩放，直接用 proxy.size 铺满。
            let avail = OneSkin.availableSize(proxy: proxy.size, screen: screen, fullScreen: fullScreenNow)
            // ⛔ 不要在这里「冻结尺寸」。
            //
            // 试过 `StableStageSize`：在 body 里读 `proxy.size`，喂给它，
            // 它再写 `@State` 决定用哪个尺寸排版。这是**反馈环**：
            //   改 State → 重排 → proxy.size 变 → 再改 State → …
            // 表现就是用户报的「横转竖后控件无限推移，得重启 App 才恢复」。
            // 而且它是「只在稳定后提交」，一旦某一帧被判成稳定、后续又变了，
            // 几何就永久卡在旧值 —— 全屏点不动也是它连带的。
            // 真正的正解是：**几何只由离散形态决定，不依赖连续尺寸**（见 shape 的说明）。
            let _ = oneSkinLog("ROOT proxy=\(Int(proxy.size.width))x\(Int(proxy.size.height)) screen=\(Int(screen.width))x\(Int(screen.height)) use=\(Int(avail.width))x\(Int(avail.height)) fs=\(fullScreenNow)")
            // ★ 整页底色必须**单独一层、不跟着内容内缩**。
            //
            // `stage` 内部是 `Group`，而 Group 上的修改器是**逐个子视图**生效的：
            // `.padding(.top, 8)` 连那一层整页底色一起缩了进去。`.ignoresSafeArea()`
            // 只按「安全区」外扩，横屏顶部安全区是 0（状态栏已隐藏），补不回来 ——
            // 于是屏幕最上沿露出的是更亮的 `OneSkinBackdropLayer`（实测 87,110,143，
            // 内容区 11,9,10），横贯整屏一条，就是用户报的「色彩不一致的顶部条」。
            // 放在这里（stage 外、padding 外）才是真正的全屏底色：条带被同色填满，
            // 同时不用动那 8pt —— 它是 One 逐像素实测的下移量，`OneSkinWindowGeometry`
            // 的 usableH / winY 都按它算，改数字整页几何就漂。
            ZStack(alignment: .topLeading) {
                OneSkinPalette.pageBase.ignoresSafeArea()
                stage(avail, fitMode: fitMode, playerAspect: aspectRatio)
            }
            //
            // 原来的写法是「每个方向各取一次较小值」：
            //   width  = min(max(proxy.w, proxy.h), max(screen.w, screen.h))
            //   height = min(min(proxy.w, proxy.h), min(screen.w, screen.h))
            // 两个方向取的**不是同一个来源**，结果恒等于「长边当宽、短边当高」：
            //   · 竖屏手机 393×852   → avail = 852×393（横的）
            //   · Duo 展开竖持 2007×2853 → avail = 2853×2007（横的）
            // 于是 `landscapeNow = measured.width > measured.height` 恒为真 ——
            // 不管怎么拿，页面都是横屏双列，Duo 展开也永远等不到竖屏单列。
            // 更糟的是全屏：把这块「横着的」包围盒铺到竖屏上，画面按横屏窗口排、
            // 上下留巨黑边、控件按横屏坐标落位 —— 就是用户报的「伪全屏」。
            //
            // 现在只做**等比**收缩：保留 proxy 自己的横竖，仅在 proxy 被父容器
            // 撑大（VM 上那 1.4 倍边栏）时整体缩到屏幕短边，绝不交换宽高。
            // 放在 static 方法里：ViewBuilder 里写 `if` 会被当成条件视图，编不过。
            // screen 只用来取「短边上限」，必须是静态值：keyWindow.bounds 在
            // 旋转动画里每帧变，会让这个缩放因子一直抖（控件坐标漂移）。
            // 形态本身已由离散的 effectiveShape 决定，不参与这里的计算。
        }
        .background(
            OneSkinBackdropLayer(image: posterImage).ignoresSafeArea()
        )
        .foregroundStyle(OneSkinPalette.primary)
        .oneSkinStatusBarHidden()
        .task(id: shown.poster) { await refreshBackdrop() }
        // 片源比例不再轮询：窗口是固定版式比例，画面在窗口内 letterbox。
        // 把构造参数镜像进本地状态：泛型视图的参数变化不保证重绘（见 fullScreenNow 的说明）。
        .onAppear {
            fullScreenNow = debugBlockFullScreen ? false : isFullScreen
            shapeNow = shape
            // 页面身份（重新）建立时，按「当前形态 + 当前屏幕」重算一次冻结盒。
            // 此时 screen 已稳定（onAppear 不是旋转动画中间帧），现算安全。
            let raw = OneSkin.fixedScreenSize()
            let land = CGSize(width: max(raw.width, raw.height), height: min(raw.width, raw.height))
            let port = CGSize(width: min(raw.width, raw.height), height: max(raw.width, raw.height))
            frozenBox = shape.isLandscape ? land : port
            // 用户确认的目标版式：竖屏片源在固定横向窗口里**居中成一条竖画、
            // 不填充**，两侧留着海报虚化的空带（哪怕看着浪费也是对的）。
            // 「填充」只允许本次会话里临时切来看，绝不跨页面/跨启动保留 ——
            // 否则 @AppStorage 会把上次点过的 fill 带回来，一进页面就变成
            // 铺满窗口那一版。这里每次出现都收回「适应」。
            if fitModeRaw != OneSkinFitMode.fit.rawValue {
                fitModeRaw = OneSkinFitMode.fit.rawValue
            }
            if legacyFill { legacyFill = false }
            #if DEBUG
            // QA 自检：`-qaOneSkinCycle` 时按固定节奏把五态轮一遍，
            // 每态停留 6 秒。VM 没有旋转接口、模拟器没有 tap，
            // 这是唯一能一次跑完五种态并逐张截图的办法。
            // 注意：这里**不再读启动参数**。
            // `apps.launch` 的 args 只有首次冷启动会进 argument domain，
            // 后续 relaunch 全部读不到（实测 `-qaOneSkinCycle` / `-qaOneSkinFold` /
            // `-qaOneSkinPortrait` 三种读法都无效，而 `-qaOneSkin` 之所以"有效"
            // 是因为 UserDefaults 里早就有这个键的持久值）。
            // 改成 UserDefaults 开关（默认关）。
            // 曾经写死 `if true` 让它无条件跑，结果 QA 循环会持续覆盖用户点击
            // 造成的状态 —— 全屏退出点了没反应，其实是循环在 12 秒后又把它设回去了。
            // 现在只有显式设过 `qaOneSkinCycle` 才跑。
            if UserDefaults.standard.bool(forKey: "qaOneSkinCycle") {
                Task { @MainActor in
                    // 每态停留 12 秒，给截图留足余量（withAnimation 0.25s + 渲染）。
                    // 顺序：先显式退全屏（上游点进来常自动进全屏）→ 五态依次。
                    try? await Task.sleep(for: .seconds(3))
                    fullScreenNow = false; portraitNow = false; foldedNow = false
                    try? await Task.sleep(for: .seconds(12))   // ① 横屏双列

                    portraitNow = true
                    try? await Task.sleep(for: .seconds(12))   // ② 竖屏单列

                    foldedNow = true                            // 直接赋值，不走动画
                    try? await Task.sleep(for: .seconds(12))   // ③ 竖屏合拢

                    portraitNow = false
                    try? await Task.sleep(for: .seconds(12))   // ④ 横屏合拢

                    foldedNow = false
                    fullScreenNow = true
                }
            }
            #endif
        }
        .onChange(of: isFullScreen) { _, new in
            guard !debugBlockFullScreen else { return }
            withAnimation(.smooth(duration: 0.28)) { fullScreenNow = new }
        }
        .onChange(of: shape) { _, new in
            // 旋转/折叠后调用方改了 shape 参数：泛型视图不保证重算 body，
            // 必须镜像进 @State 才会驱动 stage 重建（用户报的「旋转后 UI 漂移、
            // 重启才生效」正是布局停在旧形态上）。
            guard shapeNow != new else { return }
            // ⛔ 不能用 withAnimation：shapeNow 走动画会停在 column↔split 中间态，
            // 而 frozenBox 同步一步到位 —— 两者在动画期间不同步，box 是新尺寸、
            // landscapeNow 还是旧形态，控件按错形态排布 → 「推移」复发。
            // 形态是离散枚举，本该一步到位，不做过渡。
            shapeNow = new
            // 形态变了才重算冻结盒（离散事件，非动画中间帧，现算安全）。
            let raw = OneSkin.fixedScreenSize()
            let land = CGSize(width: max(raw.width, raw.height), height: min(raw.width, raw.height))
            let port = CGSize(width: min(raw.width, raw.height), height: max(raw.width, raw.height))
            frozenBox = new.isLandscape ? land : port
        }
        // 形态是离散信号，正常只会在折叠 / 旋转时跳一次。
        // 如果连续截图里这行反复出现，就说明又有人按容器尺寸反推形态了。
        .onChange(of: shape) { _, new in
            oneSkinLog("SHAPE -> \(new.logName)")
        }
    }

    /// 画面之上的控件层：顶部条 + 底部控制条。
    /// 独立叠在 stage 外面，保证压在 PlaybackView 的 UIKit 图层之上。
    /// [mi3s] 海报换了就重载。取不到海报时是纯黑，和 One 无海报时一致。
    private func refreshBackdrop() async {
        guard let url = shown.poster else {
            // 也要先检查取消：`.task(id:)` 在 poster 变化时会取消旧任务，
            // 但旧任务可能已经跑到这里，会把新海报清成 nil。
            guard !Task.isCancelled else { return }
            posterImage = nil
            return
        }

        if let cached = await OneSkinPosterCache.shared.image(for: url) {
            guard !Task.isCancelled else { return }
            posterImage = cached
            return
        }

        var request = URLRequest(url: url)
        for (key, value) in shown.posterHeaders { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }

        // ★ 取消检查必须在 `data` 返回之后。
        // `.task(id: shown.poster)` 会在 poster 变化时取消旧任务，但 URLSession 的
        // 回调不认取消 —— 快速切集时旧请求可能后返回，把新海报覆盖成旧图。
        // 同文件里 presentationSize 的轮询任务有 `while !Task.isCancelled`，
        // 这里之前没有，是同一个文件里两套标准。
        guard !Task.isCancelled else { return }

        guard let image = UIImage(data: data) else {
            posterImage = nil
            return
        }
        await OneSkinPosterCache.shared.store(image, for: url)
        guard !Task.isCancelled else { return }
        posterImage = image
    }

    // MARK: 竖屏（一列）

    /// 同一批子视图，只换轴。
    ///
    /// 上游 `VideoDetailView.swift:1155-1162` 明确标注过这个坑：
    ///   "It used to be written once per branch (stacked, split…), which tore the view down
    ///    and rebuilt it on each move: the AVPlayerLayer left the window (AVKit answered with
    ///    a second, unwanted Picture in Picture window), playback re-ran its setup, and the
    ///    page's orientation hold was released mid-turn — the picture, and then the whole page,
    ///    drifted."
    /// 所以这里绝不能按方向分叉成两棵视图树。用 AnyLayout 只换 axis，
    /// 播放器身份在每个折叠/转向/全屏之间保持不变。
    @ViewBuilder private func stage(_ size: CGSize,
                                    fitMode: OneSkinFitMode,
                                    playerAspect: CGFloat) -> some View {
        // 关键修正：调用方传的 shape 复用了我方二开的 Duo 判据
        // （duoExpanded/sideways/portraitExpanded），在 Fig-clone 虚拟机上
        // 会把横屏误判成「竖持 fullBleed」，导致画面铺满 92%、详情栏消失。
        // One 本体没有这套 Duo 逻辑，就是简单按屏幕宽高比：横屏=双列，竖屏=单列。
        // 所以这里用**实际渲染尺寸** size 重新判断横竖，覆盖调用方传的 fullBleed。
        // OneSkinViewport 在 VM 上报的是 screen.bounds（竖屏 1031x1343），
        // 与画面实际横竖不符。改用真实 key window 尺寸判断。
        // 用 @State 缓存的稳定尺寸，不在 body 里直接读 key window：
        // 旋转时 key window bounds 每帧都在变，直接读会让比例跟着变，
        // 触发「改布局 → 再读新 bounds → 再改布局」的反馈环
        // （实测连续旋转时控件 x 在 109~593 之间乱漂）。
        // 直接用根部 GeometryReader 量到的容器尺寸。
        // 不再读 stableSize / windowSize —— 那两个来源在 VM 上是错的或不稳定的
        // （见 body 里记的两条弯路）。这里加一道合理性闸门，挡掉首帧 0 值。
        // 容器尺寸要用**屏幕**做上限钳制。
        //
        // 实测 Fig-clone 上根部 GeometryReader 报 951×669pt，而屏幕只有 678×466
        //（同样的 1.40 : 1.44 倍放大）—— `oneSkinBody` 外面有 `.ignoresSafeArea()`
        // 和一层额外的坐标容器，GeometryReader 量到的是那个更大的空间。
        // 所有列宽都按 box.width 的比例算，基准一错，三栏比例就全塌
        //（0.5334×951 = 507pt，落到 2034px 屏上直接溢出）。
        // 所以：取 GeometryReader 尺寸与窗口尺寸里**较小**的那个方向，再整体等比缩到放得下。
        // ⛔ `size`（根部 GeometryReader 的连续 proxy.size）**不再参与任何布局**。
        // 它随旋转/折叠动画每帧变，一旦拿它推导 box，控件坐标就跟着疯狂推移。
        // 下面 box 完全由「离散形态 + 静态屏幕边界」推导，size 只留作首帧兜底信号。
        // QA：`-qaOneSkinPortrait 1` 可强制走竖屏分支，用于在横屏设备上
        // 验证「选集页竖屏 / 合拢态」的版式（VM 没有旋转接口，转不了屏）。
        // 用 `object(forKey:) != nil` 判存在，不用 bool(forKey:)：
        // 实测 `-qaOneSkinPortrait 1` / `YES` 都被 bool(forKey:) 读成 false
        //（NSNumber 通过 argument domain 传入时类型不匹配），
        // 而 `-qaOneSkin` 之所以有效，是因为它就是走 bool 且值为 "1"。
        // 判「键存在」最稳。
        let forcePortrait = UserDefaults.standard.bool(forKey: "qaOneSkinPortrait") || portraitNow
        // QA：强制走横屏双列分支（`-qaOneSkinLandscape 1`）。
        // Fig-clone / 部分虚拟设备没有旋转接口，真机锁屏时又起不了 App，
        // 只能靠它把「旋转横屏后」的版式跑出来截图核对。与 qaOneSkinPortrait
        // 对称，只改版式分支与容器尺寸，不改设备方向；默认关，用户无感。
        let forceLandscape = !forcePortrait && UserDefaults.standard.bool(forKey: "qaOneSkinLandscape")
        // ★ 横竖**只认离散形态**（effectiveShape），不看任何连续尺寸的宽高比。
        //
        // 实测（Fig-clone 678×466 真实横屏）：GeometryReader 的 proxy 报 **466×678**
        //（旋转前的尺寸）；反过来 Duo 展开竖持时容器又可能报宽>高。连续尺寸
        // 既分不清「展开宽屏」和「展开横屏」，在旋转动画里还会每帧变一次，
        // 于是窗口 winX/winY 与整层控件坐标一直漂移。形态由调用方按
        // interfaceOrientation / size class 一次性定死，QA 开关是唯一覆盖入口。
        let landscapeNow = stageIsLandscape
        // ⛔ box 从 frozenBox（@State）读，只在离散事件（onAppear/形态切换）重算。
        // 不能每帧由 screen.bounds 现算：旋转动画里 screen.bounds 连续变，
        // box 每帧变 = 「横竖屏切换控件疯狂推移」复发（日志铁证见 frozenBox 注释）。
        // 首帧兜底：frozenBox 尚未初始化（.zero）时按当前形态现算一次。
        let box: CGSize = {
            if frozenBox.width > 1, frozenBox.height > 1 { return frozenBox }
            let raw = OneSkin.fixedScreenSize()
            let land = CGSize(width: max(raw.width, raw.height), height: min(raw.width, raw.height))
            let port = CGSize(width: min(raw.width, raw.height), height: max(raw.width, raw.height))
            return forcePortrait ? port
                : forceLandscape ? land
                : (landscapeNow ? land : port)
        }()
        #if DEBUG
        let _ = oneSkinLog("stage box=\(Int(box.width))x\(Int(box.height)) shape=\(effectiveShape.logName) land=\(landscapeNow) frozen=\(Int(frozenBox.width))x\(Int(frozenBox.height))")
        #endif
        // One 的真实实现（Ghidra 解析 VideoDetailPage.sub_1001d90f4 伪代码）：
        //   if (bool == 0) { HorizontalAlignment.center; HStackLayout }
        //   else           { VerticalAlignment.center;   VStackLayout }
        //   AnyLayout(...)
        // 两种排布的对齐都是 .center —— 不是 .top / .leading。
        // 之前用 .top/.leading 会让画面和详情各自贴边，视觉上完全不是 One 的样子。
        // 直接用 HStack / VStack（不用 AnyLayout）：
        // AnyLayout 的子视图高度按内容决定，画面列被压成视频内容那么高，
        // 顶部/底部控件因此被塞进中间一条。HStack + maxHeight 才能拉满整列。

        // 不能在整页外面套 ScrollView：
        // pictureColumn 的高度是「整屏」，放进 ScrollView 后控件条会被排到
        // 画面下方一整屏之外，永远看不见。滚动交给 detailColumn 自己管。
        // 合拢态只画画面列；展开态左右/上下两列。
        // 三层结构：底层是画面+详情（axis 决定左右/上下），
        // 顶层是控件（pictureControls / controlBar），与 axis 同级，因此不会被
        // PlaybackView 的 UIKit 图层单独盖住（它只盖自己那一列）。
        // 用 GeometryReader 拿**真实可用高度**：OneSkinViewport 给的是
        // screen.bounds（含被 safe area 吃掉的部分），实际可用高度更小，
        // 会让画面列比屏幕矮一截（控件条因此浮在屏幕中部）。
        Group {
            // ★ 整页铺**海报取色**底，不是纯色。
            //
            // 之前只有 `pictureColumn` 内部有 `OneSkinBackdropLayer`，它只管画面列；
            // 竖屏是上下布局，下半屏没有底色，直接透到外层的 `DetailAurora`
            // → `Backdrop()`（浅色 246,248,252）—— 那就是「底部渐隐白层」。
            //
            // ⛔ 别用 `OneSkinPalette.pageBase` 这种纯色顶在这里：
            // 试过了，它会把 One 的整页海报取色（顶部暗 → 14% 峰值 → 底部近黑
            // 的三停渐变）整个盖成一片死黑，用户立刻能看出来「背景变纯黑了」。
            // `OneSkinBackdropLayer` 才是那套取色算法，复用它，只是铺满整页。
            OneSkinBackdropLayer(image: posterImage)
                .ignoresSafeArea()

            if fullScreenNow {
                // 全屏态（One 五态里的两态：全屏横屏 / 全屏竖屏）。
                // 语义 = 画面铺满可用空间，右栏与底部胶囊条都不画，
                // 只留窗口内控件（顶部图标 / 播放组 / 进度条）。
                // 画面本身仍按片源比例用 aspectRatio 适配，不做拉伸 ——
                // One 的全屏也是 letterbox 而不是裁切。
                pictureColumn(box, landscape: landscapeNow, fullScreen: true, fitMode: fitMode, playerAspect: aspectRatio)
            } else if folded {
                pictureColumn(box, landscape: landscapeNow, fitMode: fitMode, playerAspect: aspectRatio)
            } else if effectiveShape == .fullBleed {
                // ★ 展开宽屏（Duo 摊开 + 竖持）—— 与展开横屏**明确分叉**。
                //
                // 之前 `stage` 完全没读 shape，fullBleed 和 column 画成同一棵
                // VStack 单列，所以两种展开态看起来一样（只有没人调用的
                // makeLayout 里留着 fullBleed 公式）。现在真正实现上游定义：
                // 上半屏画面全出血（窗口铺满整宽、无 2.36% 内缩），
                // 下半屏是详情 / 选集抽屉。几何仍由 OneSkinWindowGeometry 给，
                // 控件层跟着同一个窗口坐标走，不另起一套绝对坐标。
                let picH = box.height * 0.56
                let detailH = max(box.height - picH, 1)
                VStack(alignment: .center, spacing: 0) {
                    pictureColumn(CGSize(width: box.width, height: picH),
                                  landscape: false, edgeToEdge: true,
                                  fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: box.width, height: picH)
                    detailColumn(CGSize(width: box.width, height: detailH), landscape: false)
                        .frame(width: box.width, height: detailH)
                }
            } else if landscapeNow {
                // 对齐用 .top 而非 .center：detailColumn 的 ScrollView 内容
                // 通常高于列高，.center 会让它上下各溢出一半，首帧就停在中间
                // （表现为「右侧内容一进来就滚到下面」）。
                // 必须显式给两列宽度：GeometryReader 在 HStack 里没有宽度约束时
                // 会塌成最小尺寸（实测被压成 134x73 塞到右栏里）。
                // 实测三栏（2034×1398）：左列 0–1085 = 53.34%、
                // 间隙 1085–1119 = 1.67%、右栏 1119–2034 = 44.99%（合计 100%）。
                // 三栏比例必须由**外层**锁死，不能让 HStack 自行分配：
                //   One 实测 2034×1398 → 左列 0–1085 = 53.34%、间隙 1085–1119 = 1.67%、
                //   右栏 1119–2034 = 44.99%。
                // 之前只在 pictureColumn 内部 `.frame(width: colW)`，那在 HStack 里只是
                // 「理想尺寸」，HStack 会按 flex 重新分配并吃掉 spacing —— 实测左列
                // 只剩 350pt（应为 361.6pt），差值正好等于 gap（11.3pt），
                // 表现为分界从 53.34% 漂到 51.62%。
                // 加 `fixedSize` 后父级不再压缩，比例才真正生效。
                // 列宽必须**基于容器自己的宽度**按比例分配。
                //
                // 教训：曾改用「绝对 pt（按 678 口径算 361.6/11.3/305.1）」，
                // 结果 HStack 总宽只有 678pt、比容器 951pt 窄 273pt，
                // 剩余空间被两列吞掉，列缝反而跑到 60%。绝对值和容器不匹配时更糟。
                // 也不能给 HStack 加 fixedSize 锁总宽（会把布局整个打散，
                // 见交接账本 R8 的否定清单）。
                // 正确做法就是最朴素的那个：**按 box.width 的比例分**，
                // 且传给 pictureColumn 的 colW 与 HStack 分配值必须完全相同。
                let colL: CGFloat = box.width * OneSkinWindowGeometry.Metrics.columnLeft
                let gapW: CGFloat = box.width * OneSkinWindowGeometry.Metrics.columnGap
                let colR: CGFloat = box.width * OneSkinWindowGeometry.Metrics.columnRight
                HStack(alignment: .top, spacing: gapW) {
                    pictureColumn(CGSize(width: colL, height: box.height), landscape: true, fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: colL, height: box.height)
                    detailColumn(CGSize(width: colR, height: box.height), landscape: true)
                        .frame(width: colR, height: box.height)
                }
            } else {
                // 竖屏单列：画面在上、详情在下。
                // 详情列拿的是**剩余高度**，不是整屏高 ——
                // 之前传 box.height 会让 detailColumn 的 colH 等于屏高，
                // 它的 at(y) 绝对定位全挤在顶部一小块，下面大段空白
                // （实测竖屏右栏只剩 2 条文本、其余 13 段全丢）。
                let picH = pictureHeightOf(box, landscape: false)
                VStack(alignment: .center, spacing: 0) {
                    // ⛔ colH 必须传 **picH**（画面区真实高度），不能传整屏 box.height：
                    // pictureColumn 内部按 colH 算窗口坐标（winY = colH×0.091），
                    // 控件层（Chrome overlay）的根 frame 也用 colH —— 传整屏时
                    // bottomBarY = min(winH*0.928, 整屏 − winY − safe)≈1170，
                    // 全屏键落到 detailColumn 区域上被后绘的 ScrollView 盖住：
                    // 用户报的「竖屏没法全屏」就是这个。传 picH 后 winY/bottomBar
                    // 全部收敛在画面区内，几何自洽。
                    pictureColumn(CGSize(width: box.width, height: picH),
                                  landscape: false, fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: box.width, height: picH, alignment: .top)
                    detailColumn(CGSize(width: box.width, height: max(box.height - picH, 1)), landscape: false)
                }
            }
        }
        // 底部胶囊条：必须在 stage **之上**单独一层。
        // 之前它写在 pictureColumn 的 ZStack 里，与 PlaybackView(UIViewRepresentable)
        // 同层且更早绘制 → UIKit 图层把它盖住，AX 树抓不到、点击全部落空。
        //
        // ⛔ 但**不能**用 `.overlay` 挂在 `Group` 上。
        //
        // `Group` 的 modifier 是**逐个子视图**应用的。竖屏那个 `else` 分支里
        // 是 `VStack { pictureColumn; detailColumn }` —— 两个子视图，
        // 于是 overlay 被贴了两遍，AX 里就是
        //   `倍速 1x` × 2、`循环` × 2、`适应` × 2、`自动·线路1` × 2
        // （横屏走 `HStack` 同样两个子视图，只是当时没在竖屏下比对，漏了）。
        //
        // 正确做法：把 stage 包进只有一个子视图的 `ZStack`，再对那个 ZStack 挂 overlay。
        // `ZStack` 只有一个内容层，overlay 自然只有一份。
        .oneSkinOverlayOnce(alignment: .bottomLeading) {
            // 全屏态不画胶囊条：One 全屏只留画面 + 窗口内控件，
            // 倍速/循环/填充/线路这些属于选集页的选择项。
            if !fullScreenNow {
                // 2026-11-09：旋转横屏后胶囊条要跟画面列走，不能钉死在整页底部。
                // 横屏双列：贴左列底部（0.868·H）；竖屏单列：画面在上、详情在下，
                // 原来那套 0.132·H 的 bottom padding 会把 chip 行推到详情区最底下，
                // 和播放器彻底脱节。改成抬到画面列下沿。
                let barW = landscapeNow
                    ? max(min(box.width * OneSkinWindowGeometry.Metrics.columnLeft - box.width * 0.10,
                              box.width * OneSkinWindowGeometry.Metrics.columnLeft), 240)
                    : max(box.width - box.width * 0.10, 200)
                let barBottom = effectiveShape == .fullBleed
                    // 展开宽屏：胶囊条必须让开**播放器自己的底栏**。
                    //
                    // 画面列占 0.56·H，播放器的底栏（时间码 / 进度条 / 全屏键）落在
                    // 列高 0.928 处、热区半高约 13，也就是 0.56·H×0.928 − 13 的上沿。
                    // 原来写的是 `0.44·H + 8`（= 951 高时距底 434，即画面下沿以上 15pt），
                    // 实测（Duo 内屏 669×951）正好把圆钮压在左下角「0:14」上，
                    // 两个控件抢同一块像素 —— 截图逐像素量过，不是估的。
                    // 现在按播放器底栏的实际位置反推：让圆钮上沿落在底栏上方 8pt。
                    ? max(box.height - (box.height * 0.56 * 0.928 - 13 - 8), 8)
                    : landscapeNow
                        ? box.height * (1 - 0.868)
                        : max(box.height - pictureHeightOf(box, landscape: false) - 6, 8)
                controlBar
                    .frame(width: min(barW, box.width - 16))
                    .padding(.leading, box.width * (landscapeNow
                        ? OneSkinWindowGeometry.Metrics.insetLandscape
                        : OneSkinWindowGeometry.Metrics.insetPortrait))
                    .padding(.bottom, barBottom)
            }
        }
        // 横向**不加 padding**：One 实测左列从 x0 起算（左列右界 1051px = 51.67%，
        // 右栏文字从 1119px = 55.02% 起）。之前这里加了 layout.margin(≈30px)，
        // 把整页往右推了 1.5%，实测分界从应有的 51.7% 漂到 53.7%。
        // 全屏不要任何额外 padding：pictureColumn 的 .frame 是按完整
        // colW×colH 画的，外层再加 padding 会把实际可用区域压小，
        // 控件位置与命中区就对不上（实测全屏态所有按钮点击全部落空，
        // 而同样按钮在双列/合拢态都正常 —— 差别就是这个 padding）。
        // ⛔ 不要给整页加 top padding。
        //
        // 原来横屏非全屏时 `.padding(.top, 8)`：整页内容下移 8pt，
        // 屏幕最上沿露出 8pt 没人画 —— 用户报的「横屏双栏顶部一条黑色条形图层」就是它。
        // 那 8pt 的本意是「让内容避开状态栏」，但观看页已经 `.statusBarHidden(true)`，
        // 状态栏根本不在，这 8pt 只剩副作用。
        .padding(.top, 0)
        // 只为拿一个 margin 就把整个 StageLayout（7 字段 + 40 行 makeLayout）
        // 重建一遍，纯浪费。margin 的定义就是 max(10, 列宽 × 0.0147)。
        .padding(.bottom, fullScreenNow ? 0 : (landscapeNow ? OneSkinWindowGeometry.margin(forColumnWidth: box.width) : 28))
        // 顶部条带的补色放在 `body` 里（stage 外面）—— 这里的 `.background`
        // 会跟着 Group 逐个子视图生效，仍旧只填到内缩后的范围，条带照样露底色。
    }

    // MARK: 版式常量

    // MARK: One 实测常量

    // 2026-11-09：删掉 onePictureRatio / oneMinPictureHeight / StageLayout /
    // makeLayout（约 110 行死代码）。它们从未被调用，却自带第四套
    // 「size.width > size.height」横竖判据，还在 `if shape == .fullBleed`
    // 里算了一套没人用的版式 —— 正是「展开宽屏 / 展开横屏看起来没区分」的
    // 误导来源，也让读代码的人以为形态已经分流过。
    //
    // 现在：形态只由 `effectiveShape` 定，几何只由 `OneSkinWindowGeometry` 定，
    // 三态版式全部落在 `stage` 一处，可读、可改、不会再各算一份。

    /// 画面 + 控件条（横屏时是一列；竖屏时也是同一条）。

    /// 竖屏画面占用的高度（含窗口上方的状态栏留白）。
    ///
    /// One 竖屏实测（1398×2034）：窗口 y185–920，即顶部留白 9.1%、
    /// 窗口高 735px（= 1332÷1.811）。所以画面区总高 = 0.091·H + winH。
    private func pictureHeightOf(_ size: CGSize, landscape: Bool) -> CGFloat {
        guard !landscape else {
            // 横屏双列时画面列就是整列高，不用切
            return size.height
        }
        // ★ 外壳满宽后窗口宽度就是列宽。这里必须同步按满宽算窗口高度，
        // 否则画面区仍按旧的 2.36% 内缩宽度切，比真实窗口矮一截，
        // 窗口下沿会压到详情列上（竖屏最明显）。
        let winW = max(size.width, 1)
        let winH = winW / OneSkinWindowGeometry.Metrics.windowAspect
        return min(size.height * OneSkinWindowGeometry.Metrics.portraitTop + winH + size.height * 0.04, size.height * 0.72)
    }

    /// 播放器窗口内的控件层。
    ///
    /// **必须**与画面层分开、由调用方用 `.overlay` 挂在最上层。
    /// 原因：`OneSkinPlayerLayer` 是 UIViewRepresentable，它的 UIView 在合成时
    /// 排在同级 SwiftUI 内容之上（UIKit 子视图顺序不受 ZStack 声明序 / zIndex 控制）。
    /// 放在同一个 ZStack 里时，全屏态窗口铺满整屏，所有按钮都会「看得见但点不到」——
    /// 双列态因为窗口只占左列一小块、多数控件落在窗口外，问题才不明显。
    private func pictureControls(colW: CGFloat, colH: CGFloat, landscape: Bool, fullScreen: Bool,
                                 edgeToEdge: Bool = false) -> some View {
        // 控件层与画面共用**同一个几何来源**（OneSkinWindowGeometry）。
        // 以前这里和 pictureColumn 各算一份，只改一处就立刻错位。
        // edgeToEdge（展开宽屏）也必须同步带上，否则控件仍按内缩窗口定位。
        let geo = OneSkinWindowGeometry(
            size: CGSize(width: colW, height: colH),
            landscape: landscape,
            fullScreen: fullScreen || edgeToEdge
        )
        // 安全区：全屏 / 展开宽屏时窗口 (0,0) 就是屏幕 (0,0)，
        // 顶栏会压进状态栏、底栏会被 Home 指示条咬掉 —— 交给控件层夹。
        let safe = OneSkinChrome.safeInsets()
        // 2026-11-09 第二次重写：控件从「OneSkin 自己画的一排装饰图标」换成
        // `OneSkinChrome` —— 上游与二开播放器里的 21 个控件、手势、弹幕、
        // 字幕、片头片尾、视频信息、画中画、外播都接在这一个入口上。
        // One 的版式（窗口坐标系、白色细线风格、控件三点分布）原样保留。
        return OneSkinChrome(
            kit: OneSkinPlayerKit(
                session: session,
                channel: channel,
                pip: pip,
                tracks: tracks,
                layout: PlayerControlsLayout(stored: controlsOrder),
                openEpisodes: onEpisodes,
                miniPlayer: onMiniPlayer,
                toggleFullScreen: onFullScreen,
                isFullScreen: fullScreen
            ),
            winW: geo.winW,
            winH: geo.winH,
            winX: geo.winX,
            winY: geo.winY,
            colW: colW,
            colH: colH,
            landscape: landscape,
            fullScreen: fullScreen,
            safeTop: safe.top,
            safeBottom: safe.bottom,
            safeLeft: safe.left,
            safeRight: safe.right,
            // 返回分三层，一次只退一层：
            //   ① 全屏 → 走 `onExitFullScreen`（只退全屏，绝不关页）
            //   ② 合拢 → 展开，把详情与选集叫回来（用户的「退回选集页」）
            //   ③ 其余 → 才真的离开这一页
            // 这一层的意义是兜底：即使 `fullScreen` / `foldedNow` 有哪一侧读到过期值，
            // 也不会出现「点一次返回直接回主页」。
            onBack: {
                if foldedNow && !fullScreen {
                    toggleFold()
                    onFold()
                } else {
                    onBack()
                }
            },
            onExitFullScreen: {
                // 先把皮肤自己的镜像收起来（布局立刻还原）……
                withAnimation(.smooth(duration: 0.25)) { fullScreenNow = false }
                // ……再让页面把 `fullScreen` 单向置 false。两步都做，
                // 哪一侧曾经读到过期的 true 都会被这次返回清掉。
                onExitFullScreen()
            },
            onFold: {
                toggleFold()
                onFold()
            },
            onRotate: onRotate
        )
    }

    private func pictureColumn(_ colSize: CGSize, landscape: Bool, fullScreen: Bool = false,
                               edgeToEdge: Bool = false,
                               fitMode: OneSkinFitMode = .fit,
                               playerAspect: CGFloat = 0) -> some View {
        #if DEBUG
        let _g = OneSkinWindowGeometry(size: colSize, landscape: landscape,
                                       fullScreen: fullScreen || edgeToEdge)
        oneSkinLog("pictureColumn shape=\(effectiveShape.logName) col=\(Int(colSize.width))x\(Int(colSize.height)) fs=\(fullScreen) edge=\(edgeToEdge) fit=\(fitMode.rawValue) aspect=\(playerAspect) win=\(Int(_g.winW))x\(Int(_g.winH))")
        #endif
        // ===== 播放器窗口几何（2026-11-07 双方向逐像素实测，One 1.7.0）=====
        //
        // 【横屏 · 选集页双列】Figs 2034×1398（678×466pt）
        //   窗口 x35–1050  y357–915  →  w1015 h558  ratio 1.819
        //   左列 x0–1050（宽 1050 = 51.6%W），窗口左缩进 35px、右侧贴列边
        //   左列行亮度：y<357 是 backdrop(≈70)，窗口内 ≈100，y>915 回落到 36 的暗带
        //
        // 【竖屏 · 选集页单列】1398×2034（466×678pt）
        //   窗口 x33–1364  y185–920  →  w1331 h735  ratio 1.811
        //   左右各缩进 33px（= 屏宽 2.36%），上下均为内容区
        //
        // 两态共同点（2026-11-09 修正）：
        //   winW = 列宽（**外壳满宽**，竖屏满屏宽 / 横屏满左列宽，winX = 0）
        //   winH = winW ÷ 版式比例 1.819（**固定，与片源无关**；空间不够只压高度）
        // 竖屏片源由 `.resizeAspect` 在横向窗口内部两侧留黑边，
        // 绝不把窗口本身拉成竖的 —— 那正是用户报的「播放竖屏时播放器被拉高」。
        // 垂直中心仍是列高 45.5%（横屏实测 (357+915)/2/1398 = 45.5%）。
        // 竖屏实测中心 (185+920)/2/2034 = 27.2% —— 因为竖屏上方没有标题栏，
        // 窗口贴着状态栏下方开始，所以竖屏改按「顶部固定起点」而非中心定位。
        // =========================================================
        let colW = colSize.width
        let colH = colSize.height
        // ⚠️ 横竖**必须由容器决定，不能由本列决定**。
        // 横屏双列时左列是 361×466 的窄高矩形（colW < colH），
        // 若这里写 `colW > colH` 就永远判成竖屏，走 `colH*0.091` 贴顶 ——
        // 实测画面被摆到 y143 而不是 One 的 y357，差 214px 正是这个符号错误。
        // 由调用方传入容器的横竖，本函数只负责在给定空间里画窗口。

        // 内边距不再在这里算：OneSkinWindowGeometry 是窗口几何的唯一来源，
        // 它内部按横/竖屏取 insetLandscape / insetPortrait。

        // 窗口几何
        // 全屏：画面铺满可用空间，按片源比例 letterbox 居中。
        // 不是把窗口撑成屏幕比例 —— 那样 16:9 片源在 2034×1398 上会被拉伸变形。
        // 窗口几何**只有这一个来源**（详见 OneSkinWindowGeometry 的说明）。
        // 这里和 pictureControls 曾经各算一份，R10 只改了其中一处，
        // 按钮就画到画面外面去了。
        let geo = OneSkinWindowGeometry(
            size: CGSize(width: colW, height: colH),
            landscape: landscape,
            // 尺寸已与片源比例解耦，不再需要 aspectRatio。
            // edgeToEdge（展开宽屏）复用「铺满」分支拿全出血坐标：
            // winX/winY = 0、winW/winH = 整块画面区。它**不是**全屏态，
            // 控件仍按选集页样式常驻（见 pictureControls 的 fullScreen 参数）。
            fullScreen: fullScreen || edgeToEdge
        )
        let winX = geo.winX, winY = geo.winY
        let winW = geo.winW, winH = geo.winH

        // 容器必须**自己有确定的尺寸**。
        // 原来第一层是 `Color.clear` —— 它是贪婪视图，在 HStack 里会把窗口
        // 撑到父级给的全部宽度，导致 `.frame(width: colW)` 只是理想值而被覆盖：
        // 实测 HStack 给左列 507pt，视频窗口却画到 651pt 宽（x36–1954）。
        // 换成显式 frame 的 Color.clear，容器尺寸就不再由父级主导。
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: colW, height: colH)

            // 播放器窗口。
            // `zIndex(-1)` 是必须的：OneSkinPlayerLayer 是 UIViewRepresentable，
            // 它的 UIView 在合成时排在同级 SwiftUI 内容之上（UIKit 子视图顺序
            // 不受 ZStack 声明序完全控制）。不加这个，窗口内所有控件
            // （返回/全屏/合拢/•••/暂停/±10s/进度条）都会看得见但点不到 ——
            // 双列态因为窗口只占左列一小块、控件多落在窗口外，问题不明显；
            // 全屏态窗口铺满整屏，就变成"整屏按钮全部失效"。
            ZStack {
                // ⛔ 选集页画面锁定：只用 `OneSkinFixedPicture`（见
                // OneSkinWindowGeometry.swift 的 LOCKED 段）。
                //
                // 这里曾经直接挂 `OneSkinPlayerLayer` + 按片源比例的
                // `OneSkinStretchModifier`。竖屏片源在 1.819 横向窗口里会被
                // 放大约 3.2 倍、只剩中间一条，用户看到的就是「点进去看不了」。
                // 现在窗口几何恒定、画面只切 videoGravity，且整页只有这一个
                // 渲染宿主 —— 通用播放器（MobilePlayer / AVPlayerViewController）
                // 的样式改动不会再渗进选集页。
                // ★ 换集/开播失败时必须让人看见。
                //
                // `PlaybackView` 的错误 UI 在 `MobilePlayerView` 里，而 OneSkin 走
                // `stageOnly: true` 把它整块跳过了 —— 于是 `prepare()` 一失败
                // （取流超时、源站 403、格式不支持）就是**静默不更新**：
                // 旧 item 还留在 player 上（`stop()` 不清 currentItem），
                // 画面停在最后一帧、秒数照跑，看起来像「播了但没内容」。
                if let err = session?.error, !err.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20))
                        Text(err)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                        if let ep = playingEpisode {
                            Button {
                                onPlay(ep)
                            } label: {
                                Text("重试")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.9)))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: winW * 0.8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                    )
                    .frame(width: winW, height: winH)
                }

                if let avPlayer {
                    OneSkinFixedPicture(
                        player: avPlayer,
                        fill: fitMode == .fill,
                        poster: posterImage,
                        size: CGSize(width: winW, height: winH),
                        // 画中画绑这一条 layer（不是播放器那条 AVKit 载体）。
                        pip: pip
                    )
                } else {
                    OneSkinPosterWash(image: posterImage)
                }
            }
            .frame(width: winW, height: winH)
            // 窗口是硬边界：海报虚化的 blur / scaleEffect、以及 UIKit 画面层
            // 都不许画到窗口外。没有这一层时竖屏片源会整列铺开（越界）。
            .clipped()
            .offset(x: winX, y: winY)
            .zIndex(-1)

            // 底部胶囊条**不在这里画**（见 stage 里的说明）：
            // 放在 pictureColumn 的 ZStack 里会被 PlaybackView 的 UIKit 图层盖住，
            // 看得见但点不到 —— 实测点 4 个位置全部无响应。
        }
        .frame(width: colW, height: colH)
        // 压暗层必须挂在 ZStack **外面**：放在里面时它默认 zIndex 0，
        // 而播放器层是 zIndex(-1)，不透明黑会把画面整个盖住 ——
        // 这就是早期「播放竖屏没内容、必须点填充才看得到」的真正原因。
        //
        // 2026-11-09：原来 0.88 直接把整列压成死黑，把整页那张海报虚化也盖没了。
        // 现在 0.22：窗口内是自己的 OneSkinPosterWash（较亮），窗口外（上下）
        // 透出整页的海报虚化（较暗），两处同为一张海报的同色虚化，层次与 One 一致。
        .background(Color.black.opacity(0.22))
        // 控件层挂 overlay：必须画在 OneSkinPlayerLayer 的 UIKit 视图之上，
        // 否则整屏按钮都会被它挡住（详见 pictureControls 的说明）。
        .overlay {
            pictureControls(colW: colW, colH: colH, landscape: landscape,
                            fullScreen: fullScreen, edgeToEdge: edgeToEdge)
        }
        // One 的「用外部播放器打开」「复制视频链接」两项。实测菜单还含
        // 「用内置播放器播放」，我们是内置播放器本体，所以不列。
        .confirmationDialog("更多", isPresented: $showsMoreMenu, titleVisibility: .hidden) {
            if let streamURL {
                Button {
                    UIPasteboard.general.string = streamURL.absoluteString
                    copiedLink = true
                } label: {
                    Label("复制视频链接", systemImage: "doc.on.doc")
                }
                // 已安装的外部播放器才出现，未安装的不列 —— 与 One 一致
                //（它按已安装状态列出 Infuse / SenPlayer / VLC / nPlayer）。
                ForEach(OneSkin.externalPlayers, id: \.name) { entry in
                    if let target = OneSkin.externalURL(entry.scheme, streamURL),
                       UIApplication.shared.canOpenURL(target) {
                        Button(entry.name) { UIApplication.shared.open(target) }
                    }
                }
            } else {
                Text("还没有可用的播放地址")
            }
            Button("取消", role: .cancel) {}
        } message: {
            if copiedLink { Text("已复制视频链接") }
        }
        .onChange(of: showsMoreMenu) { _, open in
            if open { copiedLink = false }
        }
    }

    /// 窗口内的小图标。2026-11-09 起尺寸可由窗口宽度算出 ——
    /// 旋转横屏 / 进全屏后窗口变宽，固定 22pt 会让一排图标挤在一起，
    /// 固定 44pt 的命中区又会互相盖住。默认值保持旧观感，老调用点不受影响。
    private func overlayIcon(_ symbol: String, width: CGFloat = 22, height: CGFloat = 22, font: CGFloat = 13) -> some View {
        Image(systemName: symbol)
            .font(.system(size: font, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
    }

    private func centerButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: max(9, size * 0.42), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }

    private var controlBar: some View {
        Group {
            if controlsCollapsed {
                // 折起态：一颗圆形按钮，点开恢复整行。
                Button {
                    withAnimation(.smooth(duration: 0.22)) { controlsCollapsed = false }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OneSkinPalette.primary)
                        // 同样不要圆底蒙版，与展开态那颗 chevron 保持一致：
                        // 只画图标，命中区仍由 frame 撑到 32pt。
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    controlRow
                    // 收起按钮：不占 chip 空间，贴在整行右端。
                    Button {
                        withAnimation(.smooth(duration: 0.22)) { controlsCollapsed = true }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OneSkinPalette.tertiary)
                            // 去掉圆底蒙版：那颗灰圆看着像独立按钮，跟左边一排 chip 不是一套。
                            // 只留箭头本身，命中区仍用 frame 撑到 26pt。
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One 1.7.0 详情页右栏（横屏双列 / 竖屏下半屏共用同一棵视图）。
    ///
    /// 2026-11-09 重写：原先每个块用 `.position(x:y:)` 绝对定位，坐标是按
    /// 466pt 容器量出来的 pt 值；Fig-clone 上真实容器是 669pt，坐标不缩放，
    /// 于是文字互相压叠、剧集缩略图叠成一摞、下载/评论跑到合集上方 ——
    /// 正是用户截图里「展开横屏右栏显示内容不正确」。
    /// 改成 VStack 流式后，块序与间距由内容自己决定，容器多高都不会错位。
    ///
    /// 块序严格照 One：标题 → 当前集 → 元信息 → 继续播放 + 三个圆按钮
    /// → 标签 → 简介 → 合集头 + 横排大卡片。上一版自己加的「下载卡」
    /// 与「热门评论」占位块（含「播放页只显示真实数据，不占位」这句实现
    /// 说明）One 没有，一并删除。
    private func detailColumn(_ size: CGSize, landscape: Bool) -> AnyView {
        #if DEBUG
        oneSkinLog("detailColumn \(Int(size.width))x\(Int(size.height)) landscape=\(landscape) eps=\(episodes.count)")
        #endif
        let colW = size.width
        let colH = size.height
        // One 是非对称留白：左 5.5%、右 10%（文字右缘距列右界约 3%）。
        let pad = max(14, min(colW * 0.055, 26))
        let trailing = pad + colW * 0.045
        let innerW = max(colW - pad - trailing, 1)
        // 选集卡片：右栏约 46% 宽，一排露出下一张的半张。
        let cardW = min(max(innerW * 0.46, 128), 190)

        return AnyView(
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 顶部给状态栏和右上角两个圆按钮留位置；竖屏上半已是画面。
                    Color.clear.frame(height: landscape ? 38 : 8)

                    Text(shown.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OneSkinPalette.primary)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 9)

                    if let ep = playingEpisode ?? episodes.first {
                        Text("第 \(episodeIndex + 1) 集 · \(ep.name.isEmpty ? shown.name : ep.name)")
                            .font(.system(size: 12))
                            .foregroundStyle(OneSkinPalette.primary.opacity(0.88))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !oneMetaLine.isEmpty {
                        Text(oneMetaLine)
                            .font(.system(size: 11))
                            .foregroundStyle(OneSkinPalette.tertiary)
                            .lineLimit(1)
                            .padding(.top, 7)
                    }

                    oneActionRow(width: innerW)
                        .padding(.top, 14)

                    if !tags.isEmpty {
                        tagFlow(width: innerW, sx: 1, sy: 1)
                            .padding(.top, 15)
                    }

                    if !synopsisText.isEmpty {
                        Text(synopsisText)
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .foregroundStyle(OneSkinPalette.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }

                    if !episodes.isEmpty {
                        // ★ 整行都是按钮，不再只靠右端一颗小胶囊。
                        //
                        // 原来「选集」胶囊紧贴 `innerW` 的右缘，实测换算到屏幕
                        // 正好压在最右侧那条系统/播放器控件带下面 —— 视觉上看得见，
                        // 点击全被上层吃掉，就是「选集抽屉出不来」。
                        //
                        // 现在：合集标题 + 右侧「选集」指示，整体作为一颗**满宽**按钮，
                        // 命中区从列左内边距一直到右内边距，纵向 44pt。
                        // 按钮本体宽度由 innerW 决定，远离屏幕边缘，不再与任何浮层重叠。
                        Button {
                            #if DEBUG
                            oneSkinLog("episodes tapped n=\(episodes.count)")
                            #endif
                            onEpisodes()
                        } label: {
                            HStack(alignment: .center, spacing: 8) {
                                Text("合集 · 共 \(episodes.count) 集")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OneSkinPalette.primary.opacity(0.9))
                                Spacer(minLength: 0)
                                HStack(spacing: 4) {
                                    Text("选集")
                                        .font(.system(size: 11, weight: .medium))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(OneSkinPalette.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(episodes.enumerated()), id: \.element.id) { idx, ep in
                                    // ★ 用 Button 而不是 onTapGesture。
                                    //
                                    // 卡片在一个**横向 ScrollView** 里：`onTapGesture`
                                    // 与滚动的手势识别器会互相抢，实测点卡片常常毫无反应
                                    // （尤其卡片较窄、按下又轻微移动时）——
                                    // 用户报的「竖屏资源点不进去」就是这个。
                                    // Button 的按压识别与 UIScrollView 的滚动共存是系统级处理好的。
                                    Button { onPlay(ep) } label: {
                                        oneEpisodeCard(ep, index: idx, width: cardW)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.trailing, trailing)
                        }
                        .padding(.top, 10)
                    }

                    // ⑯ 下载卡 —— One 把它放在**选集之后**
                    Button { onDownload() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("下载")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(OneSkinPalette.primary)
                                Text("第 \(episodeIndex + 1) 集 · 保存到本机")
                                    .font(.system(size: 10))
                                    .foregroundStyle(OneSkinPalette.tertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundStyle(OneSkinPalette.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 22)

                    // ⑰ 评论区 —— 下载之后
                    Text(commentCount > 0 ? "评论 \(commentCount)" : "评论")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OneSkinPalette.primary.opacity(0.9))
                        .padding(.top, 22)
                    Text(commentPreview)
                        .font(.system(size: 11))
                        .lineSpacing(3)
                        .foregroundStyle(OneSkinPalette.tertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Spacer(minLength: 30).frame(height: 30)
                }
                .frame(width: innerW, alignment: .leading)
                .padding(.leading, pad)
                .padding(.trailing, trailing)
                // ⛔ 不要 `minHeight: colH`。
                //
                // 这是「无限推移」的**反馈环本体**：
                //   colH（来自根部 GeometryReader 的 proxy）
                //     → VStack 的 minHeight
                //     → ScrollView 内容高度
                //     → stage 高度
                //     → proxy 高度
                //     → colH 变大
                //     → 回到第一步
                //
                // 实测日志（竖屏）：`proxy=669x1005 → 1002 → 998 → 995 → 986 → 982`，
                // 高度每帧都在变且单调下降 —— 不是动画抖动，是自激收敛中的振荡。
                // 用户看到的就是「控件和 UI 一直在推移，重启才恢复」。
                //
                // 这里只需要「内容不足一屏时也顶到顶部」，用**固定最小高度**即可，
                // 绝不能引用 colH。30pt 的 Spacer 已经在末尾兜住底部间距。
                .frame(minHeight: 1, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .oneSkinNoScrollEdgeEffect()
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(width: colW, height: colH)
            // ★ 这里**不再放返回/更多**。
            //
            // 返回：系统已提供（NavigationStack 的返回手势与按钮），
            // 再画一颗「＜」是重复，用户明确要求去掉。
            // 更多「⋯」：已并入主按钮行，与收藏/下载/分享同一胶囊 ——
            // 它们是一组动作，不该分处右上角与中部两地。
        )
    }

    /// 只报上游真有的字段：年份 / 备注 / 集数。观看次数与收藏数不在 `Video` 里，不编。
    private var oneMetaLine: String {
        var parts: [String] = []
        if let year = shown.year, !year.isEmpty { parts.append(year) }
        if !shown.remarks.isEmpty { parts.append(shown.remarks) }
        if !episodes.isEmpty { parts.append("共 \(episodes.count) 集") }
        return parts.joined(separator: " · ")
    }


    /// 「继续播放」白色胶囊 + 收藏 / 下载 / 分享 灰胶囊（One 主按钮行）。
    private func oneActionRow(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let ep = playingEpisode ?? episodes.first { onPlay(ep) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(position > 0 ? "继续播放" : "播放")
                            .font(.system(size: 14, weight: .semibold))
                        if position > 0 {
                            Text("第 \(episodeIndex + 1) 集 · \(timeText)")
                                .font(.system(size: 10))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 16)
                .frame(width: max(min(width * 0.5, 160), 124), height: 46)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)

            HStack(spacing: 2) {
                Button { onFavorite() } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(isFavorite ? Color.red : OneSkinPalette.primary)
                        .frame(width: 30, height: 38)
                }
                .buttonStyle(.plain)
                Button { onDownload() } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14))
                        .foregroundStyle(OneSkinPalette.primary)
                        .frame(width: 30, height: 38)
                }
                .buttonStyle(.plain)
                Button { onShare() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundStyle(OneSkinPalette.primary)
                        .frame(width: 30, height: 38)
                }
                .buttonStyle(.plain)
                // 「更多」原本浮在右上角，与收藏/下载/分享分处两地；
                // 用户要的是「和这三个在一列」—— 它们本来就是同一组动作。
                Button { showsMoreMenu = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(OneSkinPalette.primary)
                        .frame(width: 30, height: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .background(Capsule().fill(Color.white.opacity(0.13)))
        }
    }

    /// 标签胶囊：One 是灰底无描边，不是空心描边。
    private func tagFlow(width: CGFloat, sx: CGFloat, sy: CGFloat) -> some View {
        let rows = stride(from: 0, to: tags.count, by: 5).map { Array(tags[$0..<min($0+5, tags.count)]) }
        return VStack(alignment: .leading, spacing: 7 * sx) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7 * sx) {
                    ForEach(row, id: \.self) { t in
                        Text(t)
                            .font(.system(size: max(8, 10 * sx)))
                            .foregroundStyle(OneSkinPalette.secondary)
                            .padding(.horizontal, 10 * sx)
                            .padding(.vertical, 4 * sy)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// 选集大卡片（One：封面 + 集号 + 右上播放键，下面两行集名）。
    private func oneEpisodeCard(_ ep: Episode, index: Int, width: CGFloat) -> some View {
        let title = ep.name.isEmpty ? shown.name : ep.name
        let selected = ep.id == (playingEpisode?.id ?? episodes.first?.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let posterImage {
                    Image(uiImage: posterImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
            .frame(width: width, height: width * 0.68)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(selected ? 0.95 : 0.14), lineWidth: selected ? 2 : 0.7)
            )

            Text("第 \(index + 1) 集")
                .font(.system(size: 11))
                .foregroundStyle(OneSkinPalette.secondary)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OneSkinPalette.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }

    private var episodeIndex: Int {
        guard let e = playingEpisode ?? episodes.first,
              let i = episodes.firstIndex(of: e) else { return 0 }
        return i
    }

    // MARK: 画面


    // MARK: 控制选项行（倍速 / 循环 / 填充）

    private var controlRow: some View {
        // 倍速不用 popover：tvOS 没有 popover，而且内联展开在三种屏幕上点着更准。
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { showsSpeedMenu.toggle() }
                } label: {
                    chip("倍速 " + OneSkin.label(Float(speed)), on: speed != 1)
                }
                .buttonStyle(.plain)

                Button {
                    // ⛔ bug④：原来只写 AppStorage，播放器永远不知道。session.looping
                    // 才是真正驱动「播完回零重播」的开关（PlaybackView didPlayToEnd 分支）。
                    loop.toggle()
                    session?.looping = loop
                } label: { chip("循环", on: loop) }
                    .buttonStyle(.plain)

                // One 的第 3 颗 chip：画面呈现方式。点一下在
                // 适应 → 填充 → 铺满 → 拉伸 之间循环，芯片文字跟着变。
                // **只改画面怎么画，窗口几何恒定**（1.819 横向容器）。
                Button {
                    // ⛔ 固定两档：适应 / 填充。铺满、拉伸这两档会按片源比例
                    // 缩放，竖屏片源直接被放大到看不见 —— 不再提供入口。
                    let all: [OneSkinFitMode] = [.fit, .fill]
                    let i = all.firstIndex(of: fitMode) ?? 0
                    fitMode = all[(i + 1) % all.count]
                } label: {
                    chip(fitMode.label, on: fitMode != .fit)
                }
                .buttonStyle(.plain)

                // One 第 5 颗：线路延迟，形如「自动 · 线路1 · 272 ms」
                Button {
                    showsLineMenu.toggle()
                    // 展开即测一次；One 的数字也是打开面板时现测的。
                    Task { await probeLatency() }
                } label: {
                    chip(lineLabel, on: lineLatency != nil)
                }
                .buttonStyle(.plain)

                // [mi3s] 补上游有、One 没有的功能（UI 沿用 One chip 风格）：
                // 画质切换，音轨切换。无多档时整颗隐藏。
                if let s = session, s.qualities.count > 1 {
                    let current = s.qualities.first { $0.id == s.quality }?.label ?? "自动"
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { showsQualityMenu.toggle() }
                    } label: {
                        chip("画质 · \(current)", on: showsQualityMenu || s.quality != nil)
                    }
                    .buttonStyle(.plain)
                }
                if let s = session, s.audioChoices.count > 1 {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { showsAudioMenu.toggle() }
                    } label: {
                        chip("音轨", on: showsAudioMenu)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }

            if showsSpeedMenu {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(OneSkin.speeds, id: \.self) { value in
                            Button {
                                speed = Double(value)
                                // ⛔ 双轨同步：Chrome 的 ••• 菜单走 session.setSpeed，
                                // 这里走 AppStorage。任一条改了，另一条显示的还是旧值。
                                // 统一规则：**所有**倍速变更都立即下发到当前 session，
                                // AppStorage 只做持久化/显示。
                                session?.setSpeed(Float(value))
                                withAnimation(.smooth(duration: 0.2)) { showsSpeedMenu = false }
                            } label: {
                                chip(OneSkin.label(value), on: value == Float(speed))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            // 线路选择：展开显示所有线路，**每条带自己的延迟**，最快的打标。
            // 只有一条线时隐藏（单线没有可选的）。
            if showsLineMenu, lines.count > 1 {
                let fastest = lineLatencies.min { $0.value < $1.value }?.key
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(lines, id: \.self) { line in
                            Button {
                                if line != activeLine { onSelectLine(line) }
                                withAnimation(.smooth(duration: 0.2)) { showsLineMenu = false }
                            } label: {
                                HStack(spacing: 4) {
                                    chip(line.isEmpty ? "线路" : line,
                                         on: line == activeLine || line == fastest)
                                    // 延迟：测出来才显示，测不出就留空，不写假数。
                                    if let ms = lineLatencies[line] {
                                        Text("\(ms) ms")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(line == fastest
                                                             ? OneSkinPalette.primary
                                                             : OneSkinPalette.tertiary)
                                    } else if probingLines {
                                        ProgressView().controlSize(.mini)
                                    }
                                    // 最快的那条加个标记，方便一眼选出。
                                    if line == fastest, line != activeLine {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(OneSkinPalette.primary.opacity(0.8))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            // 画质展开：Auto + 各档。
            if showsQualityMenu, let s = session, s.qualities.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        Button {
                            s.choose(quality: nil)
                            withAnimation(.smooth(duration: 0.2)) { showsQualityMenu = false }
                        } label: {
                            chip("自动", on: s.quality == nil)
                        }
                        .buttonStyle(.plain)
                        ForEach(s.qualities) { q in
                            Button {
                                s.choose(quality: q.id)
                                withAnimation(.smooth(duration: 0.2)) { showsQualityMenu = false }
                            } label: {
                                chip(q.label, on: q.id == s.quality)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            // 音轨展开。
            if showsAudioMenu, let s = session, s.audioChoices.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(s.audioChoices) { choice in
                            Button {
                                s.chooseAudio(choice.id)
                                withAnimation(.smooth(duration: 0.2)) { showsAudioMenu = false }
                            } label: {
                                chip(choice.name, on: choice.id == s.audioChoice)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        // One 实测：控件条左边缘 x28（≈9pt），第一颗 chip 文字起点 x53。
        // 之前写 16/14，chip 起点落到 x85，比 One 右了 30px。
        .padding(.horizontal, 19)
        .padding(.top, 0)
    }

    /// One 第 5 颗的文字：实测原样是「自动 · 线路1 · 272 ms」。
    /// 还没测出延迟时只显示线路，不留一个假的毫秒数。
    private var lineLabel: String {
        let index = max(lines.firstIndex(of: activeLine) ?? 0, 0) + 1
        let line = lines.isEmpty ? "线路\(lineIndex)" : "线路\(index)"
        if let ms = lineLatency {
            return "自动 · \(line) · \(ms) ms"
        }
        return "自动 · \(line)"
    }

    /// 实测延迟。One 面板上的毫秒数是真的：用 HEAD 只拿响应头，不拉流。
    ///
    /// 不用 GET 打第一条字节，是因为 HLS 的首包还要等项目解析，
    /// 那个数会把「网络延迟」和「播放器开销」混在一起 —— One 显示的
    /// `1288 ms` 这类大数恰恰说明它是整条链路耗时，所以我们两次都测：
    /// 先测握手（真实网络），失败就退回整条 HEAD。
    /// 并发测**每一条线路**的延迟。
    ///
    /// 以前只测当前这条（`streamURL`），其余线路没有数字，用户无法比较、
    /// 也就谈不上「自动选最快」。现在按 `lineSamples` 逐线发 HEAD：
    ///  · 并发，互不阻塞；单条超时 6s 不影响其它；
    ///  · 拒绝 HEAD 的 CDN（常见）退回 Range: bytes=0-0 的 GET；
    ///  · 结果写进 `lineLatencies`，当前线路同步到 `lineLatency`（chip 用）。
    private func probeLatency() async {
        guard !probingLines else { return }
        await MainActor.run { probingLines = true }
        defer { Task { @MainActor in probingLines = false } }

        // 没有逐线样本时，至少把当前这条测了（保持旧行为）。
        var targets = lineSamples
        if targets.isEmpty, let u = streamURL {
            targets = [activeLine.isEmpty ? "线路1" : activeLine: OneSkinLineSample(url: u, headers: streamHeaders)]
        }
        guard !targets.isEmpty else { return }

        let results = await withTaskGroup(of: (String, Int?).self) { group in
            for (name, sample) in targets {
                group.addTask { (name, await Self.measure(sample)) }
            }
            var out: [String: Int] = [:]
            for await (name, ms) in group {
                if let ms { out[name] = ms }
            }
            return out
        }

        await MainActor.run {
            lineLatencies.merge(results) { _, new in new }
            lineLatency = lineLatencies[activeLine] ?? lineLatencies.values.min()
        }
    }

    /// 单条线路的往返耗时（毫秒）。失败返回 nil，不编造数字。
    private static func measure(_ sample: OneSkinLineSample) async -> Int? {
        var head = URLRequest(url: sample.url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        head.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (k, v) in sample.headers { head.setValue(v, forHTTPHeaderField: k) }

        let t0 = Date()
        if let (_, resp) = try? await URLSession.shared.data(for: head),
           (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 {
            return Int(Date().timeIntervalSince(t0) * 1000)
        }

        // HEAD 被拒（部分 CDN 只允许 GET）：退一个 1 字节 Range，读完头部即取消。
        var get = URLRequest(url: sample.url)
        get.httpMethod = "GET"
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        get.timeoutInterval = 6
        get.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (k, v) in sample.headers { get.setValue(v, forHTTPHeaderField: k) }
        let t1 = Date()
        if let (_, resp) = try? await URLSession.shared.data(for: get),
           (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 {
            return Int(Date().timeIntervalSince(t1) * 1000)
        }
        return nil
    }

    /// One 的 chip 不是胶囊按钮。
    ///
    /// 实测（2034×1398，y1175-1265 逐段取样）：
    ///   循环     底色 #131315（近纯黑）、文字 #F7F7F9（纯白）→ **无底、无描边**
    ///   自动全屏 底色 #000D1C（深蓝黑）、文字 #1A6CC7（蓝）→ 开启态是蓝字
    /// 之前做的「半透明胶囊 + 描边 + 绿色高亮」是错的，One 一个都没有。
    private func chip(_ title: String, on: Bool, accent: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 13, weight: on ? .semibold : .regular))
            // 开启态：一般项提亮到纯白，带 accent 的（自动全屏）走蓝
            .foregroundStyle(
                on
                    ? (accent ? OneSkinPalette.autoBlue : OneSkinPalette.primary)
                    : OneSkinPalette.secondary
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                // 只有 accent 项在开启时带一层极深蓝底（实测 #000D1C）
                Capsule().fill(on && accent ? OneSkinPalette.autoBlueDeep : Color.clear)
            )
    }

    // MARK: 标题与统计


    /// 简介文本。优先用 `detail` 的完整简介：列表页给的 `video.synopsis` 常常是截断的短版。
    private var synopsisText: String {
        if let full = detail?.synopsis, !full.isEmpty { return full }
        return shown.synopsis
    }

    /// 评论条数。上游 `Video` 没有评论接口，没有真值就显示「评论」不带数字，
    /// 不编假数据。
    private var commentCount: Int { 0 }

    /// 评论正文。上游没有评论接口时给一句真实状态，而不是硬编一条假评论。
    private var commentPreview: String {
        "还没有加载评论。播放页只显示真实数据，不占位。"
    }
    // MARK: 主按钮


    // MARK: 标签

    /// 上游把分类塞在 `Video.category`，逗号分隔；没有就不画这一行。
    /// 标签。One 的标签云来自三个字段，不是只有 `category`：
    ///   分类（逗号分隔）+ 年份 + 备注（更新至 N 集这种）
    /// 之前只读 `category`，QA 夹具里没有这个字段 → 标签区整块不渲染，
    /// 真机/VM 截图上表现为「One 有两行胶囊，我们什么都没有」。
    private var tags: [String] {
        var out: [String] = []
        if let category = shown.category {
            out += category.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let year = shown.year, !year.isEmpty { out.append(year) }
        if !shown.remarks.isEmpty, !out.contains(shown.remarks) { out.append(shown.remarks) }
        return out
    }


    // MARK: 集数条



}

/// iOS 26+ ScrollView 自动在滚动边缘挂系统毛玻璃（ScrollEdgeEffectView），
/// 右栏标题会被它压住（“透明板 + 下拉才见内容”）。低版本无此效果，原样返回。
extension View {
    @ViewBuilder
    func oneSkinNoScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden()
        } else {
            self
        }
    }
}

// MARK: - 旋转期间的尺寸冻结

/// 旋转/折叠过程中，容器尺寸是**逐帧插值**的：678×466 → 467×677 中间会出现
/// 550×580、520×600… 每一帧都不重复。
///
/// 页面里所有控件坐标都由这个尺寸算出（`OneSkinWindowGeometry` 全部以 colW/colH
/// 为输入）。于是动画期间每帧都是「一套几何」，控件看起来在**无限推移**——
/// 这就是用户反复报的那个 bug，历史上改过多次都没解决，因为改的都是
/// 「按哪个值算」，而问题在于「**根本不该按中间值算**」。
///
/// `quantize` 只做 0.5pt 取整，对连续插值毫无收敛作用。
///
/// 正解：**只在尺寸稳定后提交一次**。用一个小的 `@Observable` 持有「已提交尺寸」，
/// 容器连续变化时先不动，等到某一帧与上一帧完全相同（动画结束）再一次性写入。
/// 这样整个动画期间几何只算一次，控件定位一次到位，不会中途重排。
@MainActor
@Observable
final class StableStageSize {
    /// 已提交的尺寸。动画期间保持不变。
    private(set) var committed: CGSize = .zero
    /// 上一帧看到的原始尺寸，用来判断「是否还在动」。
    @ObservationIgnored private var lastSeen: CGSize = .zero
    /// 上次提交时的**离散形态**。形态不变就永久冻结，不再接受任何测量值。
    @ObservationIgnored private var epoch = ""
    /// 形态刚变化后的短收敛窗口；窗口关闭即冻结。
    @ObservationIgnored private var settling = false

    /// ⛔ 2026-11-09：旧实现只判「连续两帧相同」，旋转动画里会出现**假稳定**
    ///（插值恰好连续两帧落在同一值），于是又提交一套中间几何，推移继续。
    /// 现在把「离散形态」作为唯一开闸条件：同形态内零提交，形态变化后
    /// 只修正一次终值，然后冻结到下次形态变化。这才是切断闭环，不是再滤一次。
    @discardableResult
    func feed(_ raw: CGSize, epoch: String) -> Bool {
        guard raw.width > 1, raw.height > 1 else { return false }
        if committed == .zero {
            // 首帧：没有可比对象，直接提交，避免空布局。
            committed = raw
            lastSeen = raw
            self.epoch = epoch
            settling = true
            return true
        }
        if epoch != self.epoch {
            // 形态切换：立即采用新尺寸，并开一次收敛窗口。
            self.epoch = epoch
            settling = true
            lastSeen = raw
            if committed != raw { committed = raw; return true }
            return false
        }
        guard settling else { return false }
        if raw == lastSeen {
            // 收敛窗口内首次稳定：修正一次终值，之后永久冻结。
            settling = false
            if committed != raw { committed = raw; return true }
            return false
        }
        lastSeen = raw
        return false
    }
}


private extension View {
    /// `overlay` 的**只画一份**版本。
    ///
    /// `Group` 上的 modifier 是逐个子视图应用的：`Group { if a { VStack { x; y } } }`
    /// 里 overlay 会被分别贴到 `x` 和 `y` 上 —— 同一个胶囊条画两遍。
    /// 这里先用 `ZStack` 把内容裹成**单独一个**视图，再对它挂 overlay，
    /// 于是无论内部有多少分支、多少子视图，覆盖层都只有一份。
    @ViewBuilder func oneSkinOverlayOnce<V: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> V
    ) -> some View {
        ZStack(alignment: alignment) {
            self
            content()
        }
    }
}
