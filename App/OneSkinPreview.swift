#if DEBUG && os(iOS)
import SwiftUI
import TVCore

/// One 播放页的 SwiftUI Preview 载体。
///
/// 目的：改布局常量时不必「构建 → 装机 → 进播放页」走一遍（约 8 分钟），
/// 在 Xcode 预览里即时看效果。
///
/// 用法：
///   1. Xcode 打开 `App/OneSkinPreview.swift`，开 Canvas（⌥⌘↩）
///   2. 右上角切 device / 光照
///   3. 想看别的形态：改下面 `#Preview` 里的 `qaShape`
///
/// 注意：这里**只用固定 mock 数据**，不连网络、不读 Store，
/// 所以预览是确定性的，不会因为播放页进不去而黑屏。
struct OneSkinPreviewHost: View {
    /// 强制形态：column / split / fullBleed / halfFold
    let qaShape: String
    /// 模拟画布尺寸（决定 Preview 里的设备形状）
    let canvas: CGSize

    /// 预览专用 Store 实例（隔离磁盘状态，避免预览依赖真实订阅数据）。
    @State private var previewStore = Store()

    private var video: Video {
        Video(
            id: "preview-1",
            name: "预览用影片标题 · 这是一个很长很长的片名用来测两行截断",
            year: "2026",
            remarks: "更新至 36 集",
            synopsis: "这是一段用于预览的简介文本，用来检查详情区正文的行高、截断与内边距是否符合真机 One 的排版。再补一些字让它超过三行，看省略号位置。",
            episodes: (1...12).map { Episode(id: "ep\($0)", name: "第 \($0) 集", address: "https://example.com/\($0).m3u8", flag: "线路1") },
            category: "国产,剧情"
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            OneSkinStage(
                video: video,
                detail: nil,
                current: video.episodes.first,
                playing: false,
                busy: false,
                aspectRatio: 16.0 / 9.0,
                shape: OneSkinPreviewShape.from(qaShape),
                channel: nil,
                avPlayer: nil,
                session: nil,
                onExitFullScreen: {},
                onPlay: { _ in },
                onTogglePlay: {},
                onSeekBack: {},
                onSeekForward: {},
                onFullScreen: {},
                onEpisodes: {},
                onToggleSkin: {},
                isFavorite: false,
                lines: ["线路1", "线路2"],
                activeLine: "线路1"
            )
        }
        .frame(width: canvas.width, height: canvas.height)
        // ★ OneSkinPlayerChrome 用 @Environment(Store.self) 读控件布局/弹幕/字幕样式。
        //   预览必须注入，否则崩在 Environment+Objects.swift（缺 EnvironmentObject）。
        //
        // 用**独立实例**而不是 Store.shared：shared 会读订阅文件/启动加载，
        // 预览里可能因为磁盘状态不同而行为不一致。独立实例只用于取控件布局默认值。
        .environment(previewStore)
        .preferredColorScheme(.dark)
    }
}

/// `-qaPage one-preview` 的宿主：把 One 皮肤按**当前窗口真实尺寸**铺满渲染。
///
/// 与 `#Preview` 里的 `OneSkinPreviewHost` 的区别只有两点：
///   1. 画布不再写死，取 GeometryReader 的 `proxy.size`（否则在 466×678 的外屏上
///      仍按 669×951 排版 —— 正是「内容比窗口宽、两侧被裁」的来源）；
///   2. mock 数据贴参考截图：20 集、长标题、两行简介、十个 tag，
///      这样换行/间距/截断都能和真 One 截图逐项对。
///
/// 固定 mock、不读 Store、不连网络，所以截图是确定性的。
struct OneSkinQAHost: View {
    let shapeKey: String

    @State private var previewStore = Store()

    private var video: Video {
        Video(
            id: "qa-one-1",
            name: "[ONE直播▶️]喵呜2026年🐎直播合集",
            year: "2026-11-03",
            remarks: "人间杀妈客 · ♥ 14k",
            synopsis: "此合集为【ONE直播】主播-喵呜，2026年直播回放合集后续直播回放将陆续更新在此合集系列中，敬请期待！",
            episodes: (1...20).map { i in
                Episode(id: "ep\(i)", name: "第\(i)集 · 2026-03-12", address: "https://example.com/\(i).m3u8", flag: "线路9")
            },
            category: "国产,直播,ONE直播,主播,喵呜,苗条,黑丝,自慰,淫语,炮机"
        )
    }

    var body: some View {
        GeometryReader { proxy in
            OneSkinStage(
                video: video,
                detail: nil,
                current: video.episodes.first,
                playing: false,
                busy: false,
                aspectRatio: 16.0 / 9.0,
                shape: OneSkinPreviewShape.from(shapeKey),
                channel: nil,
                avPlayer: nil,
                session: nil,
                onExitFullScreen: {},
                onPlay: { _ in },
                onTogglePlay: {},
                onSeekBack: {},
                onSeekForward: {},
                onFullScreen: {},
                onEpisodes: {},
                onToggleSkin: {},
                isFavorite: false,
                lines: ["线路9"],
                activeLine: "线路9"
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .environment(previewStore)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

private enum OneSkinPreviewShape {
    static func from(_ key: String) -> OneSkinShape {
        switch key {
        case "split":     return .split
        case "fullBleed": return .fullBleed
        case "halfFold":  return .halfFold
        default:          return .column
        }
    }
}

// MARK: - 六形态预览

/// 内屏展开横持 951×669 —— 双栏，当前主攻形态。
#Preview("内屏横持 951×669") {
    OneSkinPreviewHost(qaShape: "split", canvas: CGSize(width: 951, height: 669))
}

/// 内屏展开竖持 669×951。
#Preview("内屏竖持 669×951") {
    OneSkinPreviewHost(qaShape: "fullBleed", canvas: CGSize(width: 669, height: 951))
}

/// 外屏合盖竖持 466×678。
#Preview("外屏竖持 466×678") {
    OneSkinPreviewHost(qaShape: "column", canvas: CGSize(width: 466, height: 678))
}

/// 外屏合盖横持 678×466。
#Preview("外屏横持 678×466") {
    OneSkinPreviewHost(qaShape: "split", canvas: CGSize(width: 678, height: 466))
}

/// 半折 951×669。
#Preview("半折 951×669") {
    OneSkinPreviewHost(qaShape: "halfFold", canvas: CGSize(width: 951, height: 669))
}
#endif
