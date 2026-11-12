#if os(iOS)
import SwiftUI
import TVCore

// MARK: - 哔哩哔哩三个屏幕族页面（按实测 frame 复刻）

/// 哔哩哔哩是 **三个独立 Widget 族**，不是一套布局换参数：
///
/// ```
/// 全屏  BBPlayerFullScreen{Top,Bottom,Left,Right}Widget
/// 半屏  BBPlayerHalfScreen{Top,Bottom,Left,Right}Widget + BottomRowLayout
/// 竖屏  BBPlayerPortraitScreen{Top,Bottom}Widget   （只有上下）
/// ```
///
/// 所以这里也是三个平级 `View`，共享一个 `BiliMetrics` 常量源，
/// 而不是一个 `View` 加 `shape` 开关。

// MARK: - ① 竖屏详情页

/// 实测（466×678pt）：
/// ```
/// 0  250  466×22   Progress（独立整宽，22pt）
/// 8  262  86.7×40  About / Comments
/// 414 267 40×30    Turn on danmu（浮右上）
/// 0  367.3 54×54   Creator avatar
/// 12 427.3 414×22  标题
/// 438 430.3 16×16  More
/// 12 455.3 442×34  数据行
/// 12 509.3 88.3×40 互动五行（5 个）
/// 12 565.3 93×26   标签
/// --- 下面接内联选集列表（行距 100.3pt）---
/// ```
struct BiliPortraitPage: View {
    let video: Video
    var session: PlaybackSession?
    var position: Double = 0
    var duration: Double = 0
    var aspectRatio: CGFloat = 16.0 / 9.0
    var episodes: [Episode] = []
    var playing: Episode?
    var flags: [String] = []
    var activeLine: String = ""
    var seriesTitle: String?
    var seriesSummary: String = ""
    var isFavorite: Bool = false
    var danmakuOn: Bool = true
    /// 画中画控制器：交给 `BiliSkinPicture` 把画面登记成 PiP 内容源。
    ///
    /// ⛔ 少了这一个参数，哔哩哔哩皮肤**完全开不出小窗**：
    /// `PictureInPicture.current` 永远是 nil，`startCurrent()` 第一行 guard 就返回；
    /// `RootView` 的 `pipPossible` 也恒 false，离开 App 时既不浮窗也不登出（音频空转）。
    var pip: PictureInPicture? = nil

    var onBack: () -> Void = {}
    var onCast: () -> Void = {}
    var onMore: () -> Void = {}
    /// 齿轮：打开设置面板（Speed / Timer / 画幅 / 字幕 / 画质 / 我们的增强项）。
    ///
    /// ⛔ 此前竖屏页**没有这个入口** —— 只有 `onMore` 指向 `actionMenu`（更多操作），
    /// 于是设置面板在竖屏不可达，`sleepDeadline` / `mirror` / `BiliAspectMode` /
    /// 画质增强这些能力全都摸不到。横屏/全屏有，只有竖屏缺，三形态能力不对等。
    var onSettings: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    var onFullScreen: () -> Void = {}
    var onToggleDanmu: () -> Void = {}
    var onFollow: () -> Void = {}
    var onLike: () -> Void = {}
    var onDislike: () -> Void = {}
    var onCoin: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onShare: () -> Void = {}
    var onPlay: (Episode) -> Void = { _ in }
    var onSeekTo: (Double) -> Void = { _ in }
    /// 选集入口点击 —— 由外部打开**抽屉**（不是内联铺开）。
    var onEpisodes: () -> Void = {}

    /// 播放器卡片实际容器宽度。
    ///
    /// ⛔ 版式常量（播放器高、摄像头避让）都是按 **466 宽外屏**实测的，
    /// 展开竖持 669 / 展开横持 951 直接照搬会错位：
    ///   · 播放器高 250 → 669 宽时 16:9 只剩 444×250，左右各 112pt 黑边；
    ///   · 摄像头避让 84 → 内屏没有挖孔，顶栏右端凭空空出 84pt，三键整体左移。
    /// 用真实容器宽度（不是 `UIScreen.main`，Duo 上它报外屏）驱动这些常量。
    @State private var cardWidth: CGFloat = 0

    /// 量不到容器宽度时的兜底。
    ///
    /// `cardWidth` 首帧必为 0（`.onGeometryChange` 要等一次布局才回调），
    /// 若直接把 0 喂给 `cameraInset` / `portraitHeight`，
    /// 会先按「没有挖孔 + 250pt 高」画一帧再跳到位 —— 展开态就是一次可见的跳动。
    /// 用「App 所在那块屏」的静态宽度兜底：外屏 466 / 内屏 669，恰好都落在正确档位上。
    private var effectiveCardWidth: CGFloat {
        cardWidth > 0 ? cardWidth : UIApplication.shared.appScreenBounds.width
    }

    /// 排序方向。实测哔哩哔哩默认是 **Descending**（新的在前），
    /// 点它切换；不是写死的 Ascending。
    @State private var episodesAscending = false

    /// 选集是否展开。实测这是**页面内的折叠态**：收起看推荐，展开看选集。
    /// QA：`qaBiliEpisodesExpanded` 让它一进页面就展开，便于截图核对（仅 DEBUG 生效）。
    @State private var episodesExpanded = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "qaBiliEpisodesExpanded")
        #else
        return false
        #endif
    }()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                playerCard
                // 进度条是**独立整宽元素**，紧贴 tab 行之上（实测 y=250）
                progressBar
                tabRow
                creatorRow
                titleRow
                statsRow
                actionRow
                tagRow
            }
            // 底部留白，避免最后一行被悬浮入口条压住
            .padding(.bottom, episodes.count > 1 ? 44 : 0)
        }
        .scrollIndicators(.hidden)
        .background(BiliPalette.lightPage)
        // 悬浮入口条：压在内容之上（overlay），不占文档流 —— 这是实测形态。
        .overlay(alignment: .bottom) {
            if episodes.count > 1, !episodesExpanded {
                seriesEntryRow
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 选集抽屉：从底部升起，盖住内容
        .overlay {
            if episodesExpanded {
                ZStack(alignment: .bottom) {
                    // 实测遮罩是**完全不透明纯黑**，不是半透明 —— 抽屉打开时下面看不见。
                    Color.black
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.smooth(duration: 0.22)) { episodesExpanded = false }
                        }
                    expandedEpisodes
                        .frame(maxHeight: UIApplication.shared.appScreenBounds.height * 0.72)
                        .background(BiliPalette.lightPanel)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 12, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 12))
                        .transition(.move(edge: .bottom))
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: episodesExpanded)
    }

    // MARK: 播放器卡片（顶栏三键 46×44）

    private var playerCard: some View {
        ZStack(alignment: .top) {
            BiliPalette.deep
            if let session {
                BiliSkinPicture(player: session.player,
                                 gravity: BiliAspectMode.current.gravity,
                                 mirrored: BiliPlayerExtras.shared.mirror,
                                 colorFilters: BiliColorFilter.current.caFilters(),
                                 pip: pip)
                    // 双保险：`UIViewRepresentable` 的 UIView 在 UIKit 层级里可能
                    // **浮在 SwiftUI 兄弟层之上**（不是 ZStack 顺序能控制的），
                    // 于是盖住返回/播放/全屏这些按钮。`isUserInteractionEnabled = false`
                    // 管的是 UIView 自己，这里管的是 SwiftUI 那一层的命中测试。
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                // ⚠️ 顶栏右侧**必须留 84pt** —— 这是 iPhone Duo 竖屏的前置摄像头避让区。
                //
                // 实测（466 宽屏，`ui.tree`）：
                //   Return to previous page  0,  24  46×44   → 右边界 46
                //   Cast                   282,  24  46×44   → 右边界 328
                //   More operations        336,  24  46×44   → 右边界 382
                //   466 - 382 = **84pt 空白**
                //
                // 注意：**底部行不需要避让** ——
                //   播放 0,218 46×44（贴左）、Full screen 420,218 46×44（右边界正好 466 贴右）。
                HStack(spacing: 0) {
                    topButton("chevron.backward", L10n.text("Back"), onBack)
                    Spacer(minLength: 0)
                    topButton("airplayvideo", L10n.text("Cast"), onCast)
                    topButton("ellipsis", L10n.text("More operations"), onMore)
                }
                .frame(height: M.topBarHeight)
                .padding(.top, 0)
                // 只有外屏有摄像头挖孔；内屏留 0（见 `BiliMetrics.cameraInset(forWidth:)`）。
                .padding(.trailing, M.cameraInset(forWidth: effectiveCardWidth))
                Spacer(minLength: 0)
                // 底部两个键：播放（左）、全屏（右），各 46×44，两边都贴边
                HStack(spacing: 0) {
                    topButton(session?.paused == false ? "pause.fill" : "play.fill",
                              L10n.text("Play"), onTogglePlay)
                    Spacer(minLength: 0)
                    topButton("arrow.up.left.and.arrow.down.right",
                              L10n.text("Full screen"), onFullScreen)
                }
                .frame(height: M.topBarHeight)
                .padding(.bottom, 6)
            }
        }
        // 实测（466×678 竖屏详情页）：`Progress 0,250 466×22` —— 进度条在 y=250，
        // 说明播放器占 **y 0~250 = 250pt 高**，整宽 466。
        // 之前写 220 是猜的，少 30pt，导致下面所有内容整体上移 30pt 与哔哩哔哩错位。
        //
        // ⛔ 250 是**外屏实测值**，不能照搬到内屏：展开竖持 669 宽时 16:9 片源
        // `resizeAspect` 后只剩 444×250，左右各留 112pt 黑边（「小画 + 大黑框」）。
        // 内屏改按「整宽 + 片源比例」推导，见 `BiliMetrics.portraitHeight(width:…)`。
        .frame(height: M.portraitHeight(width: effectiveCardWidth,
                                         aspectRatio: aspectRatio,
                                         screenHeight: UIApplication.shared.appScreenBounds.height))
        // 量一次真实容器宽度给上面两个常量用（`.onGeometryChange` 不参与布局，无副作用）。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if abs(w - cardWidth) > 0.5 { cardWidth = w }
        }
    }

    private func topButton(_ symbol: String, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 46, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 进度条（466×22 整宽）

    private var progressBar: some View {
        GeometryReader { geo in
            let ratio = duration > 0 ? min(max(position / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(BiliPalette.lightFill)
                Rectangle().fill(BiliPalette.accent)
                    .frame(width: geo.size.width * ratio)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard duration > 0 else { return }
                onSeekTo(location.x / geo.size.width)
            }
        }
        .frame(height: M.portraitProgressHeight * 0.18)  // 视觉 4pt 线，占位 22
        .padding(.vertical, (M.portraitProgressHeight - M.portraitProgressHeight * 0.18) / 2)
    }

    // MARK: tab 行（高 40）

    private var tabRow: some View {
        HStack(spacing: 0) {
            tabItem(L10n.text("About"), active: true)
            tabItem(L10n.text("Comments"), active: false)
            Spacer(minLength: 0)
            // 设置（齿轮）。哔哩哔哩竖屏详情页这颗齿轮打开的是 Speed / Timer /
            // 画面比例 / 字幕 / 画质 等一整块设置面板，我们此前只有「更多」一个入口
            // （`actionMenu`），设置面板在竖屏**根本进不去** —— 于是定时关闭、
            // 镜像、画幅、画质增强这些能力全部只存在于代码里，用户摸不到。
            // 与右侧弹幕键同款胶囊，保持这一行视觉一致。
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BiliPalette.lightTertiary)
                    .frame(width: 34, height: 30)
                    .background(BiliPalette.lightFill.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Playback Settings"))
            .padding(.trailing, 6)
            // 实测哔哩哔哩这块是 **40×30**，不是 81×30。
            // 我们原来写「图标 + Danmaku On / Turn on danmu」长文案，宽度翻倍。
            // 实测那个 40pt 宽说明它可视部分基本只有一个图标，长文案只是无障碍标签。
            Button(action: onToggleDanmu) {
                Image(systemName: danmakuOn ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(danmakuOn ? BiliPalette.accent : BiliPalette.lightTertiary)
                    .frame(width: 40, height: 30)
                    .background(BiliPalette.lightFill.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(danmakuOn ? L10n.text("Danmaku On") : L10n.text("Turn on danmu"))
        }
        .padding(.horizontal, 8)
        .frame(height: M.portraitTabHeight)
    }

    private func tabItem(_ title: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? BiliPalette.lightPrimary : BiliPalette.lightTertiary)
            Capsule()
                .fill(active ? BiliPalette.pink : .clear)
                .frame(width: 16, height: 2)
        }
        .frame(width: 86.7, height: M.portraitTabHeight)
    }

    // MARK: UP 主行（头像 54×54）

    private var creatorRow: some View {
        HStack(spacing: 0) {
            Circle().fill(BiliPalette.lightFill)
                .frame(width: M.avatarSize, height: M.avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.remarks.isEmpty ? L10n.text("Creator") : video.remarks)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BiliPalette.lightPrimary).lineLimit(1)
                Text(seriesSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(BiliPalette.lightTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onFollow) {
                Text(L10n.text("Follow"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(BiliPalette.pink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, M.pageInset)
        .padding(.top, 10)
    }

    // MARK: 标题 + 更多（16×16）

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(video.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BiliPalette.lightPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(BiliPalette.lightTertiary)
                    .frame(width: M.moreIcon, height: M.moreIcon)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, M.pageInset)
        .padding(.top, 8)
    }

    private var statsRow: some View {
        Text(video.synopsis.isEmpty ? "—" : String(video.synopsis.prefix(70)))
            .font(.system(size: 11))
            .foregroundStyle(BiliPalette.lightTertiary)
            .lineLimit(2)
            .padding(.horizontal, M.pageInset)
            .padding(.top, 4)
    }

    // MARK: 互动五行（88.3×40）

    private var actionRow: some View {
        HStack(spacing: 0) {
            actionItem("hand.thumbsup", L10n.text("Like"), BiliPalette.lightTertiary, onLike)
            actionItem("hand.thumbsdown", L10n.text("Dislike"), BiliPalette.lightTertiary, onDislike)
            actionItem("circle.circle", L10n.text("Coin"), BiliPalette.lightTertiary, onCoin)
            actionItem("star", L10n.text("Favorite"),
                       isFavorite ? BiliPalette.accent : BiliPalette.lightTertiary, onFavorite)
            actionItem("arrowshape.turn.up.right", L10n.text("Share"), BiliPalette.lightTertiary, onShare)
        }
        .padding(.horizontal, M.pageInset)
        .padding(.top, 8)
    }

    private func actionItem(_ symbol: String, _ label: String, _ tint: Color,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: M.actionWidth, height: M.actionHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var tagRow: some View {
        HStack(spacing: 8) {
            if !activeLine.isEmpty {
                tagChip("music.note", activeLine)
            }
            if let first = flags.first {
                tagChip("number", first)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, M.pageInset)
        .padding(.top, 6)
    }

    private func tagChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(BiliPalette.lightTertiary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(BiliPalette.lightFill.opacity(0.5), in: Capsule())
    }

    // MARK: 选集（**浮层按钮 + 抽屉**，不是内联列表）
    //
    // 用户指正 + 实测复核：底部那条 `小影速说好片Videos …… 580 videos`
    // 是**置于顶层的悬浮按钮**（overlay，压在其他内容之上等待点击），
    // 点它弹出**抽屉**展示该系列全部选集 —— 不是把列表内联铺进页面。
    //
    // 两次 `ui.tree` 实测（同一视频 `小影速说好片`，580 集）：
    //   常态（24 元素）：`24,610 84x20` 系列名 · `108,610 42.7x20` Videos · `356,612.7 58x14.7` 580 videos
    //   抽屉态（44 元素）：头部 `12,293 96x20` · `108,293 48.7x20` Videos ·
    //                       `160.7,295.7 66x14.7` (580 videos) · `346.7,296 67.3x14.3` Descending
    //                       列表行距 100.3，标题两行 40 高，时长在缩略图下方 x≈116
    // 抽屉态整块上移到 y=293 且**盖住了详情内容**（About 仍在 262 但被压住），
    // 这正是"悬浮"的证据 —— 内联展开会把下方内容推下去，而这里没有。

    /// 用户确认 + 两次 `ui.tree` 实测：
    ///   · **收起** → 底层是「推荐其他视频」，系列条贴在最下
    ///   · **展开** → 该系列选集内联铺开，把下方内容推下去
    /// 不是浮层抽屉（整宽铺开、无面板左边界）。
    ///
    /// 收起态实测（20 元素）：`24,610 70×20` 系列名 · `94,610 42.7×20` Videos ·
    /// `356,612.7 58×14.7` 604 videos（贴最右）。
    /// 展开态实测（39 元素）：`12,293 80×20` · `92,293 48.7×20` ·
    /// `144.7,295.7 66×14.7` (604 videos) · `354.3,296 59.7×14.3` Ascending。
    /// **两态行内布局不同** —— 收起时集数贴右，展开时集数紧跟 Videos、Ascending 才贴右。
    /// 收起态（实测 `20` 元素版）：
    ///   `[缩略图] 系列名  Videos ......... 604 videos`
    /// 集数贴最右（x=356 / 屏宽 466）。
    private var seriesEntryRow: some View {
        Button { withAnimation(.smooth(duration: 0.22)) { episodesExpanded = true } } label: {
            HStack(spacing: 0) {
                // 实测 x=24 起，前面 24pt 是一张缩略图（无障碍树不暴露图片，按几何推断）
                poster(video.poster)
                    .frame(width: 60, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(seriesTitle ?? video.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BiliPalette.lightPrimary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                Text(L10n.text("Videos"))
                    .font(.system(size: 12))
                    .foregroundStyle(BiliPalette.lightTertiary)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                Text(L10n.text("%@ videos", String(episodes.count)))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(BiliPalette.lightSecondary)
                    .padding(.trailing, 12)
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, M.pageInset)
        .padding(.top, 10)
    }

    /// 展开态（实测 `39` 元素版）：
    ///   标题行 `系列名 · Videos · (n videos) ............ Ascending`，
    ///   然后单列列表，行距 100.3，标题单行 20pt，时长在缩略图下方（x=116）。
    private var expandedEpisodes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // 左侧「系列名 + Videos + (n videos)」整块可点 → 收起抽屉
                Button {
                    withAnimation(.smooth(duration: 0.22)) { episodesExpanded = false }
                } label: {
                    HStack(spacing: 0) {
                        Text(seriesTitle ?? video.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(BiliPalette.lightPrimary)
                            .lineLimit(1)
                        Text(L10n.text("Videos"))
                            .font(.system(size: 12))
                            .foregroundStyle(BiliPalette.lightTertiary)
                            .padding(.leading, 8)
                        Text(L10n.text("(%@ videos)", String(episodes.count)))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(BiliPalette.lightTertiary)
                            .padding(.leading, 5)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                // 实测：`346.7,296 67.3x14.3` 是排序控件，默认文案 **Descending**。
                // 点它切换排序方向（不是点它收起 —— 收起要点头部左侧系列名）。
                Button {
                    withAnimation(.smooth(duration: 0.2)) { episodesAscending.toggle() }
                } label: {
                    Text(L10n.text(episodesAscending ? "Ascending" : "Descending"))
                        .font(.system(size: 11))
                        .foregroundStyle(BiliPalette.lightSecondary)
                        .frame(minWidth: 67.3, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 20)
            .padding(.bottom, 8)

            LazyVStack(spacing: 0) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    Button { onPlay(episode) } label: {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                poster(video.poster)
                                    .frame(width: M.portraitThumb.width, height: M.portraitThumb.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                // 实测：时长在缩略图下方（x=116）。`duration` 为 nil 时不画 ——
                                // 用户明确要求「没有数据层的不显示，只留线路」。
                                if let d = episode.duration, d > 0 {
                                    Text(Self.clock(d))
                                        .font(.system(size: 10, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(BiliPalette.lightTertiary)
                                }
                            }
                            .frame(width: M.portraitThumb.width, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(episode.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(
                                        playing?.id == episode.id ? BiliPalette.accent : BiliPalette.lightPrimary
                                    )
                                    .lineLimit(M.portraitTitleLines)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // 实测第二行：日期 · 播放量 · 弹幕数。
                                // 每一项独立判空：缺哪项就不画哪项，绝不补假值。
                                HStack(spacing: 10) {
                                    if let p = episode.published {
                                        Text(Self.relativeDay(p))
                                            .font(.system(size: 11))
                                            .foregroundStyle(BiliPalette.lightTertiary)
                                    }
                                    if let v = episode.views, v > 0 {
                                        Text(Self.compact(v))
                                            .font(.system(size: 11))
                                            .monospacedDigit()
                                            .foregroundStyle(BiliPalette.lightTertiary)
                                    }
                                    if let dm = episode.danmaku {
                                        // 实测：弹幕为 0 时哔哩哔哩**画一个短横占位**
                                        // （`229.3,398 5.7x14.3 '-'`），不是不显示。
                                        Text(dm > 0 ? Self.compact(dm) : "-")
                                            .font(.system(size: 11))
                                            .monospacedDigit()
                                            .foregroundStyle(BiliPalette.lightTertiary)
                                    }
                                    // 四个字段都没有时，才回落到线路名
                                    if episode.published == nil, episode.views == nil, episode.danmaku == nil {
                                        Text(episode.flag)
                                            .font(.system(size: 11))
                                            .foregroundStyle(BiliPalette.lightTertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.top, 2)
                            Spacer(minLength: 0)
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13))
                                .foregroundStyle(BiliPalette.lightTertiary)
                                .frame(width: 28, height: 28)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: M.episodeRow, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 10)
    }

    // MARK: 封面（网络图，非播放层）

    /// `BiliSkinPicture` 只画 `AVPlayerLayer`（视频画面），不能画网络图。
    /// 选集行的封面是静态海报，所以用 `AsyncImage`；无 URL 时留同尺寸占位，避免行高跳动。
    private func poster(_ url: URL?) -> some View {
        Group {
            if let u = url {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        BiliPalette.lightFill
                    }
                }
            } else {
                BiliPalette.lightFill
            }
        }
    }

    // MARK: 格式（只格式化已有数据，不补零、不编造）

    /// `116.2` → `01:56`
    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 实测：24 mins ago / Yesterday 17:05 / 3 days ago / 11-5
    private static func relativeDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let m = Int(Date().timeIntervalSince(d) / 60)
            return m < 60 ? "\(m) mins ago" : L10n.text("Today")
        }
        if cal.isDateInYesterday(d) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "\(L10n.text("Yesterday")) \(f.string(from: d))"
        }
        let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
        if days < 30 { return "\(days) days ago" }
        let f = DateFormatter(); f.dateFormat = "M-d"
        return f.string(from: d)
    }

    /// 实测：108 / 1.5万 / 13.6万 / 171.9K / 597.4K / 4.7M
    private static func compact(_ n: Int) -> String {
        if n >= 10_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return String(n)
    }

    private var currentIndex: Int {
        guard let playing, let i = episodes.firstIndex(where: { $0.id == playing.id }) else { return 1 }
        return i + 1
    }

    }

private typealias M = BiliMetrics
#endif