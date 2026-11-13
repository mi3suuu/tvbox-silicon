import SwiftUI
import os
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
    /// 「自动全屏」开关（参考截图里那颗蓝底蓝字的 chip）。
    /// 开启后**开播即进全屏**；关掉只影响自动行为，手动全屏键照旧。
    static let autoFullScreenKey = "oneSkinAutoFullScreen"

    /// 竖持时「视频 + 所有控件」整体下移的额外留白（pt）。
    ///
    /// 用户要求：「视频播放器和其他控件一起 往下移动一些」。
    /// 因为画面层与控件层共用 `OneSkinStage.portraitTopInset`，改这一个数
    /// 就能让两者同步下移，不会错位。
    static let portraitExtraDrop: CGFloat = 16

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
    /// POSTURE 探测用：当前安全区（一次读全四条边）。
    @MainActor static func safeInsetsForProbe() -> EdgeInsets {
        let win = UIApplication.shared.appWindowScene?.windows.first { $0.isKeyWindow }
            ?? UIApplication.shared.appWindowScene?.windows.first
        let ins = win?.safeAreaInsets ?? .zero
        return EdgeInsets(top: ins.top, leading: ins.left, bottom: ins.bottom, trailing: ins.right)
    }

    @MainActor static func fixedScreenSize() -> CGSize {
        // ★★★ 几何基准必须是**可用区域**，不是 `screen.bounds`。
        //
        // 用户指出的关键：外屏「溢出状态栏」。坐实如下 ——
        //   `screen.bounds` 是**含状态栏 + Home 指示条**的物理全屏：
        //     外屏竖持 466×678，其中状态栏 59 + Home 34 = 93pt 不可用于内容
        //     内屏 951×669，状态栏 24 + Home 20 = 44pt
        //   而 `oneSkinBody` 上的 `.ignoresSafeArea(edges: [.top, .horizontal])`
        //   **只忽略上边和左右，底部没忽略**，再叠 `.padding(.bottom, 36)`。
        //
        //   于是按 `screen.bounds.height` 排版的内容，比真实可用区**高出**
        //   （底部安全区 + 36pt padding），必然「内容 > 容器」→ 重协商 → 环。
        //   外屏竖持最严重：678 的内容塞进 549 可用，**溢出 129pt**。
        //
        // 正解：把底部不可用部分从高度里扣掉。顶部已在 `.ignoresSafeArea(.top)`
        // 里被忽略，所以**只扣底部**（左右同理，`.horizontal` 已忽略，不扣宽）。
        //
        // 这是**纯静态计算**（window + safeAreaInsets 都是离散量），不读容器，
        // 因此不构成环 —— 与 B 站 `setupModule(window:)` 同一路数。
        // 只返回**物理全屏**；安全区由 `availableScreenSize()` 单独处理，
        // 因为「扣哪条边」取决于形态（竖持扣底、横持扣右）。
        // ⛔ 绝不在这里读 `cachedLiveContainer`（容器实测值）！
        //
        // 实测证据（Fig, 2026-11-12，加了这个读法之后）：
        //   proxy  = 22153 × 13432      ← 物理屏 466×678 的 51 倍
        //   screen = 23872 × 13752      ← 51.2 倍 / 20.3 倍（宽高倍数不同 ⇒ 正反馈发散）
        //   dt     = 12–21ms            ← 每秒 50–80 次重排
        //
        // 成因是完整闭环：
        //   cachedLiveContainer → fixedScreenSize() → box → 视图 frame
        //        ↑                                              ↓
        //        └────────── .onGeometryChange 量 frame ─────────┘
        // 而 `.onGeometryChange` 量的是**视图最终 frame**，该 frame 又被这里决定，
        // 于是每轮放大一次 —— 正是本项目早先那条警告说的：
        //   「不许把 onGeometryChange 挂在这个 body 上 … 用它驱动布局，
        //     等于把内容尺寸又喂回布局，环照旧」。
        //
        // `screen.bounds` 虽不精确（内屏恒报原生竖持），但它是**离散静态量**，
        // 绝不参与 feedback ⇒ 不可能成环。精度问题改在其他地方解决。
        // ★★ 决定性修正：读**窗口**尺寸，不读 `scene.screen.bounds`。
        //
        // 真机日志铁证（2026-11-12，Duo，ROOT 行交替出现）：
        //   帧A screen=592x680 → shape=split
        //   帧B screen=672x488 → shape=fullBleed
        //   帧C screen=592x680 → shape=split      ← 1.3ms 一轮，永不收敛
        // `screen.bounds` 本应是常量，却在两个值之间跳 —— 因为
        // `appWindowScene` 在 Duo 两块屏之间切换（两屏都报 foregroundActive，
        // 取到的那块不同，screen 就不同）。而 screen 又经 availableSize 影响
        // stage 尺寸 → 视图 frame → 影响谁成为 keyWindow → scene 再跳。
        //
        // `keyWindow.bounds` 是**当前承载内容那个窗口**的尺寸，
        // 不受"哪块屏自居 active"的竞争影响，是这一帧真实可用的逻辑尺寸。
        // 仍不参与 feedback（UIKit 所有，不被 SwiftUI 重排改变）。
        let win = UIApplication.shared.appWindowScene?.keyWindow?.bounds.size
        if let win, win.width > 1, win.height > 1 { return win }
        return UIApplication.shared.appWindowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
    }

    /// 由 `VideoDetailView` 的 `.onGeometryChange` 写入的最近容器尺寸。
    /// 静态是为了让 `fixedScreenSize()`（静态方法）能读到；
    /// 只在主线程写，且已量化到 8pt 桶。
    @MainActor static var cachedLiveContainer: CGSize?

    /// 按形态给出**真正可用于排版的尺寸**（已扣掉该形态下让给系统/标签栏的边）。
    ///
    /// `oneSkinBody` 上的 `.ignoresSafeArea(edges: [.top, .horizontal])`：
    ///   · 顶部与左右**已被忽略** → 这两条边不用扣
    ///   · **底部没有被忽略** → 底部安全区 + 标签栏预留必须扣掉
    ///
    /// 竖持：底边让给 Home 指示条 + 底部浮动胶囊 → 扣 `bottom`
    /// 横持：底边只有 Home 条（高度很小），主要让位在**右缘**竖排胶囊 → 扣 `right`
    ///
    /// 这是纯静态计算，不读容器 ⇒ 不构成环。
    @MainActor static func availableScreenSize(landscape: Bool) -> CGSize {
        let scene = UIApplication.shared.appWindowScene
        let b = scene?.screen.bounds.size ?? UIScreen.main.bounds.size
        let ins = scene?.windows.first?.safeAreaInsets ?? .zero
        // `screen.bounds` 在 Duo 上不随方向交换，先按物理长/短边归位。
        let long = max(b.width, b.height), short = min(b.width, b.height)

        // ⛔ 横持**不能扣 `ins.right`**。
        //
        // 实测（Duo 内屏横持）：`ins.right = 71pt`，`951 − 71 = 880`，
        // 于是 stage box 只有 880×592，而真机截图里内容是从 x=0 铺到 x=951 的。
        // 全部右栏控件因此左移 71pt —— 这就是「坐标完全对不上」。
        //
        // 原因：`oneSkinBody` 上有 `.ignoresSafeArea(edges: [.top, .horizontal])`，
        // **左右已经被忽略**，`ins.right` 那 71pt 早已让出来了，再扣一次就是重复。
        // 顶部同理已忽略，不扣。
        // 真正没被忽略、必须让的只有**底部**（Home 条 + 浮动胶囊）。
        if landscape {
            // 横持：长边为宽，只用底部让位。
            let w = long
            let h = short - ins.bottom
            return CGSize(width: max(w, 1), height: max(h, 1))
        } else {
            // 竖持：短边为宽，底部让位（Home 条 + 浮动胶囊）。
            let w = short
            let h = long - ins.bottom
            return CGSize(width: max(w, 1), height: max(h, 1))
        }
    }

    /// 把尺寸量化成**离散桶**（对应哔哩哔哩折叠屏适配里的 `lastHingeStatus`）。
    ///
    /// 参考：哔哩哔哩 9.18.0 用 `HingeStatus` 枚举 + `lastHingeStatus` 缓存，
    /// 只有折叠状态**真的改变**才重排（`_foldableRelayoutForOcclusion` /
    /// `_foldableUpdateMiniScreenFrame` 都由状态变化驱动）。
    /// 我们这边没有 hinge 枚举，但几何诉求相同：**连续抖动不该变成连续重排**。
    ///
    /// 做法：四舍五入到 `step` 的整数倍。
    ///   · 容器抖 ±7pt 以内 → 同一个桶 → `stage` 收到完全相同的值 → 不重建
    ///   · 真正旋转/折叠 → 跨桶 → 立刻跟上
    ///
    /// `step` 取 8 是有意的：
    ///   · 太小（1–2）吸收不了实测的抖动幅度（每帧 2–14pt）
    ///   · 太大（≥16）会让形态切换看出「跳一下」
    static func stableBucket(_ size: CGSize, step: CGFloat) -> CGSize {
        guard step > 0, size.width.isFinite, size.height.isFinite else { return size }
        // 桶下限 step：绝不让可用空间塌成 0（那会让整页不可见）。
        // 宽度也必须**向下**取整：`rounded()` 会让 669→672（+3），
        // 桶比容器**宽**，等于主动制造 «内容超出容器» → 触发重协商。
        // 高度早已是 floor，宽度漏了 —— 这条独立于任何形态都会生效。
        let w = max(step, (size.width / step).rounded(.down) * step)
        // ★ 高度**不独立取整**，而是先算出「宽方向取整带来的余量」，让高度
        //   把余量吃掉，保证 <= 原值且总和不变。
        //
        // 为什么：半折形态把可用高度按 `halfFoldSplitRatio` 切成上下两半，
        // 若宽高各自独立四舍五入，两半可能变成 952 而容器只有 951 ——
        // 折痕正好在视觉中心，1–4pt 的缝或压边一眼就能看出来。
        //
        // 取 `floor` 而非 `rounded`：宁可少 1–7pt（多出的由 ZStack 居中吸收），
        // 也绝不超过容器（超出才会触发父容器重新协商 → 环）。
        let h = max(step, (size.height / step).rounded(.down) * step)
        return CGSize(width: w, height: h)
    }

    /// 量化到 0.5pt：旋转 / 折叠动画里的亚点抖动不该触发整页重排。
    private static func quantize(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * 2).rounded() / 2,
               height: (size.height * 2).rounded() / 2)
    }

    /// 注：**没有 `landscape` 参数**（2026-11-12 移除）。
    /// 方向与尺寸来自不同信号，同帧不保证一致；钳制只该看「是否超出物理屏」。
    @MainActor static func availableSize(proxy: CGSize, screen: CGSize, fullScreen: Bool = false) -> CGSize {
        // 语义：`proxy` 是**本次排版想用的空间**（调用方已按形态整形过），
        // `screen` 只做「不超出物理屏」的兜底。**绝不放大，只夹小。**
        //
        // ⛔ 三个已踩过的坑，别回头：
        //   ① 只夹宽不夹高 → proxy 高 839 漏过去，内容 839 铺 678 容器 → 成环
        //   ② 用 `screen.height` 夹高 → Duo 内屏 screen.bounds 物理固定 951×669
        //      不随方向交换，竖持 proxy=669×951 会被砍成 669×669（丢 282pt）
        //   ③ `max(proxy.width, screenShort)` → 恒等于 proxy.width，
        //      宽度钳制变成空操作（`min(x, max(x,a)) ≡ x`），侧栏 977 防护归零
        //
        // 现在：**按形态把上限分到两条轴上**，两维都 `min`，都真的能夹。
        guard proxy.width > 1, proxy.height > 1 else {
            return quantize(screen.width > 1 && screen.height > 1 ? screen : proxy)
        }
        let screenLong = max(screen.width, screen.height)
        let screenShort = min(screen.width, screen.height)
        guard screenLong > 1 else { return quantize(proxy) }
        // 全屏与分栏共用同一套上限：只是「不超出物理屏」，
        // 全屏「不缩放」的原意由调用方（proxy 已铺满）保证，不靠这里绕开。
        //
        // ★ 2026-11-12 修正：原来两维上限都用**屏幕长边**，于是
        //   竖持（951 长边）时高度那一维的钳制恒为真 —— `proxy.height ≤ 951`
        //   在正常竖持下永远成立，那行 `min` 是**空操作**，注释里承诺的
        //   「两维都真的能夹」只兑现了一半；宽度那一维反过来又放到 951，
        //   竖持 669 宽的容器根本用不到，等于没防住横向溢出。
        //
        // 正确做法是把上限**按形态分轴**，与 `OneSkinGeometry.box` 同一公式：
        //   · 横持：宽 = 长边，高 = 短边
        //   · 竖持：宽 = 短边，高 = 长边
        // 两种情况都恰好等于 `box` 的标称宽高，所以正常路径**一个字都不会被夹**
        // （不会在转屏中间帧突然缩一截）；只有 proxy 被外部撑大时才生效：
        //   · 侧栏把内容区撑到 977 宽 → 横持夹回 951 ✓
        //   · 竖持 proxy 高 1100 → 夹回长边 ✓（旧代码这里其实也能夹，因为长边就是 951）
        // ★★ 2026-11-12 纯代码审查修正：**不再用 `landscape` 分轴**。
        //
        // 旧实现 capW/capH 由 `landscape` 决定，而 `landscape`
        // （`stageIsLandscape`，源自 `shape` 参数）与尺寸（`proxy.size`，
        // 源自容器）是两个独立信号，**没有机制保证同帧一致**：
        //   · `shape` 由父视图传入，先变；
        //   · `proxy.size` 要等系统重新布局才变。
        // 形态切换的过渡帧必然出现「横持判据 + 竖持尺寸」的组合：
        //   proxy=669x951 + landscape=true  → capH=screenShort → 高度被砍
        //   proxy=951x669 + landscape=false → capW=screenShort → 宽度被砍
        // 两种都塌成 669x669，下游 box 缩小 → 分栏基准错 → 全部坐标缩水。
        //
        // 新实现：**只按"是否超出物理屏"钳制，与方向无关**。
        //   上限 = max(屏幕长边, proxy 短边)
        //   · proxy 短边以内一律放行（内容按物理屏排版，窗口只是显示区）
        //   · 只有真正撑出物理屏长边才夹（原始防护：sideways 撑到 977）
        //
        // 四类验算（screen=951x669）：
        //   (951,669)->(951,669)  (669,951)->(669,951)
        //   (678,466)->(678,466)  (977,669)->(951,669) 夹
        _ = screenShort
        let floorDim = min(proxy.width, proxy.height)
        let cap = max(screenLong, floorDim)
        let clamped = CGSize(width: min(proxy.width, cap),
                            height: min(proxy.height, cap))
        return quantize(clamped)
    }

    /// 用**真实容器**给盒子做上限（16.8）。
    ///
    /// 场景：Split View / Slide Over / PiP / 侧栏把内容区砍掉一大块，
    /// 而几何只读 `keyWindow`（窗口 951），系统实际只给 475 —— 内容溢出 476pt。
    ///
    /// 三条防成环的护栏（缺一条就会把「容器测量」重新拉回成布局输入）：
    ///   ① 容器尺寸必须是 **8pt 桶**（`commitLiveContainer` 已量化）；
    ///   ② 只在容器**明显更小**（>16pt）时才夹 —— 正常态容器 = 盒子，
    ///      相差的只有底部安全区取整那几 pt，绝不能参与运算；
    ///   ③ 容器与盒子**方向必须一致** —— 转屏瞬间 `cachedLiveContainer` 还是上一方向，
    ///      拿它夹会把横屏宽 951 夹成竖屏的 669。
    @MainActor static func cappedToContainer(_ box: CGSize, container: CGSize?) -> CGSize {
        guard let c = container, c.width > 1, c.height > 1 else { return box }
        guard (c.width > c.height) == (box.width > box.height) else { return box }
        let w = c.width < box.width - 16 ? c.width : box.width
        let h = c.height < box.height - 16 ? c.height : box.height
        guard w != box.width || h != box.height else { return box }
        return stableBucket(CGSize(width: w, height: h), step: 8)
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

/// 「用外部播放器打开」面板 —— 真机是**右侧滑出的深色竖排**。
///
/// 几何来自桌面截图 OCR（「展开横屏双栏 暂停选触发按钮」，951×669）：
///   · 面板贴右缘，文字 x=760（右栏 523..951 的 55% 处）
///   · 每行行距 **41.7pt**，行高 44
///   · 每行 = 左侧图标 + 文字，白字 15pt
///   · 深色底 `#1A1A1C`，圆角 14
///
/// 只列**已安装**的外部播放器（`canOpenURL` 判定）——真机也是这个行为，
/// 没装的 App 不出现，避免用户点了没反应。
struct OneSkinExternalPanel: View {
    let streamURL: URL?
    let onCopy: () -> Void
    let onDismiss: () -> Void

    /// 真机行距实测 41.7，取 42 便于对齐。
    private let rowHeight: CGFloat = 42
    private let panelWidth: CGFloat = 236

    private var installed: [(name: String, target: URL)] {
        guard let u = streamURL else { return [] }
        return OneSkin.externalPlayers.compactMap { entry in
            guard let t = OneSkin.externalURL(entry.scheme, u),
                  UIApplication.shared.canOpenURL(t) else { return nil }
            return (entry.name, t)
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 遮罩：点空白关掉（真机也有）
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("用其他播放器播放")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OneSkinPalette.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ForEach(installed, id: \.name) { item in
                    Button {
                        UIApplication.shared.open(item.target)
                        onDismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(OneSkinPalette.secondary)
                                .frame(width: 22)
                            Text("用 \(item.name) 播放")
                                .font(.system(size: 15))
                                .foregroundStyle(OneSkinPalette.primary)
                            Spacer(minLength: 0)
                        }
                        .frame(height: rowHeight)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if installed.isEmpty {
                    Text("未检测到已安装的外部播放器")
                        .font(.system(size: 13))
                        .foregroundStyle(OneSkinPalette.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                Divider().overlay(OneSkinPalette.buttonStroke).padding(.vertical, 4)

                Button {
                    onCopy()
                    onDismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 15))
                            .foregroundStyle(OneSkinPalette.secondary)
                            .frame(width: 22)
                        Text("复制视频链接")
                            .font(.system(size: 15))
                            .foregroundStyle(OneSkinPalette.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: rowHeight)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)
            }
            .frame(width: panelWidth)
            .background(OneSkinPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(OneSkinPalette.buttonStroke, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
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
/// body 重算探针的计数器。放文件级是为了不引入新的 @State（那本身会变成重算源）。
///
/// 单看「body 被调用多少次」无法区分「用户操作触发」与「自反馈环」；
/// 带序号与时间戳之后，相邻两次的 dt 直接读出环的速度：
///   dt ≈ 16 ms  → 每帧一次 = 自反馈环
///   dt 很大/为负 → 离散事件（用户点击、形态切换）
enum ROOTRecomputeProbe {
    nonisolated(unsafe) static var n = 0
    nonisolated(unsafe) static var last: TimeInterval = 0
}

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

    /// 单文件硬上限 4MB：超过就整体轮转（删旧、留最后 2MB）。
    /// 之前无上限，实测一次环路就能写到 8.4MB —— 既是取日志的障碍，
    /// 也反过来成了「是否成环」的量化指标：正常使用几小时才几百 KB。
    static let maxBytes = 4 * 1024 * 1024
    static let keepBytes = 2 * 1024 * 1024

    static func log(_ s: String) {
        // 同时走 os_log，真机可用 `devicectl device console` 实时抓。
        #if os(iOS)
        os_log("%{public}@", log: OSLog(subsystem: "wda.prdc.yingxia", category: "OneSkin"), type: .debug, s)
        #endif
        queue.async {
            let line = s + "\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                   size > maxBytes, let all = try? Data(contentsOf: url) {
                    try? all.suffix(keepBytes).write(to: url)
                }
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
    /// 只在**横持或全屏**时隐藏状态栏；竖持选集页保留。
    ///
    /// 参考哔哩哔哩 9.18.0（实测反汇编）：
    ///   · `BBPhoneMPZonePlayerVC`（外屏竖屏页）**既不实现** `prefersStatusBarHidden`
    ///     **也不实现** `prefersHomeIndicatorAutoHidden` —— 竖屏时状态栏保留，
    ///     内容铺到状态栏下方、顶部控件自己按 safeArea 内缩。
    ///   · `BBPhoneMPZoneFullScreenPlayerVC`（全屏兄弟类）两个都实现 —— 全幅。
    ///
    /// ⛔ 竖持不能无条件隐藏：状态栏一藏，`safeAreaInsets.top` 会塌成 0
    ///    （或只剩开孔高度），顶栏瞬间跳到物理顶边 —— 用户看到的就是「坐标不对 / 跳一下」。
    ///
    /// One 原版的竖持版式留白是 `屏高 × 0.091`（外屏 61.7pt / 内屏 86.5pt，
    /// 与 `OneSkinWindowGeometryCore` 注释里的实测值逐位吻合），
    /// **不是** iOS 的安全区（内屏 safeArea.top 只有 24pt，差 62.5pt）。
    /// 所以必须保留状态栏、再由 0.091 显式留白，两者不能互相顶替。
    @ViewBuilder func oneSkinStatusBarHidden(hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
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

    /// 半折（书本 / 帐篷）：折痕是一条**横带**，屏幕被上下分成两半。
    ///
    /// 与前三态的区别不在尺寸而在**铰链方向**：
    ///   · `split` 是左右两屏（竖折痕）→ 左右双列
    ///   · `halfFold` 是上下两屏（横折痕）→ 上半看画面、下半是控制台
    ///
    /// 判据来自 `GeometryProxy.reservedRegions(kind: .division)`：
    /// 横带中心落在容器 25%–75% 之间才算半折（贴顶/贴底的横带是状态栏或
    /// 手势条，不是折痕）。这一支必须排在 `duoExpanded` 之前 ——
    /// 半折时 size class 仍报 regular，若先走 `duoExpanded` 会被当成
    /// 「摊开竖持」，画面铺满整屏而控制台整个消失。
    ///
    /// 它不是横屏：铰链转了 90°，但用户是**竖着拿**的（帐篷立起来），
    /// 所以 `isLandscape` 仍为 false —— 与 `fullBleed` 同类。
    case halfFold

    /// 只有 split 是横向双列。fullBleed / halfFold 都不是横屏，不要按横屏排版。
    var isLandscape: Bool { self == .split }

    var logName: String {
        switch self {
        case .column:    return "column/竖持手机·折叠"
        case .split:     return "split/展开横屏·手机横持"
        case .fullBleed: return "fullBleed/展开宽屏·竖持"
        case .halfFold:  return "halfFold/半折·书本帐篷"
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

    /// 系统报的遮挡（挖孔 / 摄像头 / 系统胶囊），四边内缩。
    ///
    /// ★ 16.1：遮挡**只允许有一个消费端**。这里选几何层 ——
    ///   `OneSkinGeometryDriver.occlusionDidChange` 把它写进 `box`，
    ///   于是所有内容（画面列、详情列、控件、胶囊条）一起避开，
    ///   不存在「算出来了、皮肤却按原高排」的半套实现。
    ///   页面上那个 `.occlusionTopUp(.safeAreaPadding)` 已删除：
    ///   两个皮肤本体都是 `.ignoresSafeArea([.top, .horizontal])`，
    ///   那几条补量本来就不生效，只剩底部会莫名压缩内容高度。
    var occlusion: OcclusionInsets = .zero

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

    /// 把持久化的「循环」偏好播种到当前会话。
    ///
    /// 幂等：只读 `@AppStorage` 的 `loop` 并赋给 `session.looping`，不产生其它副作用，
    /// 所以可以在 `onAppear` 与 `onChange(of: session != nil)` 两处都调。
    /// 为什么需要它：`session.looping` 是新建 `PlaybackSession` 时的默认 false，
    /// 而用户偏好可能早就是 true（上次开着循环退出的）—— 不播种就出现
    /// 「chip 亮着、播完不循环」。（S2-P1-3）
    ///
    /// ⚠️ 这里**不**沿用 `:3521` 那颗 chip 里的写法（`loop.toggle(); session?.looping = loop`）：
    /// 那是「用户动作」，会翻转偏好；这里是「启动对齐」，只能单向赋值。
    /// 两件事共用一个变量但语义相反，混在一起就会变成「一进页面就取反」。
    private func seedLoopPreference() {
        guard let session, session.looping != loop else { return }
        session.looping = loop
    }

    /// 播种时机为什么不会覆盖用户刚点的 chip（自查，非推测）：
    ///
    /// 用户点 chip 时走的是 `loop.toggle(); session?.looping = loop` —— 两者**同步翻转**，
    /// 点完 `session.looping == loop`，所以之后再调 `seedLoopPreference()` 会命中
    /// 第一行的 `guard ... else { return }`，什么都不做。**幂等性靠「两者相等即返回」成立**，
    /// 不是靠调用时机。
    ///
    /// 唯一会让两者不等的窗口是「AppStorage 被外部改了、session 没跟上」
    /// （例如设置页/另一个入口改了 `oneSkinLoop`），那时播种正是我们要的行为。
    ///
    /// ⚠️ 已知边界（不改，记录）：`onChange(of: session != nil)` 用 Bool 比较，
    /// 而 `oneSkinStageSession` 换集时**保持不变**（`playbackSession(for:)` 复用同一会话，
    /// 见 `VideoDetailView:3806-3809` 的注释）⇒ 这个 onChange 实际只在「首次就绪」时触发一次。
    /// 对本缺陷足够（要的就是首播对齐），但如果将来有「换集后需要重新对齐偏好」的需求，
    /// 这个判据不会生效 —— 届时必须改成 `onChange(of: watchChannel)` 那种按频道比的形式。
    /// 我已在另一处踩过同样的坑（`onChange(of: playerSession == nil)` 因换集不变而 false→false 不触发）。

    /// 已播秒数与总时长。One 的进度条两端是「已播 / 剩余」，
    /// 没有真值就画不出正确的进度，所以由调用方从 `PlaybackSession` 传入。
    // ⛔ `position` / `duration` 已从本视图移除。
    //
    // 它们是「控件每秒推移」的真凶：父视图用 `playerSession?.position ?? 0`
    // 每帧喂进来（`PlaybackSession` 是 @Observable，播放时每秒 ~60 次更新），
    // 于是**整个 `OneSkinStage.body` 每帧重建 → 根部 `GeometryReader` 重跑
    // → proxy 抖动 → 用户看到控件一直在推**。
    //
    // 实测（Fig 外屏竖持，修复前）：每秒 479 次 ROOT，dt=7–11ms；
    // proxy 宽 473→469→466→462→459→455 平滑递减。
    //
    // 唯一需要进度的地方是「继续播放」按钮的文字，已收进 `OneContinueHint`，
    // 由它单独观察 —— 叶子重绘，父级不动。
    //
    // 若将来要在画面层加进度条，也必须在**独立的叶子视图**里读 session，
    // 不能把 `position` 加回这个 struct 的参数表。

    // 曾有一个 `@ViewBuilder var picture: () -> Picture` 参数，但全文件从未调用过它
    //（唯一出现是在注释里）。调用方为此白白构造了一棵 never-rendered 的视图树。
    // 真正让 PlaybackView 跑起来、触发 session.prepare 的，是 VideoDetailView 里
    // 挂在 oneSkinBody 上的 `.background(watchStage)`，与这个参数无关。
    // 已删除，别再加回来。

    /// 只退全屏、不离开页面。
    ///
    /// ⛔ 这里**没有** `onBack` 了（2026-11-11）。选集页的退出键已迁到页面层
    /// （`VideoDetailView.watchPageExitButton`）—— `OneSkinChrome` 被
    /// `.frame(winW, winH).offset(winX, winY)` 锁在画面窗口内，画在里面的键出不了窗口，
    /// 而用户要的正是「退出按钮离开视频窗口、落到界面上」。
    ///
    /// 皮肤自己仍留一个镜像 `fullScreenNow`，全屏时页面那份与它可能不同步；
    /// 所以全屏里的返回必须走这条单向通道（只退全屏），不能落到 `dismiss()` 上。
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
    /// 「用其他播放器打开」—— 把当前流地址交给系统（`UIApplication.open`），
    /// 由用户装的 VLC / Infuse / nPlayer 等接管。真机 One 的第三颗就是它。
    var onOpenExternal: () -> Void = {}
    /// 分享当前视频（One 是分享稳定链接，不是临时播放地址）。
    var onShare: () -> Void = {}
    var isFavorite: Bool = false
    /// 全部线路名（一条 flag 一条线，可能只有一条）。空则「线路」chip 隐藏。
    var lines: [String] = []
    /// 当前线路名。选集卡与「线路」chip 都按它过滤。
    var activeLine: String = ""
    /// 半折时**上半个屏**占整高的比例，跟随折痕真实位置（缺省正中央）。
    ///
    /// 不写死 0.5 的原因：`FoldGap.HorizontalBand.splitsContainer` 允许折痕
    /// 落在 25%–75% 之间都算半折，实际设备上帐篷略前倾/书本略后翻都会让
    /// 折痕偏离正中。硬编码 0.5 会让画面列与下半控制台在折痕处错位。
    ///
    /// ⚠️ 位置必须留在**成员列表末尾**：`OneSkinStage` 是逐参数位置的
    /// struct init（memberwise），中间插一个参数会让 VideoDetailView 的
    /// 整个调用点参数错位（实测报「extra arguments at positions #25/#26/…」）。
    var halfFoldSplitRatio: CGFloat = 0.5
    /// 半折折痕的**绝对 y**（容器坐标系，窗口顶 = 0），单位 pt。
    ///
    /// ⛔ 16.5：`topH = box.height × (band.centerY / 容器高)` 是把「窗口高的比例」
    ///    乘到**更矮的 box** 上 —— 窗口高 951、`box.height` 917 时，
    ///    边界会比真实折痕高 `(951−917)×0.5 ≈ 17pt`；再叠 5% 量化最坏再多 ±11pt，
    ///    画面下沿与折缝之间出现一条肉眼可见的错位/黑边。
    ///    折痕矩形与 `stage` 共用同一个坐标原点（都是窗口顶），所以直接用它当高度，
    ///    不做比例换算、也就没有误差放大。
    var halfFoldSplitY: CGFloat? = nil
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

    /// 铰链是否 partiallyOpen。`nil` = 系统没报。
    /// 只用于告诉几何层折叠态跨档了（B 站 `hingeObserver` 的模式）。
    var hingePartiallyOpen: Bool? = nil

    /// 片源比例**只影响窗口内部怎么留黑边**（`videoGravity`），不影响窗口尺寸。
    /// 原先每 400ms 轮询 presentationSize 改这个 state，既没有消费者，
    /// 又会让整页在开播后反复重绘 —— 一并删除（见 OneSkinWindowGeometry）。
    @AppStorage(OneSkin.speedKey) private var speed: Double = 1
    @AppStorage(OneSkin.loopKey) private var loop = false
    /// 参考截图里那颗「自动全屏」：默认开（One 截图里它就是蓝底蓝字的高亮态）。
    @AppStorage(OneSkin.autoFullScreenKey) private var autoFullScreen = true
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
    /// 冻结的布局盒。
    ///
    /// ⛔ 三次回归的教训，记全别再反复：
    ///   ① box 每帧由 `screen.bounds` 现算 → 旋转动画里 screen.bounds 连续变
    ///      （日志铁证：同 shape 报 466x678 与 951x669 两种），box 每帧变 =
    ///      「横竖屏切换控件疯狂推移」复发。
    ///   ② box 冻进 @State 但**写 UserDefaults 跨启动缓存** → 缓存把外屏旧值
    ///      带回内屏页面、或把旧方向 box 取回，形态变了仍读旧值。
    ///   ③ 正确做法：box 只在**离散事件**（形态/折叠/遮挡/屏幕跨档）时重算一次，
    ///      存内存 @State，动画期间冻结。
    ///
    /// 这份职责现在归 `geoDriver`（`OneSkinGeometryDriver`）：它把形态、折叠态、
    /// 遮挡、屏幕尺寸全部收成离散量，过三道幂等门后吐一个 `OneSkinGeometry` 快照。
    /// 原来这里还有一个 `frozenBox: CGSize`，只写不读（`stage` 里 `box = size`），
    /// 且两处写入源不同 —— 已在 16.8/16.10 删除，别再复活第二份。
    /// 哔哩哔哩架构的几何驱动：布局只吃它吐出的离散枚举 + 缓存值。
    /// 见 `OneSkinGeometryDriver.swift` 顶部的实测依据。
    @StateObject private var geoDriver = OneSkinGeometryDriver(shape: .column)
    /// 安全区：直接读窗口，不测量容器（哔哩哔哩架构）。
    /// 见 `body` 里关于「几何基准只用窗口」的说明。
    private var measuredSafeArea: EdgeInsets {
        guard let ins = UIApplication.shared.appWindowScene?.windows.first?.safeAreaInsets
        else { return EdgeInsets() }
        return EdgeInsets(top: ins.top, leading: ins.left,
                          bottom: ins.bottom, trailing: ins.right)
    }
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
        // ⛔ 同上：`foldedNow` 是形态开关，不是可插值的视觉量。
        // 用 `withAnimation` 包它会让「合拢/展开」过程每帧重排（实测 0.25s ≈ 15 帧）。
        foldedNow = next
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
    /// 形态（唯一读取点）。
    ///
    /// ★★ 2026-11-12：**必须接受 `override`**。
    ///
    /// `stage` 收到 `shapeOverride`（由 `GeometryReader.geo.size` 算出的真实形态）后，
    /// 只把 `landscapeNow` 改了，而 `effectiveShape` 仍返回旧的 `shape` ——
    /// 于是出现「横着排（land=true）但走单列分支（shape=column）」的矛盾。
    /// 现在所有分支与日志都走这一个方法，override 一处生效、全局一致。
    private func shape(_ override: OneSkinShape? = nil) -> OneSkinShape {
        if let override { return override }
        // ★ QA 强制必须覆盖**全部五态**（之前只认 portrait/landscape，
        // 于是 halfFold / fullBleed 在任何 QA 参数下都到不了，
        // 这正是「每种形态都不对」里半折、宽屏两态完全不可达的原因）。
        if UserDefaults.standard.bool(forKey: "qaOneSkinColumn") { return .column }
        if UserDefaults.standard.bool(forKey: "qaOneSkinLandscape") { return .split }
        if UserDefaults.standard.bool(forKey: "qaOneSkinWide") { return .fullBleed }
        if UserDefaults.standard.bool(forKey: "qaOneSkinHalfFold") { return .halfFold }
        // ⛔ 删掉 `portraitNow` 对形态的干预。
        //
        // 它是「屏幕上是否是竖持」的独立判断，与 `shape` 参数（父视图按容器宽高比
        // 算出的形态）**不同源**。两者打架时，stage 用一套、控件用另一套，
        // 就是「同帧里 ROOT 行 shape=fullBleed、stage 行 shape=split」的来源。
        // 形态只信 `shape` 一个来源（它在 VideoDetailView 里已按容器宽高比算好）。
        // ★ 直接读**传入参数** `shape`，不读镜像出来的 `shapeNow`。
        //
        // `shapeNow` 是 `onChange(of: shape)` 里写进来的 @State，读它意味着
        // 「外部已变 → 先写 State → 下一次重排才生效」，**中间必然有一帧用旧形态排版**。
        // 用户看到的「旋转后控件滞后一拍再跳过去」就是这个：几何已经承诺了新尺寸，
        // 版面却还按旧形态排。
        // `shape` 是 `let` 参数，随父视图传入即刻可见，没有这个时间差。
        // `shapeNow` 只用于 QA 循环等必须覆盖外部值的场景（由 effectiveShape 之前的分支处理）。
        return shape
    }
    /// 是否走横向双列。fullBleed（展开宽屏）是**竖持**，必须返回 false。
    ///
    /// ★ 半折是例外：它不是「横屏版式」（没有左右双列），但 `box`/上限钳制问的是
    ///   「屏幕现在哪条边长」。机器转 90° 后半折，容器是 951×669，
    ///   按竖持给 669×951 会宽少 282、高多 282（16.4）。
    ///   所以这一支跟 `OneSkinGeometry.layoutLandscape` 用**同一个判据**：
    ///   屏幕实测宽 > 高。
    /// 屏幕方向（1=横 / 0=竖 / -1=未知），由 `.onChange(of: OneSkin.fixedScreenSize())`
    /// 维护。它**只用于触发重算**：转屏时 `geo.size` 要等 UIKit 动画结束（实测 520~840ms）
    /// 才更新，而 `screen.bounds` 在动画**开始时**就变了。有了这个状态，
    /// body 会在转屏当帧重跑，`geoShape` 里的「screen 预判」分支才来得及生效。
    @State private var screenIsLandscapeNow: Bool?

    private var stageIsLandscape: Bool {
        let sh = shape()
        guard sh == .halfFold else { return sh.isLandscape }
        let s = OneSkin.fixedScreenSize()
        guard s.width > 1, s.height > 1 else { return false }
        return s.width > s.height
    }

    /// 本帧真正采用的几何快照。
    ///
    /// ⛔ 16.7：`geoDriver` 用 `shape: .column` 建立，`onAppear` 才改成真实形态。
    ///    横屏/展开宽屏直接进页面时，第一帧 `box` 是 669×951，而 `stage` 已按横屏排
    ///    —— 首帧越界、闪一下。这里发现 driver 还没跟上（形态或全屏标记不同），
    ///    就按当前值**现算**一份（纯算术，不写状态、不成环）；
    ///    `onAppear` / `onChange` 落地后两者自然一致。
    private var liveGeometry: OneSkinGeometry {
        let g = geoDriver.geometry
        guard g.shape != shape() || g.fullScreen != fullScreenNow else { return g }
        return geoDriver.preview(shape: shape(), fullScreen: fullScreenNow)
    }

    /// 竖持「列顶 → 窗口顶」的整段留白（**画面层与控件层唯一来源**）。
    ///
    /// 2026-11-12：原来是两处内联表达式各写一遍（`pictureColumn` / `pictureControls`），
    /// 改一处忘另一处就立刻错位。现在收成一个静态函数，两处都调它。
    ///
    /// 基准是**物理屏高**（`ratioBase.height`），不是 `colH`（画面区高度）。
    /// 比例分设备（真机实测）：
    ///   · 外屏/窄屏（<500pt 宽）：43.00 / 678 = 0.0634
    ///   · 内屏（≥500pt 宽）    ：85.67 / 951 = 0.091
    ///
    /// `extraDrop`：用户要求的**整体下移量**（视频与所有控件一起往下）。
    /// 加大它就是整块内容往下挪，画面层和控件层同步 —— 不会只动一半。
    static func portraitTopInset(ratioBase: CGSize, colSize: CGSize) -> CGFloat {
        let base = ratioBase.height > 1 ? ratioBase.height : colSize.height
        let ratio: CGFloat = colSize.width < 500 ? 0.0634 : 0.091
        return base * ratio + OneSkin.portraitExtraDrop
    }

    private var shown: Video { detail ?? video }
    /// 当前线路的集。线路为空（单线源）时退回全集，兼容没传 lines 的旧调用。
    private var episodes: [Episode] {
        if lines.isEmpty { return shown.episodes }
        let flag = activeLine.isEmpty ? (lines.first ?? "") : activeLine
        let filtered = shown.episodes.filter { $0.flag == flag }
        return filtered.isEmpty ? shown.episodes : filtered
    }
    private var playingEpisode: Episode? { current ?? episodes.first }

    // ⛔ 已删除 `progress` / `timeText` / `remainText`：
    //   三者全仓零消费者（唯一用到时间文字的是 `OneContinueHint`，
    //   它自己算）。它们却是 `position` / `duration` 被拖进 `OneSkinStage`
    //   的唯一理由 —— 留着就会继续把播放进度变成整页重绘的触发器。

    /// One 左端显示「已播」，右端显示「−剩余」——实测样板是 `0:00:01` / `-1:58:04`。
    /// 大数字压缩成 One 的写法（`1215k` / `16k` / `8484k`）。
    /// 真机 AX 实测：「1215k 次观看 · 收藏 16k · 评论 237」——用 k 不用万。
    static func compactCount(_ n: Int) -> String {
        if n >= 1000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// 仅供「继续播放」按钮显示文字用。
    ///
    /// 独立成一个 `View` 是有意为之：它单独观察 `position`（每帧变），
    /// 而**父级 `OneSkinStage` 不再碰 `position`**，于是根部 `GeometryReader`
    /// 不会因为播放进度而重算 —— 这是「控件每秒推移」的根治点。
    /// `GeometryProxy` 的最小替身。
    ///
    /// body 内部原来直接用 `proxy.size` / `proxy.safeAreaInsets`，
    /// 换成 `onGeometryChange` 之后没有真 proxy 了，用这个结构承接同样两个字段，
    /// 让 body 里的其余代码**一行都不用改**。
    struct OneSkinStageProxy {
        let size: CGSize
        let safeAreaInsets: EdgeInsets
    }

    private struct OneContinueHint: View {
        /// 直接持有 `@Observable` 的会话 —— **只有这个叶子视图**订阅 `position`。
        let session: PlaybackSession?
        let episodeNumber: Int

        private var position: Double { session?.position ?? 0 }

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(position > 0 ? "继续播放" : "播放")
                    .font(.system(size: 20, weight: .semibold))
                if position > 0 {
                    Text("第 \(episodeNumber) 集 · \(OneSkinStage.clock(position))")
                        .font(.system(size: 13))
                        .opacity(0.72)
                }
            }
        }
    }

    /// 胶囊条下面那行「① 已定位到上次看到的 2:52 …… 从头播放」。
    ///
    /// 参考截图六态里都有这一行（竖持/横持/外屏、暂停/未播），我们之前完全没做。
    /// 它是**叶子视图**：只有它订阅 `position`，父级 `OneSkinStage` 不跟着重绘 ——
    /// 与 `OneContinueHint` 同一条纪律。
    private struct OneResumeLine: View {
        let session: PlaybackSession?
        let onRestart: () -> Void

        private var position: Double { session?.position ?? 0 }

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                Text("已定位到上次看到的 \(OneSkinStage.clock(position))")
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 10)
                Button(action: onRestart) {
                    Text("从头播放")
                        .font(.system(size: 14))
                        .foregroundStyle(OneSkinPalette.autoBlue)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(OneSkinPalette.tertiary)
            // 没有续播位置时整行隐形（仍占位，避免底部块跳动）。
            .opacity(position > 0 ? 1 : 0)
        }
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
        // ★★★ 用 `onGeometryChange` 取代 `GeometryReader` —— 这是环的终点。
        //
        // 参考（联网查证，见本轮文档）：
        //   · philz.blog/swiftui-geometry-modifiers-ongeometrychange/
        //     「GeometryReader 作为 background/overlay 插入会**增加视图图复杂度**，
        //       让布局与命中测试变慢」
        //   · fatbobman.com/en/snippet/how-to-obtain-view-dimensions-in-swiftui/
        //     「onGeometryChange 只用于**监测**几何，**不影响布局结构**」
        //   · rebeloper（iPad split view 同一个 bug）：
        //     「feedback loop when split view changed the scroll container size，
        //       解法是 **把 viewport 尺寸与 content 尺寸分开**」
        //
        // 差别是本质性的：
        //   `GeometryReader` **参与布局** —— 它自己占空间、并把提议尺寸传给子视图。
        //   于是「量 → 排 → 量」必然成环：子视图按量到的值排版，改变了内容尺寸，
        //   父容器重新提议，GeometryReader 再量到新值 …
        //   实测 Fig 内屏横持 split：proxy 宽 1087→1078→…→799（每帧 -8pt，
        //   连续 37 帧）→ 瞬间跳回 1354 → 再来一轮，每秒 213 次 ROOT。
        //
        //   `onGeometryChange` **不参与布局** —— 它挂在视图外层当观察者，
        //   只在尺寸真的变化时把值写进 `@State`，布局用那个 State 走。
        //   视图图里没有「测量者」，环就没有闭合路径。
        //
        // ⛔ 不要退回 GeometryReader。也不要在这里再加 `.frame` 去「钉住」——
        //   那只是让内容和容器互相拉扯（第 11 轮已实测：每秒 397 次）。
        // ★★★ 哔哩哔哩架构：几何基准只用「窗口/屏幕」，**不测量容器**。
        //
        // 参考实现（B 站 9.18.0，strings 实测）：
        //   setupModule isFoldable:%d capable:%d isWideScreen:%d sizeClass:%ld window:%@
        //
        // 它一次拿齐五个**离散/半离散**信号，其中 `window` 是几何主源。
        // 关键点是：**它从不问「我这个视图被分到多大」** ——
        // 一旦去问，答案就取决于内容尺寸，内容又取决于答案，成环。
        //
        // 我们照抄这套：
        //   · 几何 = screen（窗口尺寸，外部常量，不由内容决定）
        //   · 形态 = shape（离散枚举，由 size class / duoExpanded / 折痕带判定）
        //   · 二者都不依赖本视图的内容尺寸 ⇒ 视图图里没有反馈边
        //
        // ⛔ 彻底不用 `GeometryReader`，也不用 `onGeometryChange`：
        //   前者参与布局必然成环（实测每秒 213–479 次）；
        //   后者虽然不参与布局，但量到的是「本视图最终 frame」，
        //   而这个 frame 会被内容撑大（实测 raw 宽 1621，屏幕只有 951），
        //   等于把内容尺寸又喂回布局，环照旧。
        //
        // One 的界面完全保留：`stage` 里那套绝对坐标版式一行没动，
        // 只是**几何输入的来源**从「量容器」换成「读窗口」。
        // ★★★ 几何 = **按形态整形后的屏幕**，不是物理 screen.bounds。
        //
        // `screen.bounds` 在 Duo 上是物理固定值，**永不随方向交换**
        // （本项目已坐实：内屏恒报 951×669，横竖都一样）。
        // 直接拿它当 box，竖持时就是 952×664 铺在 669 宽的容器上
        // —— **横向溢出 283pt**，画面右侧被推出屏外、下方 287pt 全空。
        // 这就是用户报的「一进页面尺寸就不对」。
        //
        // 正解：按**形态**把屏幕整形一次：
        //   · 横持（split / 全屏横屏）→ 长边为宽：951×669
        //   · 竖持（column / fullBleed）→ 短边为宽：669×951
        // 形态是离散枚举，整形结果因此也是离散的 —— 不依赖任何测量，
        // 不与内容尺寸互为因果，**不构成环**。
        // ★ 几何 = driver 缓存的离散快照（哔哩哔哩架构）。
        // 它只在「形态 / 折叠态 / 遮挡 / 屏幕尺寸」跨档时重算一次，
        // 且过三道幂等门；body 重算时**读的是缓存，不重新推导**。
        // ⚠️ `proxy` 只用于 body 里少数读 `proxy.safeAreaInsets` 的地方；
        // 真正参与排版的尺寸是 `stage(useAvail)` 的 `useAvail`（来自 GeometryReader）。
        // 2026-11-12：`liveGeometry.box` 与 `geo.size` 实测会不一致
        // （594x432 vs 678x466），所以 body 层不再用它做任何几何决策。
        let proxySize = liveGeometry.box
        let proxy = OneSkinStageProxy(size: proxySize, safeAreaInsets: measuredSafeArea)
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
        // ⛔ 绝不用 `cachedLiveContainer`！它是 `.onGeometryChange` 量的「视图最终 frame」，
        // 而该 frame 又由这里的 `screen` 经 `availableSize` 钳制后决定 —— 完整闭环。
        // 实测（真机 Duo 2026-11-12）：ROOT dt=1ms、SHAPE 翻转 3141 次（split/fullBleed 各半）。
        // `screen.bounds` 是离散静态量，绝不参与 feedback。
        //
        // 之前这里恒读 `screen.bounds`（内屏报 951×669 / 外屏报 678×466），
        // 而形态判定读容器 → 两套基准，`availableSize` 用 screen 钳制容器，
        // 实测出现 container 高 688 > screen 高 466（钳制失效）。
        // 现在两者同源，钳制才真正有效。
        let screen = OneSkin.fixedScreenSize()
        #if DEBUG
        // 一次性打齐所有几何来源，定位 294 是谁给的（只打前 3 帧，避免刷屏）。
        // ⛔ 必须写成 `let _ = { … }()` 而不是裸 `if` ——
        //    `ViewBuilder` 会把语句级 `if` 当成**条件视图**，返回 `()`
        //    就要报 "type '()' cannot conform to 'View'"（实测踩过）。
        let _ = {
            guard ROOTRecomputeProbe.n <= 3 else { return }
            let wp = (UIApplication.shared.appWindowScene?.windows.first?.bounds.size) ?? .zero
            let sc = (UIApplication.shared.appWindowScene?.screen.bounds.size) ?? .zero
            oneSkinLog("GEO proxy=\(Int(proxy.size.width))x\(Int(proxy.size.height)) screen=\(Int(screen.width))x\(Int(screen.height)) win0=\(Int(wp.width))x\(Int(wp.height)) scr=\(Int(sc.width))x\(Int(sc.height)) safe=\(Int(proxy.safeAreaInsets.top)),\(Int(proxy.safeAreaInsets.bottom))")
        }()
        #endif
        // ⛔ 伪全屏修复：`availableSize` 的短边上限缩放是给**双列态**防
        // 侧栏把内容区撑大用的（951×669 那个坑）。但全屏态侧栏已经
        // `.persistentSystemOverlays(.hidden)` 隐藏、proxy 本应就是真实可视区，
        // 再拿 `UIScreen.main.bounds`（VM 上报告错误的外屏竖屏值）去缩，
        // 全屏窗口就缩成一小块、四周巨黑边 —— 用户报的「伪全屏」。
        // 全屏态由 `fullScreen:` 参数跳过缩放，直接用 proxy.size 铺满。
        // ★★★ 哔哩哔哩式「量化桶」—— 本文件最关键的一处。
        //
        // 参考实现：哔哩哔哩 9.18.0 的折叠屏适配（MachO strings 实测）：
        //   setupModule isFoldable:%d capable:%d isWideScreen:%d sizeClass:%ld window:%@
        //   _TtC13HingeObserver13HingeObserver / HingeStatus 枚举
        //   Tq,N,V_lastHingeStatus        ← 缓存上一次状态
        //   _foldableBoundsLimitWith: / _foldableRelayoutForOcclusion
        //
        // 它的要害不是「怎么算几何」，而是 **几何只在离散状态变化时才重算**：
        // 折叠态是一个枚举，上一次的值被缓存成 `lastHingeStatus`，
        // 状态没变就完全不碰布局。所以 B 站播放页在折叠/旋转时不会每帧重排。
        //
        // 我们的问题正相反：根部 `GeometryReader` 每帧给出一个**连续**的
        // `proxy.size`，直接喂给 `stage` 排版。于是：
        //   · 容器因为任何原因（动画、播放进度、UIKit 图层）抖 1pt
        //   · `avail` 就变 → `stage` 重新排 → 控件移动
        //   · 实测每秒 479 次 ROOT 重算，dt=7–11ms，proxy 宽 473→455 递减
        //
        // 修法：把 `avail` **量化到整数桶**（8pt 一档，够粗到吸收抖动、
        // 够细到形态切换时能跟手）。桶不变 → 传给 `stage` 的值不变 →
        // SwiftUI 认为子视图无需重建 → 环断在这里。
        //
        // ⛔ 不要改成「量化到 1pt」或「不量化」：那等于没做，抖动仍是逐帧变化。
        // ⛔ 不要量化 `screen`：它是静态值，量化没有意义，还会让边界判断变糊。
        // ⛔ 不再传 `landscape`：见 `availableSize` 注释（方向与尺寸不同源）。
        let rawAvail = OneSkin.availableSize(proxy: proxy.size, screen: screen,
                                            fullScreen: fullScreenNow)
        // ★ 横持跳过 8pt 量化：951 不是 8 的倍数（floor8→944），会把正立帧三段
        //   467.667+55.333+428=951.000 压成 944，右栏凭空少 7pt。
        //   geoDriver 已是离散缓存、横持无逐帧回灌边（A3 ①），去掉横持量化
        //   不会重引入自激环；竖持/外屏仍保留 8pt 桶吸抖。
        //   ⚠ 需真机复验「横切竖」瞬间是否有 3.79pt 台阶跳变。
        let avail = stageIsLandscape ? rawAvail : OneSkin.stableBucket(rawAvail, step: 8)
        // ⛔ 不要在这里「冻结尺寸」。
        //
        // 试过 `StableStageSize`：在 body 里读 `proxy.size`，喂给它，
        // 它再写 `@State` 决定用哪个尺寸排版。这是**反馈环**：
        //   改 State → 重排 → proxy.size 变 → 再改 State → …
        // 表现就是用户报的「横转竖后控件无限推移，得重启 App 才恢复」。
        // 而且它是「只在稳定后提交」，一旦某一帧被判成稳定、后续又变了，
        // 几何就永久卡在旧值 —— 全屏点不动也是它连带的。
        // 真正的正解是：**几何只由离散形态决定，不依赖连续尺寸**（见 shape 的说明）。
        // ★ 重算频率探针：带单调递增序号 + 毫秒时间戳。
        // 单看 body 被调用次数无法区分「用户操作触发」与「自反馈环」；
        // 序号间隔（dt）能直接读出环的速度：dt≈16ms = 每帧一次 = 环。
        #if DEBUG
        // ★ 必须包在 #if DEBUG 里。
        // 它每帧写一次 `Documents/oneskin.log`；实测环里每秒 397 次，
        // 放进 Release 就是每秒 397 次磁盘写 + 日志无限增长
        // （之前那份 42.9 万行的 log 就是这么来的）。
        let _ = {
            ROOTRecomputeProbe.n += 1
            let now = Date().timeIntervalSince1970
            let dt = ROOTRecomputeProbe.last > 0 ? Int((now - ROOTRecomputeProbe.last) * 1000) : -1
            ROOTRecomputeProbe.last = now
            // ★ 决定性探针：把「入参 shape」与「镜像 shapeNow」并列打印。
            //   effectiveShape 现在直接返回入参 shape，但 ROOT 行打的是 shapeNow（@State 镜像）。
            //   两者不一致 ⇒ 镜像滞后（onChange 晚一帧），正是 body 反复重算的原因之一。
            let mirror = (shapeNow == shape) ? "same" : "LAG(shapeNow=\(shapeNow.logName))"
            oneSkinLog("ROOT #\(ROOTRecomputeProbe.n) dt=\(dt)ms proxy=\(Int(proxy.size.width))x\(Int(proxy.size.height)) screen=\(Int(screen.width))x\(Int(screen.height)) use=\(Int(avail.width))x\(Int(avail.height)) fs=\(fullScreenNow) shape=\(shape.logName) mirror=\(mirror) folded=\(foldedNow) portrait=\(portraitNow)")
        }()
        #endif
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
        // ═══════════════════════════════════════════════════════════════
        // ★★ 2026-11-12 根治：尺寸源改用 GeometryReader（对齐 B站皮肤做法）
        //
        // 此前 One 皮肤**完全不用 GeometryReader**（怕反馈环），改用
        // `fixedScreenSize()` → `geoDriver.geometry.box` 这条链。
        // 但 `fixedScreenSize()` 在 Fig 上返回 951×669（AX 的缩放坐标系），
        // 而真实容器只有 678×466 ⇒ 所有坐标被放大 1.403 倍后被窗口裁掉。
        //
        // 我方 B站皮肤（`App/BiliLandscapePage.swift:67`）用
        //   `GeometryReader { geo in ... geo.size.width ... }`
        // 同一台 Fig 上显示正常 —— 证明 `geo.size` 是**真实容器尺寸**。
        //
        // 反馈环的真正成因不是 GeometryReader，而是
        //   量到值 → 写 @State → 喂回布局
        // 这里 `geo.size` 就地使用、不写任何 State ⇒ 无环。
        //
        // 原有结构（HStack 双栏 / 比例常量 / 播放器几何 / 右栏控件）全部保留，
        // 只把**尺寸源**换成 `geo.size`。
        // ═══════════════════════════════════════════════════════════════
        // ★★ 2026-11-12 实测修正：`.ignoresSafeArea()` 必须加在 **GeometryReader 外层**。
        //
        // 加在 stage 上无效（实测 proxy 仍 379×644）—— 安全区在 GeometryReader
        // 拿到 proxy.size **之前**就被扣掉了，下游再加 ignoresSafeArea 拿不回。
        //
        // 真 One 外屏竖持（466×678）实测：
        //   视频 x=16  w=350  ⇒  466 − 16(左) − 100(右) = 350 ✓
        // 即它按**整屏 466** 排版（播放器满宽到状态栏），不扣安全区。
        // 我方按 379 排 ⇒ 视频只有 376 宽、x=0。
        GeometryReader { geo in
            // ★★★ 2026-11-12 需求3：**形态判定下沉到这一层**，与渲染同源。
            //
            // 问题：上层 `VideoDetailView.oneSkinShape` 用 `layoutSize`(=keyWindow.bounds)
            // 做判定，而真正排版用的是这里的 `geo.size`。Duo 内屏竖持时
            // keyWindow 可能仍报横值（951×669），于是 ratio≥1.15 → 判成 split，
            // 「展开竖屏」与「展开横屏」合并成同一形态 —— 用户报的正是这个。
            //
            // 现在用 `geo.size`（这一帧真实容器）重新判一次，只覆盖**方向类**
            // 判定（split / fullBleed / column）；halfFold 由折缝决定，不在此处推翻。
            let _t0 = Date().timeIntervalSince1970
            let geoShape: OneSkinShape = {
                // ① QA 强制优先（无人值守验收用，必须原样尊重，不能被几何推翻）
                if UserDefaults.standard.bool(forKey: "qaOneSkinColumn") { return .column }
                if UserDefaults.standard.bool(forKey: "qaOneSkinLandscape") { return .split }
                if UserDefaults.standard.bool(forKey: "qaOneSkinWide") { return .fullBleed }
                if UserDefaults.standard.bool(forKey: "qaOneSkinHalfFold") { return .halfFold }
                // `-qaPage one-preview -qaOneShape <shape>` 也属于强制，
                // 由 QAHost 直接传进 `shape`；此时**不要再按尺寸改判**。
                if UserDefaults.standard.string(forKey: "qaOneShape") != nil { return shape }
                // ② 半折由折缝决定，不按宽高比推翻
                if shape == .halfFold { return .halfFold }
                // ②′ **转屏预判**：`screen.bounds` 在 UIKit 转屏动画**开始时**就变了，
                //    而 `geo.size` 要等动画结束（实测 520~840ms）才更新。
                //    用 screen 的宽高比先判一步，转屏当帧就切版式，视觉上立刻响应。
                //    `screen` 只在**方向真的变了**时才与 geo 不一致，所以不会误判：
                //    两者一致时走下面的 geo 判断，结果相同。
                // 读 `screenIsLandscapeNow` 让 body 在转屏时重算（见其声明处说明）。
                let _ = screenIsLandscapeNow
                let scr = OneSkin.fixedScreenSize()
                if scr.width > 1, scr.height > 1 {
                    let screenLandscape = scr.width > scr.height
                    let geoLandscape = geo.size.width > geo.size.height
                    if screenLandscape != geoLandscape {
                        // screen 已翻向、geo 还没跟上 ⇒ 以 screen 为准（转屏进行中）
                        return screenLandscape
                            ? .split
                            : (max(scr.width, scr.height) >= 500 ? .fullBleed : .column)
                    }
                }
                // ③ 真实运行：按 One 的原始判据 —— **`w > h` 一次比较**。
                //
                // 依据（RULES.md §一，勿再推翻）：
                //   One 的 `VideoDetailPage` 只有 `__pageSize: State<CGSize>` 一个尺寸源，
                //   横竖 = `width > height`；没有阈值、没有宽高比、没有滞回。
                //   证据：`One-1.7.1.interface.swift:1630/3271`，`LargeCanvas` 无像素字段。
                //
                // 下方「竖持再分 fullBleed / column」是**我方对 Duo 的扩展**
                //   （One 没有「外屏 vs 内屏竖持」的区分，它靠 __division 判折缝）。
                //   这里按短边分档，因为外屏 466 与内屏 669 的竖持版式确实不同。
                let w = max(geo.size.width, 1)
                let h = max(geo.size.height, 1)
                if w > h { return .split }                   // 横：双栏
                return w >= 500 ? .fullBleed : .column       // 竖：内屏宽版 / 外屏单列
            }()
            let _ = oneSkinLog("GEOSRC geo=\(Int(geo.size.width))x\(Int(geo.size.height)) screen=\(Int(screen.width))x\(Int(screen.height))")
            let _ = oneSkinLog("SWITCH geo=\(Int(geo.size.width))x\(Int(geo.size.height)) shape=\(geoShape.logName) t=\(String(format: "%.0f", _t0*1000))")
            let liveAvail = OneSkin.availableSize(
                proxy: geo.size,
                screen: OneSkin.fixedScreenSize(),
                fullScreen: fullScreenNow
            )
            let useAvail = stageIsLandscape ? liveAvail : OneSkin.stableBucket(liveAvail, step: 8)
            let _ = oneSkinLog("GEOSRC liveAvail=\(Int(liveAvail.width))x\(Int(liveAvail.height)) useAvail=\(Int(useAvail.width))x\(Int(useAvail.height)) geoShape=\(geoShape.logName)")
            ZStack(alignment: .topLeading) {
                OneSkinPalette.pageBase.ignoresSafeArea()
                // ⛔ 不再经 `@State` 中转。
                //
                // 原实现写 `geoShapeNow` 再由 stage 读，而 `@State` 的值要**下一帧**
                // 才生效 ⇒ 每次转屏多一轮渲染，且偶尔「状态没变化」
                // （本帧 stage 仍读旧值）。现在直接把 `geoShape` 作为参数传入，
                // 同一次求值内生效，零延迟。
                stage(useAvail,
                      ratioBase: CGSize(width: useAvail.width, height: useAvail.height),
                      fitMode: fitMode, playerAspect: aspectRatio,
                      liveShape: geoShape)
            }
        }
        .ignoresSafeArea()
        // ⛔ 这里**不能**再 `.frame(width:) + .clipped()`。
        //
        // 2026-11-12 实测：加了这两个之后 `geo` 从 466 被压到 376
        //   `min(fixedScreenSize().width=466, avail.width=376)` = 376
        //   ⇒ 宽度凭空少 90pt，正是「内容比真机窄 26pt」的直接原因。
        // 而 `.clipped()` 又把 ignoresSafeArea 拓出来的部分切掉，
        // 等于把「满屏」抵消两次。
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
        // ⛔ 不许把 `.onGeometryChange` 挂在这个 body 上。
        //
        // 实测（Fig 内屏横持，屏幕 951×669）：
        //   GEOCH raw=1621x940 / 1486x849 / 1457x848 / 1194x700 / 466x700 …
        //   —— 宽度最大 1621，是屏幕的 1.7 倍。
        //
        // 原因：`onGeometryChange` 量的是**这个视图最终的 frame**。
        // 而这个 body 的内容（HStack 两列 + 绝对定位）会被自身内容撑大，
        // 量到的就不是「容器给了多少」，而是「内容想要多少」——
        // 用它驱动布局，等于把内容尺寸又喂回布局，环照旧。
        //
        // 正确位置见 `body` 外面的 `OneSkinViewportProbe`：那里只放一个
        // 中性的、不参与内容计算的容器来量尺寸。
        .background(
            OneSkinBackdropLayer(image: posterImage).ignoresSafeArea()
        )
        .foregroundStyle(OneSkinPalette.primary)
        // ★ 形态切换的**视觉**过渡。
        //
        // 几何本身是离散的（`liveGeometry.box` 一步到位，不做插值 —— 插值会产生
        // 「box 是新尺寸、landscapeNow 还是旧形态」的中间帧，那正是「推移」的来源）。
        // 但**离散 ≠ 硬跳**：用户看到的是控件瞬间换位，观感上是「滞后一拍再猛跳」。
        //
        // 这里把动画加在**渲染层**而不是几何层：
        //   · `liveGeometry` / `effectiveShape` 立即变成终值（无中间态、无环）
        //   · 屏幕上的位置由 SwiftUI 的隐式动画补间（smooth 曲线，0.28s）
        // 于是既有确定的终点，又有顺滑的过渡。
        // 只对 `.animation` 生效，不参与布局计算，因此不会反向影响 proxy。
        // ⛔ 已移除：`.animation(.smooth, value: effectiveShape)`。
        //
        // 加它是想做「旋转过渡顺滑」，但它挂在 `body` 最外层、
        // 而 `body` 内部就是根部 `GeometryReader`。`effectiveShape` 是**计算属性**，
        // 每次 body 求值都会产出一个新值参与动画比较 —— 动画被反复重启，
        // 每一帧都触发一次隐式动画重绘，等于给整个页面加了一个 60fps 定时器。
        //
        // 实测对比（同一页面，Fig）：
        //   加动画前 dt=28–40ms（≈30fps）
        //   加动画后 dt=9–14ms（≈75–110fps，每秒 296 次 ROOT）
        // 重算次数翻了三倍，把原本「能被用户感知的慢漂移」变成了「明显推移」。
        //
        // 过渡顺滑应该由**几何本身离散、只切换一次**来保证（见 `geoDriver` 的注释），
        // 不能靠给整页挂隐式动画。等环根治后再考虑在**叶子控件**上做局部动画。
        .oneSkinStatusBarHidden(hidden: fullScreenNow || shape().isLandscape)
        .task(id: shown.poster) { await refreshBackdrop() }
        // 片源比例不再轮询：窗口是固定版式比例，画面在窗口内 letterbox。
        // 把构造参数镜像进本地状态：泛型视图的参数变化不保证重绘（见 fullScreenNow 的说明）。
        .onAppear {
            // `-qaOneSkinFullScreen 1`：强制进全屏，用于验证全屏态版式
            // （顶部是否铺满、控件是否被顶下去）。
            let qaFS = UserDefaults.standard.bool(forKey: "qaOneSkinFullScreen")
            fullScreenNow = debugBlockFullScreen ? false : (qaFS ? true : isFullScreen)
            shapeNow = shape
            // ★ 必须传 **effectiveShape**（含 QA 强制形态），不能传父视图的 `shape`。
            //
            // 实测（模拟器外屏 + -qaOneSkinLandscape YES）：driver 认为 .column
            // （ROOT 打 shape=column、box 不扣 47 让位），而 stage 按 .split 排三栏
            // → GEOM 自检报 dX=2(expect 47)，右栏被推出容器。
            // QA 只是放大器，真机上「方向判定晚一帧」也会造成同样的两套形态并存。
            geoDriver.shapeDidChange(to: shape())
            // 全屏标记同源传给几何层（`box` 的底部扣减依赖它）。
            // `onChange(of: fullScreenNow)` 也会传，但页面**以全屏态建立**时
            // 那次赋值不一定产生一次 onChange —— 这里补一次，幂等。
            geoDriver.fullScreenDidChange(to: fullScreenNow)
            // 遮挡同源传给几何层（唯一消费端，见 `occlusion` 的说明）。
            geoDriver.occlusionDidChange(to: occlusion.geometryInsets)
            // 铰链状态同源落地（`onChange` 只覆盖页面已存在的后续变化）。
            geoDriver.hingeDidChange(to: hingePartiallyOpen.map { $0 ? .halfOpen : .flat } ?? .unavailable)
            // ⛔ 已删除 `frozenBox` 的写入（16.8 / 16.10）。
            //
            // 这个 @State 只写不读：`stage` 里 `let box = size`（几何驱动的盒），
            // DEBUG 日志里那个 `frozen=` 于是恒等于「上一次离散事件写下的大小」，
            // 与真正参与排版的 `box` 毫无关系 —— 排查时照着它比对只会被带偏。
            // 冻结盒的职责已经由 `geoDriver` + `liveGeometry` 承担（离散缓存、
            // 三道幂等门），这里再留一份没有任何消费者。
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
            // ── 循环开关必须在这里**播种**一次 ──
            //
            // ⛔ S2-P1-3：`oneSkinLoop` 是 `@AppStorage` 持久化的用户偏好，
            //    而 `session.looping` 才是真正驱动「播完回零重播」的开关
            //    （`PlaybackView` 的 didPlayToEnd 分支读它）。
            //    原来全文件只有**一处**写入 `session?.looping = loop`：
            //    `:3521` 那颗「循环」chip 的 Button 里 —— 也就是**只有用户亲手点过才会同步**。
            //    后果：用户把循环开着、退出 App、重进来 → `loop` 仍是 true（界面 chip 是亮的），
            //    但新会话的 `looping` 是默认 false ⇒ **播完不循环，chip 却显示已开**。
            //    这是「界面说开着、功能没开」的典型形态。
            seedLoopPreference()
        }
        // 会话晚于页面就绪时（`session` 由父视图异步给出）再播一次；
        // `seedLoopPreference()` 是幂等的（只赋值，不做副作用）。
        .onChange(of: session != nil) { _, ready in
            if ready { seedLoopPreference() }
        }
        .onChange(of: isFullScreen) { _, new in
            guard !debugBlockFullScreen else { return }
            // ⛔ 不能用 `withAnimation` 包住 `fullScreenNow`。
            //
            // `fullScreenNow` 决定 `stage` 的整个版式（全屏 vs 分栏），
            // 用 0.28s 曲线插值它，就等于让 SwiftUI 把这 0.28 秒内的**每一帧**
            // 都当成一次新的布局输入：
            //   动画帧 → body 重算 → onGeometryChange 回报新尺寸
            //          → measuredStageSize 变 → 再重排 → 再回报 …
            // 0.28s ≈ 17 帧 @60fps，与实测完全吻合：
            //   #44→#60 连续 17 帧，proxy 每帧 -8pt（1352→1192），dt=17–31ms。
            //
            // 形态是**离散**的（全屏 / 非全屏两种），几何一步到位即可；
            // 视觉平滑应由叶子控件自己的过渡承担，不能让整页几何参与插值。
            fullScreenNow = new
        }
        // ★ 全屏 ⇄ 非全屏要让**几何层**知道。
        //
        // 两者在 `box` 里的扣减不同：全屏 `.ignoresSafeArea(.all)` → 一点不扣；
        // 非全屏底部没忽略 → 必须扣 `safeInsets.bottom`。
        // 只写这一处：`onAppear` / `onChange(of: isFullScreen)` / 控件层的
        // 「退出全屏」三条路径都只是改 `fullScreenNow`，由这里统一往下传。
        .onChange(of: fullScreenNow) { _, value in
            geoDriver.fullScreenDidChange(to: value)
        }
        // 「自动全屏」：开播即进全屏（参考截图里那颗蓝底蓝字的 chip）。
        // 只认 `false → true` 这一跳，退出全屏不会再被立刻弹回去。
        .onChange(of: playing) { _, value in
            guard value, autoFullScreen, !fullScreenNow else { return }
            onFullScreen()
        }
        // ★ 遮挡变化（折叠/展开、转屏后挖孔换了个角）→ 几何层重算 `box`。
        //   `occlusionDidChange` 自带 0.5pt 幂等门，同一份值重传不会引起重排。
        .onChange(of: occlusion) { _, value in
            geoDriver.occlusionDidChange(to: value.geometryInsets)
        }
        // 铰链状态跨档（摊开 ⇄ 半折 ⇄ 合拢）→ 几何层知道折叠态变了。
        // `hingeDidChange` 自带相等门 + 「只在活跃档重排」门，纯角度抖动不触发。
        .onChange(of: hingePartiallyOpen) { _, value in
            geoDriver.hingeDidChange(to: value.map { $0 ? .halfOpen : .flat } ?? .unavailable)
        }
        .onChange(of: shape()) { _, new in
            // 旋转/折叠后调用方改了 shape 参数。
            //
            // ⛔ 这里只更新 `shapeNow` 镜像，**不参与 `effectiveShape` 的判定** ——
            //    后者已改为直接读 `shape`，见 `effectiveShape` 里的说明。
            //
            // 形态是离散枚举，几何一步到位、不做插值；视觉上的平滑由叶子控件
            // 自己的过渡承担（不给整页挂隐式动画，理由见 body 上的注释）。
            shapeNow = new
            oneSkinLog("SHAPE -> \(new.logName)")
            // ★ 通知几何驱动：形态跨档了才重算（B 站 `appliedRightInset` 模式）。
            // 同样必须用 effectiveShape 而不是 new —— 与 onAppear 保持同一来源。
            geoDriver.shapeDidChange(to: shape())
            // ⛔ 已删除 `frozenBox` 的写入（16.8 / 16.10）：
            //    它读的是 `cachedLiveContainer`（视图 frame，正是自激环的入口），
            //    写出来的值却没有任何读者。几何的离散缓存现在只有 `geoDriver` 一份。
        }
        // ⛔ 这里原来还有第二个 `.onChange(of: shape)` 只打一行 SHAPE 日志。
        //   两个 modifier 各自注册订阅，同一值变化触发**两次** body 求值。
        //   日志已并进上面的 SHAPE 行。
        // ★ 屏幕尺寸变了也要让几何层重算。
        //
        // **形态可以不变、可用空间却变了**：Duo 内屏进 Split View 时宽度从 951
        // 变成约 475，而 size class 仍是 regular×regular、`duoExpanded` 仍 true、
        // `oneSkinShape` 仍是 `.split` —— `shape` 一个字都没变。此时唯一会变的
        // 离散信号就是窗口尺寸，所以拿它当触发源。
        //
        // 用 `fixedScreenSize()`（keyWindow.bounds，系统所有、静态量）而不是
        // 视图测量值：后者会被内容撑大，喂回去就是自激环。
        .onChange(of: OneSkin.fixedScreenSize()) { old, new in
            // 转屏当帧就写入，驱动 body 重算（geo.size 此时还是旧值）。
            let isLand = new.width > new.height
            if screenIsLandscapeNow != isLand { screenIsLandscapeNow = isLand }
            guard OneSkinStageSize.isLayoutChange(from: old, to: new) else { return }
            geoDriver.screenDidChange()
            oneSkinLog("SCREEN -> \(Int(new.width))x\(Int(new.height))")
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
                                    ratioBase: CGSize,
                                    fitMode: OneSkinFitMode,
                                    playerAspect: CGFloat,
                                    liveShape: OneSkinShape) -> some View {
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
        // ★ 2026-11-12 需求3：横竖只认 `liveShape`（由 `GeometryReader.geo.size`
        //   在**同一次求值内**算出并传入）。不经过任何 @State 中转，
        //   所以转屏当帧即生效，没有「多等一轮」或「状态没变」。
        let landscapeNow = liveShape.isLandscape
        // ★ 布局基准盒 = 「几何层缓存的离散盒」与「系统实际分配给本视图的空间」取交集。
        // 离散盒由 `geoDriver` 给（只在形态/折叠/遮挡/屏幕跨档时重算），
        // 绝不每帧从 `screen.bounds` 现算 —— 旋转动画里那是连续量。
        // 下面那一大段实测记录讲的是为什么必须**同时**受容器约束，别删。
        // ★ 布局基准盒 = 「冻结的屏幕尺寸」与「系统实际分配给本视图的空间」取交集。
        //
        // ⛔ 这是一个自反馈环的修复（实测日志铁证）：
        //   stage 内部所有子视图都 `.frame(width: box.width, height: box.height)`，
        //   而 box 原来**只**来自 frozenBox（= 屏幕 669×951）。但 stage 被放在
        //   `GeometryReader { proxy }` 里，proxy 的高度是**父容器分给它的**，
        //   实测只有 294（屏幕 669）。于是：
        //     内容钉死 951 高 → 溢出容器 → SwiftUI 重新协商 → proxy 缩小 → 再排 → …
        //   日志里 proxy.width 逐帧单调收缩、从不重复：
        //     978→964→953→…→722（每帧约 11–13pt，dt 28–40ms ≈ 每帧一次）
        //   这就是用户报的「控件一直在推移」。
        //
        // 现在把容器空间纳入上限：内容永远不会高于/宽于系统给的空间，
        // 容器因而不再需要重新协商，环断开。
        // 冻结盒仍然决定**版式基准**（比例、列宽），只是不能超出容器。
        // ★★ 布局基准 = **容器**，不是屏幕。
        //
        // One 1.7.1 原版的真实结构（MachOSwiftSection 从 IPA 提取，
        // 见 Docs/duo/evidence-2026-11-11/One-1.7.1.interface.swift）：
        //
        //   struct VideoDetailPage {
        //       var _wide: One.LargeCanvas                    // 只读 size class
        //       var __pageSize: SwiftUI.State<CGSize>         // 一次写入
        //       var __division: SwiftUI.State<CGRect?>
        //   }
        //   struct LargeCanvas {
        //       var _horizontal: Environment<UserInterfaceSizeClass?>
        //       var _vertical:   Environment<UserInterfaceSizeClass?>
        //   }
        //
        // **原版没有任何逐帧几何依赖**：宽屏看 size class，页面尺寸存 State。
        // 我们是反过来的 —— 14 个 GeometryReader + 每帧 proxy.size 驱动布局，
        // 而连续量驱动布局必然自反馈：
        //   内容比容器高 → 容器重分配 → proxy 变小 → 再排 → …
        // 日志铁证（Fig，dt=28–40ms 每帧）：
        //   proxy.width 1210→1196→…→725（36 帧连续 -14）→ 跳回 1268 → 再收缩
        //   proxy.height 恒 294，而 screen 669；669-294=375 无法用任何安全区解释
        //   ⇒ 294 是 GeometryReader 在高度未定的父级里用「子视图理想高度」反推的
        //
        // 修法：`size`（系统真正分配的空间）是**唯一**布局基准。
        // `frozenBox` 只用来决定**比例意图**（谁宽谁高），不参与像素计算。
        // 内容永不超出 size ⇒ 容器无需重协商 ⇒ 环断开。
        // ★ 布局基准 = `size`（已由调用方 `stableBucket` 量化过）。
        //
        // ⛔ 这里不再有 `screenBox` 兜底分支 —— 它是死代码：
        //   上游 `stableBucket` 保证 `size >= step`（≥8pt），
        //   所以 `size.width > 1 && size.height > 1` 恒成立，
        //   `screenBox` 永远不会被走到。留着只会让人以为还有两套基准。
        //
        //   首帧兜底由调用方负责：`availableSize` 在 `proxy` 无效时
        //   直接返回 `screen`，所以 `size` 从一开始就是有意义的。
        // 容器可用尺寸：只用于「不要溢出」的钳制。
        // ═══ 顾及2 · 修坐标 ═══
        // `box` = 几何层已经整形过的离散盒（`OneSkinGeometry.box`：按形态决定宽高、
        // 扣掉底部安全区与遮挡），再由调用方经 `availableSize` 夹到不超屏，
        // 竖持再叠 8pt 桶吸抖。它**不是**每帧连续的 `proxy.size`：
        //   · 离散 → 不推移（3552a28 的教训：「box 每帧变 = 控件疯狂推移复发」）
        //   · 真屏尺寸 → 不退回 screen.bounds 的坐标错位
        // 这里再与 `size` 取交集，保证内容永不超出系统真正分配的空间。
        let box: CGSize = size
        // ★ 比例坐标的乘法基准 = 物理全屏（One 原版按整块屏幕排版）。
        //
        // 这两个量必须分开，混用两种错误都实测过：
        //   · 都用全屏 → 比例对但溢出 70pt → 成环（每秒 200+ 次）
        //   · 都用扣除 → 环断了但坐标缩 10.3%、胶囊条偏上 60.8pt
        // 详见 `OneSkinGeometry.ratioBase` 的注释。
        let ratio = ratioBase
        #if DEBUG
        let _ = oneSkinLog("stage size=\(Int(size.width))x\(Int(size.height)) box=\(Int(box.width))x\(Int(box.height)) shape=\(liveShape.logName) land=\(landscapeNow) ratioBase=\(Int(ratioBase.width))x\(Int(ratioBase.height))")
        // ★ 几何自检（每个形态都打）：单一基准是否成立 = box 与 ratioBase 的差是否
        // 只出现在**让位带**上（横持 47pt 右让位 / 竖持 0）。任何子视图拿 ratio
        // 当容器尺寸都会让这里出现非零的「应为 0」项。
        do {
            let dx = Int(ratioBase.width - box.width), dy = Int(ratioBase.height - box.height)
            // 期望值必须与 driver 同公式（按屏宽比例），不能再写死 47。
            let expectDX = landscapeNow ? Int((ratioBase.width * 0.0494).rounded()) : 0
            // ★ dY 的期望值不再是 0：非全屏时 `box` 会扣掉底部安全区（P1-4 修正），
            //   全屏时四边全忽略、扣 0。自检必须跟着这个口径走，
            //   否则每一帧都会报 ⚠MIXED，真出问题时反而看不见。
            let expectDY = fullScreenNow ? 0 : Int(max(measuredSafeArea.bottom, 0).rounded())
            // 允许 ±8pt（stableBucket 桶余量）；dy 同理。
            let okX = abs(dx - expectDX) <= 8 || ratioBase.width < 1
            let okY = abs(dy - expectDY) <= 8 || ratioBase.height < 1
            let mark = (okX && okY) ? "OK" : "⚠MIXED"
            let _ = oneSkinLog("GEOM[\(liveShape.logName)] box=\(Int(box.width))x\(Int(box.height)) ratio=\(Int(ratioBase.width))x\(Int(ratioBase.height)) dX=\(dx)(expect \(expectDX)) dY=\(dy)(expect \(expectDY)) → \(mark)")
            // ★ P1-4 的常驻哨兵：盒高绝不能超过容器高（容器 = 物理屏 − 底部安全区）。
            //   写在日志里而不是 `assert`：真机上宁可多打一行，也别在一个
            //   「只是差 1pt」的形态上把 QA 跑崩。
            let containerH = Int(ratioBase.height - (fullScreenNow ? 0 : max(measuredSafeArea.bottom, 0)))
            if Int(box.height) > containerH + 1 {
                let _ = oneSkinLog("⚠️BOX>CONTAINER box=\(Int(box.height)) container=\(containerH) shape=\(liveShape.logName) fs=\(fullScreenNow)")
            }
        }
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
            } else if liveShape == .halfFold {
                // ★ 半折（书本 / 帐篷）：折痕在**中部**，上下各半屏。
                //
                // 与 fullBleed 的关键差别：这里不是「画面在上、详情在下」的
                // 可滚动抽屉，而是**两个物理半屏** —— 上半只看画面，下半是控制台。
                // 用户把机器立在桌上（帐篷）或合到一半（书本），
                // 上半屏朝自己看片、下半屏当操作台。
                //
                // 所以下半不是 `detailColumn`（那是可滚动的详情/选集，
                // 半折时人手碰不到折叠面以下的内容）；改用专门的
                // `HalfFoldConsoleView`：画面缩略 + 进度 + 播放键，
                // 全部落在**下半屏的可见区域**内。
                //
                // 上界用折痕的真实位置，不写死 0.5：模拟器与实际设备上
                // 折痕并不总在正中央（`splitsContainer` 允许 25%–75%）。
                //
                // ⛔ 16.5：优先用**折痕绝对位置**（`halfFoldSplitY`）。
                //    旧式 `box.height × splitRatio` 是把窗口高的比例乘到更矮的
                //    box 上，边界凭空高 ~17pt，再叠 5% 量化最坏多 ±11pt。
                //    只有拿不到折痕矩形时才退回比例（此时页面对半分，误差本来就无从谈起）。
                let topH: CGFloat = {
                    if let y = halfFoldSplitY, y > 1 {
                        return min(max(y, box.height * 0.25), box.height * 0.75)
                    }
                    return max(box.height * halfFoldSplitRatio, 1)
                }()
                let bottomH = max(box.height - topH, 1)
                VStack(alignment: .center, spacing: 0) {
                    pictureColumn(CGSize(width: box.width, height: topH),
                                  landscape: stageIsLandscape, edgeToEdge: true, ratioBase: ratio,
                                  fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: box.width, height: topH)
                    HalfFoldConsoleView(session: session,
                                        cover: posterImage,
                                        title: current?.name ?? video.name,
                                        height: bottomH,
                                        onSeek: onSeekTo)
                        .frame(width: box.width, height: bottomH)
                }
            } else if liveShape == .fullBleed {
                // ★ 展开宽屏（Duo 摊开 + 竖持）—— 与展开横屏**明确分叉**。
                //
                // 之前 `stage` 完全没读 shape，fullBleed 和 column 画成同一棵
                // VStack 单列，所以两种展开态看起来一样（只有没人调用的
                // makeLayout 里留着 fullBleed 公式）。现在真正实现上游定义：
                // 上半屏画面全出血（窗口铺满整宽、无 2.36% 内缩），
                // 下半屏是详情 / 选集抽屉。几何仍由 OneSkinWindowGeometry 给，
                // 控件层跟着同一个窗口坐标走，不另起一套绝对坐标。
                // 画面列高度按**片源比例**优先，不再固定 0.56·H。
                // 竖片按宽算会很高，仍由 0.56 上限压住 —— 既不留无谓黑边，
                // 也不会让竖片把详情区挤没。
                let picH = bleedingPictureHeight(box, aspect: aspectRatio, lower: 0.28, upper: 0.56)
                let detailH = max(box.height - picH, 1)
                VStack(alignment: .center, spacing: 0) {
                    pictureColumn(CGSize(width: box.width, height: picH),
                                  landscape: false, edgeToEdge: true, ratioBase: ratio,
                                  fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: box.width, height: picH)
                    // ★ 2026-11-12：详情列也要跟着整体下移，且**保持既有间隔**。
                    //   原来 96/78 是「画面列下沿 → 标题」的固定距离；
                    //   现在加同一个 `portraitExtraDrop`，画面层与详情层一起下移，
                    //   两者之间的间距不变（96/78 那一段原样保留）。
                    detailColumn(CGSize(width: box.width, height: detailH), landscape: false,
                                 topInset: (session != nil ? 96 : 78) + OneSkin.portraitExtraDrop)
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
                // ★ 分栏基准 = **ratio.width（物理全屏 951）**，三段铺满。
                //
                // 2026-11-12 正立帧裁决（PIL rotate(90) CCW + OCR + 列黑度剖面）：
                //   播放器列 0..467.667 = 0.4918 / 纯黑缝 55.333 = 0.0582
                //   / 详情列 523..951 = 428pt = 0.4501，和 = 951.000。
                //   旧「容器 904 / colL 428 / 0.4735」是 **180° 倒立帧**：
                //   951−523=428、951−467.667=483.333，左右宽度归属被镜像。
                //
                // ⚠ Core 的 Metrics 命名当初按倒立帧写反了：columnLeft(0.4501)
                //   实为**正立帧详情列**占比，columnRight(0.4918) 实为**播放器列**。
                //   本次保留常量名以免牵动全仓引用，只在此处按语义取值并注明，
                //   后续统一重命名时再同步（E1 §2 P1-5）。
                // ★★ 2026-11-12 真机 AX 实测修正：**缝并入播放器列**
                //
                // 真 One（内屏展开横持 951×669，AX 实测）：
                //   播放器 x=16.0 w=475.0 → 右边界 491.0
                //   右栏起点 523.0
                //   ⇒ 播放器列实际占 0..523（含那 32pt 视觉缝），详情列 523..951（428）
                //
                // 我方旧写法：colL(467.7) + HStack spacing gapW(55.3) + colR(428)
                //   ⇒ 播放器列只有 467.7，比真机少 55.3，播放器被压成 452 宽（真机 475）
                //
                // 正解：把缝并入 colL，HStack spacing = 0。视线里那条缝由播放器
                // 自身的右边距（523-491=32）自然形成，不需要额外 spacing。
                // ★ 分栏基准统一用 **box.width**，与胶囊条（chipBar）同源。
                //
                // 胶囊条一直是对的（AX 实测位置正确），它用的是
                //   barW = box.width × Metrics.columnRight ...
                // 而 HStack 原来用 `ratio.width` —— 两者在真机上不等，
                // 导致分栏算出 669 而不是 951（右栏落 385 而非 523）。
                // 统一到 box.width 后，分栏与胶囊永远同一基准。
                let base: CGFloat = box.width
                let gapW: CGFloat = base * OneSkinWindowGeometry.Metrics.columnGap     // 0.0582 视觉缝
                let colR: CGFloat = base * OneSkinWindowGeometry.Metrics.columnLeft    // 0.4501 详情列
                let colL: CGFloat = base - colR                                        // 播放器列 = 剩余（含缝）
                HStack(alignment: .top, spacing: 0) {
                    pictureColumn(CGSize(width: colL, height: box.height), landscape: true, ratioBase: ratio, fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: colL, height: box.height)
                    detailColumn(CGSize(width: colR, height: box.height), landscape: true, ratioBase: ratio)
                        .frame(width: colR, height: box.height)
                }
                .background(
                    GeometryReader { p in
                        // 用 onChange 而不是 onAppear：onAppear 只触发一次，
                        // 抓到的是首次渲染（可能是竖持态），会误导判断。
                        let desc = "base=\(Int(base)) box=\(Int(box.width))x\(Int(box.height)) size=\(Int(size.width))x\(Int(size.height)) colL=\(Int(colL)) colR=\(Int(colR)) hstack=\(Int(p.size.width))x\(Int(p.size.height)) origin=\(Int(p.frame(in: .global).minX)),\(Int(p.frame(in: .global).minY))"
                        Color.clear
                            .onAppear { let _ = oneSkinLog("HSPLIT-A \(desc)") }
                            .onChange(of: p.size) { _, _ in let _ = oneSkinLog("HSPLIT-C \(desc)") }
                    }
                )
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
                                  landscape: false, ratioBase: ratio, fitMode: fitMode, playerAspect: aspectRatio)
                        .frame(width: box.width, height: picH, alignment: .top)
                    detailColumn(CGSize(width: box.width, height: max(box.height - picH, 1)),
                                 landscape: false, ratioBase: ratio,
                                 // 起播后用 96 让开「胶囊条 + 已定位行」那一带；
                                 // 未播放态那条带子已经不画了（见 overlay 的判据），
                                 // 再让 78 只是把标题白白推低 —— 参考里画面下沿到标题
                                 // 只有 ~20pt 的呼吸位（669×951 实测 469→522，外屏 272→348）。
                                 topInset: session != nil ? 96 : 20)
                        .frame(width: box.width, height: max(box.height - picH, 1))
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
            //
            // ★ 2026-11-12（参考截图对齐）：**未播放态也不画**。
            //
            // 三张参考图（外屏 466×678 / 内屏 669×951 / 内屏横持 951×669）的
            // 「未播放」全是同一个版式：画面下方直接就是标题，整条倍速/循环/填充/
            // 自动全屏/线路的胶囊带**根本不存在**；线路选择是详情列里一颗
            // 「自动 · 线路N · N ms ⌄」胶囊（补在 `detailColumn` 的 CTA 下方）。
            //
            // 而我们此前无条件画这条带子：466×678 上它占掉 350–373 这一带，
            // 详情列的 `topInset` 又按「让开胶囊带」给了 78 → 标题被推到 443，
            // 参考是 348。整块内容因此整体下移近 100pt，且多出一条参考里没有的控件行。
            //
            // 判据用 `session != nil`（真的起播过）而不是 `playing`：暂停态参考图里
            // 这条带子是**在的**（外屏暂停截图 284pt 处就是那五颗），只有从没起播才没有。
            // `folded`（单栏铺满，没有详情列）例外保留 —— 那里没有别的地方能放线路选择。
            if !fullScreenNow, session != nil || folded {
                // 2026-11-09：旋转横屏后胶囊条要跟画面列走，不能钉死在整页底部。
                // 横屏双列：贴左列底部（0.868·H）；竖屏单列：画面在上、详情在下，
                // 原来那套 0.132·H 的 bottom padding 会把 chip 行推到详情区最底下，
                // 和播放器彻底脱节。改成抬到画面列下沿。
                let barW = landscapeNow
                    ? max(min(ratio.width * OneSkinWindowGeometry.Metrics.columnRight - ratio.width * 0.10,
                              ratio.width * OneSkinWindowGeometry.Metrics.columnRight), 240)
                    : max(box.width - box.width * 0.10, 200)
                // 底栏按钮热区的**半高**。旧实现写死 13（`hit = 26` 时代），
                // 而 `ChromeMetrics.hit = min(52, max(44, glyph*1.8))` —— **下限 44**、半高 22。
                // 按 13 算会让胶囊条压进底栏热区。
                let barHitHalf: CGFloat = 22
                #if DEBUG
                do {
                    let bw = landscapeNow
                        ? max(min(ratio.width * OneSkinWindowGeometry.Metrics.columnRight - ratio.width * 0.10, ratio.width * OneSkinWindowGeometry.Metrics.columnRight), 240)
                        : max(box.width - box.width * 0.10, 200)
                    let _ = oneSkinLog("chipBar shape=\(liveShape.logName) box=\(Int(box.width))x\(Int(box.height)) barW=\(Int(bw)) land=\(landscapeNow) fs=\(fullScreenNow)")
                }
                #endif
                let barBottom: CGFloat = {
                    // ⛔ 分支顺序必须和 `stage` **完全一致**（`folded` 先于 `fullBleed`）。
                    //
                    // 16.6：原来只看 `liveShape == .fullBleed`，于是
                    // 「合拢 + 展开宽屏」这个组合里，`stage` 走 folded 分支
                    // （画面列拿整高 `box.height`、没有详情区），胶囊条却仍按
                    // fullBleed 的 `bleedingPictureHeight` 落位 —— 结果压进
                    // 播放器自己的底栏（0.928 处）上，既不是画面下沿也不是合拢位。
                    //
                    // 合拢态画面铺满整个 box，播放器底栏就在窗口 0.928 处，
                    // 所以胶囊条只能贴「底部往上 13.2%」，与横持双列同一口径。
                    if folded { return max(box.height * (1 - 0.868), 8) }
                    if liveShape == .fullBleed {
                        // 展开宽屏：胶囊条必须让开**播放器自己的底栏**（时间码/进度条/
                        // 全屏键，落在列高 0.928 处）。画面多高、胶囊条就贴多高 ——
                        // 两者共用 `bleedingPictureHeight`，不再一个按片源比例、
                        // 一个按固定 0.56。
                        let picH = bleedingPictureHeight(box, aspect: aspectRatio, lower: 0.28, upper: 0.56)
                        return max(box.height - (picH * 0.928 - barHitHalf - 8), 8)
                    }
                    if landscapeNow { return box.height * (1 - 0.868) }
                    return max(box.height - pictureHeightOf(box, landscape: false) - 6, 8)
                }()
                // ★ 胶囊条 + 「已定位到上次看到的 M:SS …… 从头播放」——
                //   参考截图里这两行是**同一个底部块**，第二行紧贴第一行下方
                //   （内屏竖持：胶囊 440–466、续播行 485–500）。
                //   我们之前完全没有续播行，用户的「和 One 不一样」很大一部分来自这里。
                //   续播行本身是个**叶子视图**（`OneResumeLine`），只有它观察 session，
                //   父级不会因为播放进度重绘。
                let plain = !folded && liveShape != .fullBleed
                VStack(alignment: .leading, spacing: 18) {
                    // ★ 横向可滚：466 宽外屏上 5 颗胶囊的固有宽度略超一行，
                    //   放在固定宽度里 SwiftUI 会把文字压成「自动…」。
                    //   改成 ScrollView 后每颗都保持完整宽度，窄屏可以滑。
                    ScrollView(.horizontal, showsIndicators: false) {
                        controlBar
                    }
                    .frame(width: min(barW, box.width - 16), alignment: .leading)
                    if plain, session != nil {
                        OneResumeLine(session: session) { onSeekTo(0) }
                            .frame(width: min(barW, box.width - 16))
                    }
                }
                .padding(.leading, box.width * (landscapeNow
                    ? OneSkinWindowGeometry.Metrics.insetLandscape
                    : OneSkinWindowGeometry.Metrics.insetPortrait))
                // 续播行占掉 18(spacing) + 15(行高)；把它从底距里扣掉，
                // 胶囊条本身仍然停在原来的位置，不多不少。
                .padding(.bottom, plain && session != nil ? max(barBottom - 33, 8) : barBottom)            }
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
        // ⛔ 已移除：`.frame(width: max(1, box.width), height: max(1, box.height))`
        //
        // 上一轮加它是想「把整页钉在容器上」。实测**它反而制造了环**：
        //   stage 钉死 464×568（量化后的目标）
        //   但根部 GeometryReader 的 proxy = 501×480（父容器实际大小）
        //   两者不一致 → 父容器每帧向 464 收敛 → proxy 变 → body 重算 → 再收敛
        //   实测每秒 397 次 ROOT，proxy 宽 501→497→494→487→483→480 一路缩
        //
        // GeometryReader 本来就会填满父容器，**不需要、也不该**给它的内容钉 frame。
        // 钉了只会让「内容尺寸」和「容器尺寸」打架 —— 这正是抖动的来源。
        //
        // 真正的稳定来自：`stage` 内部的列宽/列高全部由 `box`（量化后的 avail）算出，
        // `ZStack` 自然撑满即可。
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
    /// 竖屏画面区（外壳）高度。
    ///
    /// ★ 纯函数：**只吃 `size`，不读屏幕**。
    ///
    /// 之前这里调 `OneSkin.fixedScreenSize()`，结果每帧都重新测一次屏幕，
    /// 而这个 VM 的 `screen.bounds` 在形态稳定后仍在变（日志铁证同一形态下
    /// `col=466x317 / 343 / 345 / 380 / 678` 五种高度、`ROOT proxy` 在
    /// `466x604 / 638 / 555 / 507` 之间跳）—— 画面区高度跟着抖，整页就推。
    ///
    /// 现在留白比例直接乘 `size.height`（= 几何层给的离散盒高度）：
    /// box 只在 onAppear / 形态切换时重算，所以这个值也跟着离散、不抖。
    /// 「全出血」形态里画面列的高度 —— **唯一来源**。
    ///
    /// 画面列高度算在 `stage` 的 `fullBleed` 分支里，而**控制栏胶囊条的底距**
    /// 在 `stage` 外层 `.oneSkinOverlayOnce` 里另算一份。两份各写一个公式必然脱节：
    /// 画面高度按**片源比例**算（`min(max(宽/片源比, 下限), 上限)`），
    /// 而胶囊条若仍按固定的 `0.56·H` 反推，16:9 片源在 669×951 上就差 **145pt**
    /// （画面列实际 376.3，胶囊条却按 532.6 算，下沿低 145pt 扎进详情区）。
    /// 竖片恰好撞上限所以看不出来 —— 这就是它长期漏检的原因。
    private func bleedingPictureHeight(_ size: CGSize,
                                       aspect: CGFloat,
                                       lower: CGFloat,
                                       upper: CGFloat) -> CGFloat {
        // ⛔ 两条硬约束，缺一就出事：
        //   ① 结果**不得依赖 `size.height`** —— 那会让列高与容器高互为因果成环
        //      （实测：列高 213→378 爬升 → 容器被撑高 → 再来一轮，每秒 291 次）
        //   ② 结果**不得无限大** —— 片源越窄画面越高，竖片 9:16 时
        //      `width/aspect` = 669/0.5625 = 1189pt，把整页撑爆、详情栏压成 1pt
        //
        // 上一版 `min(max(f, f*lower/upper), max(size.height*upper, f))` 是**代数恒等式**
        // （`lower/upper=0.5<1` 且 `hiCap≥f`），返回恒等于 `width/aspect`，
        // `upper` 完全失效 —— 子代理用 20 万组随机反例证实 0 例外。
        // 后果实测：16:9 恰好 ≈50% 所以看不出来，但 4:3 溢出 50pt、
        // 1:1 溢出 288pt、竖片溢出 1028pt。
        //
        // 正解：上限挂在**宽度**上（宽度不随内容变，不成环），
        // 取「版式窗口按 windowAspect 铺满时的高度 × upper」。
        // `windowAspect = 1.819` 是 One 版式的窗口比例常量，
        // 内屏竖持 669 宽 → 标称窗口高 368 → 上限 368×0.56 ≈ 206…
        // 但这样会把 16:9 的 376 压到 206（上一版就这么错的）。
        //
        // ⇒ 上限必须与 `fittedH` 同尺度：用**宽度对应的最长合理画面高**。
        //   One 的版式规定画面列最多占整页 `upper` 比例，而整页高度按
        //   「宽度 / 版式宽高比」估。为避免再次压小正常片源，
        //   取 `max(该值, fittedH)` 作为**下限**，再让 upper 只压那些
        //   `fittedH` 明显超出窗口的窄片。
        let rawAspect = (aspect.isFinite && aspect > 0.2 && aspect < 6) ? aspect : 16.0 / 9.0
        let fittedH = size.width / rawAspect
        // 版式窗口高：纯由宽度推出，与容器无关。
        let nominalWindowH = size.width / OneSkinWindowGeometry.Metrics.windowAspect
        // 画面列允许的最大高度：窗口高 × upper，但**不低于** 16:9 的画面高，
        // 否则正常宽片会被压小（上两版都踩了这个坑）。
        let naturalH = size.width / (16.0 / 9.0)
        let cap = max(nominalWindowH * upper, naturalH)
        // 下限：窗口高 × lower，同样不低于 0。
        let floorH = max(nominalWindowH * lower, 1)
        return min(max(fittedH, floorH), cap)
    }

    private func pictureHeightOf(_ size: CGSize, landscape: Bool) -> CGFloat {
        guard !landscape else {
            // 横屏双列时画面列就是整列高，不用切
            return size.height
        }
        let winW = max(size.width, 1)
        // ★ 分形态：内屏竖持播放态用真机 2.146，外屏维持 1.819（与 Core 同源）。
        let winH = winW / OneSkinWindowGeometry.Metrics.portraitAspect(forColumnWidth: size.width)
        let h = max(size.height, 1)
        // 上限 0.72 保留：画面区最多占 72%，其余留给详情列。
        return min(h * OneSkinWindowGeometry.Metrics.portraitTop + winH + h * 0.04,
                   h * 0.72)
    }

    /// 播放器窗口内的控件层。
    ///
    /// **必须**与画面层分开、由调用方用 `.overlay` 挂在最上层。
    /// 原因：`OneSkinPlayerLayer` 是 UIViewRepresentable，它的 UIView 在合成时
    /// 排在同级 SwiftUI 内容之上（UIKit 子视图顺序不受 ZStack 声明序 / zIndex 控制）。
    /// 放在同一个 ZStack 里时，全屏态窗口铺满整屏，所有按钮都会「看得见但点不到」——
    /// 双列态因为窗口只占左列一小块、多数控件落在窗口外，问题才不明显。
    private func pictureControls(colW: CGFloat, colH: CGFloat, landscape: Bool, fullScreen: Bool,
                                 edgeToEdge: Bool = false,
                                 portraitTopInset: CGFloat? = nil) -> some View {
        // 控件层与画面共用**同一个几何来源**（OneSkinWindowGeometry）。
        // 以前这里和 pictureColumn 各算一份，只改一处就立刻错位。
        // edgeToEdge（展开宽屏）也必须同步带上，否则控件仍按内缩窗口定位。
        //
        // ★ portraitTopInset **必须由调用方传入**（三模型审查 B-D1）：
        //   之前这里不传，走 `nil → colH × 0.091` 回退（colH 是画面区高度不是屏高），
        //   控件层 winY：内屏竖持 44.8 vs 画面层 86.5（真机 85.67）→ 整体上移 42pt；
        //   外屏 31.3 vs 43.0（真机 43.00）→ 上移 11.7pt。画面层已正确接线、控件层漏传，
        //   正是 Core 注释警告的「两处必须同源」翻版。
        let geo = OneSkinWindowGeometry(
            size: CGSize(width: colW, height: colH),
            landscape: landscape,
            fullScreen: fullScreen || edgeToEdge,
            edgeToEdgeOnly: edgeToEdge,     // 区分「全出血」与「用户按了全屏键」
            portraitTopInset: portraitTopInset
        )
        // 安全区：全屏 / 展开宽屏时窗口 (0,0) 就是屏幕 (0,0)，
        // 顶栏会压进状态栏、底栏会被 Home 指示条咬掉 —— 交给控件层夹。
        let safe = OneSkinChrome.safeInsets()
        // 屏幕尺寸必须和 `safe` 同源（都来自 UIKit 的窗口/屏幕），
        // 且必须是**当前方向**的：控件层的「窗口外还剩多少」全部以它为基准。
        let screenNow = OneSkin.fixedScreenSize()
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
                // 控件布局档位必须按**当前形态**取，不能直接用用户手排的原始串：
                // 同一份 `controlsOrder` 在四形态下要落到不同档位
                //（比如 split 走 sideways、halfFold 走 folded 紧凑档）。
                //
                // ⛔ 这里是 P1-6 修正：原来 `skinShape` 读 `shape`（即刻可见），
                //    `layout` 却读 `shapeNow`（@State，慢一拍）—— 注释和代码正好相反。
                //    后果：几何/皮肤已按新形态，控件档位还停在旧形态，转屏/折叠时
                //    控件滞后一拍再跳；若 `onChange(of: effectiveShape)` 因为
                //    外层不重算而没触发，`shapeNow` 会**永久**停在初值 `.column`。
                //    现在两处都读 `effectiveShape`：一个来源（含 QA 强制覆盖），
                //    与 `stage` 排版的形态也完全同源。
                skinShape: shape(),
                layout: PlayerControlsLayout.current(forSkinShape: shape(), width: colW),
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
            // 物理屏（当前方向）。安全区是从**屏幕边**量的，而 `colW/colH`
            // 只是画面列 —— 横持双列时两者差 428pt，拿列宽当屏宽会把
            // 屏幕右缘的安全区算进窗口内（16.2/16.3）。
            screenW: screenNow.width,
            screenH: screenNow.height,
            // 返回分三层，一次只退一层：
            //   ① 全屏 → 走 `onExitFullScreen`（只退全屏，绝不关页）
            //   ② 合拢 → 展开，把详情与选集叫回来（用户的「退回选集页」）
            //   ③ 其余 → 才真的离开这一页
            // 这一层的意义是兜底：即使 `fullScreen` / `foldedNow` 有哪一侧读到过期值，
            // 也不会出现「点一次返回直接回主页」。
            // ⛔ `onBack` 不再传（2026-11-11）：选题页的退出键已迁到页面层，
            // 控件层里已经没有返回键了。合拢态的「返回＝展开」也随之取消 ——
            // 那是为一个**已不存在的按钮**服务的分支；页面层那颗退出键一律退出页面
            // （用户在合拢态想看详情，点画面或展开键即可，不需要再造一个语义）。
            onExitFullScreen: {
                // 先把皮肤自己的镜像收起来（布局立刻还原）……
                // ⛔ 不能包 withAnimation：`fullScreenNow` 直接决定 stage 走
                // 全屏分支还是分栏分支，0.25s ≈ 15 帧逐帧重排。
                fullScreenNow = false
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
                               ratioBase: CGSize = .zero,
                               fitMode: OneSkinFitMode = .fit,
                               playerAspect: CGFloat = 0) -> some View {
        #if DEBUG
        // ⛔ 这个探针**必须传 portraitTopInset**，否则竖持时 `winY` 会算成
        //    `colH × 0.091`（≈31），而真实 `geo` 用的是
        //    `ratioBase.height × 0.0634 + portraitExtraDrop`（≈58）。
        //    两者差 27pt —— 此前多轮「日志说 31、实际是 58」的误判就是它造成的。
        let _g = OneSkinWindowGeometry(size: colSize, landscape: landscape,
                                       fullScreen: fullScreen || edgeToEdge,
            edgeToEdgeOnly: edgeToEdge,
                                       portraitTopInset: landscape ? nil : OneSkinStage.portraitTopInset(
                                           ratioBase: ratioBase, colSize: colSize))
        oneSkinLog("pictureColumn shape=\(shape().logName) col=\(Int(colSize.width))x\(Int(colSize.height)) fs=\(fullScreen) edge=\(edgeToEdge) fit=\(fitMode.rawValue) aspect=\(playerAspect) win=\(Int(_g.winW))x\(Int(_g.winH)) at=(\(Int(_g.winX)),\(Int(_g.winY))) bottomY=\(Int(_g.winY + _g.winH))")
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
            fullScreen: fullScreen || edgeToEdge,
            // ★★★ 这个参数**从 2026-11-11 起才真正接线** —— 之前全仓零调用点，
            //     于是竖持时窗口顶边一直按 `colH * 0.091` 算，而 `colH` 只是
            //     「画面区高度」（≈ 屏高 × 0.55），比屏幕矮一半，顶边自然只有
            //     应有值的 55%：外屏 33.9pt（应 61.7）、内屏 44.8pt（应 86.5）。
            //     窗口整体上移 27.8 / 41.7pt —— 这就是用户报的
            //     「竖屏时控件没有避让摄像头」+「坐标不对」。
            //
            // 正确基准是**物理屏高**（`ratio.height`，不是 colH）：
            //     外屏 678 × 0.091 = 61.7pt ✓
            //     内屏 951 × 0.091 = 86.5pt ✓
            // 与 `OneSkinWindowGeometryCore` 注释里的实测值逐位吻合。
            // 顶边留白的基准必须是**物理屏高**，不是 colH（见 init 注释）：
            // 外屏 678×0.091=61.7 ✓  内屏 951×0.091=86.5 ✓
            portraitTopInset: landscape ? nil : OneSkinStage.portraitTopInset(
                ratioBase: ratioBase, colSize: colSize)
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

            // ★ 未播放态的**中央播放键**（2026-11-12，参考截图对齐）。
            //
            // 三张参考图的「未播放」都有一颗白色实心圆 + 黑色三角，压在画面正中
            // （外屏 ≈62pt、内屏 ≈59pt，实测都是 60 上下）。我们此前完全没有：
            // 控件层 `OneSkinChrome` 只在 `session != nil` 时画 `centerTransport`，
            // 未播放时画面是一块没有任​何入口的黑色 —— 想播只能去详情列找
            // 「继续播放」，而那颗按钮在小屏上还要滚一下才看得见。
            //
            // 用 `session == nil` 而不是 `!playing`：播放器已就绪但暂停时，
            // 控件层自己会画那颗圆键（含 ±10s），这里再画一颗会叠成两个。
            if session == nil {
                // ⛔ 用「定尺寸的透明底 + overlay 居中」，不要
                //    `Button.frame(winW, winH).offset(winX, winY)`：
                //    外层是 `ZStack(alignment: .topLeading)`，`frame` 只把**容器**
                //    撑到 winW×winH，子视图仍按 topLeading 摆 —— 实测那颗键跑到
                //    画面左上角而不是中心。`.position` 也一样会被这个 ZStack 吃掉。
                //    透明底给的是**确定的**几何，overlay 的居中与尺寸无关，稳。
                Color.clear
                    .frame(width: winW, height: winH)
                    .overlay {
                        Button {
                            // 与详情列那颗「继续播放」同一条路径：先当前集，再第一集。
                            onTogglePlay()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.black)
                                .frame(width: 62, height: 62)
                                .background(Circle().fill(Color.white))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("播放"))
                    }
                    .offset(x: winX, y: winY)
            }

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
                            fullScreen: fullScreen, edgeToEdge: edgeToEdge,
                            // 与画面层同源：同一份 portraitTopInset（B-D1）。
                            portraitTopInset: landscape ? nil : OneSkinStage.portraitTopInset(
                                ratioBase: ratioBase, colSize: colSize))
        }
        // 「用外部播放器打开」——真机是**右侧弹出的自定义面板**，不是系统弹窗。
        //
        // 实测（桌面截图「展开横屏双栏 暂停选触发按钮」，951×669 内屏横持）：
        //   用 Infuse 播放      y=151.9  x=760.2
        //   用 SenPlayer 播放   y=193.5  x=760.2   ← 行距 ≈41.7pt
        //   用 VLC 播放         y=235.7  x=760.1
        //   用 nPlayer 播放     y=277.8  x=760.2
        //   用内置播放器播放     y=319.2  x=760.2
        // ⇒ x 恒 760（贴右缘）、行距 41.7、每行是**左图标 + 文字**的一行按钮
        //
        // 之前用 `.confirmationDialog`：系统会把按钮排成居中的一堆，
        // 与真机的「贴右缘竖排」完全不同，而且颜色跟着系统走。
        .overlay {
            if showsMoreMenu {
                OneSkinExternalPanel(
                    streamURL: streamURL,
                    onCopy: {
                        if let u = streamURL { UIPasteboard.general.string = u.absoluteString }
                        copiedLink = true
                    },
                    onDismiss: { showsMoreMenu = false }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.smooth(duration: 0.2), value: showsMoreMenu)
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
    private func detailColumn(_ size: CGSize, landscape: Bool, ratioBase: CGSize = .zero, topInset: CGFloat = 0, shapeOverride: OneSkinShape? = nil) -> AnyView {
        #if DEBUG
        #endif
        #if DEBUG
        oneSkinLog("detailColumn \(Int(size.width))x\(Int(size.height)) landscape=\(landscape) eps=\(episodes.count)")
        #endif
        let colW = size.width
        let colH = size.height
        // ★ 左右内缩按参考截图量出来的固定值，不再按列宽比例。
        //
        // 参考截图（669×951 / 466×678 / 951×669 三种，OCR 换算成 pt）：
        //   正文左缘一律 **16**；竖屏/外屏右缘也是 16（全部 20 集那颗「全部」右缘 652.5/669）。
        //   横持例外：右缘要留出**返回 / 更多**两颗圆按钮的竖排轨道 ≈ 98pt。
        // 旧写法 `max(14, min(colW * 0.055, 26))` 在 669 上是 26、在 951 上是 26，
        // 比参考宽 10pt，整列文字右移，右边又留了 ~45pt 的空 —— 标题更早换行。
        // ★ 2026-11-12 真机 AX 实测修正：横持改成 pad=0 / trailing=100。
        //
        // 实测（内屏展开横持 951×669，AX）：
        //   右栏容器起点 523.0，而所有内容 x 也是 523.0 → **左内边距 = 0**
        //   最右内容边界 850.7 → 右留白 100.3pt
        //   内容实际占用 = 850.7 - 523.0 = 327.7pt
        //
        // 旧值 pad=16 / trailing=92 让 innerW = 428-16-92 = 320：
        //   · 内容右移 16pt（真机与容器同 x）
        //   · 可用宽少 7.7pt
        //
        // 新值 pad=0 / trailing=100 → innerW = 428-0-100 = 328
        //   与真机 327.7 吻合到 0.3pt。
        //
        // 竖屏/外屏仍是 16/16（那两种形态的实测右缘就是 16）。
        let pad: CGFloat = landscape ? 0 : 16
        let trailing: CGFloat = landscape ? 100 : 16
        let innerW = max(colW - pad - trailing, 1)
        // 选集卡片：右栏约 62% 宽，一排露出下一张的半张。
        //
        // 横持按参考实测反推：卡片 **210.67** 宽、gap **26.33**，而
        // innerW = 428 − 0 − 100 = 328 → 比例 0.642。原来是 0.62（=203.4），
        // 一张牌差 7pt，一排看下来整行短 3 成。
        // 竖屏/外屏沿用 0.62：那两种形态的参考图里卡片被裁在屏幕外，没有可比值。
        let cardW = min(max(innerW * (landscape ? 0.642 : 0.62), 128), landscape ? 212 : 220)
        // 日志必须打**真实的 pad/trailing/innerW**，不要重复一遍旧公式。
        // 曾经写 `max(14, min(size.width*0.055, 26))`（=23），而实际 pad 早已是 0 ——
        // 日志报 23、真实 0，白查半天。
        let _ = oneSkinLog("detailColumn shape=\(shape().logName) col=\(Int(size.width))x\(Int(size.height)) land=\(landscape) pad=\(Int(pad)) trailing=\(Int(trailing)) innerW=\(Int(innerW)) cardW=\(Int(cardW))")

        return AnyView(
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 横持：标题上沿实测 y≈40（列顶起算）。
                    // 竖屏：详情列从**画面列下沿**开始，而胶囊条 + 续播行也压在这一带里，
                    // 所以必须先让出它们的高度，否则标题会紧贴胶囊、两者黏在一起。
                    // 参考截图（669×951）：画面 415 → 胶囊 440–466 → 续播 485–500 → 标题 516，
                    // 即标题距画面下沿 ≈ 100pt。
                    Color.clear.frame(height: landscape ? 38 : max(topInset, 2))

                    Text(shown.name)
                        // 参考截图里标题是**整页最重的一档**：内屏竖持约 24pt，
                        // 外屏约 26pt，横持右栏约 22pt。我们原来写 17/20，
                        // 明显偏小，整页看起来「标题不像标题」。
                        .font(.system(size: landscape ? 25 : 24, weight: .bold))
                        .foregroundStyle(OneSkinPalette.primary)
                        .lineSpacing(landscape ? 1 : 4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)

                    // ① 当前集：`第 1 集 · <集名>`（参考 h≈15，常规字重，主色）
                    if let ep = playingEpisode {
                        // ⛔ 不要无条件拼「第 N 集 · 」：上游的 `ep.name` 本身常常
                        //    就是「第 01 集」，于是会渲染成「第 1 集 · 第 1 集 · …」。
                        let epTitle = ep.name.trimmingCharacters(in: .whitespaces)
                        Text(epTitle.hasPrefix("第") ? epTitle : "第 \(episodeIndex + 1) 集 · \(epTitle)")
                            .font(.system(size: 15))
                            .foregroundStyle(OneSkinPalette.primary.opacity(0.92))
                            .lineLimit(1)
                            .padding(.top, 11)
                    }

                    // ② 元信息：年份 + 备注（参考 h≈12），一行
                    let metaTop: [String] = {
                        var parts: [String] = []
                        if let year = shown.year, !year.isEmpty { parts.append(year) }
                        if !shown.remarks.isEmpty { parts.append(shown.remarks) }
                        return parts
                    }()
                    if !metaTop.isEmpty {
                        Text(metaTop.joined(separator: " · "))
                            .font(.system(size: 12.5))
                            .foregroundStyle(OneSkinPalette.tertiary)
                            .lineLimit(1)
                            .padding(.top, 31)
                    }

                    // ③ 统计行（真机第 4 段，y=168.6 h=14.3）：「N 次观看 · 收藏 N · 评论 N」
                    //
                    // 真 One 有观看数/收藏数/评论数三项。我方数据源只有 `Episode.views`，
                    // 没有收藏与评论计数 ⇒ **只显示真实有的，不编造**：
                    //   · 有 views  → 「X 次观看 · 共 N 集」
                    //   · 无 views  → 「共 N 集」
                    // 空着比编数好：编出来的数字是假的，用户一眼能看出。
                    if !episodes.isEmpty {
                        let totalViews = episodes.compactMap(\.views).reduce(0, +)
                        let text: String = totalViews > 0
                            ? "\(Self.compactCount(totalViews)) 次观看 · 共 \(episodes.count) 集"
                            : "共 \(episodes.count) 集"
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(OneSkinPalette.tertiary)
                            .padding(.top, 10)
                    }

                    oneActionRow(width: innerW, landscape: landscape)
                        .padding(.top, 22)

                    // ⛔ 不再单独画一条「自动 · 线路N」文本行。
                    //
                    // 参考截图（六态全对过）：线路信息只在胶囊条那一颗 chip 上出现，
                    // 「继续播放」与标签之间是**直接相接**的，没有第三行文字。
                    // 之前这里多画一条，等于同一份数据在页面上出现两次。
                    //
                    // ★ 但**未播放态**是例外：那时底部胶囊带整条不画（见 overlay 判据），
                    // 线路选择跑到详情列来，就是 CTA 下面这颗胶囊 ——
                    // 参考三态都在这个位置（横持 y≈294、外屏 y≈584、内屏 y≈676），
                    // 文案「自动 · 线路9 · 2010 ms ⌄」。此时它不再重复任何东西。
                    if session == nil, !lines.isEmpty {
                        lineSelector
                            .padding(.top, 22)
                    }

                    if !tags.isEmpty {
                        tagFlow(width: innerW, sx: 1, sy: 1)
                            .padding(.top, 22)
                    }

                    if !synopsisText.isEmpty {
                        Text(synopsisText)
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .foregroundStyle(OneSkinPalette.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 22)
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
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(OneSkinPalette.primary.opacity(0.9))
                                Spacer(minLength: 0)
                                // 真机右端是纯文本钮「全部」，无胶囊底、无描边。
                                Text("全部")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 26)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 26) {
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
                        .padding(.top, 14)
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
                    .padding(.top, 60)

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

    /// 「继续播放」按钮 + 收藏 / 下载 / 分享 / 更多 灰胶囊（One 主按钮行）。
    /// 横持：继续播放是 167×20 的紧凑文本行（无白底胶囊）；竖持：白底胶囊 190×52。
    private func oneActionRow(width: CGFloat, landscape: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let ep = playingEpisode ?? episodes.first { onPlay(ep) }
            } label: {
                if landscape {
                    // ★ 2026-11-12 真机 AX 实测修正：横持是 **168×52 实体按钮**，不是紧凑文本行。
                    //
                    // 两次独立采集（播放中 / 未播放）都给出同一组值：
                    //   x=523  y=205  w=168  h=52
                    // 旧注释「横持是 167×20 紧凑文本行」与实测不符（宽度接近、高度差 32pt）。
                    // 真机「继续播放」是**两行**（OCR 实测）：
                    //   y=525.2 「继续播放」 h=17.9
                    //   y=545.5 「第1集 · 2:59」 h=12.7
                    // 复用 `OneContinueHint`（它已经是叶子视图、自带副行、只订阅 position），
                    // 横持按 0.7 缩放字号（真机横持 14/10，竖持 20/13）。
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                        OneContinueHint(session: session, episodeNumber: episodeIndex + 1)
                            .scaleEffect(0.7, anchor: .leading)
                            .frame(width: 118, alignment: .leading)
                    }
                    .foregroundStyle(Color.white)
                    .frame(width: 168, height: 52)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                        // ★★ 只让这一小块观察 `position` —— 它每帧都变。
                        //
                        // 原来这里直接读 `position` / `timeText`，而 `position` 是
                        // `OneSkinStage` 的 `var` 参数、由父视图用
                        // `playerSession?.position ?? 0` 每帧喂进来（`PlaybackSession`
                        // 是 `@Observable`，播放时每秒 ~60 次更新）。
                        // 后果：**整个 `OneSkinStage.body` 重建 → 根部 `GeometryReader`
                        // 重跑 → `proxy` 每帧抖动 → 控件一直推移**。
                        //
                        // 实测（Fig 外屏竖持）：每秒 479 次 ROOT 重算，dt=7–11ms；
                        // proxy 宽 473→469→466→462→459→455 平滑递减；
                        // 高度夹住后稳定 568，但宽度仍抖。
                        //
                        // 也就是说：**这不是布局 bug，是「播放进度把整页重绘」**。
                        // 把观察范围收到这个叶子视图里，`GeometryReader` 就不再跟着进度走。
                        OneContinueHint(session: session, episodeNumber: episodeIndex + 1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 16)
                    // 参考尺寸：白胶囊 **190×52**（外屏实测 190×52 @(16,515)，
                    // 内屏竖持同样 190 宽）。之前上限 160，按钮明显偏窄，
                    // 和右边那组圆形按钮之间空出一大截。
                    .frame(width: max(min(width * 0.50, 190), 150), height: 52)
                    .background(Capsule().fill(Color.white))
                }
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
                // 真机第三颗是「用其他播放器打开」（AX 实测 label 就是这五个字），
                // 不是我方原来的「分享」。图标用 `play.rectangle.on.rectangle`：
                // 语义是「换个播放器接着放」，与分享（向上箭头出方框）区分开。
                Button { onOpenExternal() } label: {
                    Image(systemName: "play.rectangle.on.rectangle")
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
    /// 真机：等高 29.667pt、等宽 50pt、横向步长 58.33pt、行距 13.66pt、字号 ~13。
    private func tagFlow(width: CGFloat, sx: CGFloat, sy: CGFloat) -> some View {
        let step = 58.33 * sx
        let perRow = max(1, Int((width / step).rounded(.down)))
        let rows = stride(from: 0, to: tags.count, by: perRow).map { Array(tags[$0..<min($0+perRow, tags.count)]) }
        return VStack(alignment: .leading, spacing: 13.66 * sy) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8.33 * sx) {
                    ForEach(row, id: \.self) { t in
                        Text(t)
                            .font(.system(size: max(12, 13 * sx)))
                            .foregroundStyle(OneSkinPalette.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10 * sx)
                            .padding(.vertical, 7.5 * sy)
                            .frame(minWidth: 50 * sx, minHeight: 29.667 * sy)
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
                // 适应 ⇄ 填充 之间切换。
                // ⛔ 文案按「动作」写，不按「状态」写：参考截图里画面明明是
                //    letterbox（未填充），这颗 chip 仍写着「填充」——它是「点了会填充」。
                //    我们之前写当前状态（适应），于是同一画面下文案就和 One 反了。
                Button {
                    let all: [OneSkinFitMode] = [.fit, .fill]
                    let i = all.firstIndex(of: fitMode) ?? 0
                    fitMode = all[(i + 1) % all.count]
                } label: {
                    chip(fitMode == .fill ? "适应" : "填充", on: fitMode != .fit)
                }
                .buttonStyle(.plain)

                // One 第 4 颗：自动全屏（开播即全屏）。高亮态是蓝底蓝字。
                Button {
                    autoFullScreen.toggle()
                } label: {
                    chip("自动全屏", on: autoFullScreen, accent: true)
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

        // 逐条测，而不是一次把全部线路的 HEAD 打出去。
        //
        // ⛔ 原来这里是 `for … group.addTask` 全量并发（RCA H5 的同型问题）。
        // 线路菜单一展开就有 4~9 个 HEAD 与播放同时起跑；虽然它们现在走专用会话
        // 不再抢播放的连接池，仍然会抢**用户这条链路**的带宽。
        // 逐条测的代价只是数字一条条亮起来 —— 而那个过程本来就在面板里，用户看得见。
        var out: [String: Int] = [:]
        for (name, sample) in targets {
            if Task.isCancelled { break }
            if let ms = await Self.measure(sample) { out[name] = ms }
            await MainActor.run {
                lineLatencies.merge([name: out[name]].compactMapValues { $0 }) { _, new in new }
            }
        }

        await MainActor.run {
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

        // ⛔ 走探针专用会话，不走 `URLSession.shared`（RCA H3）。
        //
        // 共用的那个池 iOS 默认只有 6 条连接；线路菜单一点开就为每条线发一个 HEAD，
        // 再加上播放页的线路解析与选集面板的探测，正好把 6 条占满 —— 播放器的
        // m3u8 与分片请求排在后面，用户看到「点播放要等」。
        let t0 = Date()
        if let (_, resp) = try? await SourceProbeRunner.probeSession.data(for: head),
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
        if let (_, resp) = try? await SourceProbeRunner.probeSession.data(for: get),
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
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                // ★ 参考截图里**每一颗都是实心胶囊**，不是裸文字：
                //   普通项 ≈ #1F1F1F（黑底上白 10%），开启态的「自动全屏」是
                //   #000D1C 深蓝底 + #1A6CC7 蓝字。
                //   之前只有 accent 项有底、其余透明，整行看起来像四段散字，
                //   和 One 的「一排胶囊」差得很远。
                Capsule().fill(on && accent
                               ? OneSkinPalette.autoBlueDeep
                               : Color.white.opacity(0.10))
            )
    }

    // MARK: 标题与统计


    /// 详情列里的线路胶囊 —— **只在未播放态出现**（`detailColumn` 里调用）。
    ///
    /// 为什么要有这一颗：One 的未播放态把底部整条胶囊带收掉了，线路选择改放到
    /// 「继续播放」下面一颗独立胶囊上。三张参考图位置一致（横持 y≈294、
    /// 外屏 y≈584、内屏 y≈676），文案形如「自动 · 线路9 · 2010 ms ⌄」。
    /// 我们此前两种情况都不对：未播放也画整条带子（多出一行参考里没有的控件），
    /// 而详情列里一颗线路都没有。
    ///
    /// 交互与胶囊带里那颗完全一致（点开测一次延迟 → 展开线路列表），
    /// 只是把「列表」也搬到这里，因为胶囊带在未播放态不存在了。
    /// 线路选择器 —— 真机是**竖排面板**（不是横向胶囊）。
    ///
    /// OCR 实测（桌面截图）：
    ///   外屏 466×678：  V自动（推荐） y=98.5 x=48.3
    ///                   线路1•不通    y=141.2 x=43.3   ← 行距 42.7
    ///                   线路9•不通    y=476.7 x=43.3   ← 行距 42.4
    ///                   重新测速      y=539.7 x=79.7   ← 底部独立
    ///   内屏竖持 669：  V自动（推荐） y=450.5 x=288.9
    ///                   线路9·1435ms·最快 y=492.1     ← 行距 41.6
    ///
    /// 三点与旧实现不同：
    ///   ① **竖排**，每行 42pt 高；旧的是横向 ScrollView 胶囊
    ///   ② 首行固定「自动（推荐）」，代表「让 App 选最快」
    ///   ③ 每行右侧显示延迟或「不通」，最快那条加「最快」标签
    private var lineSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 收起态：一颗胶囊，显示当前线路
            Button {
                withAnimation(.smooth(duration: 0.22)) { showsLineMenu.toggle() }
                if !showsLineMenu { Task { await probeLatency() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OneSkinPalette.secondary)
                    Text(lineLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(OneSkinPalette.secondary)
                        .lineLimit(1)
                    Image(systemName: showsLineMenu ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OneSkinPalette.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            // 展开态：竖排面板（真机样式）
            if showsLineMenu, !lines.isEmpty {
                let fastest = lineLatencies.min { $0.value < $1.value }?.key
                VStack(alignment: .leading, spacing: 0) {
                    // 首行固定「自动（推荐）」
                    lineRow(title: "自动（推荐）",
                            detail: nil,
                            isActive: activeLine.isEmpty,
                            isFastest: false,
                            systemImage: "wand.and.stars") {
                        if !activeLine.isEmpty { onSelectLine("") }
                        withAnimation(.smooth(duration: 0.22)) { showsLineMenu = false }
                    }
                    ForEach(lines, id: \.self) { line in
                        let ms = lineLatencies[line]
                        lineRow(title: line.isEmpty ? "线路" : line,
                                detail: ms.map { "\($0) ms" } ?? (probingLines ? nil : "不通"),
                                isActive: line == activeLine,
                                isFastest: line == fastest && ms != nil,
                                systemImage: "antenna.radiowaves.left.and.right") {
                            if line != activeLine { onSelectLine(line) }
                            withAnimation(.smooth(duration: 0.22)) { showsLineMenu = false }
                        }
                    }
                    // 底部独立按钮
                    Button {
                        Task { await probeLatency() }
                    } label: {
                        Text("重新测速")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OneSkinPalette.secondary)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .background(OneSkinPalette.card,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(OneSkinPalette.buttonStroke, lineWidth: 0.5))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    /// 线路面板的一行。高度固定 42（真机实测行距 41.6~42.7）。
    @ViewBuilder
    private func lineRow(title: String,
                         detail: String?,
                         isActive: Bool,
                         isFastest: Bool,
                         systemImage: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? OneSkinPalette.accent : OneSkinPalette.tertiary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? OneSkinPalette.primary : OneSkinPalette.secondary)
                    .lineLimit(1)
                if isFastest {
                    Text("最快")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OneSkinPalette.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(OneSkinPalette.accent.opacity(0.16)))
                }
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(OneSkinPalette.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)          // ← 真机行距 41.6~42.7
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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

    /// 标签胶囊的文案源 = **只有 `category`**（逗号分隔）。
    ///
    /// ⛔ 不要再把 `year` / `remarks` 拼进来。之前拼了，2026-11-12 的模拟器
    /// 截图里就出现「标签行里多出一颗 `2026-11-03` 胶囊，备注 `人间杀妈客 · ♥14k`
    /// 直接压在胶囊上」—— 因为备注和元信息行是同一份数据，变成排两遍。
    /// 真 One 的标签云只有分类词（国产 / 直播 / ONE直播 / 主播 / 喵呜 …），
    /// 年份与备注各有自己的行，见 `detailColumn` 的元信息三段。
    private var tags: [String] {
        guard let category = shown.category else { return [] }
        return category.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
