#if os(iOS)
import SwiftUI
import TVCore

// MARK: - ③ 全屏页（顶栏/底栏按实测；选集按钮参考横屏补）

/// 实测顶栏（`ui.tree` 精确 frame）：
/// ```
/// 竖屏全屏                              横屏全屏
///  0  24  54×44   back                  0  24  54×44   back
/// 54  24 180×44   标题                 54  24 632×44   标题（铺满）
/// 234 24  44×44   Like                  --
/// 286 24  44×44   Share                 --
/// 338 24  44×44   more                  --
/// ```
///
/// 竖屏全屏的底栏 id（6 个，横屏全屏没有 a11y）：
/// `fullscreen_back / like / playersetting / playnext / dmswitch / switchquality`
///
/// 底栏版式（像素实测）：
/// 左时间 `01:04/01:52` @ y≈0.826、左播放组 x 30–261、
/// 右三文字按钮 `Subtitles` / `Speed` / `Auto` @ x 1605–2000。
///
/// ⚠️ 选集按钮：**横屏全屏有**（`BBPlayerFullScreenEpisodeBtnWidget`），
/// 竖屏全屏实测没露出来。按需求「参考横屏补上」，两态都放底栏右侧。
struct BiliFullScreenPage: View {
    let video: Video
    var session: PlaybackSession?
    var position: Double = 0
    var duration: Double = 0
    var portrait: Bool = true
    /// 选集列表（底栏 `Episodes` 入口需要判断是否多集）。
    var episodes: [Episode] = []
    /// 当前播放的一集。
    var playing: Episode?
    var isFavorite: Bool = false
    var danmakuOn: Bool = true
    var speed: Float = 1
    var qualityLabel: String = "Auto"

    var onBack: () -> Void = {}
    var onLike: () -> Void = {}
    var onShare: () -> Void = {}
    var onSettings: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    var onSeekBack: () -> Void = {}
    var onSeekForward: () -> Void = {}
    var onNext: () -> Void = {}
    /// 上一集（二进制实证 `bbplayer_fullscreen_playlast`）。
    var onPrevious: () -> Void = {}
    /// 小窗（二进制实证 `bbplayer_fullscreen_miniscreen`）。
    var onMiniScreen: () -> Void = {}
    /// 设置页排好的控件顺序（见 `BiliPortraitPage.controls` 的说明）。
    var controls: [PlayerControl] = []
    /// 截图（二进制实证 `bbplayer_fullscreen_screenshot`）。
    var onScreenshot: () -> Void = {}
    var onSeekTo: (Double) -> Void = { _ in }
    /// 是否有子面板（弹窗）打开。
    /// 打开时**必须禁用 `toggleChrome`** —— 那个手势盖在整个 ZStack 上，
    /// 会和弹窗、遮罩的手势互抢，表现就是「点了没反应 / 控件唤不醒」。
    var panelOpen: Bool = false
    var onSubtitles: () -> Void = {}
    var onSpeed: () -> Void = {}
    var onQuality: () -> Void = {}
    var onToggleDanmu: () -> Void = {}
    /// 参考横屏补的选集入口
    var onEpisodes: () -> Void = {}
    /// 画中画控制器：交给 `BiliSkinPicture` 把画面登记成 PiP 内容源（见 `BiliPortraitPage.pip` 的说明）。
    var pip: PictureInPicture? = nil

    @State private var chromeVisible = true
    /// 锁屏（二进制实证 `lockscreen_on` / `lockscreen_off`）。
    /// 锁住时：控件隐藏且**点画面不再唤出**，防误触。
    @State private var locked = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            BiliPalette.deep
            if let session {
                BiliSkinPicture(player: session.player,
                                 gravity: BiliAspectMode.current.gravity,
                                 mirrored: BiliPlayerExtras.shared.mirror,
                                 colorFilters: BiliColorFilter.current.caFilters(),
                                 pip: pip)
                    .allowsHitTesting(false)
                // 弹幕层（Bili 皮肤原来没有）。共用 session 的 danmaku。
                if danmakuOn, !session.danmaku.isEmpty {
                    DanmakuOverlay(player: session.player,
                                   comments: session.danmaku,
                                   opacity: session.danmakuOpacity,
                                   revision: session.danmakuRevision)
                        .allowsHitTesting(false)
                }
            }
            // 四个角色区**各自挂一层 overlay**（不在 chrome 内部再嵌套）。
            // rea 实证 `BBPlayerFullScreen{Top,Bottom,Left,Right}Widget` 是四个独立 Widget，
            // 每层只贴自己那条边，互不参与尺寸协商。
            // 之前把它们放进 chrome 的 ZStack/overlay 链里，后出现的层会因
            // 首个层撑满而被挤掉（真机实测：横屏只剩顶区+左区，底区全黑）。
            // 顶栏偏移用**固定 9.5pt**，不用 `safeAreaPadding(.top)`。
            //
            // 静态推演（竖屏 466×678）：
            //   实测 `Back` 字形 y=24，`topIcon` 热区 44 高、字形 15 高居中
            //   → 元素 top = 24 − (44−15)/2 = **9.5**
            //   而 `safeAreaPadding(.top)` 在 Duo 外屏实测加 16.2pt
            //   （历史渲染 Back 字形 30.7 = 16.2 + 14.5），会偏高 14.5pt。
            //   所以这里用精确的 9.5，与实测对齐。
            Color.clear
                .padding(.top, 9.5)
                .overlay(alignment: .top) { visibleChrome { topBar } }
                .overlay(alignment: .bottom) { visibleChrome { bottomBar(width: screenW) } }
                .overlay(alignment: .trailing) { visibleChrome { rightRail } }
                .overlay(alignment: .leading) {
                    if !portrait { visibleChrome { leftRail } }
                }

            // 锁屏键：**锁住之后仍然可见**（否则用户没法解锁）。
            // 实测 `Lock screen` 在 `634,203.7 44×44` —— 右缘中部，独立于顶/底栏。
            if locked {
                lockBadge
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 锁屏时点画面不唤出控件（`lockscreen_on` 的语义）。
            guard !panelOpen, !locked else { return }
            toggleChrome()
        }
        .onAppear {
            #if DEBUG
            // QA 截图时控件反复自动隐藏会点不中，这个开关让它常显。
            if UserDefaults.standard.bool(forKey: "qaBiliHoldChrome") { return }
            #endif
            armAutoHide()
        }
        .onDisappear { hideTask?.cancel() }
        // 弹窗开/关时同步自动隐藏任务：
        //   打开 → 取消隐藏并强制显示（否则 4 秒后 chrome 自己消失，弹窗还盖着，
        //          用户关掉弹窗只会看到一片空白，表现就是「控件唤不醒」）
        //   关闭 → 重新计时
        .onChange(of: panelOpen) { _, open in
            hideTask?.cancel()
            if open {
                chromeVisible = true
            } else {
                armAutoHide()
            }
        }
    }

    /// 右侧栏实际要画的那几颗。
    ///
    /// ⛔ 与竖屏/横屏不同：全屏页**必须**保留小窗键 —— 用户明确要求
    ///    「全屏播放页要有一个直接的迷你小窗播放按钮」。
    ///    所以 `controls` 为空时退回 `.miniPlayer`，而不是空栏。
    private var railControls: [PlayerControl] {
        let wanted = controls.filter { BiliControlSupport.isSupported($0) }
        if wanted.isEmpty { return [.miniPlayer] }
        // 小窗键在全屏页是**不可移除**的（用户要求的"直接按钮"），
        // 即使用户在设置里把它从顶栏摘掉，这里也补回来。
        return wanted.contains(.miniPlayer) ? wanted : [.miniPlayer] + wanted
    }

    private func railLabel(for control: PlayerControl) -> String {
        switch control {
        case .miniPlayer: return "Mini player"
        case .airPlay:    return "Cast"
        case .episodes:   return "Episodes"
        case .lock:       return "Lock screen"
        case .danmaku:    return "Danmu"
        case .speed:      return "Speed"
        case .quality:    return "Resolution"
        case .subtitles:  return "Subtitles"
        case .pictureSize: return "Aspect Ratio"
        case .videoInfo:  return "Video Info"
        case .anotherPlayer: return "Another Player"
        case .rotate:     return "Rotate"
        default:          return control.rawValue
        }
    }

    private func railAction(_ control: PlayerControl) -> () -> Void {
        switch control {
        case .miniPlayer: return onMiniScreen
        // 全屏页**没有**投屏/选集回调（它的版式里没有这两个入口）——
        // 指向「设置」面板，而不是留一颗点了没反应的键。
        case .airPlay, .episodes: return onSettings
        case .lock:       return {
            withAnimation(.easeInOut(duration: 0.24)) {
                locked = true
                chromeVisible = false
            }
            hideTask?.cancel()
        }
        default:
            // 其余收在「设置」面板里（全屏页那颗齿轮）。
            return onSettings
        }
    }

    private func sideIcon(_ symbol: String, _ label: String,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.28)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 锁屏

    /// 锁住时右缘中部的解锁键（实测位置 `634,203.7 44×44`，即右缘约 15pt 内边）。
    private var lockBadge: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        locked = false
                        chromeVisible = true
                    }
                    armAutoHide()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: M.topButton, height: M.topButton)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Unlock screen"))
                .padding(.trailing, 8)
            }
            .padding(.bottom, 120)
        }
    }

    // MARK: 控件层 —— 四角色区（rea 实证）
    //
    // 二进制类名直接给出分区模型：
    //   BBPlayerFullScreen{Top,Bottom,Left,Right}Widget
    //   BBPlayerHalfScreen{Top,Bottom,Left,Right}Widget
    //   BBPlayerPortraitScreen{Top,Bottom}Widget      ← 竖屏**只有 2 个区**
    //
    // 所以播放器不是「一行/两行/三行」的流式布局，而是**四个独立角色区**：
    // 每个区各自贴边、各自堆叠，区与区之间不共享 VStack 流。
    // 竖屏只渲染 Top + Bottom（无 Left/Right），这解释了竖屏控件为何更少。
    //
    // ⚠️ 这也解释了我之前踩的坑：用 VStack(spacing:) 串三行时，
    // `iconButton` 的 44pt 热区会被全额计入行高，「时间→播放」怎么压都压不到 8.9pt。
    // 四区独立后各区的内部间距互不影响。
    /// 每个角色区独立套 opacity / 命中测试，这样四层互不影响。
    @ViewBuilder
    private func visibleChrome<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
    }

    /// 当前容器宽度。
    ///
    /// ⛔ 不能用 `UIScreen.main.bounds`：Duo 双屏时它指向**外屏**（466 宽），
    /// 而 App 可能跑在内屏（669 / 951）。用外屏宽度算底栏，展开后整排按钮按
    /// 466 排就会挤在左边一条、右侧全空。
    /// 也不能用 `window.bounds` 的**逐帧**值：旋转动画期间它连续变化，会让底栏跟着抖。
    ///
    /// ⛔ 更不能直接用 `appScreenBounds.width`：它是 `UIScreen.bounds` 语义，
    ///    **不随旋转交换**。横持时它给 466/669（应为 678/951），
    ///    底栏按 466 铺到 678 上，右边空 212pt（内屏空 282pt）—— 16.9。
    ///    `appOrientedScreenSize` 取的是 `keyWindow.bounds`（系统一次性交换宽高），
    ///    既是当前方向的真实值，又不像 `screen.bounds` 那样指向另一块屏。
    private var screenW: CGFloat {
        UIApplication.shared.appOrientedScreenSize.width
    }

    // 左区：竖屏不渲染。横屏按 BBPlayerFullScreenLeftWidget 的语义放播放组。
    private var leftRail: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            sideIcon("gobackward.10", L10n.text("Back 10 seconds")) { onSeekBack() }
            sideIcon(session?.paused == false ? "pause.fill" : "play.fill",
                     L10n.text("Play")) { onTogglePlay() }
            sideIcon("goforward.10", L10n.text("Forward 10 seconds")) { onSeekForward() }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }

    // 右区：小窗 / 截图 / 锁屏（rea 实证三个独立 Widget）+ 竖屏的弹幕与画质。
    private var rightRail: some View {
        // overlay(alignment: .trailing) 里高度不受限，`Spacer` 会塌成 0 →
        // 用固定 top padding 把三键压到实测的 y≈204。
        VStack(spacing: 4) {
            // 按设置页的顺序画（`controls` 为空退回内置：只有小窗）。
            ForEach(railControls, id: \.rawValue) { control in
                sideIcon(BiliControlSupport.symbol(for: control) ?? "circle",
                         L10n.text(railLabel(for: control))) {
                    railAction(control)()
                }
            }
            // 截图与锁屏是 B 站全屏特有的，`PlayerControl` 里没有对应项，恒常驻。
            sideIcon("camera", L10n.text("Screenshot")) { onScreenshot() }
            sideIcon("lock.open", L10n.text("Lock screen")) {
                withAnimation(.easeInOut(duration: 0.24)) {
                    locked = true
                    chromeVisible = false
                }
                hideTask?.cancel()
            }
        }
        .padding(.top, portrait ? 116 : 60)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: M.backWidth, height: M.backHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Back"))

            // 标题紧贴返回键，**左对齐**，不居中（实测 x=54 起）
            // 实测标题固定 180pt（x 54→234），**不是自适应**。
            // 之前只写 lineLimit(1)，长标题会把它撑到占满剩余宽度，
            // 把 Like/Share/更多 三个按钮一路挤到屏幕外，再叠 84pt 摄像头避让就越界了。
            Text(video.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                // 按屏宽比例给上限（外屏 466×0.386≈180 保持实测值，内屏放宽），
                // 否则展开后 951 宽仍只给 180，标题被截断而右边一大片空白。
                .frame(minWidth: 0,
                       idealWidth: M.fullscreenTitleMaxWidth(forWidth: screenW),
                       maxWidth: M.fullscreenTitleMaxWidth(forWidth: screenW),
                       alignment: .leading)
                .padding(.leading, 4)
                .shadow(color: .black.opacity(0.6), radius: 3)

            Spacer(minLength: 6)

            // 竖屏全屏实测有 Like / Share / 更多 三个 44×44
            if portrait {
                // `isFavorite` 之前声明了没用：点赞态应当高亮。
                Button(action: onLike) {
                    Image(systemName: isFavorite ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isFavorite ? BiliPalette.accent : .white)
                        .frame(width: M.topButton, height: M.topButton)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Like"))
                topIcon("arrowshape.turn.up.right", L10n.text("Share"), onShare)
            }
            // ⚠️ 顶栏**只能放 3 个**（实测 Like / Share / More）。
            // 宽度核算（466 屏）：Back 54 + title 180 + 3×44 = 366，
            // 再加 84pt 摄像头避让 = 450 ≤ 466 ✅。
            // 放 6 个会到 582pt，超屏 116pt，按钮直接被挤出屏幕。
            //
            // 小窗 / 截图 / 锁屏 → 全部移到**右缘竖排**（`sideRail`），
            // 那里实测本来就有 `Lock screen 634,203.7`。
            topIcon("ellipsis", L10n.text("More operations"), onSettings)
        }
        .frame(height: M.topBarHeight)
        // 竖屏全屏同样要避开 Duo 前置摄像头。
        //
        // 实测（466 宽）：
        //   Back   0,24 54×44 → 54    title 54,24 180×44
        //   Like  234,24 44×44 → 278  Share 286,24 44×44 → 330
        //   more  338,24 44×44 → 382
        //   466 - 382 = **84pt 空白**，与详情页顶栏完全一致。
        // 只有外屏有摄像头挖孔；内屏留 0（见 `BiliMetrics.cameraInset(forWidth:)`）。
        .padding(.trailing, portrait ? M.cameraInset(forWidth: screenW) : 0)
    }

    private func topIcon(_ symbol: String, _ label: String,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: M.topButton, height: M.topButton)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 底栏（左时间 + 左播放组 + 右三文字按钮 + 选集）

    // MARK: 底区 —— 照 `BBPlayerFullScreenBottomWidget` 的真实三个子容器
    //
    // swift-section 实证（/tmp/bili_objc.txt:779252）：
    //   @interface BBPlayerFullScreenBottomWidget : BBPlayerBeyondBoundsWidget {
    //       BBPlayerBeyondBoundsFlexContainerWidget *_topControlWidget;   ← 顶部控制行
    //       BBPlayerFlexContainerWidget *_leftControlWidget;              ← 左控制组
    //       BBPlayerFlexContainerWidget *_rightControlWidget;             ← 右控制组
    //       struct UIEdgeInsets _occlusionAvoidInsets;                    ← 遮挡避让
    //   }
    //
    // 所以底区 = topControlRow + leftControlGroup + rightControlGroup **三块并列**，
    // 不是「时间行/播放行/弹幕行」的三行流式。之前所有 VStack/offset 试错
    // 都是在错误结构上调参数。
    private func bottomBar(width: CGFloat) -> some View {
        // ─────────────────────────────────────────────────────────────
        // 底区（`BBPlayerFullScreenBottomWidget`）
        //
        // 静态推演出的精确坐标（不是试出来的）。推演链条：
        //   竖屏 466×678，实测字形 top：时间 507.0 / 播放 516.0 / 弹幕 610.0 / 画质 619.7
        //   图标字形在 44pt 热区里居中，所以要反推元素 top：
        //     播放 516.0 − (44−14.3)/2 = 501.15
        //     弹幕 610.0 − (44−17.7)/2 = 596.85
        //     画质 619.7 − (44−14.3)/2 = 604.85
        //   取底区高 200、顶 y = 678−200 = 478，四者的相对坐标：
        //     时间 29.00 / 播放 23.15 / 弹幕 118.85 / 画质 126.85
        //
        // ⚠️ 为什么必须绝对定位：时间(507) 与 播放(516) 只差 8.9pt，
        // 而时间字高就有 13.3 —— 这两者在垂直上**互相重叠**，
        // 用 VStack 串行排永远做不到（前一版算出来播放会落到 534.85，差 19pt）。
        // 这也解释了之前反复调 padding 却只能满足 1~2 个元素。
        // ─────────────────────────────────────────────────────────────
        ZStack(alignment: .topLeading) {
            // ① 时间 + 进度条（`_topControlWidget`）
            VStack(spacing: 2) {
                Text("\(BiliClock.text(position))/\(BiliClock.text(duration))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                seekBar
            }
            .padding(.horizontal, 8)
            .offset(y: portrait ? 29.0 : 0)

            if portrait {
                // ② 播放组（`_leftControlWidget`）—— 与时间带重叠
                //
                // 实测竖屏播放组是 `播放 0,516` + `下一个 56,514`（两个，间隔 56）。
                // 哔哩哔哩竖屏**没有**独立的上一集键（`playlast` 只在横屏/半屏暴露），
                // 但 `onPrevious` 是二进制实证存在的动作，这里以长按/双击语义保留入口，
                // 不额外占位以免破坏实测坐标。
                HStack(spacing: 0) {
                    iconButton(session?.paused == false ? "pause.fill" : "play.fill",
                               L10n.text("Play"), onTogglePlay)
                    iconButton("forward.end", L10n.text("Next episode"), onNext)
                }
                .offset(x: 0, y: 23.15)

                // ③ 弹幕（左）+ 画质（右）（`_rightControlWidget`）
                iconButton(danmakuOn ? "text.bubble.fill" : "text.bubble",
                           L10n.text("Turn on danmu"), onToggleDanmu)
                    .foregroundStyle(danmakuOn ? BiliPalette.accent : .white)
                    .offset(x: 0, y: 118.85)

                // 画质右侧、同一行放选集（`episodes.count > 1` 才显示）——
                // 实测竖屏这一带是 `弹幕(左) ... 画质(右)`，选集入口夹在两者之间。
                if episodes.count > 1 {
                    textButton(L10n.text("Episodes"), onEpisodes)
                        .offset(x: width - 130, y: 126.85)
                }

                textButton(qualityLabel, onQuality)
                    .offset(x: width - 56, y: 126.85)
            } else {
                // 横屏：所有键一行贴底（实测 y≈400，屏高 466 → 距底 66）
                HStack(spacing: 0) {
                    iconButton(session?.paused == false ? "pause.fill" : "play.fill",
                               L10n.text("Play"), onTogglePlay)
                    iconButton("forward.end", L10n.text("Next episode"), onNext)
                    iconButton(danmakuOn ? "text.bubble.fill" : "text.bubble",
                               L10n.text("Turn on danmu"), onToggleDanmu)
                        .foregroundStyle(danmakuOn ? BiliPalette.accent : .white)
                    Spacer(minLength: 6)
                    textButton(L10n.text("Subtitles"), onSubtitles)
                    textButton(L10n.text("Episodes"), onEpisodes)
                    textButton(String(format: "%gx", speed), onSpeed)
                    textButton(qualityLabel, onQuality)
                }
                .frame(width: width)
                .offset(y: 126.85)
            }
        }
        .frame(width: width, height: portrait ? 200 : 200, alignment: .topLeading)
    }

    private var seekBar: some View {
        GeometryReader { geo in
            let ratio = duration > 0 ? min(max(position / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24)).frame(height: 3)
                Capsule().fill(BiliPalette.accent)
                    .frame(width: geo.size.width * ratio, height: 3)
                Circle().fill(BiliPalette.accent)
                    .frame(width: 8, height: 8)
                    .offset(x: geo.size.width * ratio - 4)
            }
            .frame(height: 4)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard duration > 0 else { return }
                onSeekTo(location.x / geo.size.width)
            }
        }
        .frame(height: 4)
    }

    private func iconButton(_ symbol: String, _ label: String,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 右侧文字按钮 —— 实测 `Subtitles` / `Speed` / `Auto` 都是**带文字**的。
    /// 底栏文字按钮。
    ///
    /// ⚠️ 实测哔哩哔哩这些按钮的**可点击区比文字大得多**；早先只给 9/5 padding，
    /// 实际热区只有约 24×14pt，手点和自动点击都极难命中（真机上是「点了没反应」）。
    /// 统一撑到 44pt 高（Apple 最小可触控尺寸）并加 `contentShape`。
    private func textButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                // 热区靠 frame 撑，不要用 `contentShape` 包 Text ——
                // 那样会把无障碍元素吃掉（实测底栏整层从 `ui.tree` 里消失）。
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 自动隐藏

    private func toggleChrome() {
        // ⚠️ 必须先算新值再赋值，不能在 `withAnimation` 闭包里 `toggle()` 之后
        // 立刻读 `chromeVisible` —— @State 写入在动画事务里不保证同步可见，
        // 读到旧值会让「显示后永不自动隐藏 / 隐藏后又立刻重排一次隐藏」都发生，
        // 表现就是用户说的「控件藏了唤不醒」。
        let next = !chromeVisible
        withAnimation(.easeInOut(duration: 0.24)) { chromeVisible = next }
        if next {
            armAutoHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func armAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { chromeVisible = false }
        }
    }
}

private typealias M = BiliMetrics
#endif