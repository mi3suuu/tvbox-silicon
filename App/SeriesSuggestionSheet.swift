import SwiftUI
import TVCore

/// The rows the end screen ranks, offered wherever a viewer might look for them —
/// the pause menu and the detail page — instead of only after the last episode.
///
/// The end screen can assume the viewer is done, so it auto-advances. Here they are
/// still watching, so nothing starts on its own: picking a row is the only way out.
struct SeriesSuggestionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Playing channel, when opened from the pause menu. Nil means the detail page,
    /// which passes a catalog directly.
    var channel: Channel?
    /// Title whose series to rank, for the detail-page case.
    var catalog: PlaybackCatalog?

    @State private var suggestions: [SeriesSuggestion] = []
    @State private var loading = true

    private var current: PlaybackCatalog? {
        if let catalog { return catalog }
        guard let channel else { return nil }
        return store.catalog(for: channel)
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if suggestions.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("No Other Seasons"), systemImage: "rectangle.stack")
                    } description: {
                        Text(L10n.text("This source has nothing else filed under this title."))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(suggestions) { suggestion in
                                Button { pick(suggestion) } label: { row(suggestion) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(L10n.text("More in This Series"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Close")) { dismiss() }
                }
            }
            .task { await load() }
            .settingsPage()
        }
    }

    private func row(_ suggestion: SeriesSuggestion) -> some View {
        HStack(spacing: 12) {
            PosterImage(url: suggestion.video.poster, headers: suggestion.video.posterHeaders)
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.video.name)
                    .font(Brand.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !suggestion.video.remarks.isEmpty {
                    Text(suggestion.video.remarks).font(Brand.meta).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(suggestion.sourceName).font(Brand.metaFixed).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title2)
        }
        .padding(10)
        .background(Brand.pageBackground, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Play %@", suggestion.video.name))
    }

    private func load() async {
        guard let catalog = current, let context = contextFor(catalog) else {
            loading = false
            return
        }
        suggestions = await store.seriesSuggestions(for: catalog, context: context)
        loading = false
    }

    private func contextFor(_ catalog: PlaybackCatalog) -> (sourceKey: String, sourceName: String, origin: URL)? {
        if let channel, let context = channel.historyContext {
            return (context.sourceKey, context.sourceName, context.origin)
        }
        // Detail page: the catalog's client carries the site it came from.
        return (catalog.client.site.sourceKey, catalog.client.site.name, catalog.client.origin)
    }

    private func pick(_ suggestion: SeriesSuggestion) {
        dismiss()
        store.playSuggestion(suggestion)
    }
}
