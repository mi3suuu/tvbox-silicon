//
//  OneSkinBackdrop.swift  [mi3s]
//
//  One 观看页的背景：海报铺底 → UIBlurEffect(.systemThinMaterial) → 暗色渐变。
//
//  机制来源（One 二进制反编译，不是猜的）：
//    0x10019fb7c  _objc_opt_self(UIBlurEffect)
//    0x10019fb84  init(style:)  实参 w2 = 0x9  →  UIBlurEffect.Style.systemThinMaterial
//    0x10019fb60  UIVisualEffectView 相关实参 2
//    0x10019fb6c  相关实参 1
//    0x100325830  _OBJC_CLASS_$_UIVisualEffectView
//  即 One 用的是 UIVisualEffectView + UIBlurEffect，不是 CoreImage，也不是 SwiftUI .blur()。
//
//  为什么这样能对上截图：
//    material 会把底下的海报糊成大块色斑 —— 实测背景"最干净块"σ 只有 0.6（被压平了），
//    但整片仍有大尺度起伏（std 60），正是材质压过图的样子。
//    纯色渐变做不到这个。
//

import SwiftUI
import UIKit

// MARK: - 背景视图

/// One 的观看页背景：海报 → 材质模糊 → 压暗。
struct OneSkinBackdropLayer: View {
    /// 海报图；nil 时退回纯黑，和 One 无海报时一致。
    let image: UIImage?
    /// 压暗强度。One 实测：右边缘峰值 #4A433D，底部 #070605。
    var dim: Double = 0.78   // 参考实测：左列上区亮度 70-90、底部 14；0.62 时实测整屏 159 过亮

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // 略放大，避免模糊后边缘露出底色
                    .scaleEffect(1.18)
                    .clipped()

                // 关键：UIBlurEffect(.systemThinMaterial)，style = 9，与 One 一致
                OneSkinMaterialBlur(style: 9)

                // 压暗 + 上下收黑。
                // 2026-11-09：原来底部压到 0.97 黑，播放器**上下**整片变成中性黑
                // (21,23,28)，海报色一点不剩 —— 用户要的是「上下和海报同色做虚化」。
                // 改成上下都留住一档海报色，底部仍最暗（对应 One 的暗带 ≈36/255），
                // 但不再是纯黑。中间 0.13 处最亮，保持 One 的大尺度明暗起伏。
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(dim * 0.55), location: 0),
                        .init(color: .black.opacity(dim * 0.34), location: 0.13),
                        .init(color: .black.opacity(dim * 0.72), location: 0.55),
                        .init(color: .black.opacity(min(0.82, dim * 1.05)), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // 整屏再压一层：material 本身透亮，参考整页均值 ~50
                Color.black.opacity(0.12)
            }
        }
        .ignoresSafeArea()
    }
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

// MARK: - UIVisualEffectView 桥

/// `UIVisualEffectView` 的 SwiftUI 包装。
/// style 用整数传，方便和 One 里读到的常量直接对齐。
struct OneSkinMaterialBlur: UIViewRepresentable {
    let style: Int

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIBlurEffect(style: Self.blurStyle(style))
        let view = UIVisualEffectView(effect: effect)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: Self.blurStyle(style))
    }

    /// 把整数映射到 SDK 里真实存在的 style；越界时按语义就近取。
    private static func blurStyle(_ raw: Int) -> UIBlurEffect.Style {
        switch raw {
        case 0: return .extraLight
        case 1: return .light
        case 2: return .dark
        case 3: return .extraLight
        case 4: return .regular
        case 5: return .prominent
        case 6: return .regular
        case 7: return .systemUltraThinMaterial
        case 8: return .systemUltraThinMaterial
        case 9: return .systemThinMaterial      // ← One 用的是这个
        case 10: return .systemMaterial
        case 11: return .systemThickMaterial
        case 12: return .systemChromeMaterial
        case 13: return .systemUltraThinMaterialLight
        case 14: return .systemThinMaterialLight
        case 15: return .systemMaterialLight
        case 16: return .systemThickMaterialLight
        case 17: return .systemChromeMaterialLight
        case 18: return .systemUltraThinMaterialDark
        case 19: return .systemThinMaterialDark
        case 20: return .systemMaterialDark
        case 21: return .systemThickMaterialDark
        case 22: return .systemChromeMaterialDark
        default: return .systemThinMaterial
        }
    }
}

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
