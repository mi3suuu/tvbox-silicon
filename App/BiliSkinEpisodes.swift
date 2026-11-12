#if os(iOS)
import SwiftUI
import TVCore

/// 选集行要显示的四个字段（发布日期 / 时长 / 播放量 / 弹幕）。
///
/// 直接读 `TVCore.Episode` 上的真实可选属性（`published` / `duration` / `views` / `danmaku`）。
/// 这些属性由数据源详情响应或跨源匹配（TMDB）填充；通用 TVBox 目录解析器不填，于是为 nil。
/// 每个字段单独映射为展示串（缺失即 nil），渲染处按 nil 逐字段判空——绝不编造假数据。
private extension Episode {
    static let biliDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()
    /// 发布日期，如 `11-5`（实测归一 y≈0.730）。无数据则 nil。
    var biliDateText: String? { published.map { Self.biliDateFormatter.string(from: $0) } }
    /// 时长，如 `01:03`（实测在缩略图下方 x≈0.751）。无数据则 nil。
    var biliDurationText: String? {
        duration.map { let s = Int($0); return String(format: "%d:%02d", s / 60, s % 60) }
    }
    /// 播放量，如 `142.3K 播放`（实测 x≈0.759）。无数据则 nil。
    var biliViewsText: String? { views.map { Self.biliCompactCount($0) + " 播放" } }
    /// 弹幕数，如 `45 弹幕`（实测 x≈0.757）。无数据则 nil。
    var biliDanmakuText: String? { danmaku.map { Self.biliCompactCount($0) + " 弹幕" } }

    /// 紧凑计数：`142300 -> "142.3K"`，`12000000 -> "12.0M"`，否则原值。
    static func biliCompactCount(_ n: Int) -> String {
        if n >= 10_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "(n)"
    }
}

// MARK: - 哔哩哔哩选集抽屉（按实测量复刻）

/// 照 9.18.0 的真实抽屉复刻。**不是网格，是单列列表。**
///
/// 数据来源：guest 里跑哔哩哔哩本体，点开 `Series` 那一行，读 `ui.tree`
/// 并截图（1398×2034 = 横屏 678×466pt @3x）。实测归一坐标：
///
///     0.440 0.025  AI Fun Video                       ← 系列名（大号粗体）
///     0.484 0.025  Total 107 episodes · 85.4M views    ← 副标题
///     0.516 0.023  简介两行 + 右侧 More / Favorite      ← 系列简介区
///     0.578 0.029  Episodes        0.578 0.803  Ascending  ← 标题 + 排序
///     0.613 0.336  缩略图
///     0.671 0.332  单集标题（两行）
///     0.730 0.330  11-5                                ← 发布日期
///     0.751 0.241  01:03   0.759 0.361  142.3K  0.757 0.469  45
///     ---- 下一集 0.816 起，行距约 0.10 ----
///
/// 与旧实现相反的四个判据：
/// 1. **列表，不是网格** —— 旧版用 LazyVGrid adaptive 64–120，全错。
/// 2. 每行左侧**缩略图**（约 60pt 宽），右侧标题两行 + 日期 + 统计。
/// 3. 顶部是**系列信息区**（系列名 / 集数总览 / 简介 / 收藏），不是「共 N 集」小标题。
/// 4. 排序按钮在右端，文案 `Ascending`，前带上下箭头图标。
/// 5. 抽屉只占下半屏，上半屏**仍留着画面**（黑）——所以用 `.medium` detent。
struct BiliEpisodeDrawer: View {
    let episodes: [Episode]
    var playing: Episode?
    var flags: [String] = []
    var activeLine: String = ""
    /// 系列名（`Series ·` 后面那段）。
    var title: String = ""
    /// 集数总览，如「Total 107 episodes · 85.4M views」；空则整行不画。
    var summary: String = ""
    /// 系列简介。
    var synopsis: String = ""
    var isFavorite: Bool = false
    @Binding var reversed: Bool
    var onSelectLine: (String) -> Void = { _ in }
    var onFavorite: () -> Void = {}
    var onPlay: (Episode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if flags.count > 1 { lineRow }
            Divider().overlay(BiliPalette.lightLine.opacity(0.5))
            list
        }
        .background(BiliPalette.lightPage)
    }

    // MARK: 系列信息区（实测 y≈0.44–0.57）

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(BiliPalette.lightPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onFavorite) {
                    HStack(spacing: 3) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 12))
                        Text(L10n.text("Favorite"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(isFavorite ? BiliPalette.accent : BiliPalette.lightSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)

            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(BiliPalette.lightTertiary)
                    .padding(.top, 4)
            }

            if !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: 12))
                    .foregroundStyle(BiliPalette.lightSecondary)
                    .lineLimit(2)
                    .padding(.top, 8)
            }

            HStack(spacing: 0) {
                Text(L10n.text("Episodes"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BiliPalette.lightPrimary)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.smooth(duration: 0.2)) { reversed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(reversed ? L10n.text("Descending") : L10n.text("Ascending"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(BiliPalette.lightSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 12)
    }

    private var lineRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(flags, id: \.self) { flag in
                    Button { onSelectLine(flag) } label: {
                        Text(flag)
                            .font(.system(size: 12, weight: flag == activeLine ? .semibold : .regular))
                            .foregroundStyle(flag == activeLine ? BiliPalette.accent : BiliPalette.lightSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(flag == activeLine ? BiliPalette.accent.opacity(0.14) : BiliPalette.lightFill.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    // MARK: 单列列表

    private var ordered: [Episode] { reversed ? episodes.reversed() : episodes }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { _, episode in
                    row(episode: episode)
                    Divider().overlay(BiliPalette.lightLine.opacity(0.35)).padding(.leading, 12)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func row(episode: Episode) -> some View {
        let current = playing?.id == episode.id
        return Button { onPlay(episode) } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(BiliPalette.lightFill)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BiliPalette.lightTertiary)
                }
                .frame(width: 62, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.name)
                        .font(.system(size: 13, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? BiliPalette.accent : BiliPalette.lightPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    // 哔哩哔哩这一行是「发布日期 + 时长 + 播放量 + 弹幕数」。
                    // 四个字段都来自 `Episode` 的可选属性，逐字段判空：缺哪个就不画哪个。
                    // 四个全缺时回落到线路名（`flag`），让这一行不空着——绝不编造假数据。
                    HStack(spacing: 8) {
                        if let date = episode.biliDateText {
                            Text(date).font(.system(size: 11)).foregroundStyle(BiliPalette.lightTertiary)
                        }
                        if let dur = episode.biliDurationText {
                            Text(dur).font(.system(size: 11)).foregroundStyle(BiliPalette.lightTertiary)
                        }
                        if let v = episode.biliViewsText {
                            Text(v).font(.system(size: 11)).foregroundStyle(BiliPalette.lightTertiary)
                        }
                        if let d = episode.biliDanmakuText {
                            Text(d).font(.system(size: 11)).foregroundStyle(BiliPalette.lightTertiary)
                        }
                        if episode.biliDateText == nil, episode.biliDurationText == nil,
                           episode.biliViewsText == nil, episode.biliDanmakuText == nil {
                            Text(episode.flag)
                                .font(.system(size: 11))
                                .foregroundStyle(BiliPalette.lightTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif