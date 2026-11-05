import SwiftUI
import TVCore

// Loading, empty and error states.

struct EmptyPage<Footer: View>: View {
    let symbol: String
    let title: String
    let message: String
    let action: String
    let actionSymbol: String
    let perform: () -> Void
    @ViewBuilder var footer: Footer
    #if os(tvOS)
    private let icon: CGFloat = 132, titleSize: CGFloat = 46, text: CGFloat = 28, spacing: CGFloat = 30, width: CGFloat = 960
    #else
    private let icon: CGFloat = 84, titleSize: CGFloat = 24, text: CGFloat = 15, spacing: CGFloat = 18, width: CGFloat = 420
    #endif
    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: symbol)
                .font(.system(size: icon * 0.42, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(width: icon, height: icon)
                .background(Brand.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: spacing * 0.4) {
                Text(title).font(.system(size: titleSize, weight: .bold))
                Text(message)
                    .font(.system(size: text)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: width)
            Button(action: perform) { Label(action, systemImage: actionSymbol).padding(.horizontal, 8) }
                .controlButton(prominent: true).controlSize(.large)
            footer.font(.system(size: text * 0.8)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyPage where Footer == EmptyView {
    init(symbol: String, title: String, message: String, action: String, actionSymbol: String, perform: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, message: message, action: action, actionSymbol: actionSymbol, perform: perform) { EmptyView() }
    }
}

struct EmptyResults: View {
    let symbol: String
    let title: String
    var message: String?
    var action: String?
    var actionSymbol = "arrow.clockwise"
    var perform: (() -> Void)?
    #if os(tvOS)
    private let icon: CGFloat = 60, titleSize: CGFloat = 38, text: CGFloat = 26, spacing: CGFloat = 22, width: CGFloat = 900, inset: CGFloat = 60
    #else
    private let icon: CGFloat = 36, titleSize: CGFloat = 20, text: CGFloat = 15, spacing: CGFloat = 12, width: CGFloat = 420, inset: CGFloat = 48
    #endif
    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: symbol).font(.system(size: icon, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: spacing * 0.4) {
                Text(title).font(.system(size: titleSize, weight: .semibold))
                if let message {
                    Text(message).font(.system(size: text)).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center).frame(maxWidth: width)
            if let action, let perform {
                Button(action: perform) { Label(action, systemImage: actionSymbol).padding(.horizontal, 8) }
                    .controlButton().padding(.top, spacing * 0.4)
            }
        }
        .padding(.vertical, inset).padding(.horizontal, Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvFocusSection()
        .accessibilityElement(children: .contain)
    }
}

struct LoadingProgress {
    var title: String
    var detail: String? = nil
    var fraction: Double? = nil
    var reason: String? = nil
    var steps: [String] = []
}

extension LoadingProgress {
    static func source(_ site: Site, origin: URL, title: String) -> LoadingProgress {
        if site.runtime == .jar {
            guard let state = PluginPreparation.snapshot(site: site, origin: origin) else { return LoadingProgress(title: title) }
            return LoadingProgress(title: state.stage == .loading ? title : state.stage.title,
                                   detail: state.detail, fraction: state.fraction, reason: state.reason)
        }
        return server(URL(string: site.api)?.host(), title: title)
    }

    static func server(_ host: String?, title: String) -> LoadingProgress {
        guard let host, !host.isEmpty else { return LoadingProgress(title: title) }
        return LoadingProgress(title: title, detail: L10n.text("Waiting for %@", host),
                               reason: L10n.text("%@ is responding slowly. The server may be busy or far away; you can keep waiting or try another source.", host))
    }
}

struct ElapsedTime: View {
    @State private var started = Date()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(Duration.seconds(max(0, Int(timeline.date.timeIntervalSince(started)))).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct LoadingCard: View {
    static let quiet: TimeInterval = 1.5
    static let patience: TimeInterval = 10
    static let compact: CGFloat = 620
    var appearAfter: TimeInterval = 0
    var maxWidth: CGFloat = .infinity
    let progress: () -> LoadingProgress
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(started))
            let speaks = elapsed >= appearAfter + Self.quiet
            Group {
                if speaks {
                    card(progress(), elapsed: Int(elapsed)).transition(.opacity)
                } else if elapsed >= appearAfter {
                    ProgressView().frame(maxWidth: maxWidth).padding(.vertical, 14).transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: speaks)
        }
    }

    private func card(_ state: LoadingProgress, elapsed: Int) -> some View {
        let explains = Double(elapsed) >= Self.patience && state.reason != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let detail = state.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    ForEach(Array(state.steps.suffix(2).enumerated()), id: \.offset) { _, step in
                        Text(step).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let fraction = state.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Brand.accent)
            }
            if explains, let reason = state.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .animation(.smooth(duration: 0.25), value: state.title)
        .animation(.smooth(duration: 0.25), value: explains)
    }
}

struct ErrorStateCard: View {
    let title: String
    let message: String
    let details: String
    var retry: (() -> Void)?
    var goBack: (() -> Void)?
    var busy = false
    var backTitle = L10n.text("Back to sources")
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Brand.accent)
                .frame(width: 76, height: 76)
                .background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 25))
                .overlay { RoundedRectangle(cornerRadius: 25).strokeBorder(Brand.accent.opacity(0.18)) }
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                Text(message).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(spacing: 12) { actions }
            }
            .controlSize(.large)
            VStack(spacing: 14) {
                Divider().overlay(Color.primary.opacity(0.04))
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.text(showsDetails ? "Hide details" : "Show details"))
                        Image(systemName: showsDetails ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                #if os(tvOS)
                .controlButton()
                #else
                .buttonStyle(.plain)
                #endif
                if showsDetails {
                    ScrollView {
                        Text(details).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).selectable().padding(14)
                    }
                    .frame(height: detailsHeight)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(28)
        .frame(maxWidth: recoveryWidth)
        .contentPanel(cornerRadius: 28)
        .frame(maxWidth: .infinity)
        .onChange(of: details) { showsDetails = false }
    }

    private var recoveryWidth: CGFloat {
        #if os(tvOS)
        900
        #else
        560
        #endif
    }
    private var detailsHeight: CGFloat {
        #if os(tvOS)
        240
        #else
        180
        #endif
    }

    @ViewBuilder private var actions: some View {
        if let retry {
            Button(action: retry) {
                Label(L10n.text("Retry"), systemImage: "arrow.clockwise").padding(.horizontal, 12)
            }
            .controlButton(prominent: true).tint(Brand.accent).disabled(busy)
        }
        if let goBack {
            Button(action: goBack) { Text(backTitle).padding(.horizontal, 8) }
                .controlButton().tint(.secondary)
        }
    }
}
