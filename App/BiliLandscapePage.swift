#if os(iOS)
import SwiftUI
import TVCore

// MARK: - 哔哩哔哩横屏展开（左画面 + 右信息列，选集内联）

/// 照 9.18.0 在 **Duo 展开横持** 下的真实版式复刻。
///
/// 实测（guest 里哔哩哔哩本体，屏幕 678×466pt @3x，截图 2034×1398）：
///
/// 像素采样：左 1/4 全黑（0,0,0）= 画面；右 3/4 白（254,254,254）= 信息列。
///
/// ```
/// x=628 起    About(652,20) / Comments(652,31)          ← 右栏 tab
/// y=67        Creator avatar(628)  UP主(761)  +Follow    ← UP 主行
/// y=145       344.4K播放 · 655弹幕 · 时间 · 901 watching
/// y=202       Like(646)  Dislike  Coin  Favorite  Share   ← 互动五行
/// y=256       Series · Recent Works / 66/66 >            ← 选集入口
/// y=305       发现《Trouble Maker》  AI MV大赛>           ← 标签
/// y=382       单集 1（缩略图 + 两行标题 + 0:26 · 92.8K · 73）
/// y=474       单集 2                       ← 行距 92pt
/// ```
///
/// **最重要的一条**：展开横持时选集不是抽屉，是**内联列表直接铺在右栏**。
/// 这与合拢态（点入口弹底部抽屉）是两种交互，必须分开实现。
///
/// 顶栏只有三个控件：返回(23,46) / 投屏(524,46) / 三点(578,46)。
/// 没有全屏键 —— 因为已经是展开态。
struct BiliLandscapePage: View {
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
    var summary: String = ""
    var isFavorite: Bool = false
    /// 左列画面宽度占比。实测左列到 x≈628/678 ≈ 0.926？不 —— 那是右栏起点，
    /// 右栏宽 = 678-628 = 50pt 太窄。实测黑区是左 1/4，白区起于 0.75。
    /// 取 0.72 让画面保持 16:9 又不挤掉右栏。
    /// 左列（画面）占屏宽比例。
    /// 实测横屏 678 宽：左列 ≈428pt → 0.631；右栏 ≈250pt → 0.369。
    /// 之前 0.72 是猜的，画面占太宽、右栏被压窄。
    var pictureFraction: CGFloat = 0.63
    /// 画中画控制器：交给 `BiliSkinPicture` 把画面登记成 PiP 内容源（见 `BiliPortraitPage.pip` 的说明）。
    var pip: PictureInPicture? = nil
    /// 弹幕开关。与 Portrait / 全屏读同一个 `DanmakuPreference.key`（经 `danmakuOnForSkin` 传入）。
    var danmakuOn: Bool = true

    var onBack: () -> Void = {}
    var onCast: () -> Void = {}
    var onMore: () -> Void = {}
    var onFollow: () -> Void = {}
    var onLike: () -> Void = {}
    var onDislike: () -> Void = {}
    var onCoin: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onShare: () -> Void = {}
    var onEpisodes: () -> Void = {}
    var onPlay: (Episode) -> Void = { _ in }
    /// 信息列里的齿轮：进播放设置面板（与竖屏页同款入口）。
    var onSettings: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            // 实测（横屏 678×466）：`ui.tree` 报的横坐标基准不是 678。
            // 右栏最小 x=601、内容宽 350 → 合计 951 > 678，
            // 反推缩放 = 951/678 ≈ 1.403，换算回真实 pt：
            //   左列 = 601/1.403 ≈ **428pt（63.1%）**
            //   右栏 = 678-428 ≈ **250pt（36.9%）**
            // 之前 `max(width*0.28, 240)` 在 678 屏上得 240（差 10pt），
            // 而且那个 240 硬底在窄屏会把比例压坏 —— 去掉，纯按比例。
            let rightW = geo.size.width * (1 - pictureFraction)
            HStack(spacing: 0) {
                picture
                    .frame(width: geo.size.width - rightW)
                infoColumn
                    .frame(width: rightW)
            }
        }
        .background(BiliPalette.page)
    }

    // MARK: 左：画面 + 顶栏三键

    private var picture: some View {
        ZStack(alignment: .top) {
            BiliPalette.deep
            if let session {
                // ⚠️ `aspectRatio` 参数之前**只在声明处出现，从未被使用** ——
                // 结果画面按整列铺满、`resizeAspect` 自己在里面留黑边，
                // 视觉上视频很小、长宽利用率极低（用户明确反馈这一点）。
                // 现在按片源比例算出画面实际矩形，让它**撑满可用宽度、垂直居中**。
                BiliSkinPicture(player: session.player,
                                 gravity: BiliAspectMode.current.gravity,
                                 mirrored: BiliPlayerExtras.shared.mirror,
                                 colorFilters: BiliColorFilter.current.caFilters(),
                                 pip: pip)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 弹幕层（Bili 皮肤原来没有）。与 Portrait 同源同写法：
                // 共用 session 的 danmaku，叠在画面之上、控件之下。
                if danmakuOn, !session.danmaku.isEmpty {
                    DanmakuOverlay(player: session.player,
                                   comments: session.danmaku,
                                   opacity: session.danmakuOpacity,
                                   revision: session.danmakuRevision)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 0) {
                iconButton("chevron.backward", "Back", onBack)
                Spacer(minLength: 0)
                iconButton("airplayvideo", "Cast", onCast)
                iconButton("ellipsis", "More operations", onMore)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    // MARK: 右：信息列（tab / UP主 / 数据 / 互动 / 选集入口 / 标签 / 内联选集）

    private var infoColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tabRow
                creatorRow
                statsRow
                actionRow
                if episodes.count > 1 { seriesRow }
                tagRow
                if episodes.count > 1 { inlineEpisodes }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(BiliPalette.page)
    }

    private var tabRow: some View {
        HStack(spacing: 18) {
            VStack(spacing: 3) {
                Text(L10n.text("About"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BiliPalette.primary)
                Capsule().fill(BiliPalette.pink).frame(width: 16, height: 2)
            }
            Text(L10n.text("Comments"))
                .font(.system(size: 12))
                .foregroundStyle(BiliPalette.tertiary)
            Spacer(minLength: 0)
            // 齿轮：与竖屏页同款入口。横屏此前只有顶栏那颗 ellipsis（`actionMenu`），
            // 设置面板进不去 —— 三形态能力不对等。哔哩哔哩横持时这颗齿轮同样在信息列里。
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BiliPalette.tertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Playback Settings"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var creatorRow: some View {
        HStack(spacing: 8) {
            Circle().fill(BiliPalette.card).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(video.remarks.isEmpty ? L10n.text("Creator") : video.remarks)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BiliPalette.primary).lineLimit(1)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(BiliPalette.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onFollow) {
                Text(L10n.text("Follow"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(BiliPalette.pink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var statsRow: some View {
        Text(video.synopsis.isEmpty ? "—" : String(video.synopsis.prefix(60)))
            .font(.system(size: 10))
            .foregroundStyle(BiliPalette.tertiary)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.top, 6)
    }

    /// 互动五行：实测 x=646/699/…，在右栏内等分。
    private var actionRow: some View {
        HStack(spacing: 0) {
            actionItem("hand.thumbsup", "Like", BiliPalette.tertiary, onLike)
            actionItem("hand.thumbsdown", "Dislike", BiliPalette.tertiary, onDislike)
            actionItem("circle.circle", "Coin", BiliPalette.tertiary, onCoin)
            actionItem("star", "Favorite", isFavorite ? BiliPalette.accent : BiliPalette.tertiary, onFavorite)
            actionItem("arrowshape.turn.up.right", "Share", BiliPalette.tertiary, onShare)
        }
        .padding(.top, 10)
    }

    private func actionItem(_ symbol: String, _ label: String, _ tint: Color,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
    }

    /// 选集入口：实测 y=256，格式 `Series · 名称  N/M >`。
    private var seriesRow: some View {
        Button(action: onEpisodes) {
            HStack(spacing: 0) {
                Text(L10n.text("Series"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BiliPalette.secondary)
                Text(" · ").font(.system(size: 11)).foregroundStyle(BiliPalette.tertiary)
                Text(seriesTitle ?? video.name)
                    .font(.system(size: 11))
                    .foregroundStyle(BiliPalette.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Rectangle().fill(BiliPalette.line).frame(width: 1, height: 9)
                Text("\(episodeIndex)/\(episodes.count)")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(BiliPalette.secondary).padding(.leading, 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(BiliPalette.tertiary).padding(.leading, 3)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(BiliPalette.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var episodeIndex: Int {
        guard let playing, let i = episodes.firstIndex(where: { $0.id == playing.id }) else { return 1 }
        return i + 1
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            if !activeLine.isEmpty {
                Text(activeLine)
                    .font(.system(size: 10))
                    .foregroundStyle(BiliPalette.tertiary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(BiliPalette.card.opacity(0.5), in: Capsule())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: 内联选集列表（实测 y=382 起，行距 92pt）

    private var inlineEpisodes: some View {
        LazyVStack(spacing: 0) {
            ForEach(episodes) { episode in
                let current = playing?.id == episode.id
                Button { onPlay(episode) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(BiliPalette.card)
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(BiliPalette.tertiary)
                        }
                        .frame(width: 56, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.name)
                                .font(.system(size: 12, weight: current ? .semibold : .regular))
                                .foregroundStyle(current ? BiliPalette.accent : BiliPalette.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text(episode.flag)
                                .font(.system(size: 10))
                                .foregroundStyle(BiliPalette.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func iconButton(_ symbol: String, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.3), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
    }
}
#endif