import SwiftUI
import TVCore

/// The sweep, the grouping and the routing, on the page where those decisions are actually made.
///
/// Why this exists
/// ---------------
/// The Sources page already holds three sets of choices about a source — which group it is filed
/// under, whether it is pinned or hidden, and whether it goes direct or through the relay — and the
/// page that measured them lived in Settings, on the other side of the app. The measurement was
/// available where the decision was not.
///
/// What it does that the old page could not
/// ----------------------------------------
/// 1. Incremental. A sweep re-probes only sources whose reading is older than the window, so
///    pressing it twice costs seconds instead of minutes. The window is a setting on the page.
/// 2. Per group. A group can be measured on its own; the footer says how many it will visit.
/// 3. Batch migration. Everything that answered can be filed into a group together, or moved into
///    another group together — without dragging 300 cards one at a time.
/// 4. Batch routing. "Answered goes direct, silent goes through the relay" is one action, taken
///    from the readings rather than from a guess.
struct SourceSpeedLab: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Bumped after a sweep or a write, so the rows re-read the stores: SourceProbeStore is a
    /// dictionary behind UserDefaults, not observable, and a page that read it once would keep
    /// showing the numbers from before.
    @State private var revision = 0
    @State private var scope: Scope = .all
    @State private var pickedGroup = ""
    @State private var pickedSubscription = ""
    @State private var note: String?
    /// Sources handed in by the page that opened this sheet — the ticked cards. They make the sheet
    /// answer "measure/hide/file *these*", which is the question a reader has right after ticking
    /// them; without it every batch action would be a second trip to the page they came from.
    var picked: [Site] = []

    private enum Scope: String, CaseIterable, Identifiable {
        case all, subscription, group, picked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L10n.text("Everything")
            case .subscription: return L10n.text("One Subscription")
            case .group: return L10n.text("One Group")
            case .picked: return L10n.text("Picked")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                sweepSection
                tidySection
                readingSection
                filingSection
                routingSection
                footnote
            }
            .navigationTitle(L10n.text("Speed & Grouping"))
            // `navigationBarTitleDisplayMode` 是 UIKit 侧 API：macOS 没有。
            // 原来写的是 `!os(tvOS)`，于是 macOS target 在这一行直接报
            // 「unavailable in macOS」—— macOS 构建的最后一道门就是它。
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }
                }
            }
        }
        // 勾着源打开这一页时，默认作用域就是那批源：否则读者勾了 12 个、点「测速」，
        // 页面按的是「全部源」，会把 300 个源扫一遍——那个交互等于没实现。
        .task {
            if !picked.isEmpty { scope = .picked }
            adoptFirstGroup()
        }
        // A group can disappear (all its sources moved away) while the sheet is open: without this the
        // Scope picker shows a group id that no longer resolves and every count reads zero.
        .onChange(of: selectableGroups.map(\.id)) { _, ids in
            if !ids.contains(pickedGroup) { pickedGroup = ids.first ?? "" }
        }
    }

    // MARK: - Scope

    private var scopeSection: some View {
        Section {
            // A menu, not a segmented control: four labels — "One Subscription", "手选的源" — do not
            // fit four segments on a phone, and a truncated segment is a scope the reader cannot
            // tell apart from its neighbour. The scope is read once before pressing Measure, so a
            // menu costs one tap and no ambiguity.
            Picker(L10n.text("Measure"), selection: $scope) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            if scope == .subscription {
                Picker(L10n.text("Subscription"), selection: $pickedSubscription) {
                    ForEach(store.environmentSubscriptions.filter(\.enabled)) { entry in
                        Text(entry.title).tag(entry.address)
                    }
                }
            }
            if scope == .group {
                Picker(L10n.text("Group"), selection: $pickedGroup) {
                    ForEach(selectableGroups) { group in
                        Text(group.title).tag(group.id)
                    }
                }
            }
            if scope == .picked {
                // 手选的源只存在于被借用进来的这次任务里，所以这一档显示的是「外面选了几个」，
                // 而不是再给一份列表让人挑第二次。
                Text(picked.isEmpty
                     ? L10n.text("No sources were ticked. Close this and tick some on the Sources page.")
                     : L10n.text("%lld ticked sources.", picked.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // The incremental window, stated as time rather than as a flag: "skip anything measured
            // in the last ten minutes" is the sentence a person can reason about.
            Picker(L10n.text("Skip readings newer than"), selection: Binding(
                get: { Int(store.probeMaxAge) },
                set: { store.probeMaxAge = TimeInterval($0) })) {
                Text(L10n.text("Never skip")).tag(0)
                Text(L10n.text("5 minutes")).tag(300)
                Text(L10n.text("10 minutes")).tag(600)
                Text(L10n.text("30 minutes")).tag(1800)
                Text(L10n.text("1 hour")).tag(3600)
            }
            Text(L10n.text("A source measured inside this window is left alone, so a second sweep costs only what changed. Set it to Never skip to re-measure everything."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(L10n.text("Scope"))
        }
    }

    // MARK: - 测完自动整理

    /// 一轮扫描结束后自动做什么。
    ///
    /// 从前「测速 → 按结果分组 → 按得分排序 → 按可达性改路由」是四个独立的手动步骤，
    /// 忘一步列表就停在半整理状态。这里把它们串成一次，默认只开「重排」——
    /// 那个不改分组、不改地址；另外两项会动用户亲手整理过的东西，得他自己点头。
    private var tidySection: some View {
        Section {
            Toggle(L10n.text("Reorder by score"), isOn: Binding(
                get: { store.postSweepTidy.contains(.reorder) },
                set: { setTidy(.reorder, $0) }))
            Toggle(L10n.text("File into Reachable / Unreachable"), isOn: Binding(
                get: { store.postSweepTidy.contains(.fileByResult) },
                set: { setTidy(.fileByResult, $0) }))
            Toggle(L10n.text("Reachable to Direct, Unreachable to Proxy"), isOn: Binding(
                get: { store.postSweepTidy.contains(.routeByResult) },
                set: { setTidy(.routeByResult, $0) }))
            if let said = store.lastTidyNote {
                Text(said).font(.caption).foregroundStyle(Brand.accent)
            }
        } header: {
            Text(L10n.text("After the Sweep"))
        } footer: {
            Text(L10n.text("Grouping only moves sources that have a reading, so a group you arranged by hand stays as it is until a source in it is measured. Routing rewrites the address a source API is fetched from; media still comes from the source's own CDN."))
            // 分书架是自动的，不需要在这里勾任何一项 —— 但读者看不到代码，只看到「测完了列表没变」。
            Text(L10n.text("Once three or more sources in a group play, the Sources page shelves that group by connection on its own."))
        }
    }

    private func setTidy(_ option: PostSweepTidy, _ on: Bool) {
        var next = store.postSweepTidy
        if on { next.insert(option) } else { next.remove(option) }
        store.postSweepTidy = next
    }

    // MARK: - Sweep

    private var sweepSection: some View {
        Section {
            if let run = store.probeRun {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                    HStack {
                        Text(L10n.text("%lld of %lld measured", run.done, run.total))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("Stop")) { store.cancelProbingAllSources() }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                Button {
                    start()
                } label: {
                    Label(measureTitle, systemImage: "speedometer")
                }
                .disabled(targets.isEmpty)

                if let skipped = store.probeSkipped, skipped > 0 {
                    Text(L10n.text("%lld skipped: measured recently.", skipped))
                        .font(.caption).foregroundStyle(.secondary)
                }
                // 和「读数太新」是两回事：这些源被阶段 1 判为连不上/服务器报错，
                // 没有进入细测。不说清楚，用户只会看到「测了 150 个」而不知道另 200 个去哪了。
                if let screened = store.probeScreenedOut, screened > 0 {
                    Text(L10n.text("%lld not attempted: the endpoint did not answer.", screened))
                        .font(.caption).foregroundStyle(Brand.amber)
                }
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.text("Sweep"))
        }
    }

    // MARK: - Readings

    private var readingSection: some View {
        Section {
            let _ = revision
            LabeledContent(L10n.text("Sources"), value: String(buckets.all.count))
            // 与「分组」「路由」两段用同一对词：同一页里一处叫 Answered/Silent、另一处叫
            // Reachable/Unreachable，读者会以为是四个不同的量。分组实际建出来的组名就是
            // 「可连 / 不通」，统计行用同一对名字。
            LabeledContent(L10n.text("Reachable"), value: String(buckets.up.count))
            LabeledContent(L10n.text("Unreachable"), value: String(buckets.down.count))
            LabeledContent(L10n.text("Not measured"), value: String(buckets.unknown.count))
            if let window = SourceProbeStore.shared.measurementWindow {
                LabeledContent(L10n.text("Newest reading"),
                               value: window.newest.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text(L10n.text("Readings"))
        }
    }

    // MARK: - Filing

    private var filingSection: some View {
        Section {
            // 一键两半：连得上的进「可连」，连不上的进「不通」，一次做完。
            // 拆成两个按钮会让人漏掉一半——而「一半应用了、一半没应用」正是分组最坏的状态：
            // 源既在错的分组里，又没人记得它本该去哪。
            // 两个组都已存在时，按钮说的是「归入」而不是「新建」：同一批订阅一天里测两次，
            // 想的是把新结果并进昨天那个组，不是再长出一层「可连 2」。
            Button {
                fileByResult()
            } label: {
                Label(L10n.text(answeredGroupExists && silentGroupExists
                                ? "File the Result into the Existing Groups"
                                : "New Groups from the Result (reachable / unreachable)"),
                      systemImage: "square.grid.2x2")
            }
            .disabled(buckets.up.isEmpty && buckets.down.isEmpty)

            // One menu, not two: "where do the answered ones go" and "where do the silent ones go"
            // are the same question, and answering it twice is how a batch ends up half-applied.
            if !store.sourceGroupBook.groups.isEmpty {
                Menu {
                    ForEach(store.sourceGroupBook.groups) { group in
                        // 同一页里说「Reachable / Unreachable」，菜单里就别再说「Answered / Silent」：
                        // 四个不同的词会让人以为这是四个不同的量。
                        Button(L10n.text("Reachable into %@", group.name)) { fileInto(buckets.up, groupID: group.id) }
                        Button(L10n.text("Unreachable into %@", group.name)) { fileInto(buckets.down, groupID: group.id) }
                    }
                } label: {
                    Label(L10n.text("Move a batch into an existing group"), systemImage: "arrow.right.square")
                }
                .disabled(buckets.up.isEmpty && buckets.down.isEmpty)
            }

            Button {
                createGroup()
            } label: {
                Label(L10n.text("New group"), systemImage: "plus.rectangle.on.folder")
            }

            if let note {
                Text(note).font(.caption).foregroundStyle(Brand.accent)
            }
        } header: {
            Text(L10n.text("Grouping"))
        } footer: {
            Text(L10n.text("A source with no reading is left where it is. Filing an unmeasured source is a guess, and a working source hidden in the wrong group is worse than one that is slow."))
        }
    }

    // MARK: - Routing

    private var routingSection: some View {
        Section {
            Button {
                let result = store.routeByReachability(targets)
                note = L10n.text("%lld to Direct, %lld to Proxy, %lld left unmeasured.",
                                 result.direct, result.relay, result.unknown)
                revision += 1
            } label: {
                Label(L10n.text("Reachable to Direct, Unreachable to Proxy"), systemImage: "arrow.triangle.branch")
            }
            .disabled(buckets.up.isEmpty && buckets.down.isEmpty)
            Text(L10n.text("A route changes the address a source API is fetched from. Media comes from whatever CDN the source hands back and is not rewritten, so a source whose API answers but whose segments are blocked still needs hiding."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(L10n.text("Routing"))
        }
    }

    private var footnote: some View {
        Section {
            Button(role: .destructive) {
                SourceProbeStore.shared.forgetEverything()
                note = nil
                revision += 1
            } label: {
                Label(L10n.text("Forget Every Reading"), systemImage: "trash")
            }
        }
    }

    // MARK: - Targets

    /// The three buckets, computed once per body pass.
    ///
    /// `answered` and `silent` each walk every source's reading, and the body's sections ask for them
    /// six times each: 350 sources times twelve walks per keystroke, on the main actor. The counts
    /// below are what the sections read instead.
    private var buckets: (up: [Site], down: [Site], unknown: [Site], all: [Site]) {
        let all = targets
        return (store.answered(all), store.silent(all), store.unmeasured(all), all)
    }

    /// The sources this scope covers: the ticked cards, one subscription, one group, or everything.
    private var targets: [Site] {
        switch scope {
        case .picked:
            return picked
        case .subscription:
            guard !pickedSubscription.isEmpty else { return [] }
            return store.sources(inSubscription: pickedSubscription)
        case .group:
            guard !pickedGroup.isEmpty else { return [] }
            return store.sources(inGroup: pickedGroup)
        case .all:
            guard let config = store.subscription else { return [] }
            return store.orderedSites(config)
        }
    }

    private var selectableGroups: [SourceGroup] {
        store.sourceGroups(includeHidden: false).filter { $0.kind != .hidden && !$0.sites.isEmpty }
    }

    /// What the sweep button says. Naming the scope beats "Measure" with a picker above it: the
    /// label is the last thing read before a press that can cost minutes of traffic.
    private var measureTitle: String {
        switch scope {
        case .all: return L10n.text("Measure Every Source")
        case .subscription: return L10n.text("Measure This Subscription")
        case .group: return L10n.text("Measure This Group")
        case .picked: return L10n.text("Measure the Picked Sources")
        }
    }

    private var summary: String {
        let all = targets
        guard !all.isEmpty else { return L10n.text("Nothing to measure here.") }
        let window = store.probeMaxAge
        guard window > 0 else { return L10n.text("%lld sources will be measured.", all.count) }
        let probes = SourceProbeStore.shared
        let fresh = all.filter { (probes.latest(sourceKey: $0.sourceKey)?.measuredAt.timeIntervalSinceNow ?? -1e9) > -window }
        if fresh.isEmpty { return L10n.text("%lld sources will be measured.", all.count) }
        return L10n.text("%lld to measure, %lld skipped as recent.", all.count - fresh.count, fresh.count)
    }

    // MARK: - Actions

    private func adoptFirstGroup() {
        if pickedGroup.isEmpty, let first = selectableGroups.first { pickedGroup = first.id }
        if pickedSubscription.isEmpty, let first = store.environmentSubscriptions.first(where: \.enabled) {
            pickedSubscription = first.address
        }
    }

    private func start() {
        let sites = targets
        guard !sites.isEmpty else { return }
        // Everything is the incremental sweep the page has always run; a smaller scope is the same
        // runner asked for these sources, so a subscription or a tick is measured by the same code.
        if scope == .all { store.startProbingAllSources() }
        else { store.startProbing(sites, skippingFresh: store.probeMaxAge) }
        revision += 1
    }

    /// Whether a group by each name already exists, so the button can say "file into" rather than
    /// "new group" — the reader is about to add to something rather than start something.
    private var answeredGroupExists: Bool {
        L10n.everyRendering(of: "Reachable").contains { store.sourceGroupBook.group(named: $0) != nil }
    }
    private var silentGroupExists: Bool {
        L10n.everyRendering(of: "Unreachable").contains { store.sourceGroupBook.group(named: $0) != nil }
    }

    /// Files the answered half and the silent half in one press, into two groups of those names.
    private func fileByResult() {
        // All four languages' names: switching the interface language between two sweeps must file
        // into the group the first sweep made, not beside it.
        let result = store.fileByReachability(targets,
                                              into: L10n.text("Reachable"),
                                              silentGroup: L10n.text("Unreachable"),
                                              alsoMatching: L10n.everyRendering(of: "Reachable"),
                                              silentAliases: L10n.everyRendering(of: "Unreachable"))
        note = result.unknown > 0
            ? L10n.text("Filed %lld answered and %lld silent; %lld have no reading yet.", result.answered, result.silent, result.unknown)
            : L10n.text("Filed %lld answered and %lld silent.", result.answered, result.silent)
        revision += 1
    }

    /// Files one half (answered or silent) into a group the viewer picks, creating it when missing.
    private func fileInto(_ sites: [Site], groupID: String) {
        guard !sites.isEmpty, let group = store.sourceGroupBook.group(groupID) else { return }
        let moved = store.fileSources(sites, intoGroup: group.id)
        note = L10n.text("%lld moved into %@.", moved, group.name)
        revision += 1
    }

    /// Numbered so two presses in a row make two groups rather than one silently reused.
    private func createGroup() {
        let existing = Set(store.sourceGroupBook.groups.map(\.name))
        var n = store.sourceGroupBook.groups.count + 1
        while existing.contains(L10n.text("Group %lld", n)) { n += 1 }
        guard let group = store.createSourceGroup(named: L10n.text("Group %lld", n)) else { return }
        pickedGroup = group.id
        scope = .group
        note = L10n.text("Created %@.", group.name)
        revision += 1
    }
}
