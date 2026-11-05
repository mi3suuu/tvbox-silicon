import SwiftUI
import TVCore

struct VideoDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// Opened from Continue Watching: on an iPhone the page resumes it at once.
    var resume: PlaybackHistoryEntry? = nil
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var fullScreen = false
    /// Full Screen came from turning the phone sideways, so turning it upright again returns to the page.
    @State private var turnedFullScreen = false
    @State private var showsAllEpisodes = false
    @State private var episodeScroll: Episode.ID?
    /// The Duo unfolded and the page is landing sideways: held from the moment it opens until the interface
    /// has actually turned. `interfaceOrientation` only changes once the geometry request is honoured, so
    /// without this the page draws a frame or two of the upright full-bleed layout — the picture filling a
    /// tall screen with the details in a sheet — before snapping into the two-column landscape.
    @State private var unfoldingToLandscape = false
    /// The page's player shows its picture (or an error); until then the page's cover stays over it.
    @State private var playerStarted = false
    /// Back on the cover while it starts: shown for a moment by a tap, as the player's controls are.
    @State private var coverBack = false
    /// The page's player, whose wait the cover tells about.
    @State private var playerSession: PlaybackSession?
    /// The source's config center, open in the app (`ConfigCenterView`).
    @State private var showsConfigCenter = false
    #endif
    @State private var requestTask: Task<Void, Never>?
    @State private var detail: Video?
    /// Short labels (第1集) for lines whose episode names are file names, by episode id (#318). Display only.
    @State private var episodeLabels: [Episode.ID: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var pendingPlan: PlaybackPlan?
    @State private var pendingEpisode: Episode?
    @State private var choosingQuality = false
    @State private var synopsisExpanded = false
    @State private var selectedFlag: String?
    /// 倒序: the episode lists show the last episode first. A per-page preference, so flipping one
    /// video's list around never flips every other video's.
    @State private var reversesEpisodes = false
    /// Play takes over focus from the loading placeholder; otherwise nothing is focused once details load.
    @FocusState private var playFocused: Bool
    @State private var containerWidth: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    /// The picture's own width-over-height, reported by the player once the stream is known.
    /// 16:9 until then, which is what most sources serve and therefore the least surprising guess.
    @State private var playerAspectRatio: CGFloat = 16.0 / 9.0
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @State private var artAspect: CGFloat?
    /// TMDB's backdrop once its picture has loaded. The source's cover stays until then, and when it never does
    /// (image.tmdb.org is blocked on some networks, #237).
    @State private var loadedBackdrop: URL?
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    @State private var signingIn: CloudDrive?
    /// A sign-in the source's CatPawOpen bundle runs itself (UC's TV token).
    @State private var bundleSignIn: BundleSignIn?
    @State private var choosingDownloads = false
    /// How many episodes were just queued, shown briefly under the header.
    @State private var queuedNotice: Int?
    /// A line has no episode to continue the one playing: shown briefly under the header.
    @State private var lineNotice: String?
    /// TMDB's details for the video (TMDBViews.swift). The page shows the source's own until they are in, then fades them in.
    @State private var tmdb = TMDBLookup()
    /// The source's own recommendations, shown under the video when TMDB has none for it. Loaded lazily, once TMDB
    /// has answered, so the related list fills the space below the episodes instead of leaving it blank.
    @State private var siteRelated: [Recommendation] = []
    private var flags: [String] {
        var seen = Set<String>()
        return (detail?.episodes ?? []).map(\.flag).filter { seen.insert($0).inserted }
    }
    private var activeFlag: String { flags.contains(selectedFlag ?? "\u{0}") ? selectedFlag! : (flags.first ?? "") }
    /// The active line's episodes. `activeFlag` goes through every episode, so it is read once, not once per episode:
    /// in the filter it made each page update quadratic (4 lines of 1,000 episodes took seconds, and iOS killed the app).
    private var activeEpisodes: [Episode] {
        let flag = activeFlag
        return (detail?.episodes ?? []).filter { $0.flag == flag }
    }
    private var wideMinWidth: CGFloat {
        #if os(tvOS)
        1200
        #else
        760
        #endif
    }
    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        let previous = requestTask
        previous?.cancel()
        requestTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if watchLayout { watchBody } else { pageBody }
            #else
            pageBody
            #endif
        }
        .safeAreaInset(edge: .bottom) { if !isWatchPage { loadingCard } }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Only commit a change that matters: the split column's width feeds back into the layout,
            // and committing every sub-point drift re-renders the page, which drifts again — the page
            // appeared to shrink for ever.
            if abs(size.width - containerWidth) > 0.5 { containerWidth = size.width }
            // The height is always read: it sizes the picture box on every shape (half the screen on
            // the upright unfolded Duo, the whole column when split), so a fold that only changed the
            // height — the inner display is 2853pt tall, the outer cover 2034 — must not keep the
            // previous shape's number. That stale height is what pushed the picture, and the whole
            // page, off the screen after folding back.
            if abs(size.height - containerHeight) > 0.5 { containerHeight = size.height }
            #if DEBUG && os(iOS)
            if UserDefaults.standard.bool(forKey: "qaLogGeometry") {
                let sb = UIApplication.shared.appWindowScene?.screen.bounds.size ?? .zero
                NSLog("GEO w=%.0f h=%.0f hSize=%@ vSize=%@ duo=%@ land=%@ port=%@ scrW=%.0f scrH=%.0f", size.width, size.height,
                      String(describing: sizeClass), String(describing: verticalSizeClass), String(describing: duoExpanded),
                      String(describing: landscapeScreen), String(describing: portraitExpanded), sb.width, sb.height)
            }
            #endif
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DetailAurora(poster: video.poster, headers: video.posterHeaders) }
        #else
        .screenBackdrop()
        #endif
        .screenTitle(video.name).task {
            store.searchModel.suspend()
            // A Continue Watching card, or a favorite, can still be on screen when the vault relocks
            // (timeout, a screenshot, the app going to the background). The page must not then reveal a
            // hidden source's title, cover, or episode list, nor resume it. The resume path's own choke
            // point (`resumeHistory`) refuses playback, but this page would still draw the details.
            let blocked = if let resume {
                !store.vault.permitsPlayback(sourceKey: resume.context.sourceKey, origin: resume.context.origin)
            } else {
                !store.vault.permits(site: client.site, fallback: client.origin)
            }
            if blocked {
                store.error = L10n.text("This title is hidden. Unlock the Privacy Vault to watch it.")
                dismiss()
                return
            }
            #if os(iOS)
            // From Continue Watching the watch page resumes at once, resolving its own details.
            let continues = watchLayout && watchChannel == nil && store.resumingHistoryID == nil
            if continues, let resume { store.resume(resume) }
            #endif
            if detail == nil { await loadDetail() }
            #if os(iOS)
            // A video of one episode then plays by itself, from where the viewer stopped if watched before. One of
            // several waits on its cover for the viewer to choose the line and episode (#260).
            if continues, resume == nil, watchChannel == nil, store.resumingHistoryID == nil, activeEpisodes.count <= 1 {
                playWatchCover()
            }
            // Opened on a video of several episodes with nothing watched before: the viewer's next step is
            // picking one, so the episode list comes up rather than a cover with a Play button that only leads
            // to the same list. A video watched before skips this — its continuation is the point of opening it.
            // On the Duo's unfolded landscape the episode grid already lives in the right column beside the
            // picture, so the auto-pop sheet would only cover it — skip the pop there.
            if opensIntoEpisodes, store.resumingHistoryID == nil, watchChannel == nil,
               !(duoExpanded && sideways), !portraitExpanded {
                showsAllEpisodes = true
            }
            #endif
            #if DEBUG
            // `-qaDownloadPicker 1` opens the episode picker, for screenshots.
            if UserDefaults.standard.bool(forKey: "qaDownloadPicker") { choosingDownloads = true }
            #endif
        }
        .onDisappear {
            requestTask?.cancel()
            #if os(iOS)
            // The page itself is gone (not just folded/unfolded): leave Full Screen. The video keeps playing,
            // so the floating mini player (RootView) takes over and the viewer can still get back to it.
            // On a fold this view stays alive, so playback carries on into the other layout.
            if fullScreen { fullScreen = false; PlayerOrientation.set(landscape: false) }
            #endif
        }
        .task(id: detail?.id) {
            // The source's related titles load beside TMDB's lookup, not after it: a title TMDB doesn't know
            // (or a Worker that is slow) would otherwise leave the space under the video empty until the
            // lookup timed out. The related list shows the source's own titles while TMDB is still thinking,
            // and TMDB's recommendations replace them once they arrive.
            async let tmdbLookup: Void = startTMDB()
            async let related: Void = loadRelatedFallback()
            _ = await (tmdbLookup, related)
        }
        .onChange(of: choosingQuality) { _, open in if !open && !busy { loadingEpisode = nil } }
        #if os(iOS)
        .sheet(isPresented: $showsConfigCenter) { ConfigCenterView { await configCenterAddress() } }
        #endif
        // Sign in where playback failed, then resume the episode that needed the account.
        #if !os(tvOS)
        .sheet(item: $bundleSignIn) { pending in
            CatPawSignInView(client: client, provider: pending.provider) {
                if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
            }
        }
        #endif
        #if os(macOS)
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei {
                XunleiSignInView { if let episode = playbackIssue?.episode { startRequest { await play(episode) } } }
            } else if drive == .baidu {
                // Baidu signs in with a code to scan on a Mac, as in Settings.
                CloudQRLoginView(drive: .baidu) { retryAfterSignIn() }
            } else {
                CloudLoginView(provider: drive.provider) { cookie, ticket in
                    try await drive.provider.saveLogin(cookie, ticket: ticket)
                    if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
                }
            }
        }
        #elseif os(iOS)
        // The drive's own sign-in page; the code is for signing in with another phone.
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else {
                WebSignInView(service: drive.webSignIn, signedIn: retryAfterSignIn) {
                    CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() }
                }
            }
        }
        #else
        .fullScreenCover(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else { CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() } }
        }
        #endif
        .downloadPicker(isPresented: $choosingDownloads) {
            DownloadPicker(video: video, site: client.site, flag: activeFlag,
                           episodes: activeEpisodes, origin: client.origin) { count in
                guard count > 0 else { return }
                withAnimation(.smooth(duration: 0.2)) { queuedNotice = count }
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation(.smooth(duration: 0.2)) { queuedNotice = nil } }
            }
        }
        .confirmationDialog(L10n.text("Choose quality"), isPresented: $choosingQuality, titleVisibility: .visible) {
            if let plan = pendingPlan, let episode = pendingEpisode {
                ForEach(plan.choices) { choice in
                    Button(choice.name) { startRequest { await resolve(plan, choice: choice, episode: episode) } }
                }
            }
        }
    }

    /// One page on Mac, iPad and Apple TV: the banner, the synopsis, the episodes, then TMDB's cast and facts. An episode
    /// rail beside the banner (once used for long lists, and always on Apple TV) squeezed the banner into a card.
    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if detail != nil {
                    episodePanel
                    tmdbExtras
                } else if let error {
                    errorCard(error).padding(.top, 12)
                } else {
                    // The Play placeholder in the header holds focus while details load.
                    DetailSkeleton()
                }
            }
            .pageContainer()
        }
    }

    private var isWatchPage: Bool {
        #if os(iOS)
        watchLayout
        #else
        false
        #endif
    }

    @ViewBuilder private var loadingCard: some View {
        if busy {
            // Keyed by the step, so the timer restarts when details turn into resolving a link.
            LoadingCard { .source(client.site, origin: client.origin, title: busyTitle) }
                .id(busyTitle)
                .frame(maxWidth: .infinity).padding(.horizontal, Layout.gutter).padding(.bottom, 24)
        }
    }
    @ViewBuilder private var playbackBanner: some View {
        if let count = queuedNotice {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent)
                Text(count == 1 ? L10n.text("1 episode added to Downloads.") : L10n.text("%lld episodes added to Downloads.", count)).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button(L10n.text("Show Downloads")) { store.section = .downloads }.settingsButton()
            }
            .padding(Spacing.panel)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let notice = lineNotice {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill").foregroundStyle(Brand.accent)
                Text(notice).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
            }
            .padding(Spacing.panel)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let issue = playbackIssue {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: issue.drive != nil || issue.signIn != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.amber)
                    .frame(width: 36, height: 36)
                    .background(Brand.amber.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Couldn't play %@", EpisodeRow.title(issue.episode.name)))
                            .font(.headline).lineLimit(2)
                        Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).selectable()
                    }
                    HStack(spacing: 8) {
                        if let drive = issue.drive {
                            Button(drive.signInTitle) { signingIn = drive }.settingsButton(prominent: true)
                        }
                        #if !os(tvOS)
                        if let provider = issue.signIn {
                            Button(L10n.text("Get UC TV Token")) { bundleSignIn = BundleSignIn(provider: provider) }
                                .settingsButton(prominent: true)
                                .accessibilityIdentifier("playbackIssue.bundleSignIn")
                        }
                        #endif
                        Button(L10n.text(issue.blockedBeforeRequest ? "Try Anyway" : "Retry")) {
                            startRequest { await play(issue.episode, skipAccountCheck: true) }
                        }
                        .settingsButton(prominent: issue.drive == nil && issue.signIn == nil)
                        #if os(tvOS)
                        // A focusable action instead of the small corner close button.
                        Button(L10n.text("Dismiss")) { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } }.settingsButton()
                        #endif
                    }
                }
                Spacer(minLength: 0)
                #if !os(tvOS)
                Button { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss")).help(L10n.text("Dismiss"))
                #endif
            }
            .padding(Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    private func errorCard(_ error: String) -> some View {
                    ErrorStateCard(
                        title: detail == nil ? L10n.text("Unable to load video details") : L10n.text("Unable to start playback"),
                        message: detail == nil
                            ? L10n.text("Try again, or go back and choose another video.")
                            : L10n.text("Try another episode or playback source."),
                        details: error,
                        retry: detail == nil ? { startRequest { await loadDetail() } } : nil,
                        goBack: { dismiss() },
                        busy: busy,
                        backTitle: L10n.text("Go back")
                    )
    }
    private var busyTitle: String {
        if detail == nil { return L10n.text("Loading video details…") }
        let episode = detail?.episodes.first { $0.id == loadingEpisode }
        return episode.map { L10n.text("Getting the video link for %@…", EpisodeRow.title($0.name)) } ?? L10n.text("Getting the video link…")
    }
    private func loadDetail() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await client.detail(video.id, cached: client.site.type == 3 || client.site.type == 4)
            try Task.checkCancellation()
            // Worked out once, off the main thread: a line can hold thousands of episodes.
            let episodes = value.episodes
            episodeLabels = await Task.detached(priority: .userInitiated) { EpisodeLabels.labels(episodes) }.value
            detail = value
            // Start on the line watched last (#362), else on one that can play: not one from a drive the viewer has no
            // way to sign in to.
            if selectedFlag == nil { selectedFlag = watchedFlag ?? CloudDrive.preferredFlag(flags) }
            #if os(tvOS)
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "detail \(client.reportContext)", error)
            self.error = error.localizedDescription
            #if os(tvOS)
            // The loading placeholder that held focus is gone: Retry in the hero takes it.
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        }
    }
    /// What this device knows shows at once; otherwise the lookup starts once the source's details are in (their
    /// synopsis and episodes help tell works of the same name apart).
    private func startTMDB() async {
        guard TMDBLookup.applies(to: client.site) else { return }
        let key = TMDBMatchStore.key(source: client.site.key, video: video.id)
        guard let detail else { _ = await tmdb.prepare(key: key); return }
        let request = TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video,
                                        source: TMDBMatch.SourceRef(key: client.site.key, name: client.site.name))
        // AI-generated videos and short dramas aren't on TMDB: the page keeps the source's own data.
        guard !TMDBMatch.labeledNotOnTMDB(request) else { tmdb.skip(); return }
        await tmdb.run(key: key, request: request)
    }
    /// The source's own related titles, shown when TMDB has no recommendations for the video. Loaded once per page;
    /// `relatedSection` only uses them while TMDB's recommendations are empty, so a matched title never shows both.
    private func loadRelatedFallback() async {
        guard siteRelated.isEmpty else { return }
        if let recs = try? await client.recommendations() {
            guard !Task.isCancelled else { return }
            siteRelated = recs
        }
        #if DEBUG && os(iOS)
        NSLog("RELATED-FALLBACK count=%d", siteRelated.count)
        #endif
    }
    /// A video without episodes. A config center entry (a CatPawOpen bundle's, #311, or a Wex plugin's, #360) opens its page in the app.
    @ViewBuilder private func noEpisodes(_ detail: Video) -> some View {
        #if os(iOS)
        if ConfigCenter.page(of: detail, site: client.site) != nil {
            Button { showsConfigCenter = true } label: { Label(L10n.text("Open Config Center"), systemImage: "gearshape") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.configCenter")
        } else {
            Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        }
        #else
        Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        #endif
    }
    #if os(iOS)
    /// The config center's address now. Asking the bundle again gives its current port, which changes when iOS took
    /// back its socket while the app was suspended; the page's details can be older than that, or cached.
    private func configCenterAddress() async -> URL? {
        let fresh = try? await client.detail(video.id)
        return (fresh ?? detail).flatMap { ConfigCenter.page(of: $0, site: client.site) }
    }
    #endif
    /// TMDB's story when it has one, else the source's synopsis.
    private func synopsisText(_ detail: Video) -> String {
        if let story = tmdb.details?.story, !story.isEmpty { return story }
        return detail.synopsis
    }
    /// The lookup's progress or its question, then TMDB's cast, facts and notice, under the page's own content.
    @ViewBuilder private var tmdbStatus: some View {
        TMDBLookupStatus(lookup: tmdb)
    }
    @ViewBuilder private var tmdbExtras: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let details = tmdb.details {
                if !details.cast.isEmpty { TMDBCastRow(cast: details.cast) }
                TMDBInfoGrid(details: details)
                TMDBFooter(lookup: tmdb, title: currentVideo().name)
            }
            relatedSection
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    /// "猜你喜欢" over the related list. The list itself falls back from TMDB's recommendations to the source's
    /// own related titles, then to this video's episodes, so the space below the video never sits empty.
    @ViewBuilder private var relatedSection: some View {
        let recs = tmdb.details?.recommendations ?? []
        if !recs.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            TMDBRelatedList(titles: recs) { store.searchVideos($0) }
        } else if !siteRelated.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(siteRelated) { item in
                    switch item.destination {
                    case .detail(let video):
                        RouteLink { CatalogDestination(video: video, client: client) } label: {
                            RelatedCard(title: item.name, subtitle: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                        }
                    case .search(let query):
                        Button { store.searchVideos(query) } label: {
                            RelatedCard(title: item.name, subtitle: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                        }
                        .tmdbCardButton()
                    }
                }
            }
        } else if let detail, !activeEpisodes.isEmpty {
            Text(L10n.text("You May Like")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(shownOrder(activeEpisodes)) { episode in
                    Button { startRequest { await play(episode) } } label: {
                        RelatedCard(title: episodeTitle(episode), subtitle: SourceLabel(client.site.name).text,
                                    poster: video.poster, headers: video.posterHeaders)
                    }
                    .tmdbCardButton()
                }
            }
        }
    }
    private var bannerHeight: CGFloat {
        #if os(tvOS)
        // Leaves the synopsis in view under it.
        min(max(containerWidth * 0.38, 480), 680)
        #else
        min(max(containerWidth * 0.42, 280), 540)
        #endif
    }
    /// TMDB's backdrop banner once its picture is in, the source's cover and title until then.
    @ViewBuilder private var tmdbHero: some View {
        if let details = tmdb.details, let backdrop = details.backdrop, backdrop == loadedBackdrop {
            let banner = TMDBBanner(details: details, backdrop: backdrop, unmatched: tmdb.answer?.unmatched ?? "") { playControl }
            banner.frame(height: bannerHeight).transition(.opacity)
        } else {
            hero.transition(.opacity)
        }
    }
    private var headerLayout: AnyLayout {
        #if os(iOS)
        if sizeClass == .compact { return AnyLayout(HStackLayout(alignment: .top, spacing: 16)) }
        #endif
        return AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }
    private var compactDetail: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    @ViewBuilder private func synopsis(_ detail: Video) -> some View {
        let text = synopsisText(detail)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(.secondary)
                    .lineLimit(synopsisExpanded ? nil : synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if text.count > 100 {
                    let toggle = Button(L10n.text(synopsisExpanded ? "Show Less" : "Show Full Synopsis")) { synopsisExpanded.toggle() }
                    #if os(tvOS)
                    toggle.controlButton()
                    #else
                    toggle.buttonStyle(.plain).font(.subheadline.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full width, so Down from the banner's buttons reaches Show Full Synopsis wherever they sit.
            .tvFocusSection()
        }
    }
    private var synopsisLineLimit: Int {
        #if os(tvOS)
        4
        #else
        3
        #endif
    }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #elseif os(iOS)
        compactDetail ? 104 : 150
        #else
        Layout.detailPoster
        #endif
    }
    private var isWide: Bool { containerWidth >= wideMinWidth }
    /// The details, with the list's poster when the details came without one.
    private func currentVideo() -> Video { (detail ?? video).keepingPoster(video.poster, headers: video.posterHeaders) }

    private func videoFavorite() -> FavoriteItem {
        .video(FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()))
    }

    private func episodeFavorite(_ episode: Episode) -> FavoriteItem {
        .episode(FavoriteEpisode(video: FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()), episodeFlag: episode.flag, episodeName: episode.name, episodeID: episode.id))
    }

    @ViewBuilder private var playControl: some View {
        if let detail {
            if let first = activeEpisodes.first ?? detail.episodes.first {
                // Beside the poster on a phone there is no room for both labels: Download drops to its icon.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: false); videoFavoriteButton }
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: true); videoFavoriteButton }
                }
            } else {
                #if os(tvOS)
                // No episodes, so no Play: without a button here nothing on the page could take focus, and Back
                // did nothing at all.
                goBackButton(prominent: true).focused($playFocused)
                #endif
            }
        } else if error == nil {
            // On Apple TV the hero fills the screen and the skeleton below it is off-screen: the
            // Play button's placeholder holds focus, so Back leaves the page instead of the app.
            SkeletonBlock(cornerRadius: 10).frame(width: 150, height: 40).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            #if os(tvOS)
            // The details failed. The error card's buttons are below the full-screen hero, out of the remote's reach,
            // so the hero offers them too; they hold focus, and Back leaves the page again.
            HStack(spacing: 10) {
                Button { startRequest { await loadDetail() } } label: { Label(L10n.text("Retry"), systemImage: "arrow.clockwise") }
                    .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
                    .disabled(busy)
                    .focused($playFocused)
                    .accessibilityIdentifier("detail.retry")
                goBackButton(prominent: false)
            }
            #endif
        }
    }
    #if os(tvOS)
    private func goBackButton(prominent: Bool) -> some View {
        Button { dismiss() } label: { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
            .controlButton(prominent: prominent).controlSize(.large)
            .accessibilityIdentifier("detail.goBack")
    }
    #endif
    private func playButton(_ episode: Episode) -> some View {
        Button { startRequest { await play(episode) } } label: {
            HStack(spacing: 8) {
                if loadingEpisode == episode.id { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                Text(L10n.text("Play"))
            }
            .font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 8)
        }
        .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
        .focused($playFocused)
    }
    private func downloadButton(iconOnly: Bool) -> some View {
        Button { choosingDownloads = true } label: {
            Label(L10n.text("Download"), systemImage: "arrow.down.circle")
                .labelStyle(DownloadLabelStyle(iconOnly: iconOnly))
                .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large).accessibilityLabel(L10n.text("Download"))
    }
    /// Icon-only, beside Play and Download. An empty heart keeps the control color; a saved one is rose.
    /// Set as text in their font, so the button is as tall as theirs: a bare image made a smaller one on Apple TV.
    private var videoFavoriteButton: some View {
        let saved = store.favorites.contains(videoFavorite())
        let title = saved ? L10n.text("Remove %@ from favorites", currentVideo().name) : L10n.text("Add %@ to favorites", currentVideo().name)
        return Button { store.favorites.toggle(videoFavorite()) } label: {
            Group {
                if saved {
                    Text(Image(systemName: "heart.fill")).foregroundStyle(Brand.rose)
                } else {
                    Text(Image(systemName: "heart"))
                }
            }
            .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large)
        .accessibilityLabel(title).help(title)
        .accessibilityIdentifier("detail.favorite")
    }
    /// Share the video's TMDB page, whose link is stable (a source's playback address is temporary).
    @ViewBuilder private var shareButton: some View {
        #if !os(tvOS)
        if let link = tmdb.details?.link {
            ShareLink(item: link) {
                Text(Image(systemName: "square.and.arrow.up"))
                    .font(.headline).lineLimit(1).fixedSize()
            }
            .controlButton().controlSize(.large)
            .accessibilityLabel(L10n.text("Share"))
            .accessibilityIdentifier("detail.share")
        }
        #endif
    }
    /// The source's cover in TMDB's banner shape, so the page keeps its layout when TMDB's backdrop fades in, and for
    /// titles TMDB doesn't have.
    private var hero: some View {
        PosterBanner(poster: video.poster, headers: video.posterHeaders, title: video.name, subtitle: video.remarks,
                     aspect: $artAspect) { playControl }
            .frame(height: bannerHeight)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            // TMDB's banner at any width, so a matched title's page looks the same everywhere.
            if isWide || hasBackdrop {
                tmdbHero
                playbackBanner
                tmdbStatus
                if let detail, !synopsisText(detail).isEmpty {
                    synopsis(detail).font(.body).padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: posterWidth)
                        .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    // As tall as the 2:3 poster, so the buttons line up with its bottom edge.
                    MinHeightLayout(minHeight: posterWidth * 1.5) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(video.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            if !video.remarks.isEmpty { Text(video.remarks).font(.subheadline).foregroundStyle(.secondary) }
                            if let facts = tmdb.details?.facts, !facts.isEmpty {
                                Text(facts).font(.subheadline).foregroundStyle(.secondary).transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            playControl
                        }
                    }
                    Spacer(minLength: 0)
                }
                playbackBanner
                tmdbStatus
                if let detail { synopsis(detail) }
            }
        }
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.45), value: loadedBackdrop)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
        .task(id: tmdb.details?.backdrop) {
            // Into TMDBArtwork's cache, so the banner shows it at once.
            guard let backdrop = tmdb.details?.backdrop,
                  await TMDBArtwork.load(backdrop, maxPixels: TMDBBannerMetrics.backdropPixels) != nil,
                  !Task.isCancelled else { return }
            loadedBackdrop = backdrop
        }
    }
    private var hasBackdrop: Bool {
        tmdb.details?.backdrop != nil && tmdb.details?.backdrop == loadedBackdrop
    }
    @ViewBuilder private var episodePanel: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        #if os(tvOS)
                        if items.count > 1 {
                            episodeOrderButton(count: items.count)
                        } else {
                            Text(L10n.text("Episodes")).font(.headline)
                        }
                        #else
                        Text(L10n.text("Episodes")).font(.headline)
                        Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        if items.count > 1 { episodeOrderButton }
                        #endif
                        Spacer(minLength: 8)
                        if flags.count == 1, !activeFlag.isEmpty {
                            Text(SourceLabel(activeFlag).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    flagPicker
                    episodeList(items)
                }
            }
        }
    }
    @ViewBuilder private var flagPicker: some View {
        if flags.count > 1 {
            #if os(tvOS)
            ChipRow {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        Chip(title: flag.isEmpty ? L10n.text("Play") : flag, selected: flag == activeFlag) { selectedFlag = flag }
                    }
                }
            }.tvFocusSection()
            #else
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { selectedFlag = $0 }
            #endif
        }
    }
    #if os(tvOS)
    /// On Apple TV the heading itself turns the list around (倒序): one glass button whose arrow shows the order,
    /// up for the first episode first, down for the last.
    private func episodeOrderButton(count: Int) -> some View {
        Button { reversesEpisodes.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: reversesEpisodes ? "arrow.down" : "arrow.up").contentTransition(.symbolEffect(.replace))
                Text(L10n.text("Episodes"))
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .glassPill()
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #else
    /// The small button beside the episode count that turns the lists around (倒序).
    private var episodeOrderButton: some View {
        Button { reversesEpisodes.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(reversesEpisodes ? Brand.accent : Color.secondary)
                .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
        .help(L10n.text("Reverse Order"))
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #endif

    /// What the pickers show for an episode: its short label when its line has them, else its name without the size tag.
    private func episodeTitle(_ episode: Episode) -> String { episodeLabels[episode.id] ?? EpisodeRow.title(episode.name) }

    /// The episodes in the order the lists show them. Only the lists: Play and the next episode still follow the source.
    private func shownOrder(_ items: [Episode]) -> [Episode] { reversesEpisodes ? items.reversed() : items }

    private func episodeList(_ items: [Episode]) -> some View {
        // A chip fits about six characters before it truncates (《一…); longer names get rows.
        let longNames = (items.map { (episodeLabels[$0.id] ?? $0.name).count }.max() ?? 0) > 6
        // Under a full-width banner, long names fill columns rather than one stretched list.
        let rowColumns = isWide ? [GridItem(.adaptive(minimum: 320), spacing: 8)] : [GridItem(.flexible())]
        // TMDB's stills, when its season lines up with most of the episodes and has pictures for them; without
        // pictures the small chips read better than empty tiles. While TMDB is still looking, tiles with the episode
        // numbers, so its stills fade into the same tiles instead of chips turning into tiles.
        let stills = tmdb.episodes(items)
        let showsStills = items.count > 1
            && (stills.values.filter { $0.still != nil }.count * 2 >= items.count || (tmdbPending && items.count <= 60))
        let columns = showsStills ? [GridItem(.adaptive(minimum: TMDBMetrics.episodeTile), spacing: TMDBMetrics.spacing, alignment: .top)]
            : longNames ? rowColumns : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: showsStills ? TMDBMetrics.spacing : longNames ? 4 : 8) {
            ForEach(shownOrder(items)) { episode in
                let saved = download(episode)
                Group {
                    if showsStills {
                        Button { startRequest { await play(episode) } } label: {
                            TMDBEpisodeTile(name: episodeTitle(episode), info: stills[episode.id], loading: loadingEpisode == episode.id, width: nil)
                        }
                        .tmdbCardButton()
                        .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
                        .accessibilityLabel(episode.name)
                    } else if longNames {
                        EpisodeRow(name: episode.name, label: episodeLabels[episode.id], loading: loadingEpisode == episode.id, download: saved) {
                            startRequest { await play(episode) }
                        }
                    } else {
                        Chip(title: episodeLabels[episode.id] ?? episode.name, selected: loadingEpisode == episode.id, fill: true) { startRequest { await play(episode) } }
                            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if store.favorites.contains(episodeFavorite(episode)) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 12, weight: .semibold))
                            .foregroundStyle(Brand.rose)
                            .padding(4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contextMenu {
                    // The file name a label stands for: its resolution and codec can matter on a netdisk line.
                    if episodeLabels[episode.id] != nil { Text(episode.name) }
                    FavoriteMenuButton(item: episodeFavorite(episode), name: episode.name)
                    if saved == nil || saved?.status == .failed {
                        Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                            DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin),
                                                            title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                        }
                    } else if let saved {
                        Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                            DownloadLibrary.shared.remove([saved.id])
                        }
                    }
                }
            }
        }
        #if os(tvOS)
        // Room for the focused glass row, which grows toward the trailing edge.
        .padding(.trailing, 16).padding(.vertical, 6)
        #endif
        .tvFocusSection()
        .animation(.smooth(duration: 0.4), value: showsStills)
    }
    /// Mac and iPad, under the banner: TMDB hasn't answered yet. Short-drama-length lists stay chips (see episodeList).
    private var tmdbPending: Bool {
        #if os(tvOS)
        false
        #else
        isWide && (tmdb.phase == .looking || (tmdb.phase == .idle && TMDBLookup.applies(to: client.site)))
        #endif
    }
    private var episodeMin: CGFloat {
        #if os(tvOS)
        170
        #else
        // Room for 第 10 集 / 第01集 without an ellipsis.
        100
        #endif
    }
    private func download(_ episode: Episode) -> DownloadItem? {
        DownloadLibrary.shared.item(for: DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin))
    }
    private func play(_ episode: Episode, skipAccountCheck: Bool = false) async {
        guard !busy else { return }
        // A downloaded episode plays from the device: no link to fetch, and it works offline.
        if let saved = download(episode), saved.status == .completed {
            store.playing = DownloadLibrary.shared.channel(for: saved)
            return
        }
        // Cloud-drive plugins wait for an in-app login that cannot appear on this platform,
        // which surfaces only as a 60-second timeout. Ask for the account up front instead.
        if !skipAccountCheck, let drive = CloudDrive.missingLogin(forFlag: episode.flag) {
            withAnimation(.smooth(duration: 0.25)) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.loginHint, drive: drive, blockedBeforeRequest: true)
            }
            return
        }
        busy = true; loadingEpisode = episode.id
        withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil }
        defer { busy = false; if !choosingQuality { loadingEpisode = nil } }
        do {
            let plan = try await client.preparePlayback(episode)
            try Task.checkCancellation()
            if plan.choices.count > 1 {
                pendingPlan = plan; pendingEpisode = episode; choosingQuality = true
            } else {
                let playback = store.subscription.map { client.applying($0) } ?? client
                let resolved = try await playback.resolvePlayback(plan, choice: plan.choices[0])
                try Task.checkCancellation()
                store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
            }
        } catch { fail(episode, error) }
    }
    private func resolve(_ plan: PlaybackPlan, choice: PlaybackChoice, episode: Episode) async {
        busy = true; loadingEpisode = episode.id
        defer { busy = false; pendingPlan = nil; pendingEpisode = nil; loadingEpisode = nil }
        do {
            let playback = store.subscription.map { client.applying($0) } ?? client
            let resolved = try await playback.resolvePlayback(plan, choice: choice)
            try Task.checkCancellation()
            store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
        } catch { fail(episode, error) }
    }
    private func retryAfterSignIn() {
        if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
    }
    private func fail(_ episode: Episode, _ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        let login = error as? CloudDriveLoginRequired ?? CloudDriveLoginRequired(bundleMessage: error.localizedDescription)
        // A drive that needs signing in is expected, not a failure to report.
        if login == nil {
            Diagnostics.shared.failure("catalog", "play \(client.reportContext) flag=\(episode.flag)", error)
        }
        withAnimation(.smooth(duration: 0.25)) {
            // Plugins report a missing or expired drive login in their own words ("夸克授权失败，请扫码登录");
            // say what happened and offer the sign-in instead of echoing them.
            if let login, let drive = CloudDrive(rawValue: login.rawValue) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else if let provider = CatPawSignIn.provider(for: error.localizedDescription) {
                // Signed in, but the bundle wants a token its own code gives; signing in again would change nothing.
                playbackIssue = PlaybackIssue(episode: episode, message: L10n.text("You're signed in to UC, but this source plays UC accounts without premium through UC's TV app, which needs a token of its own. Get it once with the UC Browser app, or choose another line."),
                                              drive: nil, blockedBeforeRequest: false, signIn: provider)
            } else if let drive = CloudDrive(flag: episode.flag), CloudDrive.isLoginFailure(error.localizedDescription) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else {
                playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription,
                                              drive: CloudDrive.missingLogin(forFlag: episode.flag), blockedBeforeRequest: false)
            }
        }
    }

    /// This video's playback scopes (`PlaybackHistoryContext.id`); the details may carry another ID than the list's.
    private var watchScopes: Set<String> {
        let origin = client.site.origin(or: client.origin)
        return Set([video.id, detail?.id].compactMap { $0 }.map { EpisodeSkipSettings.scope(origin: origin, source: client.site.sourceKey, video: $0) })
    }
    /// Whether opening this page should land on the episode list instead of a cover.
    ///
    /// A video of several episodes with nothing watched before has no single episode to
    /// start: the first one may be the wrong line, and the previous behaviour left the
    /// viewer on a Play button that opened the very list they now get directly.
    private var opensIntoEpisodes: Bool {
        #if os(iOS)
        guard watchLayout, activeEpisodes.count > 1 else { return false }
        return watchHistory == nil
        #else
        return false
        #endif
    }
    /// Where the viewer stopped last time, for Continue.
    private var watchHistory: PlaybackHistoryEntry? {
        store.visibleHistory.first { watchScopes.contains($0.context.id) }
    }
    /// The line of the episode playing, else of the one watched last, while the details still have it: the page opens
    /// on that line so the episode shows in its list, not on the first line (#362).
    private var watchedFlag: String? {
        guard let episodes = detail?.episodes else { return nil }
        #if os(iOS)
        let context = watchChannel?.historyContext ?? watchHistory?.context
        #else
        let context = watchHistory?.context
        #endif
        return context?.episode(in: episodes)?.flag
    }

    #if os(iOS)
    // MARK: iPhone watch page

    private var watchLayout: Bool { WatchPage.applies(sizeClass, verticalSizeClass) }

    /// Landscape on a phone held sideways: the page splits left/right rather than stacking — the picture
    /// on the left, the episode list on the right. A phone held sideways is compact in both directions
    /// (`compact × compact`). The Duo's *folded outer* display in portrait reports `regular × compact`,
    /// which `verticalSizeClass == .compact` alone mistook for sideways and wrongly split; requiring the
    /// horizontal class too keeps the outer portrait a single stacked column (video on top, details below).
    private var landscapePage: Bool { sizeClass == .compact && verticalSizeClass == .compact }
    /// iPhone Duo's inner display: still a phone (`idiom == .phone`) but regular in both directions.
    /// It is not "held sideways" — it is a real folded-out tablet-sized screen — so it uses the same
    /// two-column layout as a landscape phone (picture on the left, synopsis + episodes on the right).
    /// A real iPad (`idiom == .pad`) never reaches here: `WatchPage.applies` keeps it on the plain
    /// detail page.
    private var duoExpanded: Bool {
        #if DEBUG
        // `-qaDuoExpanded 1` renders this branch anywhere, so the folded-out layout can be photographed
        // without an iPhone Duo simulator — that model needs an iOS 27.1 runtime, and on a machine that
        // only has 26.5 / 27.0 the device type refuses to be created at all.
        if UserDefaults.standard.bool(forKey: "qaDuoExpanded") { return true }
        #endif
        // The Duo unfolded is a tablet-sized screen, much wider than the folded outer cover. Held upright
        // its classes report `.regular × .regular`; held sideways they report `.regular × .compact`, the
        // *same classes as the folded outer cover*. So the classes alone can't tell unfolded from folded —
        // the width can: wide = unfolded, narrow = folded.
        // A landscape phone (compact × compact) is wide too, but it is NOT the Duo unfolded — it keeps its
        // immersive single-surface layout. Only a regular-width phone (the Duo's inner display) can be unfolded.
        return UIDevice.current.userInterfaceIdiom == .phone
            && sizeClass == .regular
            && (containerWidth > 600 || verticalSizeClass == .regular)
    }
    /// Whether the screen itself is genuinely wider than tall. The Duo's inner display held sideways
    /// reports `regular × .regular` in practice (the size class does NOT flip to `.compact` as the
    /// comment above assumed), so a `verticalSizeClass` test misreads the unfolded landscape as upright.
    /// `screen.bounds.width > height` is no better: the inner display reports its *native* portrait
    /// bounds (2007×2853) even while its `interfaceOrientation` is `.landscapeLeft/Right` (rot90), so a
    /// bounds comparison always read "upright" and the unfolded landscape borrowed the portrait
    /// full-bleed layout. The interface orientation is discrete and cannot sit at the width:height
    /// critical point during the unfold/rotate animation, so it is the stable signal that keeps the
    /// two unfolded shapes — landscape column vs portrait full-bleed — independent.
    private var landscapeScreen: Bool {
        switch UIApplication.shared.appWindowScene?.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return true
        default: return false
        }
    }
    /// The Duo unfolded and held upright: a tall, tablet-sized screen that is wider than the folded cover
    /// but taller than wide. It is neither the folded portrait column nor the unfolded landscape two-column
    /// page — it plays the video full-bleed and tucks the details + episode list into a half-height sheet
    /// the viewer pulls up, rather than stacking them under a 16:9 picture that wastes most of the tall
    /// screen. `duoExpanded` is true here but the screen is taller than wide (`!landscapeScreen`), which is
    /// exactly what separates it from the unfolded landscape column — the size classes cannot tell the two
    /// apart, but the screen's own aspect can.
    /// Whether the unfolded Duo is in its landscape column. Not the same as `landscapeScreen`: the page
    /// opens sideways and the interface turns a beat later, so between the unfold and the turn this is
    /// already true while the orientation still reads upright. Every layout decision reads this, never
    /// `landscapeScreen` on its own, so the first frame of an unfold is the landscape one.
    private var sideways: Bool { landscapeScreen || (duoExpanded && unfoldingToLandscape) }
    private var portraitExpanded: Bool { duoExpanded && !sideways }
    /// The page is laid out left/right — picture on one side, details and episodes beside it — rather
    /// than stacked. True for a phone held sideways and for the unfolded Duo's wide inner display; Full
    /// Screen owns the whole display instead, so it never splits.
    private var splitsWatchPage: Bool { (landscapePage || (duoExpanded && sideways)) && !fullScreen }
    /// The landscape the unfolded Duo first lands on, read from how the viewer is holding it. Unfolding
    /// must always open into landscape, but *which* landscape follows the grip rather than being pinned
    /// left. `UIDevice.current.orientation` reports `.landscapeLeft` / `.landscapeRight` while held
    /// sideways; when the device is flat or still settling it reports `.faceUp` / `.faceDown` / `.unknown`,
    /// and there is no sideways grip to honour, so it falls back to `.landscapeLeft`.
    private var unfoldedLandscape: UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft, .faceUp, .faceDown, .unknown, .portrait, .portraitUpsideDown:
            return .landscapeLeft
        @unknown default: return .landscapeLeft
        }
    }
    /// Lands an unfold on landscape: ask once, and hold the landscape layout until the interface is actually
    /// sideways. Unfolding has always opened in landscape, but only from `onChange(of: duoExpanded)` — a page
    /// opened on an already unfolded Duo never sees that change, so it stayed on the upright full-bleed
    /// layout with the details in a sheet. Both entries go through here, and the hold covers the beat before
    /// `interfaceOrientation` flips, so the first frame drawn is the two-column one.
    private func landLandscape() {
        unfoldingToLandscape = true
        Task { @MainActor in
            // The unfold animation swallows the geometry request made on its first frame (the scene is
            // still resizing, so the turn is dropped), which is exactly how an unfold kept landing
            // upright. Keep holding the landscape layout and ask again while the display settles; stop
            // the moment the interface reports sideways. The whole window is well under two seconds.
            for _ in 0 ..< 8 {
                PlayerOrientation.turn(to: unfoldedLandscape)
                for _ in 0 ..< 5 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if landscapeScreen { break }
                }
                if landscapeScreen { break }
            }
            unfoldingToLandscape = false
        }
    }
    /// What plays at the top of the page: one of this video's episodes.
    private var watchChannel: Channel? {
        store.playing.flatMap { watchScopes.contains($0.historyContext?.id ?? "") ? $0 : nil }
    }
    /// The episode playing, else the one watched last: marked in the list, which scrolls to it.
    private var currentEpisodeID: Episode.ID? {
        guard let episodes = detail?.episodes else { return nil }
        return (watchChannel?.historyContext ?? watchHistory?.context)?.episode(in: episodes)?.id
    }

    /// As in Bilibili's app: the player at the top, under the status bar, and the title, actions, synopsis and
    /// episodes scrolling below it. Full Screen grows the same player over the page, so playback carries on.
    ///
    /// One structure for every shape of the phone. The picture sits at the top of the page with the details
    /// and episode list under it; held sideways — and on the unfolded Duo's wide inner display — the same two
    /// pieces are laid out left/right instead. `AnyLayout` swaps the *axis*, never the views, so the player
    /// keeps its identity through every fold, turn and Full Screen. It used to be written once per branch
    /// (stacked, split, and a third full-bleed one for the upright unfolded Duo), which tore the view down
    /// and rebuilt it on each move: the `AVPlayerLayer` left the window (AVKit answered with a second,
    /// unwanted Picture in Picture window), playback re-ran its setup, and the page's orientation hold was
    /// released mid-turn — the picture, and then the whole page, drifted.
    @ViewBuilder private var watchBody: some View {
        // The picture's own shape, never a fixed 16:9 box: a 4:3 or a 2.35:1 film fills it exactly, so
        // the bars the old box drew inside the player are gone. The page reports what the stream is;
        // 16:9 is only the guess until it does.
        let ratio = max(playerAspectRatio, 0.4)
        let side = containerWidth > 0 ? containerWidth : 390
        // Landscape splits the page left/right instead of stacking, as One does: the picture keeps the
        // width it needs and the episode list uses the space beside it rather than below. A Duo unfolded
        // does the same across its wide inner display. Upright — the folded outer cover and the unfolded
        // inner display alike — stacks one column, picture on top, details and episodes below.
        let splits = splitsWatchPage
        // The folded-out Duo gives the right column a clamped share: wide enough for the episode tiles
        // and the synopsis, narrow enough to leave the picture room. Clamping to a range (instead of a
        // raw fraction) also stops the measured width feeding back into the column width and shrinking
        // the page turn after turn.
        let detailWidth = splits ? (duoExpanded ? min(max(containerWidth * 0.36, 300), 460) : max(0, containerWidth * 0.42)) : 0
        let playerWidth = splits ? max(1, side - detailWidth) : side
        // The picture keeps the stream's shape and takes at most half the upright screen, so the episode
        // list is on screen under it — on the unfolded Duo too, which used to hide that list behind a
        // half-height sheet while the picture owned the whole display. Full Screen is the way to give the
        // picture everything.
        let tall = containerHeight > 1 ? containerHeight : side * 1.6
        let pictureHeight = min(playerWidth / ratio, tall * 0.5)
        let stageHeight: CGFloat? = fullScreen ? nil : (splits ? max(1, tall) : max(1, pictureHeight))
        let axis = splits ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        ZStack(alignment: .top) {
            // Black belongs behind the picture, not behind the page: in the split layout a full-height
            // black band behind the details column left black text on black in light mode. Full Screen is
            // one black surface, so it keeps the plain black behind everything.
            if fullScreen || splits { Color.black.ignoresSafeArea() }
            axis {
                watchStage
                    .frame(width: splits ? playerWidth : nil, height: stageHeight)
                    .frame(maxWidth: fullScreen ? .infinity : nil, maxHeight: fullScreen ? .infinity : nil)
                if !fullScreen {
                    ScrollView {
                        watchDetails
                            .padding(.horizontal, splits ? Layout.gutter : 16)
                            .padding(.top, splits ? 16 : 14)
                            // The column runs to the physical bottom edge (the page hides the status bar
                            // and the tab bar's inset does not reach this pushed page), so the last card
                            // needs its own reserve or the home indicator cuts its caption.
                            .padding(.bottom, splits ? 48 : 24)
                    }
                    .scrollIndicators(.never)
                    .frame(width: splits ? detailWidth : nil)
                    .overlay(alignment: .leading) {
                        // A hairline between the picture and the details column, so the two-column page
                        // reads as two surfaces rather than text glued to the picture's edge.
                        if splits { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .statusBarHidden(true)
        // The upright watch page is immersive: the edge swipe is its way back. On a folded-out Duo the
        // page keeps its section menu (the floating tab bar) so a viewer can hop sections without
        // leaving playback, and the picture itself carries the Back button.
        // `setBarVisibility` uses `.toolbarVisibility` (iOS 18+) rather than `.toolbar(_, for:)`,
        // which is deprecated on iOS 27 and silently stops hiding the Liquid Glass bars.
        // The watch page carries its own top bar over the picture (see the back button on the player
        // and the split column's header), so the navigation bar is hidden on every shape of it — the
        // Duo unfolded included: a white title strip across the top of a poster prints the name twice
        // and, after a fold, left the system's back button floating at the wrong end of the window.
        .setBarVisibility(.hidden, for: .navigationBar)
        // A hidden navigation bar can leave its back chevron floating over the player's own
        // round Back button (two back controls stacked in the top-left corner). Hiding the bar
        // alone does not always hide the back button on a pushed page, so hide it explicitly
        // whenever the bar is hidden.
        .navigationBarBackButtonHidden(true)
        .background { EdgeSwipeBack(enabled: !fullScreen && !duoExpanded) }
        // The Duo's section menu stays resident even in Full Screen: it floats over the picture
        // (sidebarAdaptable never widens the safe area for it), so a viewer can hop sections without
        // leaving playback. The upright phone hides it in Full Screen, as before.
        // `setBarVisibility` not `.toolbar(_, for:)`: the old form is deprecated on iOS 27 and
        // stops hiding the floating Liquid Glass tab bar, leaving the capsule over a full-screen video.
        // The unfolded-upright Duo (portraitExpanded) plays full-bleed down to the home indicator, so its
        // tab bar hides to keep the seek bar clear; the unfolded landscape column and Full Screen keep it
        // resident. Gated on `duoExpanded` so a plain upright phone still hides its tab bar in Full Screen.
        .setBarVisibility(duoExpanded && (!portraitExpanded || fullScreen) ? .visible : .hidden, for: .tabBar)
        .onAppear {
            store.watchPageScopes.formUnion(watchScopes)
            // The folded-out Duo is its own landscape screen; only the upright outer display is held
            // portrait. (The inner display ignores orientation locks anyway, but holding it here also
            // keeps Full Screen's turn from fighting the page.)
            // A page opened on an already unfolded Duo never gets the fold/unfold change below, so this is
            // the only place that can land it sideways — without it the page sat upright, picture filling a
            // tall screen with the details in a sheet.
            if duoExpanded {
                PlayerOrientation.holdPortrait(false)
                landLandscape()
            } else {
                PlayerOrientation.holdPortrait(true)
            }
            // Turning the phone sideways opens Full Screen, so listen for its orientation while a video plays.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onChange(of: watchScopes) { old, new in
            store.watchPageScopes.subtract(old.subtracting(new)); store.watchPageScopes.formUnion(new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            phoneTurned()
        }
        .onChange(of: duoExpanded) { _, expanded in
            // Fold/unfold swaps the watch page between the outer display (held portrait) and the
            // inner display (which ignores orientation locks). Re-assert the right hold each way so
            // an unfold doesn't leave the upright lock fighting a landscape Full Screen.
            PlayerOrientation.holdPortrait(!expanded)
            // Unfolding opens into landscape by default (the inner display is a sideways tablet), but
            // does not pin it: `turn` moves the picture once and leaves the mask free, so the viewer
            // can still turn it upright afterwards. `holdPortrait(false)` above already let the mask
            // follow the device; this just gives the first landing a landscape instead of portrait.
            //
            // Which landscape, though, follows the grip: a viewer already holding the phone sideways
            // lands straight on their landscape, not a hard-coded `landscapeLeft` that first flashes
            // the other way round and then snaps back. Only when the device reports no sideways grip
            // (flat on a table, or mid-turn) does it fall back to `landscapeLeft`.
            if expanded {
                landLandscape()
            } else {
                // Folded back to the outer display, which is held portrait: drop the hold with it, so a
                // fold during the turn cannot leave the landscape layout up on the cover screen.
                unfoldingToLandscape = false
            }
            // A Full Screen started on the inner display must not carry onto the outer one: folding
            // while full-screen left the player filling a portrait screen it could not turn, with the
            // watch page's own layout gone. Fold the page back to its normal (non-full-screen) state
            // so it reads correctly again; unfolding re-opens the two-column watch page.
            if !expanded && fullScreen { fullScreen = false }
        }
        // Fold/unfold flips the tab bar, the scrim's bleed and the controls' safe-area padding at once;
        // animate the lot together so the swap reads as one move, not a pop.
        .animation(.smooth(duration: 0.3), value: duoExpanded)
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            // An iPhone Duo fold/unfold swaps `watchBody` for `pageBody` (and back) without the page leaving, so the
            // page-level `onDisappear` handles stopping playback and leaving Full Screen. Here only the watch page's
            // own contributions are undone; they are re-established by `onAppear` when the watch page returns.
            store.watchPageScopes.subtract(watchScopes)
            turnedFullScreen = false
            // Unconditional: an unfold sets the hold to false already, but closing the page while
            // folded shut used to skip this and leave the app held upright.
            PlayerOrientation.holdPortrait(false)
        }
        .onChange(of: watchChannel == nil) { _, ended in
            playerStarted = false
            if ended { playerSession = nil }
            if ended && fullScreen { setFullScreen(landscape: false) }
            // Started with the phone already sideways: Full Screen at once, as turning it would.
            if !ended { phoneTurned() }
        }
        .sheet(isPresented: $showsAllEpisodes) { allEpisodes }
    }

    /// The picture's own surface: black, so the bands a fit leaves inside it read as part of the frame
    /// rather than as the page showing through, with the player on top. Not clipped: in Full Screen the
    /// player ignores the safe area and reaches the physical edges, and a clip at the page's own bounds
    /// would cut that overflow back off. On the page the player stays inside its box, so there is nothing
    /// to clip there either.
    private var watchStage: some View {
        ZStack {
            Color.black
            watchPlayer
        }
    }

    @ViewBuilder private var watchPlayer: some View {
        // One cover from opening the page to the first picture: the player's own wait stays under it, so nothing
        // swaps or flickers on the way.
        let covered = watchChannel == nil || (!playerStarted && !fullScreen)
        ZStack {
            if let channel = watchChannel {
                PlaybackView(channel: channel, session: store.playbackSession(for: channel),
                             watch: WatchPlayback(fullScreen: fullScreen, toggleFullScreen: setFullScreen,
                                                  leave: leavePlayer,
                                                  immersive: splitsWatchPage || duoExpanded,
                                                  started: { playerStarted = $0 }, opened: { playerSession = $0 },
                                                  aspect: { ratio in
                                                      // Only grow, never shrink below 16:9 into a squat box: a
                                                      // source that reports nothing keeps the usual shape.
                                                      guard ratio.isFinite, ratio > 0.2, ratio < 6 else { return }
                                                      if abs(ratio - playerAspectRatio) > 0.01 { playerAspectRatio = ratio }
                                                  },
                                                  openEpisodes: { store.showsEpisodes = true }))
            }
            if covered { watchCover.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.35), value: covered)
    }

    /// Back from the picture. In Full Screen that means back to the page — the details and the episode
    /// list the viewer was looking at — not out of the page: the button sits in the top-left corner of a
    /// page the viewer only enlarged, so closing the page under it dropped them on Home with the video
    /// floating in the mini player. Leaving the page itself is the cover's Back, or the edge swipe.
    private func leavePlayer() {
        if fullScreen { setFullScreen(landscape: false) } else { dismiss() }
    }


    /// The cover's words while it waits: the source finding the episode's link, then the page's player getting it ready.
    private func coverStatus(_ elapsed: TimeInterval) -> PlaybackWait {
        if let session = playerSession, let channel = watchChannel, loadingEpisode == nil {
            return session.wait(elapsed: elapsed, resume: channel.resumePosition, linesHint: false)
        }
        let progress = LoadingProgress.source(client.site, origin: client.origin, title: busyTitle)
        return PlaybackWait(message: progress.title, detail: progress.detail)
    }

    private func setFullScreen(landscape: Bool) {
        let entering = !fullScreen
        // A button's Full Screen stays until the viewer leaves it; turning the phone back upright ends only a
        // Full Screen the turning opened.
        if !entering { turnedFullScreen = false }
        withAnimation(.smooth(duration: 0.3)) { fullScreen = entering }
        // A landscape picture turns the phone; a portrait one fills the screen upright.
        // The Duo's unfolded inner display ignores orientation requests (regular × regular): asking it
        // to turn while entering Full Screen only interlocks the refused geometry update with the
        // full-screen transition and freezes the picture. The screen is already its own shape, so just
        // switch the full-screen state and leave the orientation alone.
        guard !duoExpanded else { return }
        if !entering { PlayerOrientation.set(landscape: false) } else if landscape { PlayerOrientation.set(landscape: true) }
    }

    /// Turning the phone sideways while its video plays opens Full Screen, as the player's button does, and turning
    /// it upright again returns to the page. The watch page holds the interface upright (`PlayerOrientation`), so it
    /// doesn't turn by itself: this listens to the phone's own turning instead.
    private func phoneTurned() {
        guard watchChannel != nil, PlayerOrientation.available else { return }
        // The controls lock also pins the orientation: turning the phone must not open Full Screen (and
        // flip the picture) while it is on. The rotate button still turns by hand — that asks for a
        // specific orientation, which is not the gyroscope following a changed grip.
        guard !PlayerOrientation.isLocked else { return }
        switch UIDevice.current.orientation {
        case .landscapeLeft, .landscapeRight:
            guard !fullScreen else { return }
            turnedFullScreen = true
            setFullScreen(landscape: true)
        case .portrait:
            guard fullScreen, turnedFullScreen else { return }
            setFullScreen(landscape: false)
        default:
            break
        }
    }

    /// The cover's Play: where the viewer stopped, else the line's first episode.
    private func playWatchCover() {
        if let watchHistory { store.resume(watchHistory); return }
        guard let first = activeEpisodes.first ?? detail?.episodes.first else { return }
        startRequest { await play(first) }
    }

    /// Before the picture: the cover across the top, blurred, while an episode starts. Otherwise (a video of several
    /// episodes waiting for one to be chosen, or an episode that failed, which the banner below explains) the cover
    /// shows clear, as Discover's page does, with Play.
    private var watchCover: some View {
        let starting = (detail == nil && error == nil) || busy || loadingEpisode != nil || store.resumingHistoryID != nil || watchChannel != nil
        let playable = watchHistory != nil || (activeEpisodes.first ?? detail?.episodes.first) != nil
        // The list's poster when there was one, so the picture doesn't change once the details arrive.
        let poster = video.poster != nil ? video : detail ?? video
        return WatchCoverBackdrop(poster: poster.poster, headers: poster.posterHeaders, loading: starting, clear: !starting, wide: (landscapePage || duoExpanded) && !fullScreen) { coverStatus($0) }
            .contentShape(Rectangle())
            .onTapGesture { if starting { withAnimation(.smooth(duration: 0.25)) { coverBack.toggle() } } }
            .task(id: coverBack) {
                guard coverBack else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { coverBack = false } }
            }
            .overlay {
                if !starting, playable {
                    Button { playWatchCover() } label: {
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .glassSurface(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Play"))
                    .accessibilityIdentifier("watch.play")
                }
            }
            .overlay(alignment: .topLeading) {
                // While it starts by itself nothing sits on the cover until it's tapped. Every shape of
                // the page shows it: the navigation bar is hidden on all of them (a white title strip
                // over a poster printed the name twice), so this is the only way back from the cover.
                if !starting || coverBack {
                    Button { leavePlayer() } label: { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                        .chromeButton()
                        .accessibilityLabel(L10n.text("Back"))
                        .accessibilityIdentifier("watch.back")
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    private var watchDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentVideo().name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let facts = tmdb.details?.facts, !facts.isEmpty {
                    Text(facts).font(.subheadline.weight(.medium)).lineLimit(2).transition(.opacity)
                }
                let meta = [currentVideo().remarks, currentVideo().year ?? "", SourceLabel(client.site.name).text].filter { !$0.isEmpty }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let genres = tmdb.details?.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre).font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
            if detail?.episodes.isEmpty == false {
                HStack(spacing: 10) { downloadButton(iconOnly: false); videoFavoriteButton; shareButton }
            }
            playbackBanner
            tmdbStatus
            if let detail { synopsis(detail) }
            if detail != nil {
                seasonPicker
                watchEpisodes
                tmdbExtras.padding(.top, 6)
            } else if let error {
                errorCard(error)
            } else {
                DetailSkeleton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its buttons are Liquid Glass, like the player's above them (#293).
        .environment(\.glassControls, true)
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    /// A row of the series' seasons, so a matched multi-season show can jump between them. Only shown when
    /// TMDB has more than one season and the viewer is on the matching one's details.
    @ViewBuilder private var seasonPicker: some View {
        if let details = tmdb.details, details.mediaType == .tv {
            let seasons = details.seasons.filter { $0.number > 0 }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.number) { season in
                            let selected = details.season?.number == season.number
                            Button {
                                Task { await tmdb.selectSeason(season.number) }
                            } label: {
                                Text(season.name.isEmpty ? L10n.text("Season %lld", season.number) : season.name)
                                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("detail.season.\(season.number)")
                        }
                    }
                }
            }
        }
    }

    /// As in Bilibili's 选集: one row of episodes that scrolls sideways to the one playing, and All for the full list.
    /// A video with one episode has no row (its only episode is the video); several lines still show to choose from.
    ///
    /// On the Duo's unfolded landscape (the two-column page) the right column is tall and wide enough to hold the
    /// whole list at once, so the sideways row gives way to a resident vertical grid — the episode list lives beside
    /// the picture instead of hiding behind an "All" sheet, the same way the synopsis and lines do.
    @ViewBuilder private var watchEpisodes: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                let compact = compactTileWidth(items) != nil
                // B站式数字卡片网格：展开双栏/竖屏 sheet 走常驻网格，每行约 6 个；窄屏外屏保留
                // 横向滚动 + 全部（布局形态不变，只把卡片换成数字方块）。
                if duoExpanded && items.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            episodeOrderButton
                        }
                        watchLines
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], spacing: 8) {
                            ForEach(shownOrder(items)) { watchEpisodeCard($0, fill: true) }
                        }
                    }
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    if items.count > 1 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            episodeOrderButton
                            if items.count > (compact ? 5 : 2) {
                                Button { showsAllEpisodes = true } label: {
                                    HStack(spacing: 3) { Text(L10n.text("All")); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 10).frame(minHeight: 32)
                                        .glassOrFill(.regular.interactive(), Color.clear, in: Capsule())
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("watch.allEpisodes")
                            }
                        }
                    } else if flags.count > 1 {
                        Text(L10n.text("Lines")).font(.headline)
                    }
                    watchLines
                    if items.count > 1 {
                        // scrollPosition rather than ScrollViewReader: scrollTo also scrolls the page's vertical
                        // scroll view, which pushed the title under the player.
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 8) { ForEach(shownOrder(items)) { watchEpisodeCard($0) } }
                                .scrollTargetLayout()
                                .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                        .scrollPosition(id: $episodeScroll, anchor: .center)
                        // Edge to edge, unclipped: the tiles' glass shadow ran past the row and was cut off in a band (#293).
                        .scrollClipDisabled()
                        .padding(.horizontal, -16)
                        .onAppear { episodeScroll = currentEpisodeID }
                        .onChange(of: currentEpisodeID) { _, id in if let id { withAnimation { episodeScroll = id } } }
                    }
                }
                }
            }
        }
    }

    /// The lines, when there are several. Choosing one while an episode plays switches to it on that line.
    @ViewBuilder private var watchLines: some View {
        if flags.count > 1 {
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { flag in
                let previous = activeFlag
                selectedFlag = flag
                guard watchChannel != nil, let episodes = detail?.episodes else { return }
                let playing = episodes.first { $0.id == currentEpisodeID }
                guard let same = episode(on: flag, matching: playing, in: episodes) else {
                    // This line has no episode to continue the one playing: stay on it, and say so.
                    selectedFlag = previous
                    withAnimation(.smooth(duration: 0.2)) { lineNotice = L10n.text("This line doesn't have this episode.") }
                    Task { try? await Task.sleep(for: .seconds(4)); withAnimation(.smooth(duration: 0.2)) { lineNotice = nil } }
                    return
                }
                if same.id != currentEpisodeID { startRequest { await play(same) } }
            }
            // Edge to edge and unclipped, like the episodes, so the strip doesn't cut the chips' glass shadow (#293).
            .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
            .padding(.horizontal, -16)
        }
    }

    /// The episode on `flag` that continues `playing`: the same name, else the same episode number (第20集 / EP20 /
    /// S01E20), else nil when this line has no such episode. With nothing playing, the line's first episode.
    private func episode(on flag: String, matching playing: Episode?, in episodes: [Episode]) -> Episode? {
        guard let playing else { return episodes.first { $0.flag == flag } }
        let line = episodes.filter { $0.flag == flag }
        if let same = line.first(where: { $0.name == playing.name }) { return same }
        if let number = TMDBMatch.episodeNumber(playing.name),
           let same = line.first(where: { TMDBMatch.episodeNumber($0.name) == number }) { return same }
        return nil
    }

    /// TMDB's stills for the line's episodes, when its season lines up with most of them and has pictures for them;
    /// otherwise none, and the episodes keep their small cards.
    private func watchStills(_ items: [Episode]) -> [Episode.ID: TMDBMatch.EpisodeInfo] {
        let stills = tmdb.episodes(items)
        return items.count > 1 && stills.values.filter { $0.still != nil }.count * 2 >= items.count ? stills : [:]
    }

    /// The width of the small tiles when every name is short (第1集, 01, 4K国语), or nil for two-line cards. The tiles
    /// are as wide as the widest name, at least 64 points: a fixed 64 cut off names of four or five characters such as
    /// 4K国语 or 第100集 (#290). Measures one name, in the same pass that checks their lengths.
    private func compactTileWidth(_ items: [Episode]) -> CGFloat? {
        var widest = "", widestUnits = 0
        for item in items {
            let title = episodeTitle(item)
            guard title.count <= 5 else { return nil }
            // Chinese and other wide characters take about twice the room of digits and Latin letters.
            let units = title.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
            if units > widestUnits { widest = title; widestUnits = units }
        }
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        let text = (widest as NSString).size(withAttributes: [.font: font]).width
        // 8 points of padding on each side, and a little room for the bold of the episode playing.
        return max(64, (text + 20).rounded(.up))
    }

    /// An episode as a B站-style number tile: a compact dark square with the episode number centred, the
    /// playing one inverted (light fill + dark number) as the one clear anchor. No still, no caption — the
    /// number is the whole tile, so the grid stays small and uniform across the three shapes. The resume
    /// state (watched halfway) is a "续 N%" corner badge instead of a bottom progress bar.
    private func watchEpisodeCard(_ episode: Episode, fill: Bool = false, chosen: (() -> Void)? = nil) -> some View {
        let current = episode.id == currentEpisodeID
        // B站式纯数字卡片：播放中集反白（浅底深字）是「正在播放」的唯一清晰锚点；续播集用
        // 左上角「续 N%」小角标代替底部进度条；未看是深灰底。无封面、无标题行，方块小而均匀。
        let playing = current && watchChannel != nil
        let resumeProgress: Double? = {
            guard current, watchChannel == nil, let history = watchHistory,
                  !history.completed, history.progress > 0 else { return nil }
            return history.progress
        }()
        let saved = download(episode)
        let number = TMDBMatch.episodeNumber(episode.name)
        let label = number.map(String.init) ?? episodeTitle(episode)
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        return Button {
            chosen?()
            // The episode already playing keeps playing.
            guard !(current && watchChannel != nil) else { return }
            startRequest { await play(episode) }
        } label: {
            ZStack {
                shape.fill(playing ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                if loadingEpisode == episode.id {
                    ProgressView().controlSize(.small).tint(playing ? Brand.onAccent : Color.primary)
                } else {
                    Text(label)
                        .font(.system(size: number == nil ? 13 : 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(playing ? Brand.onAccent : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .padding(.horizontal, 4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: fill ? nil : 64, height: fill ? nil : 64)
            .overlay(alignment: .topLeading) {
                if let resumeProgress {
                    Text(L10n.text("Resume %lld%%", Int((resumeProgress * 100).rounded())))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Brand.accent, in: Capsule())
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .id(episode.id)
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu {
            if episodeLabels[episode.id] != nil { Text(episode.name) }
            if saved == nil || saved?.status == .failed {
                Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                    DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode, origin: client.origin),
                                                    title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                }
            } else if let saved {
                Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                    DownloadLibrary.shared.remove([saved.id])
                }
            }
        }
    }

    private var allEpisodes: some View {
        let items = activeEpisodes
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    watchLines
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], spacing: 8) {
                        ForEach(shownOrder(items)) { watchEpisodeCard($0, fill: true) { showsAllEpisodes = false } }
                    }
                }
                .padding(16)
            }
            .navigationTitle(L10n.text("Episodes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { episodeOrderButton }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showsAllEpisodes = false } }
            }
        }
        .environment(\.glassControls, true)
        // A phone held upright wants the half-height sheet so the picture stays in view above it.
        // On the Duo's inner display the page is already two columns with the episode list at the
        // right, so a half sheet would only cover the picture and the recommendations below — open
        // full-height there instead.
        //
        // For a short list (a single-season title with a handful of episodes) a half sheet leaves a
        // tall band of empty glass under two tiles, which reads as a broken, sparse panel. Size the
        // sheet to its content in that case, so the panel hugs the lines + tiles instead of floating
        // over a blank sheet.
        .presentationDetents(duoExpanded
                             ? [.large]
                             : (items.count <= 6 ? [.height(320), .large] : [.medium, .large]))
    }
    #endif
}

#if os(iOS)
/// iPhone: a video's page is a watch page, its player at the top (`VideoDetailView`). iPhone Duo's inner
/// display (regular both ways) keeps the watch page too — it is still a phone (`idiom == .phone`), and it
/// folds back to the compact outer screen, so the playback page must survive the fold. Only a real iPad
/// (`idiom == .pad`) takes the tablet's plain detail page.
enum WatchPage {
    @MainActor static func applies(_ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}

/// A swipe from the left edge goes back, as on any pushed page: hiding the navigation bar turns that gesture off.
/// It also comes before the picture's slide-to-seek and the episode row's scrolling, which would otherwise take a
/// swipe that starts at the edge.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    /// Off in Full Screen, where the swipe would leave the page, and on a folded-out Duo, where the page keeps
    /// its own navigation bar (and the system sidebar owns the left edge).
    var enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enabled = enabled }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = true {
            didSet { if enabled != oldValue { apply(animated: false) } }
        }
        private weak var recognizer: UIGestureRecognizer?
        private weak var previous: UIGestureRecognizerDelegate?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // The swipe already under way goes on; other pages get the system's own rules back.
            disarm()
        }

        /// Only the immersive (enabled) page hides the navigation bar and arms the edge swipe. On a folded-out
        /// Duo the page keeps its nav bar and tab bar for an explicit way back, so this must not hide the bar —
        /// doing so left the expanded page with neither a back button nor a working swipe.
        private func apply(animated: Bool) {
            guard isViewLoaded, view.window != nil else { return }
            if enabled {
                // Pushed from a search field still active (after Search was pressed), the bar the page hides
                // stayed, and its Back showed over the page's own.
                if navigationController?.isNavigationBarHidden == false {
                    navigationController?.setNavigationBarHidden(true, animated: animated)
                }
                arm()
            } else {
                disarm()
            }
        }

        /// Again after a swipe that was let go halfway, which brings the page back.
        private func arm() {
            guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate !== self else { return }
            recognizer = pop; previous = pop.delegate
            pop.delegate = self; pop.isEnabled = true
        }

        private func disarm() {
            if let recognizer, recognizer.delegate === self { recognizer.delegate = previous }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            enabled && (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            enabled && other is UIPanGestureRecognizer
        }
    }
}
#endif

extension PlaybackHistoryEntry {
    /// The watched title as a list card, to open its page with.
    var listVideo: Video {
        Video(id: context.videoID, name: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
    }
}

private struct PlaybackIssue {
    let episode: Episode
    let message: String
    let drive: CloudDrive?
    /// True when playback was not attempted because a required account is missing.
    let blockedBeforeRequest: Bool
    /// A sign-in the source's CatPawOpen bundle runs itself (`CatPawSignIn.provider(for:)`).
    var signIn: String? = nil
}

private struct BundleSignIn: Identifiable {
    let provider: String
    var id: String { provider }
}

/// Cloud drives whose plugins need a saved login before they can return a stream.
private enum CloudDrive: String, Identifiable {
    /// Xunlei's sign-in is only for CatPawOpen bundles, which say when it is missing; other sources play their Xunlei
    /// lines without it, so those lines are never held back for it. Baidu comes only from a plugin's error
    /// (`CloudDriveLoginRequired`), never from a line's name: other plugins sign in to it with their own code.
    case quark, uc, xunlei, baidu
    var id: String { rawValue }
    /// FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC.
    init?(flag: String) {
        let text = flag.lowercased()
        if text.contains("夸克") || text.contains("夸父") || text.contains("quark") { self = .quark }
        else if text.hasPrefix("uc") || text.contains("uc网盘") || text.contains("优汐") { self = .uc }
        else if text.contains("迅雷") || text.contains("xunlei") { self = .xunlei }
        else { return nil }
    }
    /// Lines from drives that sign in through the plugin's own QR code (FTY's 嘟嘟 is Baidu, 阿狸 is
    /// Aliyun). They ask for a scan the first time, so they never start a title on their own.
    static func withoutSignIn(_ flag: String) -> Bool {
        let text = flag.lowercased()
        return ["嘟嘟", "百度", "度盘", "baidu", "阿狸", "阿里", "aliyun"].contains { text.contains($0) }
    }
    /// The first line that can play now: not from a drive without a sign-in, nor one whose sign-in is missing.
    static func preferredFlag(_ flags: [String]) -> String? {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        return flags.first { flag in
            if withoutSignIn(flag) { return false }
            guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return true }
            let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
            return !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .xunlei: L10n.text("Xunlei")
        case .baidu: L10n.text("Baidu Netdisk")
        }
    }
    var signInTitle: String {
        switch self {
        case .quark: L10n.text("Sign In to Quark")
        case .uc: L10n.text("Sign In to UC")
        case .xunlei, .baidu: L10n.text("Sign In to %@", name)
        }
    }
    #if os(macOS)
    var provider: CloudProvider { self == .quark ? .quark : .uc }
    #else
    var qrDrive: CloudDriveQRLogin.Drive { self == .quark ? .quark : self == .baidu ? .baidu : .uc }
    var webSignIn: WebSignIn { self == .quark ? .quark : self == .baidu ? .baidu : .uc }
    #endif
    var loginHint: String { L10n.text("This source plays from %@ and needs you to sign in first.", name) }
    var expiredHint: String { L10n.text("Your %@ sign-in is missing or has expired. Sign in again to play this episode.", name) }
    static func missingLogin(forFlag flag: String) -> CloudDrive? {
        guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return nil }
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
        return cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? drive : nil
    }
    static func isLoginFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["授权", "登录", "扫码", "cookie", "login", "unauthorized"].contains { text.contains($0) }
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
private struct EpisodeRow: View {
    let name: String
    /// The episode's short label (第1集), shown in place of the name; the size tag stays as detail.
    var label: String? = nil
    let loading: Bool
    var download: DownloadItem? = nil
    let action: () -> Void
    @State private var hovering = false
    static func split(_ name: String) -> (title: String, detail: String?) {
        if let match = name.firstMatch(of: /^\s*\[([^\]]+)\]\s*(.+)$/) { return (String(match.2), String(match.1)) }
        return (name, nil)
    }
    static func title(_ name: String) -> String { split(name).title }
    /// Row type and height per platform: a Mac list size is unreadable from a sofa.
    private static var metrics: (text: CGFloat, icon: CGFloat, height: CGFloat, inset: CGFloat) {
        #if os(tvOS)
        (28, 18, 42, 0) // GlassRowStyle adds its own padding and focus glass
        #elseif os(iOS)
        (15, 11, 44, 14)
        #else
        (13, 10, 36, 12)
        #endif
    }
    private var parts: (title: String, detail: String?) {
        let parts = Self.split(name)
        return (label ?? parts.title, parts.detail)
    }
    var body: some View {
        let parts = parts
        let button = Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "play.fill").font(.system(size: Self.metrics.icon)).foregroundStyle(hovering ? .primary : .tertiary) }
                }
                .frame(width: Self.metrics.icon + 6)
                Text(parts.title).font(.system(size: Self.metrics.text, weight: loading ? .semibold : .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let detail = parts.detail {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                if let download { DownloadState(item: download) }
            }
            .padding(.horizontal, Self.metrics.inset).frame(minHeight: Self.metrics.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(loading ? 0.12 : (hovering ? 0.08 : 0.04)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        #if os(tvOS)
        button.glassRow()
        #else
        button.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }
}

private struct DownloadLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}

/// Gives its one subview at least `minHeight`, even in a scroll view, where `frame(minHeight:)`
/// leaves the content at its ideal height and spacers inside it never grow.
private struct MinHeightLayout: SwiftUI.Layout {
    var minHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: max(size.height, minHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
