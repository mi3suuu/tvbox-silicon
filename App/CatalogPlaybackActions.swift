#if !os(tvOS)
import SwiftUI
import TVCore

/// Catalog-only actions alongside the existing native transport controls.
///
/// This menu does not present the episode sheet itself. It asks its host to, via
/// `openEpisodes`, because the sheet's presentation depends on which of the
/// iPhone Duo's three player shapes is on screen — a sheet over a full-screen
/// player, a panel inside the picture at the top of a watch page. That decision
/// belongs to `PlayerSurface` in the player, not to this menu, and having the
/// menu present its own sheet as well meant two different episode experiences
/// depending on where the viewer tapped.
struct CatalogPlaybackActions: View {
    let channel: Channel
    let session: PlaybackSession
    /// Ask the player to open its episode sheet or panel.
    var openEpisodes: () -> Void = {}
    @Environment(Store.self) private var store
    @State private var showsSkip = false
    @State private var showsDanmaku = false
    @State private var showsSeries = false

    var body: some View {
        if channel.historyContext != nil {
            Menu {
                if store.catalog(for: channel) != nil {
                    Toggle(L10n.text("Auto-play next episode"), isOn: Binding(
                        get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 }))
                    // One tap into the episode sheet: lines, their health and the
                    // whole grid, instead of a two-level menu.
                    Button(action: openEpisodes) {
                        Label(L10n.text("Episodes"), systemImage: "list.bullet.rectangle")
                    }
                    .disabled(store.resolvingEpisode != nil)
                    .accessibilityIdentifier("player.episodes")
                    // Same rows the end screen ranks, offered mid-episode: a viewer who
                    // pauses to look for the next season should not have to finish first.
                    Button { showsSeries = true } label: {
                        Label(L10n.text("More in This Series"), systemImage: "rectangle.stack")
                    }
                    .accessibilityIdentifier("player.series")
                }
                Toggle(L10n.text("Automatically skip intro and outro"), isOn: Binding(
                    get: { session.skipSettings.enabled },
                    set: { value in
                        var settings = session.skipSettings
                        settings.enabled = value
                        session.applySkipSettings(settings)
                    }))
                Button(L10n.text("Skip intro / outro")) { showsSkip = true }
                    .accessibilityIdentifier("player.skip")
                if channel.historyContext?.sourceKey != Bilibili.siteKey {
                    Button(L10n.text("Danmaku")) { showsDanmaku = true }
                        .accessibilityIdentifier("player.danmaku")
                }
                if let error = store.episodeError { Text(error) }
            } label: {
                #if os(macOS)
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34).contentShape(Circle())
                #else
                Image(systemName: "ellipsis.circle").font(.headline).frame(width: 22, height: 22)
                #endif
            }
            #if os(macOS)
            // The same 34 pt glass circle as the window's other buttons; a bordered menu drew a wider capsule, and a
            // borderless one drew its icon at the leading edge of the circle instead of the centre.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .glassSurface(.regular.interactive(), in: Circle())
            .help(L10n.text("Episodes"))
            #else
            .chromeButton()
            #endif
            .accessibilityLabel(L10n.text("Playback Options"))
            .accessibilityIdentifier("player.catalogOptions")
            .sheet(isPresented: $showsSeries) {
                SeriesSuggestionSheet(channel: channel)
            }
            .sheet(isPresented: $showsSkip) { EpisodeSkipSettingsView(session: session) }
            .sheet(isPresented: $showsDanmaku) {
                CatalogDanmakuSettingsView(model: session.catalogDanmaku, channelName: channel.name)
            }
        }
    }
}
#endif

#if !os(tvOS)
// MARK: - [mi3s] 二开融合：上游 playerSheet 保留
//
// 上游 1.8.11 在 CatalogPlaybackActions.swift 里定义了 `View.playerSheet()`（播放器上的设置 sheet 用深色，
// 治 #533 浅色模式下白底白字）。我方重写了本文件、把 sheet 呈现交给播放器宿主，但上游 PlayerEpisodes
// 仍在调用它，所以这里原样保留。

extension View {
    /// A settings sheet over the player, dark like the player. A player at the top of a page makes only its own views
    /// dark (`PlayerScheme`); before iOS 26 a sheet it opens inherits that for its text but keeps the phone's light
    /// background, so on a phone in light mode the sheet showed white text on a white form (#533).
    /// The Mac's sheets keep the window's appearance, as before.
    @ViewBuilder func playerSheet() -> some View {
        #if os(iOS)
        preferredColorScheme(.dark)
        #else
        self
        #endif
    }
}
#endif
