#if os(iOS)
import SwiftUI
import TVCore

// MARK: - 哔哩哔哩的三个弹出面板（按实测复刻）

/// 这三个面板在哔哩哔哩里是**三套独立实现**，条目集不同：
///
/// - `BiliActionMenu`   ← 详情页「更多操作」。两行横向按钮，64×77 / 64×102。
/// - `BiliSettingsSheet`← 竖屏全屏齿轮。底部覆盖，含 Speed 七档 + Timer + 开关。
/// - `BiliSettingsRail` ← 横屏全屏三点。右缘竖条，含单集循环/镜像/后台/画幅。
///
/// 所有尺寸取自 `BiliMetrics`，不在这里写魔法数字。

// MARK: - ① 操作菜单

/// 两行图标按钮。实测：第一行 7 个 64×77、第二行 6 个 64×102，行距 81pt。
///
/// 横屏从 x≈262 起（贴右半屏），竖屏从 x≈26 起（几乎整宽）——
/// 按钮尺寸与行距两态完全一致，只有起点不同，所以用同一个组件 + 参数。
struct BiliActionMenu: View {
    /// 竖屏还是横屏。决定整块的起始 x，以及**是否追加底部两段**。
    ///
    /// 实测（48 元素那次）：竖屏操作菜单 = 两行按钮（64×77 / 64×102）
    /// **+ Speed 七档（57×21）+ 两个开关行**；横屏只有两行按钮。
    /// 之前竖屏少了后两段，所以和哔哩哔哩对不上。
    var portrait: Bool = true

    /// 竖屏专属：倍速与两个开关的绑定。
    var speed: Binding<Float>? = nil
    var autoPlayNext: Binding<Bool>? = nil
    var loopPlayback: Binding<Bool>? = nil

    var onPosts: () -> Void = {}
    var onMessage: () -> Void = {}
    var onPic: () -> Void = {}
    var onDownload: () -> Void = {}
    var onShareFromHere: () -> Void = {}
    var onCopyLink: () -> Void = {}
    var onMore: () -> Void = {}

    var onSeeOriginal: () -> Void = {}
    var onNotInterested: () -> Void = {}
    var onWatchLater: () -> Void = {}
    var onPiP: () -> Void = {}
    var onCast: () -> Void = {}

    var body: some View {
        // ⚠️ 实测弹窗是**可滚动长面板**，内容远超一屏。
        // 用户明确指出「它里面是有很多内容的，下拉才可以看到」。
        // 滚动实测露出的下半段：`Danmu Settings` / `Mirror Flip`（与竖屏设置面板同款段落）。
        // 之前是裸 `VStack`，内容一多就溢出/截断 —— 必须包 `ScrollView`。
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            // 第一行：分享/操作，7 个 64×77
            HStack(spacing: 0) {
                menuItem("square.and.arrow.up", L10n.text("Posts"), M.menuRow1Item, onPosts)
                // 专用键：Message 在别的界面已译作「内容」，全局改会伤到那里。
                menuItem("bubble.left", L10n.text("Bili Message"), M.menuRow1Item, onMessage)
                menuItem("photo", L10n.text("Bili Pic"), M.menuRow1Item, onPic)
                menuItem("arrow.down.circle", L10n.text("Download"), M.menuRow1Item, onDownload)
                menuItem("square.and.arrow.up.on.square", L10n.text("Share from Here"), M.menuRow1Item, onShareFromHere)
                menuItem("link", L10n.text("Copy Link"), M.menuRow1Item, onCopyLink)
                menuItem("ellipsis", L10n.text("More"), M.menuRow1Item, onMore)
            }
            // 行距 81pt —— 实测两态一致
            .padding(.bottom, 0)

            // 第二行：播放功能，6 个 64×102
            HStack(spacing: 0) {
                menuItem("rectangle.on.rectangle", L10n.text("See Original"), M.menuRow2Item, onSeeOriginal)
                menuItem("hand.thumbsdown", L10n.text("Not Interested"), M.menuRow2Item, onNotInterested)
                menuItem("clock", L10n.text("Watch later"), M.menuRow2Item, onWatchLater)
                menuItem("arrow.down.circle", L10n.text("Download"), M.menuRow2Item, onDownload)
                menuItem("pip", L10n.text("PiP"), M.menuRow2Item, onPiP)
                menuItem("airplayvideo", L10n.text("Cast"), M.menuRow2Item, onCast)
            }
            .padding(.top, 4)

            // 竖屏追加：Speed 七档 + 两个开关（实测在 495 / 587 / 635 三行）
            if portrait, let speed {
                Text(L10n.text("Playback Speed"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BiliPalette.lightPrimary)
                    .padding(.leading, 60)
                    .padding(.top, 18)

                HStack(spacing: 0) {
                    ForEach(speeds, id: \.self) { value in
                        let active = abs(speed.wrappedValue - value) < 0.001
                        Button { speed.wrappedValue = value } label: {
                            Text(String(format: value == 1 ? "1.0" : "%g", value))
                                .font(.system(size: 11, weight: active ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(active ? BiliPalette.accent : BiliPalette.lightSecondary)
                                .frame(width: M.speedChipSmall.width, height: M.speedChipSmall.height)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(active ? BiliPalette.accent.opacity(0.16) : BiliPalette.card.opacity(0.5))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 32)
                .padding(.top, 6)

                if let autoPlayNext {
                    actionSwitchRow(L10n.text("Auto-play Next"), autoPlayNext)
                }
                if let loopPlayback {
                    actionSwitchRow(L10n.text("Loop playback"), loopPlayback)
                }
            }
        }
        .padding(.leading, portrait ? M.menuPortraitOriginX : M.menuLandscapeOriginX)
        }
        .scrollIndicators(.hidden)
    }

    /// 实测七档，含 3.0。
    private var speeds: [Float] { [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0] }

    /// 开关行：文字 x=60、开关贴右 x=392（实测）。
    private func actionSwitchRow(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(BiliPalette.lightPrimary)
                .padding(.leading, M.switchTextInset)
            Spacer(minLength: 0)
            Toggle("", isOn: value)
                .labelsHidden()
                .tint(BiliPalette.pink)
                .frame(width: M.switchSize.width, height: M.switchSize.height)
                .padding(.trailing, 14)
        }
        .frame(height: 40)
        .padding(.top, 6)
    }

    private func menuItem(_ symbol: String, _ title: String, _ size: CGSize,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(BiliPalette.lightPrimary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(BiliPalette.lightSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: size.width, height: size.height)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ② 竖屏设置（底部覆盖）

/// 实测条目与尺寸：
/// ```
/// See Original / Watch Later / PiP / Cast   ← 四个 85×102
/// Speed                                      ← 分区标题 高17
/// 0.5 0.75 1.0 1.25 1.5 2.0 3.0             ← 七个 62×51，步长 62.5
/// Timer
/// Disabled 15:00 30:00 60:00 Custom          ← 五个 86.8×51
/// Auto-Play Next                             ← 开关 40.9×18.2 @ x=392
/// Loop playback
/// ```
struct BiliSettingsSheet: View {
    /// 打开时要滚到的分区。默认 `.speed`。
    var focus: BiliSettingsFocus = .speed
    /// 选集列表（全屏底栏的 Episodes 落到本面板时需要）。
    var episodes: [Episode] = []
    var playing: Episode?
    var onSelectEpisode: (Episode) -> Void = { _ in }

    /// `116.2` → `01:56`（只格式化已有数据，不补零编造）。
    private static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    @Binding var speed: Float
    @Binding var sleepMinutes: Int
    @Binding var autoPlayNext: Bool
    @Binding var loopPlayback: Bool
    // 实测面板里的三个开关（顺序与实测一致）
    @Binding var backgroundAudio: Bool
    @Binding var subtitlesOn: Bool
    @Binding var mirror: Bool
    // 四个整宽可点行
    var onSubtitleSettings: () -> Void = {}
    var onDanmuSettings: () -> Void = {}
    var onMoreSettings: () -> Void = {}
    var onNotes: () -> Void = {}
    var onClose: () -> Void = {}
    var onSeeOriginal: () -> Void = {}
    var onWatchLater: () -> Void = {}
    var onPiP: () -> Void = {}
    var onCast: () -> Void = {}

    /// 实测七档，注意含 **3.0**（此前漏过）。
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    /// 实测四档 + Custom。
    private let timers: [(Int, String)] = [(0, "Disabled"), (15, "15:00"), (30, "30:00"), (60, "60:00"), (-1, "Custom")]

    var body: some View {
        // 用 ScrollViewReader 把落点滚到 `focus` 指定的分区。
        // 不这样做的话，点「字幕」「画质」都会停在最顶上，看到的是 See Original。
        ScrollViewReader { proxy in
        ScrollView {
        // ⚠️ `frame(maxWidth: .infinity, alignment: .leading)` 不能省。
        // 里面全是定宽子项（85×102 按钮、62×51 chip），`VStack` 会被压到内容宽度，
        // 于是「贴底整宽面板」渲染出来是一条窄条 —— 这就是竖屏设置看着像右缘竖条的原因。
        VStack(alignment: .leading, spacing: 0) {
            // 四个大按钮 2×2（实测 85×102，步长 85）
            HStack(spacing: 0) {
                bigButton("rectangle.on.rectangle", L10n.text("See Original"), onSeeOriginal)
                bigButton("clock", L10n.text("Watch Later"), onWatchLater)
                bigButton("pip", L10n.text("PiP"), onPiP)
                bigButton("airplayvideo", L10n.text("Cast"), onCast)
            }
            .padding(.leading, M.sectionInset)

            sectionTitle(L10n.text("Playback Speed")).id(BiliSettingsFocus.speed)
            HStack(spacing: 0) {
                ForEach(speeds, id: \.self) { value in
                    chip(String(format: value == 1 ? "1.0" : "%g", value),
                         size: M.speedChipLarge,
                         active: abs(speed - value) < 0.001) {
                        speed = value
                    }
                }
            }
            .padding(.leading, M.sectionInset)

            // ⚠️ 实测（竖屏全屏 15 元素）：Timer 不是一排 chip，而是**一整条 434×52 的可点行**；
            // 下面依次是 3 个开关行 + 4 个整宽可点行。整块左右各留 16pt（434 = 466 - 32）。
            // 七档倍速**不在这个面板里**（它在操作菜单）。
            rowButton(L10n.text("Timer"), detail: timerLabel) { cycleTimer() }
                .id(BiliSettingsFocus.timer)

            switchRow2(L10n.text("Background Play"), $backgroundAudio)
            switchRow2(L10n.text("Subtitles"), $subtitlesOn)

            rowButton(L10n.text("Subtitle settings"), detail: nil) { onSubtitleSettings() }
            rowButton(L10n.text("Danmu Settings"), detail: nil) { onDanmuSettings() }

            switchRow2(L10n.text("Mirror Flip"), $mirror)

            rowButton(L10n.text("More playback settings"), detail: nil) { onMoreSettings() }
            rowButton(L10n.text("Notes"), detail: nil) { onNotes() }

            switchRow(L10n.text("Auto-Play Next"), $autoPlayNext)
            switchRow(L10n.text("Loop playback"), $loopPlayback)

            // 字幕 / 画质两节：哔哩哔哩在这里放实际选项，但我们没有字幕轨
            // 与清晰度列表数据源接到这一层，所以只留可定位的标题，不编造候选项。
            sectionTitle(L10n.text("Subtitles")).id(BiliSettingsFocus.subtitles)
            Text(L10n.text("Follows the player's current track."))
                .font(.system(size: 11))
                .foregroundStyle(BiliPalette.lightTertiary)
                .padding(.leading, M.sectionInset)
                .padding(.bottom, 6)

            // 全屏底栏的 `Episodes` 也落到这个面板 —— 实测四钮同源。
            // 这里给出选集区锚点，让 `scrollTo(.episodes)` 有落点。
            sectionTitle(L10n.text("Episodes")).id(BiliSettingsFocus.episodes)
            if episodes.isEmpty {
                Text(L10n.text("No episodes for this video."))
                    .font(.system(size: 11))
                    .foregroundStyle(BiliPalette.lightTertiary)
                    .padding(.leading, M.sectionInset)
                    .padding(.bottom, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(episodes.prefix(20)) { ep in
                        Button { onSelectEpisode(ep) } label: {
                            HStack(spacing: 0) {
                                Text(ep.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(playing?.id == ep.id
                                                     ? BiliPalette.accent : BiliPalette.lightPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let d = ep.duration, d > 0 {
                                    Text(Self.mmss(d))
                                        .font(.system(size: 10))
                                        .monospacedDigit()
                                        .foregroundStyle(BiliPalette.lightTertiary)
                                }
                            }
                            .padding(.horizontal, M.sectionInset)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
            }

            sectionTitle(L10n.text("Quality")).id(BiliSettingsFocus.quality)
            Text(L10n.text("Follows the player's current quality."))
                .font(.system(size: 11))
                .foregroundStyle(BiliPalette.lightTertiary)
                .padding(.leading, M.sectionInset)
                .padding(.bottom, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        }
        .onAppear { proxy.scrollTo(focus, anchor: .top) }
        }
        .background(BiliPalette.lightPanel)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(BiliPalette.lightPrimary)
            .frame(height: M.sectionTitleHeight)
            .padding(.leading, M.sectionInset)
            .padding(.top, 12)
    }

    private func chip(_ title: String, size: CGSize, active: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(active ? BiliPalette.accent : BiliPalette.lightSecondary)
                .frame(width: size.width, height: size.height)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? BiliPalette.accent.opacity(0.16) : BiliPalette.lightFill.opacity(0.5))
                )
        }
        .buttonStyle(.plain)
    }

    /// 实测：434×52 的整宽可点行（左右各 16pt inset，整条有背景）。
    private func rowButton(_ title: String, detail: String?,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(BiliPalette.lightPrimary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(BiliPalette.lightSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BiliPalette.lightTertiary)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 14)
            .frame(width: M.sheetRowWidth, height: M.sheetRowHeight)
            .background(BiliPalette.lightFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, M.sectionInset)
    }

    /// 实测：开关行文字 x=60、开关贴右 x=392，无背景，高约 20。
    private func switchRow2(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(BiliPalette.lightPrimary)
                .padding(.leading, M.switchTextInset)
            Spacer(minLength: 0)
            Toggle("", isOn: value)
                .labelsHidden()
                .tint(BiliPalette.pink)
                .frame(width: M.switchSize.width, height: M.switchSize.height)
                .padding(.trailing, M.sectionInset + 14)
        }
        .frame(height: 44)
    }

    /// Timer 当前值文案（0 = Disabled）。
    private var timerLabel: String {
        sleepMinutes <= 0 ? L10n.text("Disabled") : String(format: "%02d:00", sleepMinutes)
    }

    /// 点 Timer 行按 0 → 15 → 30 → 60 → 0 循环（面板里没有五档横排，实测是单行）。
    private func cycleTimer() {
        switch sleepMinutes {
        case 0: sleepMinutes = 15
        case 15: sleepMinutes = 30
        case 30: sleepMinutes = 60
        default: sleepMinutes = 0
        }
    }

    private func switchRow(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(BiliPalette.lightPrimary)
                .padding(.leading, M.switchTextInset)
            Spacer(minLength: 0)
            Toggle("", isOn: value)
                .labelsHidden()
                .tint(BiliPalette.pink)
                .frame(width: M.switchSize.width, height: M.switchSize.height)
                .padding(.trailing, 14)
        }
        .frame(height: 40)
    }

    private func bigButton(_ symbol: String, _ title: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(BiliPalette.lightPrimary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(BiliPalette.lightSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: M.railHeroButton.width, height: M.railHeroButton.height)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ③ 横屏右缘竖条设置

/// 实测（9 元素）：
/// ```
/// 615    8    85×102   See Original
/// 615  123.7  37×17    Timer
/// 615  154    74×51    Disabled
/// 659  237    97×19    Auto-Play Next
/// 659  284    93.7×20  Loop playback
/// 631  319.7  139×21   Single Episode Loop
/// 659  376    66×19    Mirror Flip
/// 659  427    108.3×19 Background Play
/// 615  462    320×51   Aspect Ratio, Fit
/// ```
///
/// ⚠️ 无障碍报的宽（97 / 320）会右溢过屏宽 —— 那是内容固有宽，
/// 实际视觉是被右缘裁切的竖条，**不要按那个宽度建布局**。
struct BiliSettingsRail: View {
    @Binding var sleepMinutes: Int
    @Binding var playMode: BiliPlayMode
    @Binding var mirror: Bool
    @Binding var backgroundAudio: Bool
    @Binding var fitToScreen: Bool
    /// 倍速（实测 Speed 段有七档，我们之前整段缺失）。
    @Binding var speed: Float
    /// 打开时滚到哪一段（全屏底栏四钮同源，靠这个区分落点）。
    var focus: BiliSettingsFocus = .speed
    var onSeeOriginal: () -> Void = {}
    var onWatchLater: () -> Void = {}
    var onPiP: () -> Void = {}
    var onCast: () -> Void = {}
    var onClose: () -> Void = {}

    /// 实测七档，含 3.0。
    private var railSpeeds: [Float] { [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0] }

    /// 大按钮（实测 85×102，四个横排，步长 85）。
    private func railHero(_ symbol: String, _ title: String,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(BiliPalette.primary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(BiliPalette.secondary)
                    .lineLimit(1)
            }
            .frame(width: M.railHeroButton.width, height: M.railHeroButton.height)
        }
        .buttonStyle(.plain)
    }

    /// 倍速 chip（实测 57×21 量级，深色底上用亮字）。
    private func railSpeedChip(_ value: Float, active: Bool) -> some View {
        Button { speed = value } label: {
            Text(String(format: value == 1 ? "1.0" : "%g", value))
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(active ? BiliPalette.accent : BiliPalette.primary)
                .frame(width: 44, height: 32)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        // 与 `BiliSettingsSheet` 同理：四钮同源，靠 scrollTo 决定落点。
        // 之前 rail 是裸 ScrollView，点哪个都停在顶部。
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 实测（全屏弹窗 OCR）：顶部是**四个大按钮横排** ——
                //   See Original / Watch Later / PiP / Cast
                // 之前只做了 See Original 一个，少了三个。
                HStack(spacing: 0) {
                    railHero("rectangle.on.rectangle", L10n.text("See Original"), onSeeOriginal)
                    railHero("clock", L10n.text("Watch Later"), onWatchLater)
                    railHero("pip", L10n.text("PiP"), onPiP)
                    railHero("airplayvideo", L10n.text("Cast"), onCast)
                }
                .padding(.top, 8)

                // 实测：Speed 段在 Timer **之上**，七档 0.5/0.75/1.0/1.25/1.5/2.0/3.0。
                // 我们之前整段缺失。
                railTitle(L10n.text("Speed")).id(BiliSettingsFocus.speed)
                HStack(spacing: 0) {
                    ForEach(railSpeeds, id: \.self) { value in
                        railSpeedChip(value, active: abs(speed - value) < 0.001)
                    }
                }

                railTitle(L10n.text("Timer")).id(BiliSettingsFocus.timer)
                // 实测是 5 个按钮横排（Disabled/15:00/30:00/60:00/Custom，各 64x51），
                // 不是单个当前值按钮点一下轮换。之前那版是自创的。
                HStack(spacing: 0) {
                    ForEach(railTimers, id: \.0) { item in
                        railTimerChip(item.1, active: sleepMinutes == item.0) {
                            sleepMinutes = item.0
                        }
                    }
                }

                // 竖条只有 112pt 宽，「Auto-Play Next」「Loop playback」竖排会挤。
                // 改成开关在上、标签在下，与实测的「文字左 + 开关右」等价但更省横向空间。
                railSwitchStacked(L10n.text("Auto-Play Next"), playMode.autoAdvances) {
                    playMode = playMode.autoAdvances ? .quit : .next
                }
                railSwitchStacked(L10n.text("Loop playback"), playMode.loopsCurrent) {
                    playMode = playMode.loopsCurrent ? .quit : .loop
                }
                // 单集循环是独立子模式（实测 631,319.7 139×21）
                railChip(L10n.text("Single Episode Loop"), active: playMode == .loop) {
                    playMode = .loop
                }

                railSwitch(L10n.text("Mirror Flip"), mirror) { mirror.toggle() }
                railSwitch(L10n.text("Background Play"), backgroundAudio) { backgroundAudio.toggle() }

                railChip(L10n.text("Aspect Ratio") + ", " + (fitToScreen ? L10n.text("Fit") : L10n.text("Fill")),
                         active: fitToScreen, height: M.railFooterHeight) {
                    fitToScreen.toggle()
                }
                .padding(.bottom, 8)
            }
            .padding(.leading, 14)
        }
        .scrollIndicators(.hidden)
        .onAppear { proxy.scrollTo(focus, anchor: .top) }
        }
        .background(BiliPalette.panel)
    }

    private func railTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BiliPalette.tertiary)
            .frame(height: M.sectionTitleHeight)
            .padding(.top, 10)
    }

    /// 实测 Timer 五档：Disabled / 15:00 / 30:00 / 60:00 / Custom。
    /// `-1` 代表 Custom（自定义分钟数，本实现先落到 90 分钟占位）。
    private var railTimers: [(Int, String)] {
        [(0, L10n.text("Disabled")), (15, "15:00"), (30, "30:00"), (60, "60:00"), (-1, L10n.text("Custom"))]
    }

    /// 单个 Timer 按钮：实测 64×51（Disabled 74×51，Custom 68×51，宽度随文字）。
    private func railTimerChip(_ title: String, active: Bool,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(active ? BiliPalette.accent : BiliPalette.primary)
                .frame(width: 64, height: 51)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? BiliPalette.accent.opacity(0.16) : BiliPalette.card.opacity(0.55))
                )
        }
        .buttonStyle(.plain)
    }

    private var timerChip: some View {
        Button {
            // 实测是单个「当前值」按钮（74×51），点击展开成选项
            sleepMinutes = sleepMinutes == 0 ? 30 : (sleepMinutes == 30 ? 60 : 0)
        } label: {
            Text(sleepMinutes == 0 ? L10n.text("Disabled") : "\(sleepMinutes):00")
                .font(.system(size: 12))
                .foregroundStyle(BiliPalette.primary)
                .frame(width: 74, height: 51)
                .background(BiliPalette.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// 竖条专用的开关行：**标签在上、开关在下**。
    ///
    /// 实测哔哩哔哩是「文字左 + 开关右」（x=659 起、开关贴右），但那要求面板至少
    /// 160pt 宽；竖条可视区只有 63pt，照搬会把「自动连播」「循环播放」全裁成「自动…」。
    /// 纵向堆叠在 112pt 内能把中文标签完整显示出来。
    private func railSwitchStacked(_ title: String, _ on: Bool,
                                   _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(BiliPalette.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Capsule()
                    .fill(on ? BiliPalette.pink : BiliPalette.card)
                    .frame(width: M.switchSize.width, height: M.switchSize.height)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: M.switchSize.height - 4)
                            .padding(2)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func railSwitch(_ title: String, _ on: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(BiliPalette.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Capsule()
                    .fill(on ? BiliPalette.pink : BiliPalette.card)
                    .frame(width: M.switchSize.width, height: M.switchSize.height)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: M.switchSize.height - 4)
                            .padding(2)
                    }
            }
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }

    private func railChip(_ title: String, active: Bool, height: CGFloat = 30,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? BiliPalette.accent : BiliPalette.secondary)
                .lineLimit(1)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// 局部别名，避免每处都写 `BiliMetrics.`。

// MARK: - 设置子面板（来自竖屏设置面板的四个整宽可点行）

/// 子面板通用的顶部条：标题 + 右上「完成」。
@MainActor
private func biliPanelHeader(_ title: String, onClose: @escaping () -> Void) -> some View {
    HStack(spacing: 0) {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(BiliPalette.primary)
        Spacer(minLength: 8)
        Button(action: onClose) {
            Text(L10n.text("Done"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(BiliPalette.accent)
    }
    .padding(.horizontal, M.sectionInset)
    .frame(height: M.sectionTitleHeight + 24)
}

private func biliSectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(BiliPalette.primary)
        .frame(height: M.sectionTitleHeight)
        .padding(.leading, M.sectionInset)
        .padding(.top, 12)
}

private func biliToggleRow(_ title: String, _ value: Binding<Bool>) -> some View {
    HStack(spacing: 0) {
        Text(title)
            .font(.system(size: 14))
            .foregroundStyle(BiliPalette.primary)
            .padding(.leading, M.switchTextInset)
        Spacer(minLength: 0)
        Toggle("", isOn: value)
            .labelsHidden()
            .tint(BiliPalette.pink)
            .frame(width: M.switchSize.width, height: M.switchSize.height)
            .padding(.trailing, M.sectionInset + 14)
    }
    .frame(height: 44)
}

/// 字幕设置：复用全应用已有的 `SubtitleStyleView`（位置/大小/字体/颜色/描边/延时）。
struct BiliSubtitleSettingsView: View {
    var onClose: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            biliPanelHeader(L10n.text("Subtitle settings"), onClose: onClose)
            Divider().background(BiliPalette.lightLine)
            SubtitleStyleView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BiliPalette.lightPanel)
        }
        .background(BiliPalette.lightPanel)
    }
}

/// 弹幕设置：开关 + 显示区域 + 字号 + 不透明度，全部落到仓库已有的 UserDefaults 键。
struct BiliDanmuSettingsView: View {
    var onClose: () -> Void = {}
    @AppStorage(DanmakuPreference.key) private var danmakuOn = true
    @AppStorage(DanmakuArea.key) private var area = DanmakuArea.standard
    @AppStorage(DanmakuStyle.fontSizeKey) private var fontSize = DanmakuStyle.standardFontSize
    @AppStorage(DanmakuStyle.opacityKey) private var opacity = DanmakuStyle.standardOpacity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                biliPanelHeader(L10n.text("Danmu Settings"), onClose: onClose)
                Divider().background(BiliPalette.lightLine)
                biliSectionTitle(L10n.text("Show Danmu"))
                biliToggleRow(L10n.text("Danmu"), $danmakuOn)
                biliSectionTitle(L10n.text("Display Area"))
                areaPicker
                biliSectionTitle(L10n.text("Text Size"))
                sizePicker
                biliSectionTitle(L10n.text("Opacity"))
                opacityPicker

                // 二进制实证 `danmaku_speed` —— 之前整项缺失（渲染层硬编码 9 秒）。
                biliSectionTitle(L10n.text("Speed"))
                speedPicker

                // 二进制实证 `danmaku_filter` / `danmaku_block_switch` —— 之前整项缺失。
                biliSectionTitle(L10n.text("Blocked Words"))
                blockWordsField

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .background(BiliPalette.lightPanel)
    }

    @AppStorage(BiliDanmakuSpeed.key) private var speedRaw = BiliDanmakuSpeed.normal.rawValue
    @AppStorage(BiliDanmakuFilter.wordsKey) private var blockWordsRaw = ""

    private var speedPicker: some View {
        Picker(L10n.text("Speed"), selection: $speedRaw) {
            ForEach(BiliDanmakuSpeed.allCases) { (sp: BiliDanmakuSpeed) in
                Text(L10n.text(sp.label)).tag(sp.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, M.sectionInset)
        .padding(.bottom, 8)
    }

    /// 屏蔽词：逗号或换行分隔，支持 `/正则/`。
    private var blockWordsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.text("Comma separated, /regex/ supported"), text: $blockWordsRaw, axis: .vertical)
                .font(.system(size: 12))
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(8)
                .background(BiliPalette.lightFill, in: RoundedRectangle(cornerRadius: 6))
            Text(L10n.text("%@ blocked", String(BiliDanmakuFilter.words.count)))
                .font(.system(size: 10))
                .foregroundStyle(BiliPalette.lightTertiary)
        }
        .padding(.horizontal, M.sectionInset)
        .padding(.bottom, 8)
    }

    private var areaPicker: some View {
        Picker(L10n.text("Area"), selection: $area) {
            ForEach(DanmakuArea.allCases, id: \.self) { a in
                Text(a.title).tag(a)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, M.sectionInset)
        .padding(.bottom, 8)
    }

    private var sizePicker: some View {
        Picker(L10n.text("Size"), selection: $fontSize) {
            ForEach(DanmakuStyle.fontSizes(including: fontSize), id: \.self) { s in
                Text(verbatim: "\(Int(s.rounded()))").tag(s)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, M.sectionInset)
        .padding(.bottom, 8)
    }

    private var opacityPicker: some View {
        Picker(L10n.text("Opacity"), selection: $opacity) {
            ForEach(DanmakuStyle.opacities(including: opacity), id: \.self) { o in
                Text(verbatim: "\(Int((o * 100).rounded()))%").tag(o)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, M.sectionInset)
        .padding(.bottom, 8)
    }
}

/// 更多播放设置：画幅 / 后台听视频 / 镜像翻转，复用已有的存储键与单例。
struct BiliMorePlaybackSettingsView: View {
    var onClose: () -> Void = {}
    @AppStorage(OneSkin.fitModeKey) private var fitModeRaw = OneSkinFitMode.fit.rawValue
    /// ⛔ 这里原来还有两个画质增强开关（`upscalesVideo` / `smoothsVideo`，键是
    ///    `VideoEnhancement.upscaleKey` / `smoothKey`，全局共享）。**已移除**，因为它是个假开关：
    ///
    ///    · 三个哔哩哔哩播放页（`BiliPortraitPage:166` / `BiliLandscapePage:96` /
    ///      `BiliFullScreenPage:79`）画的都是 `BiliSkinPicture` ——
    ///      `BiliSkin.swift:307` 的一条裸 `AVPlayerLayer`，**没有任何增强渲染层**。
    ///      `grep -c EnhancedVideoSurface Bili*.swift` 在 13 个文件上全为 0。
    ///    · 键是全局的，所以在哔哩哔哩里拨这个开关：自身画面毫无变化，
    ///      但全局键被写成 true —— 之后切回 One 或原版，增强莫名开着。**跨皮肤键污染**。
    ///
    ///    补实现需要给上面三页各接一层 `EnhancedVideoSurface`，且必须与各自的
    ///    `AVPlayerLayer` **边缘完全对齐**（见 `MobilePlayer:429` 的注释：对齐不准会
    ///    在侧边留一条页面色、或把画面裁掉）。三页几何各自不同，且整条链受
    ///    `canUpscale` 门槛限制 —— 该值在模拟器恒 false，改完连触发都验不了。
    ///    ⇒ 登记为 P2「补实现」，等有真机（OS 26）再动，不在这里盲改。
    /// 广告拦截总开关。三个皮肤与 HLS 代理、设置页共用同一个键。
    @AppStorage(AdSkip.key) private var skipsAds = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                biliPanelHeader(L10n.text("More playback settings"), onClose: onClose)
                Divider().background(BiliPalette.lightLine)
                biliSectionTitle(L10n.text("Screen"))
                biliToggleRow(L10n.text("Fit to Screen"), Binding(
                    get: { fitModeRaw == "fit" },
                    set: { fitModeRaw = $0 ? "fit" : "fill" }
                ))
                // 画质增强的两个开关**已从这里移除** —— 哔哩哔哩皮肤没有增强渲染层，
                // 摆在这里是假开关（拨了没反应，还会污染全局键）。理由见上面属性区的注释。
                // 广告拦截：哔哩哔哩本体没有这个开关，但能力早就在
                //（`AdSkip` + `AdSignatureLibrary` + HLS 代理），不暴露就等于白丢。
                // 与 One、原版播放器、设置页共用 `player.skipAds` 一个键。
                biliSectionTitle(L10n.text("Ads"))
                biliToggleRow(L10n.text("Ad Blocking"), $skipsAds)
                biliSectionTitle(L10n.text("Background"))
                biliToggleRow(L10n.text("Background Play"), Binding(
                    get: { BiliPlayerExtras.shared.backgroundAudio },
                    set: { BiliPlayerExtras.shared.backgroundAudio = $0 }
                ))
                biliToggleRow(L10n.text("Mirror Flip"), Binding(
                    get: { BiliPlayerExtras.shared.mirror },
                    set: { BiliPlayerExtras.shared.mirror = $0 }
                ))
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .background(BiliPalette.lightPanel)
    }
}

/// 笔记：按视频 id 存一段自由文本（UserDefaults，key = `biliVideoNote.<id>`）。
struct BiliNotesView: View {
    let videoID: String
    var onClose: () -> Void = {}
    @State private var text: String
    private let key: String

    init(videoID: String, onClose: @escaping (() -> Void) = {}) {
        self.videoID = videoID
        self.onClose = onClose
        self.key = "biliVideoNote." + videoID
        let initial = UserDefaults.standard.string(forKey: self.key) ?? ""
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            biliPanelHeader(L10n.text("Notes"), onClose: onClose)
            Divider().background(BiliPalette.lightLine)
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .background(BiliPalette.lightFill.opacity(0.4))
                .foregroundStyle(BiliPalette.lightPrimary)
                .font(.system(size: 14))
                .padding(M.sectionInset)
                .onChange(of: text) { _, _ in persist() }
        }
        .background(BiliPalette.lightPanel)
    }

    private func persist() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(text, forKey: key) }
    }
}

/// 局部别名，避免每处都写 `BiliMetrics.`。
private typealias M = BiliMetrics
// MARK: - 全屏底部弹窗（统一款式，以「画质」弹出框为基准）
//
// 用户指定：全屏底栏 Subtitles / Episodes / Speed / Auto 四个按钮
// **共用这一个容器款式**，只是内容不同。
//
// 实测基准（画质框，竖屏 466×678）：
//   标题行 左 `Resolution` x≈16 / 右 `Advanced Settings >` x≈329
//   选项    `Auto (720P HD)` y≈452、`720P HD` y≈515、`480P SD` y≈575、`360P Smooth` y≈637
//   → 上沿 59.4% 屏高、行距 ≈61、左缩进 14、深色底 #212326
struct BiliFullscreenPopup<Content: View>: View {
    /// 标题（左）。
    var title: String
    /// 右上角次要动作文案（如 `Advanced Settings >`）。空则不显示。
    var trailing: String = ""
    var onTrailing: () -> Void = {}
    /// 是否为横屏。横屏走右侧 208pt 窄条，竖屏底部整宽。
    var landscape: Bool
    var onClose: () -> Void = {}
    @ViewBuilder var content: () -> Content

    /// 当前方向下的逻辑屏高。
    ///
    /// ⛔ 不能用 `appScreenBounds.height`：它是 `UIScreen.bounds` 语义，
    ///    不随旋转交换。内屏横持时它报 951，而真正可用的容器只有 669 ——
    ///    面板按 951 给 min/maxHeight，上半截直接被顶出屏幕（16.9）。
    private var screenH: CGFloat {
        let h = UIApplication.shared.appOrientedScreenSize.height
        return h > 1 ? h : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题行：左右分置（实测 x≈16 / x≈329）
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BiliPalette.primary)
                Spacer(minLength: 8)
                if trailing.isEmpty {
                    // 没有右上动作时，给一个关闭键 ——
                    // 之前 `onClose` 声明了却从未被使用，弹窗无法从自身关闭。
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BiliPalette.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Close"))
                }
                if !trailing.isEmpty {
                    Button(action: onTrailing) {
                        HStack(spacing: 2) {
                            Text(trailing)
                                .font(.system(size: 12))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(BiliPalette.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, BiliPopupMetrics.rowInset)
            .frame(height: BiliPopupMetrics.headerHeight)

            ScrollView {
                VStack(spacing: 0) { content() }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: landscape ? BiliPopupMetrics.landscapeWidth : .infinity,
               alignment: .top)
        // 竖屏：实测上沿在 59.4% 屏高 → 面板占下方 40.6%。
        //
        // ⚠️ 这里必须同时给 minHeight **和** maxHeight。
        // 只给 minHeight 时，内容（四键 102 + 9 个菜单行 × 61 = 651pt）会把面板
        // 顶到 699pt —— 比屏高 678 还高，弹窗直接铺满整屏、标题跑到 y=16
        //（真机实测）。给 maxHeight 后内容在 ScrollView 里滚，面板严格占 40.6%。
        .frame(minHeight: landscape
               ? screenH
               : screenH * (1 - BiliPopupMetrics.portraitTopFraction),
               maxHeight: landscape
               ? screenH
               : screenH * (1 - BiliPopupMetrics.portraitTopFraction),
               alignment: .top)
        .background(Color(biliHex: 0x212326))
        // 上沿分界线（与实测的高亮边一致）
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(biliHex: 0x3D3F43))
                .frame(height: 0.5)
        }
    }

    /// 弹窗内的一行选项（实测行距 61、左缩进 14、高 54~62）。
    static func row(_ text: String, selected: Bool = false,
                    height: CGFloat = BiliPopupMetrics.rowHeight,
                    _ action: @escaping () -> Void) -> BiliPopupRow {
        BiliPopupRow(text: text, selected: selected, height: height, action: action)
    }
}


/// `BiliFullscreenPopup.row` 的返回类型（SwiftUI 泛型推断在 `@ViewBuilder`
/// 内联多行 `ForEach` 里推不出来，必须给具体类型）。
struct BiliPopupRow: View {
    let text: String
    let selected: Bool
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? BiliPalette.accent : BiliPalette.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BiliPalette.accent)
                }
            }
            .padding(.horizontal, BiliPopupMetrics.rowInset)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
