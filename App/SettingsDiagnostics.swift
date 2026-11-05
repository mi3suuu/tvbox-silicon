import SwiftUI
import TVCore

struct LicensesView: View {
    private var notices: String {
        (Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "DexLoom · MIT License"
    }
    var body: some View {
        #if os(tvOS)
        // Each paragraph is a row the remote can land on, which is how the page scrolls.
        SettingsPage(title: L10n.text("Open Source Licenses"), symbol: "doc.plaintext", subtitle: "Mi3s \(Brand.copyright)") {
            SettingsGroup {
                ForEach(Array(notices.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Button {} label: {
                        // The file is wrapped for a terminal; proportional text reads better reflowed.
                        Text(paragraph.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 24)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ParagraphStyle())
                }
            }
        }
        #else
        SettingsPage(title: L10n.text("Open Source Licenses")) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mi3s \(Brand.copyright)").font(.headline)
                    Link("www.getmegaportal.com", destination: Brand.website).font(.subheadline)
                }
            }
            Section {
                Text(notices)
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).selectable()
            }
        }
        #endif
    }
    #if os(tvOS)
    /// A glass row's focus, in a rounded rectangle: a capsule around a tall paragraph looked odd.
    private struct ParagraphStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }
        private struct Plate: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var focused
            var body: some View {
                configuration.label
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .glassSurface(focused ? .regular.tint(.white.opacity(0.12)) : .identity, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .animation(.easeOut(duration: 0.15), value: focused)
            }
        }
    }
    #endif
}

struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var level = "all"
    @State private var search = ""
    @State private var live = true
    @State private var dropped = 0
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var selected: LogEntry?
    private var filtered: [LogEntry] {
        entries.reversed().filter {
            (level == "all" || $0.level.rawValue == level) &&
            (search.isEmpty || "\($0.category) \($0.message)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { heading; Spacer(minLength: 24); actions }
                VStack(alignment: .leading, spacing: 16) { heading; actions }
            }
            VStack(spacing: 0) {
                filters.padding(16)
                Divider()
                logList
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: live ? "circle.fill" : "pause.circle.fill").font(.system(size: live ? 6 : 11)).foregroundStyle(live ? Brand.accent : .secondary)
                    Text(L10n.text(live ? "Newest first · Updates every 2 seconds" : "Updates paused"))
                    Spacer()
                    Text("\(filtered.count) / \(entries.count)").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, DiagnosticGrid.inset).padding(.vertical, 12)
            }
            .background(SettingsStyle.groupFill, in: RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            Text(L10n.text("Shows the latest 1,000 events from this run. Export includes retained log files."))
                .font(.caption).foregroundStyle(.secondary)
            if dropped > 0 {
                Label(L10n.text("Log overload: %lld events dropped", dropped), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.amber)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Brand.rose).selectable() }
        }
        .padding(Layout.gutter)
        .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackdrop()
        .screenTitle(L10n.text("Diagnostic Logs"))
        .sheet(item: $selected) { entry in DiagnosticDetail(entry: entry) }
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                if live { await refresh() }
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if !os(tvOS)
            Text(L10n.text("Runtime Activity")).font(.title2.weight(.bold))
            #endif
            Text(L10n.text("Inspect plugin requests and errors.")).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }.controlSize(.regular)
    }
    @ViewBuilder private var actionButtons: some View {
            Button { live.toggle() } label: {
                Label(L10n.text(live ? "Pause Logs" : "Resume Logs"), systemImage: live ? "pause.fill" : "play.fill")
            }.controlButton()
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }.controlButton().accessibilityLabel(L10n.text("Refresh Logs")).help(L10n.text("Refresh Logs"))
            Menu {
                Button { export() } label: { Label(L10n.text("Export Logs"), systemImage: "square.and.arrow.up") }.disabled(exporting)
                #if os(macOS)
                Button { NSWorkspace.shared.open(Diagnostics.shared.directory) } label: {
                    Label(L10n.text("Open Log Folder"), systemImage: "folder")
                }
                #endif
                #if !os(tvOS)
                if let exportURL { ShareLink(item: exportURL) { Label(L10n.text("Share Logs"), systemImage: "square.and.arrow.up") } }
                #endif
            } label: {
                Label(L10n.text(exporting ? "Exporting Logs…" : "Log Files"), systemImage: "doc.text")
            }.controlButton()
    }
    private var filters: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Search Logs"), text: $search).textFieldStyle(.plain).autocorrectionDisabled()
                if !search.isEmpty {
                    let clear = Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(L10n.text("Clear Search"))
                    #if os(tvOS)
                    clear.glassPill()
                    #else
                    clear.buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            ChipRow {
                HStack(spacing: 6) {
                    levelButton("all", title: L10n.text("All Logs"), count: entries.count, color: Brand.accent)
                    ForEach(LogLevel.allCases, id: \.rawValue) { item in
                        levelButton(item.rawValue, title: item.title, count: entries.filter { $0.level == item }.count, color: item.tint)
                    }
                }
            }
        }
    }
    @ViewBuilder private func levelButton(_ value: String, title: String, count: Int, color: Color) -> some View {
        #if os(tvOS)
        // The glass chips of every other filter on the TV, with the level's dot and its count.
        Chip(title: "\(title) \(count)", selected: level == value, dot: value == "all" ? nil : color) { level = value }
        #else
        Button { level = value } label: {
            HStack(spacing: 7) {
                if value != "all" { Circle().fill(color).frame(width: 5, height: 5) }
                Text(title).fontWeight(.semibold)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 26, alignment: .trailing)
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            .background(level == value ? color.opacity(0.14) : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(level == value ? color.opacity(0.35) : .clear, lineWidth: 1) }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(level == value ? .isSelected : [])
        #endif
    }
    private var logList: some View {
        let visible = filtered
        return GeometryReader { geometry in
            #if os(tvOS)
            let compact = true
            #else
            let compact = geometry.size.width < DiagnosticGrid.compactWidth
            #endif
            VStack(spacing: 0) {
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                        Text(L10n.text("Log Time")).frame(width: DiagnosticGrid.time, alignment: .leading)
                        Text(L10n.text("Log Level")).frame(width: DiagnosticGrid.level, alignment: .leading)
                        Text(L10n.text("Log Module")).frame(width: DiagnosticGrid.module, alignment: .leading)
                        Text(L10n.text("Log Message")).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: DiagnosticGrid.accessory, height: 1)
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, DiagnosticGrid.inset).frame(height: 36)
                    .background(Color.primary.opacity(0.025))
                    Divider()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            Button { selected = entry } label: { DiagnosticRow(entry: entry, compact: compact).foregroundStyle(.primary) }
                                .glassRow()
                            Divider().padding(.horizontal, DiagnosticGrid.inset)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.text("No Logs"), systemImage: "waveform.path")
                        } description: {
                            Text(L10n.text(search.isEmpty && level == "all" ? "Plugin activity will appear here." : "Try another level or search term."))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func export() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportURL = try await Diagnostics.shared.export()
                #if os(macOS)
                if let exportURL { NSWorkspace.shared.activateFileViewerSelecting([exportURL]) }
                #endif
            } catch { self.error = error.localizedDescription }
        }
    }
    private func refresh() async {
        let snapshot = await Diagnostics.shared.snapshot()
        if entries.last?.id != snapshot.entries.last?.id { entries = snapshot.entries }
        dropped = snapshot.dropped
        error = snapshot.fileError
    }
}

private extension LogLevel {
    var tint: Color {
        switch self {
        case .debug: .secondary
        case .info: Brand.accent
        case .warning: Brand.amber
        case .error: Brand.rose
        }
    }
    var title: String {
        switch self {
        case .debug: L10n.text("Debug Logs")
        case .info: L10n.text("Info Logs")
        case .warning: L10n.text("Warning Logs")
        case .error: L10n.text("Error Logs")
        }
    }
}

// One grid for the header and every row. Content never selects its own layout.
private enum DiagnosticGrid {
    static let inset: CGFloat = 16
    static let gap: CGFloat = 12
    static let time: CGFloat = 76
    static let level: CGFloat = 76
    static let module: CGFloat = 112
    static let accessory: CGFloat = 12
    static let compactWidth: CGFloat = 620
}

private struct DiagnosticRow: View {
    let entry: LogEntry
    let compact: Bool
    @State private var hovering = false
    var body: some View {
        Group {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    Text(entry.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                    Text(entry.level.rawValue.uppercased()).foregroundStyle(entry.level.tint)
                    Text(entry.category)
                }.font(.caption).foregroundStyle(.secondary)
                Text(entry.message).font(.body).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(.vertical, 18)
            #else
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                        timestamp.frame(width: DiagnosticGrid.time, alignment: .leading)
                        badge.frame(width: DiagnosticGrid.level, alignment: .leading)
                        module
                        Spacer(minLength: 0)
                    }
                    message.lineLimit(2, reservesSpace: true)
                }
                .padding(.vertical, 12)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                    timestamp.frame(width: DiagnosticGrid.time, alignment: .leading)
                    badge.frame(width: DiagnosticGrid.level, alignment: .leading)
                    module.frame(width: DiagnosticGrid.module, alignment: .leading)
                    message.lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(width: DiagnosticGrid.accessory)
                }
                .frame(height: 44)
            }
            #endif
        }
        .padding(.horizontal, DiagnosticGrid.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        #if !os(tvOS)
        .onHover { hovering = $0 }
        #endif
    }
    private var timestamp: some View {
        Text(entry.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .lineLimit(1)
    }
    private var badge: some View {
        Text(entry.level.rawValue.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(entry.level.tint).frame(width: 60, height: 20)
            .background(entry.level.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
    private var module: some View {
        Text(entry.category).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
    }
    private var message: some View {
        let preview = entry.message.split(whereSeparator: \.isWhitespace).filter {
            !$0.hasPrefix("session=") && !$0.hasPrefix("request=") && !$0.hasPrefix("command=")
        }.joined(separator: " ")
        return Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.88))
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticDetail: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Pill(text: entry.level.title, tint: entry.level.tint)
                Text(entry.category).font(.headline)
                Spacer()
                Button(L10n.text("OK")) { dismiss() }.controlButton()
            }
            Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(entry.message).font(.system(.body, design: .monospaced)).selectable()
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.contentPanel(cornerRadius: 14)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 720, minHeight: 360, idealHeight: 480)
        #elseif os(tvOS)
        .frame(width: 1100, height: 700)
        #endif
        .screenBackdrop()
    }
}
