#if !os(tvOS)
import SwiftUI
import TVCore

/// 手动标广告：用户**自己指定起点和终点**。
///
/// 为什么需要这一页，而不是只有「标注广告」按钮：
///
///   那一条走 `markAd(at:)`，靠 `AdBoundary.locate` 抓帧猜边界。猜有三重不可靠：
///   ① 广告内部有转场/纯色卡/品牌收尾，相似度会在中途掉下去，段被切一半；
///   ② 正片开头若有黑场或台标，会被当成广告的一部分往外扩；
///   ③ 抓帧本身可能拿不到（切片源、解密流），此时什么都没发生。
///
///   而用户往往**看得见边界**：黑场切、片头卡、台标出现/消失。
///   让他点两个时间点，就是两个时间点 —— 算法不再往里塞猜测。
///
/// 交互：起止点默认取当前播放位置，可一键「设为当前」，也可直接输入时间码。
/// 「边界微调」用 ±0.5 秒按钮，因为用户暂停那一刻通常差半秒。
struct AdRangeEditor: View {
    let session: PlaybackSession
    /// 打开时把播放位置带进来当起点。
    var onSaved: (AdRange) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    /// 起点/终点。用「秒」存，界面上显示时间码。
    @State private var start: Double = 0
    @State private var end: Double = 0
    /// 用户在某个输入框里打字时不覆盖他的输入。
    @State private var editingStart = false
    @State private var editingEnd = false
    @State private var saving = false
    @State private var message: String?

    private var duration: Double { session.duration }

    /// 当前这一段能不能提交。
    private var draft: AdRange? {
        AdMarkRange.make(from: start, to: end, duration: duration)
    }

    /// 与已有段重叠的提示 —— 不算错误（提交时新段会替换旧的），但要提前说清楚。
    private var overlapping: [AdRange] {
        guard let draft else { return [] }
        return session.skipSettings.ads.filter { $0.overlaps(draft) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(title: L10n.text("Ad starts at"), value: $start, editing: $editingStart,
                        identifier: "ad.range.start")
                    row(title: L10n.text("Ad ends at"), value: $end, editing: $editingEnd,
                        identifier: "ad.range.end")
                } header: {
                    Text(L10n.text("Ad Range"))
                } footer: {
                    Text(L10n.text("Mark where the ad begins and ends. Playback jumps past exactly this range."))
                }

                Section {
                    // ⛔ 这两个按钮的标题**绝不能**直接读 `session.position`。
                    //
                    // `position` 每秒被 `updateSkipping` 改写。一旦它进了 `body`，
                    // 整个 Form 每秒重建一次：输入框会丢焦点、键盘会被收回去、
                    // 按钮点不中 —— 本项目已经为这个形态吃过一次苦（「更多」菜单抖动）。
                    // 现在的做法：标题用 `TimelineView` 把 1Hz 变化**圈在一个小节点里**，
                    // 点击时才在 action 里读一次真实位置。
                    Button {
                        let here = session.position
                        start = here
                        if end <= start { end = min(start + 15, max(duration, start + 15)) }
                    } label: {
                        HStack {
                            Label(L10n.text("Start at current position"), systemImage: "arrow.right.to.line")
                            Spacer()
                            nowText
                        }
                    }
                    .accessibilityIdentifier("ad.range.startHere")

                    Button {
                        let here = session.position
                        end = here
                        if start >= end { start = max(0, end - 15) }
                    } label: {
                        HStack {
                            Label(L10n.text("End at current position"), systemImage: "arrow.left.to.line")
                            Spacer()
                            nowText
                        }
                    }
                    .accessibilityIdentifier("ad.range.endHere")

                    // 暂停那一刻差半秒是常态：给整体平移，不给拉伸。
                    // 拉伸会让用户同时动两个数字，越调越乱。
                    HStack(spacing: 12) {
                        Button { nudge(-0.5) } label: { Label("−0.5s", systemImage: "minus") }
                            .buttonStyle(.bordered)
                        Button { nudge(0.5) } label: { Label("+0.5s", systemImage: "plus") }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button { stretchEnd(-0.5) } label: { Text(L10n.text("End −0.5s")) }
                            .buttonStyle(.borderless)
                        Button { stretchEnd(0.5) } label: { Text(L10n.text("End +0.5s")) }
                            .buttonStyle(.borderless)
                    }
                    .font(.footnote)
                } header: {
                    Text(L10n.text("Fine Adjust"))
                }

                if let draft {
                    Section {
                        LabeledContent(L10n.text("Length"),
                                       value: EpisodeSkipSettings.formatTime(draft.length))
                            .accessibilityIdentifier("ad.range.length")
                    } footer: {
                        if !overlapping.isEmpty {
                            Text(L10n.text("This overlaps %d marked range(s); saving replaces them.",
                                           overlapping.count))
                            .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section {
                        Text(L10n.text("The end must be at least %@ after the start.",
                                       EpisodeSkipSettings.formatTime(AdMarkRange.shortest)))
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("ad.range.invalid")
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }

                // 本集已标的段：让用户看得见、删得掉。
                // 此前这些段**只在跳过的那一瞬间存在**——界面从不显示，
                // 用户没法确认标没标上，也没法删掉标错的。
                if !session.skipSettings.ads.isEmpty {
                    Section {
                        ForEach(session.skipSettings.ads.sorted { $0.start < $1.start }) { ad in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(EpisodeSkipSettings.formatTime(ad.start)) – \(EpisodeSkipSettings.formatTime(min(ad.end, duration)))")
                                        .font(.subheadline).monospacedDigit()
                                    Text(ad.marked ? L10n.text("Marked by hand")
                                                   : L10n.text("Found automatically"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    session.removeAdRange(id: ad.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("ad.range.delete")
                            }
                        }
                    } header: {
                        Text(L10n.text("Ads in This Episode"))
                    }
                }
            }
            .navigationTitle(L10n.text("Mark Ad Range"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save")) { Task { await save() } }
                        .disabled(draft == nil || saving)
                        .accessibilityIdentifier("ad.range.save")
                }
            }
            .onAppear(perform: prepare)
            #if os(macOS)
            .frame(width: 520, height: 620)
            #else
            .presentationDetents([.large])
            #endif
        }
    }

    /// 当前播放位置的只读读数。
    ///
    /// `TimelineView` 把每秒的变化限制在这个小节点内：父级 Form 不参与重算，
    /// 输入框因此不会每秒丢焦点。
    private var nowText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(EpisodeSkipSettings.formatTime(session.position))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 行

    private func row(title: String, value: Binding<Double>, editing: Binding<Bool>,
                     identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("00:00", text: Binding(
                get: { EpisodeSkipSettings.formatTime(value.wrappedValue) },
                set: { text in
                    editing.wrappedValue = true
                    if let parsed = EpisodeSkipSettings.parseTime(text) {
                        value.wrappedValue = min(parsed, max(duration, parsed))
                    }
                }))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 110)
                .accessibilityIdentifier(identifier)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }

    // MARK: - 动作

    private func prepare() {
        // 起点默认 = 播放位置，终点默认 = 起点 + 15 秒（常见贴片长度，用户再改）。
        let here = session.position.isFinite ? max(0, session.position) : 0
        start = here
        end = min(here + 15, max(duration, here + 1))
        // 没有片长的频道（直播、还没加载完）不给标：标了也存不进、跳不了。
        if !(duration.isFinite && duration > 0) {
            message = L10n.text("Wait for the video duration before marking an ad.")
        }
    }

    /// 整体平移，两端一起动 —— 起终点都算错半秒时用它。
    private func nudge(_ delta: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let span = max(0, end - start)
        var newStart = min(max(0, start + delta), max(0, duration - span))
        if !newStart.isFinite { newStart = 0 }
        start = newStart
        end = min(duration, newStart + span)
    }

    /// 只动终点（用户看清了广告结束在哪一格）。
    private func stretchEnd(_ delta: Double) {
        guard duration.isFinite, duration > 0 else { return }
        end = min(max(start + 0.5, end + delta), duration)
    }

    private func save() async {
        guard let draft, !saving else { return }
        saving = true
        defer { saving = false }
        let saved = await session.markAd(from: draft.start, to: draft.end)
        if let saved {
            onSaved(saved)
            dismiss()
        } else {
            // 存不下来只有一种原因：这个频道没有 skipScope（设置页手工建的播放 URL）。
            // 以前这里静默成功，用户以为标上了，下一集全没。
            message = L10n.text("This video can't remember marks. Open it from a series to use them.")
        }
    }
}
#endif
