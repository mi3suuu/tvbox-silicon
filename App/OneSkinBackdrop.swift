// ⚠️ 本文件**只适用于 iOS**：它整段围绕 `UIImage` / `UIViewRepresentable` /
// `AVPlayerLayer` 的宿主 UIView 写，macOS 与 tvOS 没有 UIKit。
// 之前在文件级完全没守卫，macOS target 的第一个错误就落在这里的 `import UIKit`
// （历史记录：修了这一处还会连带暴露十几处）。
//
// 文件尾部 `ScreenBackdropIfNeeded` 是例外：它不碰 UIKit，被**跨平台**的
// `VideoDetailView` 使用，所以那段留在守卫外，见文件末尾 —— 也正因为如此，
// `import SwiftUI` 必须留在守卫外；`import UIKit` 只有上半段要，放守卫内。
import SwiftUI
import TVCore

#if os(iOS)
import UIKit
//
//  OneSkinBackdrop.swift  [mi3s]
//
//  One 观看页的背景：黑底 + 48px 封面放大 + 顶→底两停黑罩。**没有模糊滤镜**。
//
//  2026-11-11 重定（rea + MachOSwiftSection 双重取证，结论已用 VM 截图做过像素复核）：
//
//    One 里那个背景是一个独立类型 `AmbientBackground`（只有一个字段 `cover: String`），
//    它的 `body` 类型别名从 Swift 元数据里直读出来是：
//
//      ModifiedContent<
//        ZStack<TupleView<(
//            Color,
//            Optional<ModifiedContent<ModifiedContent<RemoteImage, _ScaleEffect>, _OpacityEffect>>,
//            LinearGradient
//        )>>,
//        _SafeAreaRegionsIgnoringLayout
//      >
//
//    ★ 整条类型链里**没有 `_BlurEffect`** —— 这张「虚化」不是模糊，是
//      「封面按 48px 解码，再用 .high 插值放大 40 多倍」。
//
//    对应函数 `sub_1001e3ed4`（入口 x0/x1 即 cover 那个 String），逐条指令是：
//
//      ZStack {
//          Color.black
//          if !cover.isEmpty {
//              RemoteImage(cover, .fill, .black, maxPixel: 48, interpolation: .high)
//                  .scaleEffect(1.4)     // 0x3ff6666666666666
//                  .opacity(0.6)         // 0x3fe3333333333333
//          }
//          LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.35)],
//                         startPoint: .top, endPoint: .bottom)
//          （旧值 0.15/0.88 是早期误写，现行为 top 0.10 / bottom 0.35，勿再以本注释为准）
//      }
//
//  ⚠️ 被否掉的旧结论（详见 TVCore/OneWatchPageModel.swift 的取证表）：
//    · `sub_1001e5360` 不是观看页背景（700px / .medium / clear→0.55 / center→bottom）；
//      它的 self 取自结构体 +0x38，与「self 就是一个 String」的 AmbientBackground 对不上。
//    · `blur(radius: 40)` 与 `dim 0.786` 是当年为凑「边缘能量 3.41」反推的假参数，
//      二进制里没有任何模糊调用。实测两者都比真实背景差一个数量级：
//      真实（亮度 57.6 / std 12.2 / 边缘 0.55），48px 方案（52.8 / 11.3 / 0.56），
//      700+blur40 方案（91.5 / 26.0 / 0.63）。
//    · 「海报顶部 9% 取样 + HSL 压 L/S + 三停渐变」是误读：`getHue` / `getRed` /
//      `CIAreaAverage` / `histogram` 在全部导入符号里 0 命中，One 不取色。
//

// MARK: - 背景视图

/// One 的观看页背景 —— 结构与常量都来自 `AmbientBackground.body`（`sub_1001e3ed4`）。
///
/// 三层，顺序即 One 的 `ZStack`：
///
/// 1. `Color.black` 打底；
/// 2. 封面：按 **48px** 解码 → `.high` 插值铺满 → `.scaleEffect(1.4)` → `.opacity(0.6)`；
/// 3. `LinearGradient(black 0.10 → black 0.35, .top → .bottom)`。
///
/// 「糊」全在第 2 步：48px 的图放大到 2034px 宽是 42 倍，再 `.high` 插值 ——
/// 得到的就是实机那种「没有边界、只有色块」的效果。**没有任何 `.blur()`**。
struct OneSkinBackdropLayer: View {
    /// 海报图；nil 时只剩黑底 + 渐变（One 在 `cover.isEmpty` 时同样如此）。
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black

            if let image {
                // 48px 解码是 One 的 `maxPixel` 参数本体。降采样用 ImageIO
                // （`CreateThumbnailFromImageAlways`），和 One 的 `RemoteImage` 同一套底层。
                Image(uiImage: OneSkinBackdropLayer.downsampled(
                        image, maxPixel: OneSkinBackdropMetrics.maxPixel))
                    .resizable()
                    // `.high`（`0x10031e9c8` = `Image.Interpolation.high`）。
                    // 这一项必须和 48px 配对：48px + 高质量插值 = 柔和的大色块；
                    // 换成 `.none` 会变成马赛克方块，换回 700px 则「过于清晰」。
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    // `scaleEffect(1.4)`：One 用这 40% 的放大把 48px 图像的
                    // 边缘推到屏幕外，避免低分辨率在边角露出硬边。
                    .scaleEffect(OneSkinBackdropMetrics.scale)
                    // ★ 高斯模糊必须在 `.clipped()` **之前**。
                    //
                    // 顺序错误会羽化露黑边：`.blur` 作用在已裁剪的结果上，
                    // 会在四边各羽化约一个半径宽的透明带，透出 ZStack 底下的
                    // `Color.black`（纯 0,0,0）—— 内屏实测 x<30pt 纯黑带
                    // （三模型审查 C-D1，OneSkinBackdrop.swift 修饰符顺序）。
                    // 正确顺序：blur 大图 → scale 1.4 已把羽化边推到屏幕外 → 再 clip。
                    .blur(radius: OneSkinBackdropMetrics.blurRadius)
                    .clipped()
                    // 历史（Frida 动态实测）：**这是 One 真正的做法，Frida 动态实测得出**：
                    // 在运行中的 One 1.7.0 里 dump CALayer，背景层挂的是
                    //     CALayer.filters = [CAFilter(name: "gaussianBlur")]
                    // 出现在 6 个 CALayer + 3 个 BackdropLayer 上。
                    //
                    // 之前所有静态判断都错了：符号表里搜 `UIBlurEffect` / `_BlurEffect` /
                    // `CIFilter` 名字都搜不到，因为 CAFilter 是私有类，名称和参数
                    // 都不进字符串表 —— 只有运行时 dump layer.filters 才看得见。
                    //
                    // 半径由输出反推（CAFilter 的 inputRadius 在私有 C++ 结构里取不到）：
                    // 与 One 截图缩到同尺度(263×102)比边缘能量，One=3.41、我们未模糊=22.95；
                    // radius=40 → 3.49，亮度同时命中(46.6 vs 47.1)。
                    // 用户可在「设置 → 播放 → 背景模糊」里调；0 = 关。
                    // `opacity(0.6)` 叠在黑底上，同时完成「压暗」——
                    // 这就是旧实现里 `backdropDim = 0.786` 想做的事，
                    // 但 One 是乘法混合，不是单独盖一层黑。
                    .opacity(OneSkinBackdropMetrics.coverOpacity)
            }

            // 渐变：**black 0.10 → black 0.35**，方向 **.top → .bottom**，两停写死。
            // 注意它**不在 `if let` 里**：One 的 ZStack 第三个元素是常驻的，
            // 无封面时也照画（曾经误放进 if 内，无图时候整页纯黑，底色断层）。
            LinearGradient(
                colors: [
                    .black.opacity(OneSkinBackdropMetrics.topDim),
                    .black.opacity(OneSkinBackdropMetrics.bottomDim),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    /// 按 `maxPixel` 降采样 —— **逐行对照 One 的 `sub_10011c554` 重写**。
    ///
    /// One 的原始实现（反编译 `0x10011c554`，完整结构）：
    /// ```
    /// src = CGImageSourceCreateWithData(data, [kCGImageSourceShouldCache: true])
    /// guard src != nil else { return nil }
    ///
    /// if CGImageSourceGetCount(src) >= 2 {        // 多帧（GIF/WebP 动画）
    ///     return UIImage(data: data)               // 原样返回，不缩
    /// }
    ///
    /// opts = [
    ///     kCGImageSourceCreateThumbnailFromImageAlways: true,   // 强制从原图生成
    ///     kCGImageSourceCreateThumbnailWithTransform:  true,    // 尊重 EXIF 方向
    ///     kCGImageSourceShouldCacheImmediately:        true,    // 立即解码
    ///     kCGImageSourceThumbnailMaxPixelSize:         maxPixel // Int，像素口径
    /// ]
    /// cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    /// return cg.flatMap { UIImage(cgImage: $0) }
    /// ```
    ///
    /// ⛔ 关键差别在 `CreateThumbnailFromImageAlways`：它会**无条件按 maxPixel 缩放**，
    /// 哪怕原图比 maxPixel 小 —— 也就是说 One 的「虚化强度」是**恒定的**
    /// （无论海报原图 270px 还是 2000px，解码后都是 maxPixel 那么大）。
    ///
    /// 我之前的写法用 `guard longEdge > maxPixel else { return image }`，
    /// 原图 270px 时直接跳过 → 不缩放 → 铺满屏幕靠 SwiftUI 插值 → 与本机
    /// ImageIO 的缩放算法不同，观感就和 One 不一致（用户报的「效果不一样」）。
    ///
    /// 还有一点：ImageIO 缩图是**高质量重采样**（内部 Lanczos），
    /// 而 `UIGraphicsImageRenderer` 走的是默认插值，两者糊的"质感"不同。
    /// 这里直接换成 ImageIO，和 One 用同一套底层。
    ///
    /// - Parameter image: 已解码的源图。为了走 ImageIO，这里重新编码成 Data；
    ///   `OneSkinPosterCache` 存的是 `UIImage`，拿不到原始字节，
    ///   所以用 `jpegData` 转一次（质量 1.0，不引入可见损失）。
    static func downsampled(_ image: UIImage, maxPixel: Int) -> UIImage {
        guard maxPixel > 0 else { return image }

        // ★ 结果缓存：`body` 每次重算都会调这里，而一次 ImageIO 缩图要先
        //   `pngData()` 重编码（512px 海报约 5–10ms）。旋转、手势动画期间
        //   body 会被反复求值，不缓存就是肉眼可见的掉帧。
        //
        //   key 用**源 UIImage 的地址**：海报换图时必定是新对象（地址变），
        //   同一张海报在整页生命周期内地址稳定，命中率高。
        let key = "\(ObjectIdentifier(image).hashValue)#\(maxPixel)" as NSString
        if let hit = Self.thumbCache.object(forKey: key) { return hit }

        // 拿到原始字节。有 cgImage 就用 PNG 保无损；没有就退回 JPEG。
        let data: Data
        if let png = image.pngData() {
            data = png
        } else if let jpg = image.jpegData(compressionQuality: 1.0) {
            data = jpg
        } else {
            return image
        }

        guard let src = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ) else { return image }

        // 多帧（GIF/动画 WebP）：One 原样返回，不缩。
        if CGImageSourceGetCount(src) >= 2 {
            oneSkinLog("BG downsample SKIP: multiframe count=\(CGImageSourceGetCount(src))")
            return image
        }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            oneSkinLog("BG downsample FAILED: src=\(CGImageSourceGetCount(src))f")
            return image
        }
        let out = UIImage(cgImage: cg)
        Self.thumbCache.setObject(out, forKey: key)
        oneSkinLog("BG downsample \(Int(image.cgImage?.width ?? 0))x\(Int(image.cgImage?.height ?? 0))px -> \(cg.width)x\(cg.height)px (max=\(maxPixel))")
        return out
    }

    /// 降采样结果缓存（`NSCache` 自带并发安全 + 内存压力回收）。
    ///
    /// 8 张足够：整页只有一张背景，切集时新旧两张并存也不过 2–3 张。
    private static let thumbCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()
}

/// 背景常量 —— **全部转发自 `TVCore.OneWatchPage.Backdrop`**（唯一真源，有回归测试）。
///
/// 这里不再写字面量：改背景观感必须先改 TVCore 那份断言，避免「悄悄改个浮点数」。
enum OneSkinBackdropMetrics {
    /// 封面解码上限像素 = **48**（`mov w8, #0x30`）。糊的本体。
    static let maxPixel: Int = OneWatchPage.Backdrop.maxPixel
    /// 封面放大倍数 = **1.4**（`0x3ff6666666666666`）。
    static let scale: Double = OneWatchPage.Backdrop.scale
    /// 封面不透明度 = **0.6**（`0x3fe3333333333333`），叠黑底即压暗。
    static let coverOpacity: Double = OneWatchPage.Backdrop.coverOpacity
    /// 渐变顶部黑。
    ///
    /// ⛔ 2026-11-11 真机反推修正：原值 0.15 / 0.88 会让**海报几乎不可见**。
    ///
    /// 反推过程（最终亮度 = (1-d) × opacity × 海报原亮度 L）：
    ///   底部实测 22.7，若 d=0.88 → L 需 315 > 255，**物理不可能**；
    ///   最亮处实测 110.7，若 d=0.15 → L 需 217（勉强），d=0.88 → L 需 1537（荒谬）。
    /// ⇒ One 的最终明暗**由海报自己决定**，渐变只是一层「保证文字可读」的兜底，
    ///   不是把画面压成黑的遮罩。用户明确说过：「它的明暗是根据海报来做的后续处理，
    ///   都取决于海报，而不是硬编码」。
    ///
    /// 新值只做最低限度的可读性保障：顶部略压（状态栏文字）、底部略压（按钮区）。
    /// 亮度层次全部交给模糊海报本身。
    static let topDim: Double = 0.10
    static let bottomDim: Double = 0.35
    /// 高斯模糊半径 —— 用户可调（设置 → 播放 → 背景模糊）。
    static var blurRadius: Double { OneWatchPage.Backdrop.currentBlurRadius }
}

// MARK: - 播放器窗口内的海报虚化底

/// 播放器窗口里 letterbox（视频上下 / 左右的空带）专用底：与海报同色的虚化。
///
/// 和 `OneSkinBackdropLayer` 的关键区别：**不用 `UIVisualEffectView`**。
/// `OneSkinPlayerLayer` 是 UIViewRepresentable，UIKit 把它的 UIView 排在同级
/// SwiftUI 内容之上；虚化层若也是 UIVisualEffectView，两个 UIKit 视图的叠放
/// 顺序不受 ZStack 声明序控制，虚化层可能盖到视频上、把画面一起糊掉。
/// 这里用 SwiftUI 原生 `.blur`，纯 SwiftUI 合成，永远待在视频层下面。
///
/// 2026-11-09：窗口内的空带以前是纯黑 —— 宿主 UIView `backgroundColor = .black`
/// 加左列 `.background(Color.black.opacity(0.88))` 叠三层，整块屏都黑掉。
/// 用户明确要求「它的上下应该和海报同色做虚化」。窗口内比整页背景亮一档，
/// 对应 One 左列「窗口内亮、窗口外暗带」的层次。
struct OneSkinPosterWash: View {
    let image: UIImage?
    /// 同色压暗：只降亮度、不改色相，海报的色调仍在。
    var dim: Double = 0.38
    var radius: CGFloat = 26

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // 略放大，避免模糊后边缘露出底色
                    .scaleEffect(1.18)
                    .blur(radius: radius)
                Color.black.opacity(dim)
                // 上下收一点暗，中间留住海报色 —— 参考 One 窗口内上暗/中亮/下暗
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(dim * 0.40), location: 0),
                        .init(color: .black.opacity(dim * 0.06), location: 0.5),
                        .init(color: .black.opacity(dim * 0.55), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipped()
    }
}


// MARK: - 已删除：材质模糊桥

// 2026-11-10 删除 `OneSkinMaterialBlur`（原 `UIVisualEffectView` + `UIBlurEffect(style: 9)`）。
//
// One 的观看页背景里没有模糊：`sub_1001e3ed4` 只做「海报原图 + 两停黑罩」。
// style 9 出现的地方是 `BlurShieldController.loadView`（后台任务卡片的隐私模糊），
// 与观看页无关。留着这个桥只会让后来的人以为背景该有材质。

// MARK: - 海报缓存

/// 海报原图缓存。取色和铺底都需要图，缩到 512px 足够。
actor OneSkinPosterCache {
    static let shared = OneSkinPosterCache()

    private var memory: [URL: UIImage] = [:]
    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OneSkinPoster", isDirectory: true)
    }()

    func image(for url: URL) -> UIImage? {
        if let hit = memory[url] { return hit }
        let file = folder.appendingPathComponent(Self.key(for: url))
        guard let data = try? Data(contentsOf: file), let img = UIImage(data: data) else { return nil }
        memory[url] = img
        return img
    }

    func store(_ image: UIImage, for url: URL) {
        let scaled = Self.downscale(image, to: 512)
        memory[url] = scaled
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(Self.key(for: url)), options: .atomic)
    }

    private static func downscale(_ image: UIImage, to maxSide: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w > maxSide || h > maxSide else { return image }
        let scale = maxSide / max(w, h)
        let size = CGSize(width: w * scale, height: h * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 文件名用 URL 的稳定哈希，避免非法字符。
    private static func key(for url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - 视口尺寸

// 2026-11-09：删掉 `OneSkinViewport`（约 75 行死代码）。
//
// 它自称「不能用 GeometryReader」，body 里却仍在 `.background` 放了一个
// GeometryReader，`onAppear` / `onChange(of: proxy.size)` / 两个方向通知
// 共 5 个来源把测量结果写回 `@State size`，再由 `content(size)` 拿去排版 ——
// 正是「子测父、父按子排版」的反馈环，注释里自己都写了「每转一次屏就缩一圈，
// 整个界面往左上角漂」。它现在没有实例化点，但留着就会在下一次回归时被重新启用。
//
// 现在几何只由 `OneSkinStage` 根部 GeometryReader 在闭包内直接使用，
// 不写任何 @State；`VideoDetailView` 侧则只在离散形态变化时采样一次。

#else
// ═══════════════════════════════════════════════════════════════════════════
// tvOS 段：本文件被跨平台视图引用的部分
// ═══════════════════════════════════════════════════════════════════════════
//
// iOS 段围绕 `UIVisualEffectView` / `UIViewRepresentable` 写，tvOS 二者都没有（实证），整段不搬。
// 但 `OneSkinPosterWash` 是**纯 SwiftUI**（UIImage + Image(uiImage:) + blur + 渐变），
// tvOS 全部支持 → 原样移植，是真实现，不是空壳。
import SwiftUI
import TVCore

/// 海报虚化铺底。与 iOS 版逐行同义。
struct OneSkinPosterWash: View {
    let image: UIImage?
    var dim: Double = 0.38
    var radius: CGFloat = 26

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.18)
                    .blur(radius: radius)
                Color.black.opacity(dim)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(dim * 0.40), location: 0),
                        .init(color: .black.opacity(dim * 0.06), location: 0.5),
                        .init(color: .black.opacity(dim * 0.55), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipped()
    }
}
#endif

// MARK: - 主题底开关

/// 皮肤开着时不铺主题底（`Backdrop` 是浅色 244,246,251，会把 One 的黑底顶起来）。
struct ScreenBackdropIfNeeded: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.screenBackdrop()
        } else {
            content
        }
    }
}
