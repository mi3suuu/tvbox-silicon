#if os(iOS)
import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - 半折下半屏控制台（对齐哔哩哔哩 BBPlayerHalfFoldConsoleWidget）
//
// 真机结构（静态实证，见 `Docs/duo/哔哩哔哩-9.18-逆向-三形态与小窗真机结构.md`）：
//
//   class BBPlayerHalfFoldConsoleWidget: BBPlayerWidget {
//       let currentTimeLabel: UILabel
//       let durationLabel: UILabel
//       let brightnessSlider: BBPlayerHalfFoldSliderView
//       let volumeSlider:     BBPlayerHalfFoldSliderView
//       let systemVolumeView: MPVolumeView
//       var coverImageView:   UIImageView?
//       var seekHiddenViews:  [UIView]
//   }
//   BBPlayerHalfFoldWidgetService: enterWithUpperRect:lowerRect: / exit / isHalfFoldActive
//
// 关键：**下半屏是控制台，不是详情列**。
// 半折（书本/帐篷）时上半屏放画面、下半屏放「封面 + 时间 + 亮度 + 音量 + 进度」，
// 用户单手就能调，不用把设备摊平。我们此前完全没有这个形态 —— 半折时
// 要么按展开竖持排版（详情列挤在窄高度里），要么按合盖排版（画面占满）。
//
// 为什么亮度/音量要放在这里而不是只靠手势：半折时下半屏就在手掌里，
// 滑块比「在画面上上下滑」精确得多，也不干扰上半屏的观看。

/// 半折时下半屏的控制台。
/// 半折控制台的配色。
///
/// ⛔ 为什么要做成一族参数：本视图**挂在 One 皮肤**（`OneSkin.swift` 的半折分支），
/// 而 One 是**深色**版式（右栏文字区实测 RGB 约 52,50,50）。此前本文件把每一处颜色
/// 都写成 `BiliPalette.light*`（哔哩哔哩**亮色**板），真机实测后果是：
///
///   `-qaSection home -qaPage one-preview -qaOneShape halfFold` 的截图里
///   上半屏（画面）纯黑 RGB(2.7,2.7,2.7)，
///   下半屏（控制台）近白 RGB(248.7,249.4,250.0)，近白像素占 95.1%，
///   上下分界 y=334.7pt（50.02%）—— 一块深色页面里贴了一张白纸。
///
/// 配色是**皮肤的**属性，不该由「这个控件最早为谁写」决定。所以做成注入值，
/// One 传深色、哔哩哔哩若将来要用就传 `.biliLight`。
struct HalfFoldConsolePalette {
    /// 下半屏底色。
    var page: Color
    /// 主文字（标题、播放键）。
    var primary: Color
    /// 次文字（亮度/音量图标）。
    var secondary: Color
    /// 三级文字（时间码、百分比）。
    var tertiary: Color
    /// 轨道 / 封面占位等中性填充。
    var fill: Color
    /// 强调色（进度条、滑块）。
    var accent: Color

    /// One 皮肤：深色。底与右栏同族（深灰，不是纯黑，避免与上半屏画面黑连成一片）。
    ///
    /// 数值取 One 右栏实测的文字区背景 (52,50,50) 稍压暗一档，
    /// 让「控制台」与「详情列」在视觉上可分但同属深色体系。
    static let oneDark = HalfFoldConsolePalette(
        page: Color(biliHex: 0x2A2929),
        primary: Color(biliHex: 0xF2F1F1),
        secondary: Color(biliHex: 0xB8B6B6),
        tertiary: Color(biliHex: 0x8C8A8A),
        fill: Color(biliHex: 0x454343),
        accent: Color(biliHex: 0xFF6699)
    )

    /// 哔哩哔哩亮色板（原行为，保留给该皮肤将来接入时用）。
    static let biliLight = HalfFoldConsolePalette(
        page: BiliPalette.lightPage,
        primary: BiliPalette.lightPrimary,
        secondary: BiliPalette.lightSecondary,
        tertiary: BiliPalette.lightTertiary,
        fill: BiliPalette.lightFill,
        accent: BiliPalette.accent
    )
}

struct HalfFoldConsoleView: View {
    /// 播放会话（进度、时长、播放/暂停）。
    var session: PlaybackSession?
    /// 当前封面（已解好的图，复用播放页海报缓存 —— 不二次下载）。
    /// `nil` 时画中性占位，不编造图片。
    var cover: UIImage?
    /// 页头（集名等）。
    var title: String
    /// 下半屏可用的高度（由 `FoldSplitLayout` 的 lower rect 给）。
    var height: CGFloat
    /// 配色。默认深色 —— 当前唯一调用方是 One 皮肤。
    var palette: HalfFoldConsolePalette = .oneDark
    /// 点画面/进度条跳转（0…1）。
    var onSeek: (Double) -> Void = { _ in }

    @State private var systemVolume = MusicVolumeSlider.SystemSlider()
    /// 拖动中的进度（0…1）。拖的时候不跟随播放位置，松手才 seek。
    @State private var scrubbing: Double?
    /// 进控制台时的屏幕亮度。离开时**恢复**，否则用户回桌面发现屏幕被压暗。
    @State private var brightnessBefore: CGFloat?

    private var position: Double { scrubbing.map { $0 * max(session?.duration ?? 0, 1) } ?? (session?.position ?? 0) }
    private var duration: Double { session?.duration ?? 0 }
    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sliders
            seekbar
            transport
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.page)
        // 隐藏的系统音量视图：`SystemSlider` 靠它拿到 UISlider 才能写音量。
        // 1×1 且不吃触摸 —— 只是宿主，不参与布局。
        .background {
            MusicVolumeSlider.HiddenVolumeView(system: systemVolume)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .onAppear {
            // 记住进入前的亮度，离开时恢复。
            if brightnessBefore == nil, let screen = UIApplication.shared.appWindowScene?.screen {
                brightnessBefore = screen.brightness
            }
        }
        .onDisappear {
            if let before = brightnessBefore,
               let screen = UIApplication.shared.appWindowScene?.screen {
                screen.brightness = before
            }
            brightnessBefore = nil
            scrubbing = nil
        }
    }

    // MARK: 封面 + 标题 + 时间

    private var header: some View {
        HStack(spacing: 12) {
            coverThumb
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                // 时间放在封面右边而不是另起一行：下半屏高度有限，
                // 每省一行就多给滑块一点触控余量。
                Text("\(BiliClock.text(position))/\(BiliClock.text(duration))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// 封面缩略。高度跟着下半屏高度走（范围 40…64），
    /// 半折角度不同时下半屏高度会变，写死会让卡片被裁。
    private var coverThumb: some View {
        let side = min(max(height * 0.16, 40), 64)
        return Group {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                palette.fill
            }
        }
        .frame(width: side * 16 / 9, height: side)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 亮度 / 音量

    private var sliders: some View {
        VStack(spacing: 6) {
            consoleSlider(symbol: "sun.max.fill",
                          value: Binding(
                              get: { Double(UIApplication.shared.appWindowScene?.screen.brightness ?? 0.5) },
                              set: { newValue in
                                  UIApplication.shared.appWindowScene?.screen.brightness = CGFloat(newValue)
                              })) {
                // 进控制台时还没记过就记一次（`onAppear` 也可能晚于第一次拖动）。
                if brightnessBefore == nil {
                    brightnessBefore = UIApplication.shared.appWindowScene?.screen.brightness
                }
            }
            consoleSlider(symbol: "speaker.wave.2.fill",
                          value: Binding(
                              get: {
                                  // `MPVolumeView` 的 UISlider 在系统里恒有值；
                                  // 拿不到时返回当前系统音量，不编一个假值。
                                  Double(systemVolume.slider?.value ?? AVAudioSession.sharedInstance().outputVolume)
                              },
                              set: { systemVolume.set($0) }))
        }
        .padding(.horizontal, 14)
    }

    /// 一根「图标 + 滑块 + 百分比」的控制条。三个形态共用这一种款式，
    /// 与哔哩哔哩半折控制台的两个 `BBPlayerHalfFoldSliderView` 同构。
    private func consoleSlider(symbol: String,
                               value: Binding<Double>,
                               onEditing: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondary)
                .frame(width: 18)
            Slider(value: value, in: 0...1) { editing in
                if editing { onEditing() }
            }
            .tint(palette.accent)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 30)
    }

    // MARK: 进度

    private var seekbar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.fill).frame(height: 4)
                    Capsule().fill(palette.accent)
                        .frame(width: geo.size.width * fraction, height: 4)
                    Circle().fill(palette.accent)
                        .frame(width: 9, height: 9)
                        .offset(x: geo.size.width * fraction - 4.5)
                }
                .frame(height: 10)
                .contentShape(Rectangle())
                // 拖动用 `DragGesture` 而不是 `onTapGesture(location:)`：
                // 半折时用户会按住拖，只支持点会让他以为「拖不动」。
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard geo.size.width > 0 else { return }
                            scrubbing = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { value in
                            guard geo.size.width > 0, duration > 0 else { scrubbing = nil; return }
                            let target = min(max(value.location.x / geo.size.width, 0), 1)
                            onSeek(target)
                            scrubbing = nil
                        }
                )
            }
            .frame(height: 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: 播放控制

    private var transport: some View {
        HStack(spacing: 28) {
            Spacer(minLength: 0)
            transportButton("gobackward.10") { session?.skip(-10) }
            transportButton(session?.paused == false ? "pause.fill" : "play.fill", size: 22) {
                session?.togglePlayback()
            }
            transportButton("goforward.10") { session?.skip(10) }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func transportButton(_ symbol: String,
                                 size: CGFloat = 17,
                                 _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(palette.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif
