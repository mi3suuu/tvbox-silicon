import SwiftUI
import TVCore

#if os(iOS)

/// 换源面板：在全部订阅的所有源里，找出同一部剧的其它副本。
///
/// 为什么需要它
/// -----------
/// 一部剧平均有 20–60 个源都有。某个源卡了、某条线断了、某源只有 480p，
/// 现在的做法是「退回搜索页重新搜一遍，再从几十条同名结果里手工认」——
/// 用户得自己判断哪条是同一部剧。这个面板把判定做掉，只留「选哪个」。
///
/// 判据在 `CrossSourceMatch`（标题归一 + 年份 + 集数 + 分类，三档结论），
/// 数据在 `Store.searchCrossSource`（向所有可见源派发搜索）。
///
/// 每一行必须写清**为什么认为是同一部**：`Candidate.reason` 里的
/// 「同一年 2019 · 同为 46 集」是用户敢点换源的唯一依据。只给一个布尔
/// 等于让他赌。
struct CrossSourceSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 换源成功后做什么（通常是关面板 + 提示）。
    var onSwitched: (CrossSourceMatch.Candidate) -> Void = { _ in }
    /// 换源失败的原因，交给调用方弹提示。
    var onFailed: (String) -> Void = { _ in }

    @State private var switching: String?
    @State private var showOnlyExact = false

    private var state: Store.CrossSourceState { store.crossSource }

    private var rows: [CrossSourceMatch.Candidate] {
        showOnlyExact ? state.candidates.filter { $0.verdict == .sameShow } : state.candidates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            lineMatrix
            if !state.matrixCells.isEmpty { Divider().opacity(0.3) }
            content
            Divider().opacity(0.3)
            footer
        }
        .background(.regularMaterial)
        .task {
            // 打开就搜。已经搜过同一个关键词时 `searchCrossSource` 直接复用结果，
            // 反复开关面板不会反复打几十上百个源。
            await store.searchCrossSource()
        }
    }

    // MARK: 头

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("换个源看")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Close"))
            }

            // 正在看的那部，让用户确认「换的是这一部」。
            if let catalog = store.playbackCatalog {
                HStack(spacing: 10) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 30)
                        .overlay { PosterImage(url: catalog.video.poster, headers: catalog.video.posterHeaders) }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(catalog.video.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text([catalog.video.year, catalog.client.site.name]
                                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                                    .joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            SourceRouteBadge(site: catalog.client.site)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // 进度：问了多少源、回了多少、谁没答。转圈之外必须有数字 ——
            // 「搜了 60 个源」与「搜了 3 个源」的等待感受完全不同。
            HStack(spacing: 8) {
                if state.running {
                    ProgressView().controlSize(.small)
                    Text("正在搜索 \(state.asked) 个源 · 已回 \(state.answered)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if state.finished {
                    Text(state.candidates.isEmpty
                         ? L10n.text("No other source has this title.")
                         : L10n.text("%lld sources have this title", state.candidates.count))
                        .font(.caption).foregroundStyle(.secondary)
                    if !state.skipped.isEmpty {
                        Text(L10n.text("· %lld did not answer", state.skipped.count))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    // ★ 测试连通性：真正发请求。
                    //
                    // 这个面板此前从不测速，只显示 `SourceProbeStore` 的旧缓存，
                    // 没测过的源一律空白 —— 看起来能测、实际一个请求都没发。
                    // 现在这一颗按钮会逐个拉候选源的详情、解析真实播放地址再测，
                    // 数字逐行填上来。
                    if !state.candidates.isEmpty {
                        Button {
                            Task { await store.probeCrossSourceCandidates(force: true) }
                        } label: {
                            if state.probing {
                                Text(L10n.text("Testing %lld/%lld", state.probed, state.probeTotal))
                                    .font(.caption).monospacedDigit()
                            } else {
                                Label(L10n.text("Test Connections"), systemImage: "speedometer")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(state.probing || state.running)
                    }
                    // ★ 全线路矩阵：把这部剧在**每个源 × 每条线**上摊平实测。
                    //
                    // 与上面那颗「测试连通性」的分工：那颗每源只测一条线（回答"换到哪个源"），
                    // 这颗测每源每条线（回答"换到哪个源的哪条线"）。
                    // 换源的真实动机常常跨维度：A 源 2 号线 40ms 但 80KB/s，
                    // B 源 1 号线 120ms 但 3MB/s —— 源级数字挑不出来。
                    if !state.candidates.isEmpty {
                        Button {
                            Task { await store.buildCrossSourceLineMatrix(force: true) }
                        } label: {
                            if state.matrixRunning {
                                Text(L10n.text("Scanning %lld/%lld", state.matrixDone, state.matrixTotal))
                                    .font(.caption).monospacedDigit()
                            } else {
                                Label(L10n.text("All Lines"), systemImage: "square.grid.3x3")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(state.matrixRunning || state.running)
                    }
                    if state.candidates.contains(where: { $0.verdict == .sameShow }) {
                        Toggle(isOn: $showOnlyExact) {
                            Text("只看确定的").font(.caption)
                        }
                        .toggleStyle(.button)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: 列表

    /// 矩阵结果区：按源分组，每行一个源，行内列出它的每条线路读数。
    /// 矩阵区最多显示多少个源、每个源最多几条线。
    ///
    /// 20–60 个源 × 若干线路，全部铺开会把 sheet 顶爆：
    /// 候选列表和页脚被挤出可视区，用户找不到「换源」按钮。
    /// 取 8 个源（已按最优排序，前 8 个就是要选的）、每源 4 条线 ——
    /// 超出的部分在页脚提示，不静默截断。
    private static let matrixRowLimit = 8
    private static let matrixCellLimit = 4

    @ViewBuilder private var lineMatrix: some View {
        let all = LineMatrix.build(state.matrixCells)
        let grouped = Array(all.prefix(Self.matrixRowLimit))
        if !grouped.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(L10n.text("Every source, every line"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if let best = LineMatrix.overallBest(grouped) {
                        // 「一键答案」：全矩阵最优的那一格，直接说清是哪个源哪条线。
                        Text(L10n.text("Best: %@ · %@", best.sourceName, best.flag))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(grouped) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.sourceName)
                            .font(.caption2.weight(.medium)).lineLimit(1)
                        ForEach(Array(row.cells.prefix(Self.matrixCellLimit))) { cell in
                            HStack(spacing: 6) {
                                Text(cell.flag)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .frame(width: 48, alignment: .leading)
                                if let r = cell.result {
                                    Text(probeText(r))
                                        .font(.caption2).foregroundStyle(probeColor(r))
                                } else {
                                    Text(L10n.text("Not measured"))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                }
                }
                .frame(maxHeight: 220)   // 上限：绝不能把候选列表与页脚挤出可视区
                // 截断了要说出来 —— 静默只显示前几个会让用户以为「只有这几个源」。
                if all.count > Self.matrixRowLimit {
                    Text(L10n.text("Showing the best %lld of %lld sources",
                                   Self.matrixRowLimit, all.count))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: state.running ? "magnifyingglass" : "rectangle.on.rectangle.slash")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(state.running
                         ? L10n.text("Looking through your subscriptions…")
                         : L10n.text("Nothing else to switch to. Only this source has it."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !state.running, !state.skipped.isEmpty {
                        Text(state.skipped.joined(separator: "、"))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .padding(.horizontal, 20)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { candidate in
                        row(candidate)
                        Divider().opacity(0.25).padding(.leading, 66)
                    }
                }
            }
        }
    }

    private func row(_ candidate: CrossSourceMatch.Candidate) -> some View {
        Button {
            guard switching == nil else { return }
            switching = candidate.id
            store.switchToCrossSource(candidate) {
                switching = nil
                onSwitched(candidate)
                dismiss()
            } failed: { message in
                switching = nil
                onFailed(message)
            }
        } label: {
            HStack(spacing: 12) {
                Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 42)
                    .overlay { PosterImage(url: candidate.video.poster, headers: candidate.video.posterHeaders) }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1)) }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.sourceName)
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        // 确定性徽标：用户一眼分清「同一年同集数」与「只是同名」。
                        badge(for: candidate.verdict)
                    }
                    Text(candidate.reason)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    // 订阅来源 + 该源的可达性。测过才写，没测过不编。
                    HStack(spacing: 6) {
                        Text(candidate.origin.host() ?? candidate.origin.absoluteString)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        // 实测读数优先（用户点过"测试连通性"），其次才是搜索时的缓存。
                        // 这条链修的是「面板显示能测速、实际从不测」的旧行为。
                        if let probe = state.readings[candidate.id] ?? candidate.probe {
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text(probeText(probe))
                                .font(.caption2)
                                .foregroundStyle(probeColor(probe))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if switching == candidate.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switching != nil)
    }

    @ViewBuilder private func badge(for verdict: CrossSourceMatch.Verdict) -> some View {
        switch verdict {
        case .sameShow:
            Text("同一部")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Brand.accent.opacity(0.18)))
                .foregroundStyle(Brand.accent)
        case .likelySame:
            Text("同名")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
        case .different:
            EmptyView()
        }
    }

    /// 可达性的一句话。只说测出来的事：延迟、吞吐、声明分辨率。
    private func probeText(_ probe: SourceProbeResult) -> String {
        var parts: [String] = []
        if let label = probe.resolutionLabel, !label.isEmpty { parts.append(label) }
        if let ms = probe.latencyMilliseconds { parts.append("\(ms) ms") }
        if let kbps = probe.kilobytesPerSecond, kbps > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(kbps) * 1024, countStyle: .file) + "/s")
        }
        switch probe.reachability {
        case .unreachable: return L10n.text("Not reachable last time")
        case .slow: parts.insert(L10n.text("Slow"), at: 0)
        case .reachable, .unknown: break
        }
        return parts.isEmpty ? L10n.text("Not measured") : parts.joined(separator: " · ")
    }

    private func probeColor(_ probe: SourceProbeResult) -> Color {
        switch probe.reachability {
        case .reachable: return .secondary
        case .slow: return Brand.amber
        case .unreachable: return Brand.rose
        case .unknown: return Color.secondary.opacity(0.6)
        }
    }

    // MARK: 底

    private var footer: some View {
        HStack(spacing: 10) {
            // 说清「为什么只有这些」：同名的被判成别的剧时，用户需要知道不是我漏了。
            Text("标题相同但年份或集数对不上的，不会出现在这里。")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                Task { await store.searchCrossSource(force: true) }
            } label: {
                Label(L10n.text("Search Again"), systemImage: "arrow.clockwise")
            }
            .controlButton()
            .disabled(state.running)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

#endif
