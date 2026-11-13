//
//  VideoTasks.swift
//  映匣 / Mi3s
//
//  「多任务播放」—— 应用内可以同时挂着**多个**迷你播放器。
//
//  为什么不能继续只用一个 `store.playing`
//  --------------------------------
//  上游（以及本仓此前的二开）把「在播的那一集」写成一个单值 `store.playing`，配一个
//  单槽会话 `activeSession`。那套结构只能表达「一集在前台播、缩成小窗后仍只有它」。
//  用户这次的要求是另一件事：
//
//    · 长按海报「直接迷你播放器打开播放」，并且**不影响已有的已打开迷你播放器**；
//    · 迷你播放器可以同时存在多个，随时选择回到哪一个。
//
//  单值状态在结构上无法表达「同时两集在跑」，所以这里引入 `VideoTaskCenter`：
//  每个迷你播放器 = 一个 `VideoTask`（自己的 `PlaybackSession`、自己的频道，以及
//  「点一下回到那一集的选集页」所需的视频/源句柄）。
//
//  与 `store.playing` 的分工（**这条不搞清楚会互相踩**）
//  --------------------------------
//  · `store.playing` / `store.playbackSession(for:)` 仍然是**前台**那一集（观看页、
//    全屏播放器）。前台只能有一个，这是 iOS 的呈现现实。
//  · `VideoTaskCenter.tasks` 是**坞里**的那些。坞里可以有很多个。
//  · 两者互斥：一集要么在前台、要么在坞里。`promote` 把坞里的挪到前台，
//    `dock` 把前台的挪进坞里 —— 都只在各自那一侧增删，绝不两边同时存在，
//    否则返回时会出现「同一集被停两次」或「同一集被恢复成两集」。
//
//  音频
//  --------------------------------
//  多个 `AVPlayer` 同时出画面是允许的，但**同时出声音是噪音**。坞里只有正在被操作的
//  那一个（`activeTaskID`，默认最近加入的）出声，其余一律 `isMuted = true`。
//  用户点了别的卡片，它就变成出声的那一个。
//

import AVKit
import SwiftUI
import TVCore

// MARK: - 一次播放任务

/// 坞里的一个迷你播放器：一集正在播的视频，连同「回到它」所需的全部句柄。
@MainActor @Observable final class VideoTask: Identifiable {
    let id = UUID()
    /// 正在播的这一集。
    private(set) var channel: Channel
    /// 它自己的播放会话。坞里的任务**不走** `store.playbackSession(for:)`：
    /// 那个单槽是前台专用的，混用会互相顶掉。
    let session: PlaybackSession
    /// 点卡片回到选集页要用的视频与源。云文件 / 直播这类没有详情页的留空，
    /// 点卡片时退回全屏播放器。
    let video: Video?
    let client: CatalogClient?
    /// 这一路自己的「当前作品」。
    ///
    /// ⛔ 必须自带，不能读 `store.playbackCatalog`。
    ///
    /// 那个是 **Store 上的单值**：坞里再起播第二部剧时 `remember()` 会把它整个覆盖掉。
    /// 于是第一部剧那张卡片的自动连播（`nextEpisode(after:)` → `catalog(for:)` 按 scope
    /// 比对返回 nil）就再也找不到下一集 —— 表现为「坞里只有一个任务时能自动连播，
    /// 挂上第二个之后第一个就停在最后一集不动了」。
    ///
    /// 这也是「互顶」的一种：不是画面被抢，是**功能被抢**。
    /// 自动连播换了下一集时随之更新（见 `move(to:episode:)`）。
    private(set) var catalog: PlaybackCatalog?
    /// 云文件目录（只有从「文件」页起播的任务才有）。
    ///
    /// ⛔ 必须随任务携带，不能读 `store.filesFolder` —— 那是单值，坞里同时播两个
    /// 不同目录里的文件时，它只指向最后开始的那一个，另一个的「下一集」就会算不出来
    /// （或算到别人的目录里去）。`Store.file(_:from:in:)` 有三重比对兜底，
    /// 拿错目录只会返回 nil，不会串片。
    private(set) var filesFolder: CloudFilesFolder?
    /// **这一张卡片自己的声音设定**；nil = 跟随设置里的全局档位。
    ///
    /// 用户要求「在迷你播放器的窗口上可以单独做声音设定」：坞里挂着几个任务时，
    /// 可能只想要其中一个大声、另一个彻底静音、第三个跟全局走。
    /// 全局那三档（静音/只有当前/背景/均分）是「一把尺子」，做不到逐卡控制。
    ///
    /// 存成可选而不是给个默认值：**「没设过」与「设成跟随」是两件事** ——
    /// 用户没动过这一张时，改全局设置应当立刻生效；一旦他在卡片上动过，
    /// 就不该被全局设置覆盖。
    var audioOverride: DockTaskAudio?
    /// 加进坞的时刻，用来排序（新的在前）。
    let createdAt = Date()

    init(channel: Channel, session: PlaybackSession, video: Video?, client: CatalogClient?,
         catalog: PlaybackCatalog? = nil, filesFolder: CloudFilesFolder? = nil) {
        self.channel = channel
        self.session = session
        self.video = video
        self.client = client
        self.catalog = catalog
        self.filesFolder = filesFolder
    }

    /// 自动连播换了下一集：频道与作品目录一起前进，会话不变（同一个 `AVPlayer`，只换 item）。
    ///
    /// `catalog` 也要更新：跨集后 `scope` 已变（`PlaybackHistoryContext.id` 按集算），
    /// 不更新就会拿旧 scope 去比对，`nextEpisode` 依然返回 nil。
    func move(to channel: Channel, catalog: PlaybackCatalog? = nil) {
        self.channel = channel
        if let catalog { self.catalog = catalog }
    }

    /// 卡片第一行：作品名。
    var title: String { channel.historyContext?.videoName ?? channel.name }
    /// 卡片第二行：集名；单集片与作品同名时留空，免得两行一模一样。
    var subtitle: String {
        guard let context = channel.historyContext else { return "" }
        return context.episodeName == context.videoName ? "" : context.episodeName
    }

    /// 从**本任务自己的**作品目录算下一集。
    ///
    /// 与 `Store.nextEpisode(after:)` 的差别只有一处：那个读 Store 上的单值
    /// `playbackCatalog`，坞里存在第二个任务时它已被覆盖，`catalog(for:)` 按 scope
    /// 比对会返回 nil，于是这一路永远没有下一集。这里读任务自带的目录，彼此独立。
    var nextEpisode: Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog?.playlist.next(after: context)
    }

    /// 这一路在云文件目录里的下一集（`offset` = ±1）。
    ///
    /// 目录由任务自己带着 —— 坞里两个不同目录的文件各算各的，不会串。
    /// 这不是个复制的清单遍历：三重比对（`drive.key` / `folder.id` / 文件名都在同一个
    /// context 里）保证拿错目录只会返回 nil，绝不会播到别的目录里的片子。
    func cloudFileStep(_ offset: Int) -> Channel? {
        guard let context = channel.historyContext, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        let file = folder.files[index + offset]
        return CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name,
                                  subtitles: folder.subtitles)
    }

    /// 一次播放的作品目录 scope（与 `PlaybackHistoryContext.id` 同一算法）。
    ///
    /// 必须与 `Channel.historyContext.id` 逐字相同，否则 `playlist.next(after:)`
    /// 找不到当前集、`catalog(for:)` 也按 scope 比对失败。
    static func scope(for channel: Channel, video: Video, client: CatalogClient) -> String {
        EpisodeSkipSettings.scope(origin: client.origin, source: client.site.sourceKey, video: video.id)
    }

    /// 两个任务是不是「同一部剧的同一集」。
    ///
    /// 按 `historyContext`（作品 scope + 集 id）判，**不按 URL**：换线路后同一集的
    /// `url` 会变，但作品与集都没变 —— 那种情况该就地激活，不该留两张卡。
    /// 云文件 / 直播 / 手填地址没有 `historyContext`，只能退回按 `Channel` 整体比较
    /// （它们的 URL 就是身份，同一地址重复挂确实应该合并）。
    func isSameEpisode(as other: VideoTask) -> Bool {
        if let mine = channel.historyContext, let theirs = other.channel.historyContext {
            return mine.id == theirs.id && mine.episodeID == theirs.episodeID
        }
        return channel == other.channel
    }

    var isPaused: Bool { session.paused }
    var isLoading: Bool { session.loading }

    /// 卡片画面比例取**实际画面**：唯一真源仍是 `presentationSize`，
    /// 但必须读 `session.presentationAspect` 这个**可观察镜像**。
    ///
    /// ⛔ 原来直接读 `session.player.currentItem?.presentationSize` —— 那是普通属性，
    /// 不是 SwiftUI 可观察源：源比例就绪后卡片**不会重算**，一直按回退值 16/9 排版。
    /// 竖屏源（9:16）于是被排成扁条，画面 `resizeAspect` 居中 ⇒ 左右留白，
    /// 正是用户报的「竖屏源小窗缩到最小右侧有白边」。
    /// 镜像由 `PlaybackSession.updateSkipping(_:)` 每采样 tick 同步。
    var aspectRatio: CGFloat {
        let r = DockCardAspect.resolved(session.presentationAspect)
        #if DEBUG
        // 探针（真机判据）：卡片实际拿去算高度用的比例，与它读到的镜像值。
        // #16 的缺陷形态是「取数方式两种」——`fraction` 读 @Observable（会刷新），
        // `aspectRatio` 过去读 `AVPlayerItem.presentationSize`（普通属性、不刷新），
        // 于是竖源永远停在回退 16/9、卡片按横比例量高，右侧留白。
        // 真机验收：竖源（nat=1080x1920）时 resolved 必须 ≈0.5625 而不是 1.7778；
        // 且换集期间不得跳回 fallback（`from()` 返回 nil 时保留上次好值）。
        oneSkinLog("DOCKASPECT mirrored=\(String(format: "%.4f", session.presentationAspect)) "
            + "resolved=\(String(format: "%.4f", r)) fallback=\(r == DockCardAspect.fallback)")
        #endif
        return r
    }

    /// 播放进度（0…1），卡片底边那条细线用。
    var fraction: Double {
        guard session.duration > 0 else { return 0 }
        return min(max(session.position / session.duration, 0), 1)
    }
}

// MARK: - 坞

/// 所有迷你播放器。作为 `Store` 主类的一个 stored property 存在
/// （Swift 的 extension 不能加存储属性，见项目铁律第一条）。
@MainActor @Observable final class VideoTaskCenter {
    /// 坞里的播放器，新的在前。
    private(set) var tasks: [VideoTask] = []
    /// 正在出声的那一个。`nil` 表示坞是空的。
    private(set) var activeTaskID: UUID?

    /// 坞里最多挂几个。
    ///
    /// 取值统一到 `PlaybackCapacity.dock`（Sources/TVCore/PlaybackCapacity.swift）。
    /// 原先是这里的字面量 4，而底层各路流存储各自写死 3/4 个槽位，两边没有任何联动 ——
    /// 「坞 4 + 前台 1 = 5」必然逐出**正在播**的那一路，正是用户报的「互顶」。
    /// 现在上限只有一个真源，流槽位由它推导（= (坞 + 前台) × 2）。
    static var capacity: Int { PlaybackCapacity.dock }

    var hasTasks: Bool { !tasks.isEmpty }
    var activeTask: VideoTask? { tasks.first { $0.id == activeTaskID } }

    // MARK: 增删

    /// 放一个任务进坞。**不碰前台** —— 这是「不影响已有的已打开迷你播放器」的落点。
    @discardableResult
    func add(_ task: VideoTask) -> VideoTask {
        // 同一集已经在坞里：不重复挂，激活并返回。长按同一个海报两次很常见。
        //
        // ⛔ 去重键不是 `Channel == Channel`。那个比较含 `url`（`Channel.id` 就是
        // `group|name|url`），而**同一集换一条线路 url 就变了** —— 于是「第一集看的是
        // 高清线，换到流畅线再长按一次」会在坞里留下两张其实同一集的卡片。
        // 正确的键是「哪一部剧的哪一集」：`historyContext.id`（scope）+ `episodeID`。
        // 云文件 / 直播没有 `historyContext`，退回按 `Channel` 整体比较。
        if let existing = tasks.first(where: { $0.isSameEpisode(as: task) }) {
            activate(existing.id)
            task.session.stop()
            return existing
        }
        tasks.insert(task, at: 0)
        activate(task.id)
        trim()
        return task
    }

    func remove(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: index)
        task.session.stop()
        if activeTaskID == id { activeTaskID = tasks.first?.id }
        applyMuting()
    }

    func removeAll() {
        for task in tasks { task.session.stop() }
        tasks.removeAll()
        activeTaskID = nil
    }

    /// 把**某一集**从坞里摘掉（若有）。
    ///
    /// 与 `removeAll()` 的区别：那个清空整个坞，这个只摘这一集，别的卡片不受影响。
    /// 供「退出键 = 彻底退出那个视频」用（`Store.quitPlayback`）——
    /// 用户点了退出，那一集就不该留在坞里继续播。
    func removeAll(of channel: Channel) {
        let doomed = tasks.filter { $0.channel == channel }
        guard !doomed.isEmpty else { return }
        for task in doomed {
            if activeTaskID == task.id { activeTaskID = nil }
            tasks.removeAll { $0.id == task.id }
            task.session.stop()
        }
        if activeTaskID == nil { activeTaskID = tasks.first?.id }
        applyMuting()
    }

    /// 点卡片：这一个开始出声，其余静音。
    func activate(_ id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        activeTaskID = id
        applyMuting()
    }

    private func trim() {
        while tasks.count > Self.capacity {
            tasks.removeLast().session.stop()
        }
        if let active = activeTaskID, !tasks.contains(where: { $0.id == active }) {
            activeTaskID = tasks.first?.id
        }
        applyMuting()
    }

    /// 按设置里的策略分配声音（`DockAudioPolicy`）。
    ///
    /// 三种策略都在这里落地，**只有这一处**改音量/静音 —— 分散到各个调用点必然走散。
    ///
    /// `focused`（默认）用 `isMuted`：静音是确定生效的，不依赖 `volume`。
    /// `dimmed` / `mixed` 用 `volume`，同时确保非活跃的不被上一轮的 `isMuted` 卡住。
    /// 按「卡片自己的设定 → 全局档位」算出每一张该出的声，**只有这一处**改音量/静音。
    ///
    /// 分散到各个调用点必然走散 —— 之前就是这样：策略从「只有当前」切到「背景」时，
    /// 上一轮留下的 `isMuted` 没被还原，那几路会永远静音（用户改了设置却听不到变化）。
    /// 所以这里每轮都把 `isMuted` 与 `volume` **一起重算**，不依赖上一次的状态。
    ///
    /// 逐卡设定优先于全局：见 `DockAudioPolicy.output(isActive:taskIndex:taskCount:override:)`。
    func applyMuting() {
        let policy = DockAudioPolicy.current
        let count = tasks.count
        for (index, task) in tasks.enumerated() {
            let output = policy.output(isActive: task.id == activeTaskID,
                                       taskIndex: index, taskCount: count,
                                       override: task.audioOverride)
            let player = task.session.player
            player.isMuted = output.isMuted
            // ⛔ 不要用 `player.volume` 做用户音量滑块。
            //
            // Apple 在 SDK 头文件 `AVPlayer.h` 里写得很直接：
            //   「iOS note: Do not use this property to implement a volume slider
            //     for media playback. … This property is most useful on iOS to control
            //     the volume of the AVPlayer relative to other audio output,
            //     not for volume control by end users.」
            // 而 `isMuted` 的注释是「Only affects audio muting for the player instance」——
            // 两条不同通道，这正是实测「静音生效、音量不生效」的原因。
            //
            // 真要按用户值改音量只能走 `AVAudioMix`：
            // `AVMutableAudioMixInputParameters.setVolume(_:at:)` 是**解码后的增益**，
            // 不受系统音量耦合影响。见 `DockTask.audioMix`。
            task.session.player.volume = 1
            task.session.applyAudioGain(output.volume)
        }
    }

    /// 单独设定某一张卡片的声音；`nil` = 恢复跟随全局档位。
    ///
    /// 改完立刻重算 —— 否则用户拖完滑杆要等下一次「切活跃卡片」才听得到变化。
    func setAudio(_ audio: DockTaskAudio?, for id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        task.audioOverride = audio
        applyMuting()
    }

    // MARK: 起播

    /// 直接以迷你播放器打开一部作品（长按海报的「迷你播放器播放」）。
    ///
    /// 与「进详情页再点播放」只差一点：**它不动前台**。前台可能正有一集在看，
    /// 这个新任务只在坞里起播，用户回到那一集时它是完好的。
    ///
    /// 起哪一集：看过就接上次那集，没看过就第一集 —— 与详情页「继续播放」同一取舍，
    /// 免得同一部剧两个入口从不同集开始。
    func start(video: Video, client: CatalogClient, store: Store) async {
        guard let episode = startingEpisode(video, client: client, store: store) else {
            store.notice = L10n.text("This title has no episodes to play.")
            return
        }
        do {
            let resolved = try await client.playback(episode)
            guard !Task.isCancelled else { return }
            let channel = store.catalogChannel(resolved, video: video, episode: episode, client: client)
            let session = PlaybackSession()
            session.history = store.playbackHistory
            session.skipDefaults = store.playbackDefaults
            session.player.isMuted = true
            // ⛔ 作品目录随任务携带，不读 `store.playbackCatalog`（那是单值，会被
            // 坞里后来起的另一部剧覆盖，见 `VideoTask.catalog` 的注释）。
            let catalog = PlaybackCatalog(video: video, client: client,
                                          scope: VideoTask.scope(for: channel, video: video, client: client))
            let task = add(VideoTask(channel: channel, session: session, video: video, client: client, catalog: catalog))
            // 已经在坞里（同一集挂过一次）：上面那次 `add` 已经把它激活，会话收掉了，这里不再起。
            guard task.session === session else { return }
            startCatalogPlayback(session, channel: channel, store: store)
            // 自动连播在坞里也照旧：换集只换频道，会话（同一个 AVPlayer）不变。
            //
            // ⛔ 下一集**从本任务自己的目录算**，不走 `store.nextEpisode` ——
            // 那条路依赖 Store 上的单值 `playbackCatalog` / `filesFolder`，坞里多任务时
            // 会被别的剧/别的目录覆盖，于是只有「坞里唯一一个任务」时才连播得动，
            // 这正是用户说的互顶（功能被抢，不是画面被抢）。
            session.onPlaybackEnded = { [weak store, weak session, weak task] in
                guard let store, let session, let task, store.autoPlayNext else { return }
                // 云文件目录：同一目录里的下一个文件，直接起播（不用向源解析地址）。
                if let nextFile = task.cloudFileStep(1) {
                    task.move(to: nextFile)
                    session.start(nextFile)
                    return
                }
                // 点播源：下一集要向源重新解析地址。
                // `client` 从**任务**取，不从闭包捕获时的参数取 —— 换源后任务上的
                // client 才是当前有效的那一个（`sourceReassignment` 会换掉它）。
                guard let video = task.video, let source = task.client, let next = task.nextEpisode else { return }
                Task { @MainActor in
                    guard let nextResolved = try? await source.playback(next) else { return }
                    let nextChannel = store.catalogChannel(nextResolved, video: video, episode: next, client: source)
                    task.move(to: nextChannel,
                              catalog: PlaybackCatalog(video: video, client: source,
                                                       scope: VideoTask.scope(for: nextChannel, video: video, client: source)))
                    session.start(nextChannel)
                }
            }
            applyMuting()
        } catch {
            guard !(error is CancellationError) else { return }
            Diagnostics.shared.failure("tasks", "dock play \(client.reportContext) episode=\(episode.flag)", error)
            store.error = L10n.text("Unable to play this title: %@", error.localizedDescription)
        }
    }

    /// 长按海报起播用哪一集：上次看到的那一集，否则第一集。
    private func startingEpisode(_ video: Video, client: CatalogClient, store: Store) -> Episode? {
        let scope = EpisodeSkipSettings.scope(origin: client.origin, source: client.site.sourceKey, video: video.id)
        let watched = store.visibleHistory.first { $0.context.id == scope && !$0.completed }
        if let watched, let episode = watched.context.episode(in: video.episodes) { return episode }
        return video.episodes.first
    }

    // MARK: 与前台之间搬家

    /// 前台那一集收进坞（观看页「返回上一层」/ 小窗键）。
    ///
    /// `session` 是前台正在用的那一个：**原样搬进坞**，不重建。重建会重新取流、
    /// 从零加载，用户看到的是「返回一下，进度条跳回开头」。
    @discardableResult
    func dock(channel: Channel, session: PlaybackSession, store: Store) -> VideoTask {
        // 作品目录随任务带走。`store.catalog(for:)` **按 scope 比对**，只在「它就是当前
        // 这一集的作品」时给得出东西 —— 正好是我们需要的。
        //
        // ⛔ 取不到就留空，**绝不回退到 `store.playbackCatalog`**：那个单值此刻可能
        // 属于坞里另一部剧（坞里起播第二部剧时 `remember()` 会覆盖它）。拿错目录的后果
        // 比没有目录严重得多 —— 这一路会在剧终时自动连播到**另一部剧**的下一集。
        let catalog = store.catalog(for: channel)
        return add(VideoTask(channel: channel, session: session,
                             video: catalog?.video, client: catalog?.client, catalog: catalog,
                             filesFolder: store.filesFolder))
    }

    /// 坞里的那一个回到前台，返回它的视频/源句柄；没有详情页的（云文件、直播）返回 nil，
    /// 调用方据此退回全屏播放器。
    ///
    /// 会话**原样交回**前台（`store.adoptSession`），不新建 —— 否则回到选集页会重新起播。
    @discardableResult
    func take(_ id: UUID, store: Store) -> (video: Video, client: CatalogClient)? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let task = tasks[index]
        tasks.remove(at: index)
        if activeTaskID == id { activeTaskID = tasks.first?.id }
        applyMuting()

        // ⛔ 摘掉坞期间挂上的自动连播回调，交给前台重新接。
        //
        // 坞里那段 `onPlaybackEnded` 是闭包捕获了**坞那一侧**的状态（`task` / `client`），
        // 它会在剧终时把 `task.move(to:)` 与 `session.start()` 又跑一遍 —— 而这一集此刻
        // 已经回到前台、由观看页的 `startCatalogPlayback` 管。两套回调同时挂着，
        // 集末会**各起一次**，表现为「最后两集来回跳」。
        // 观看页拿到会话后会自己 `startCatalogPlayback` 重绑这一组回调。
        task.session.onPlaybackEnded = nil
        // 回到前台就是唯一的那一路：静音与音量都要还原。
        // 只清 `isMuted` 不清 `volume` 的话，`.dimmed` / `.mixed` 策略下
        // 回到选集页的那一集音量会停在 0.15 或均分值（用户觉得「声音变小了」）。
        //
        // ⛔ 「卡片上单独设过静音」也必须在这里清掉。
        // 那是**坞里那张卡片**的设定，不是「这一集永久静音」——
        // 用户点回选集页是明确要去看它，结果发现没声音，只会认为播放器坏了。
        // 覆盖值随任务一起丢弃（任务已从坞里摘除），所以只清播放器状态即可。
        task.session.player.isMuted = false
        task.session.player.volume = 1

        // 会话原样交回前台：`adoptSession` 只写那一对槽，不新建会话。
        store.adoptSession(task.session, for: task.channel)
        // ⛔ 先决定「回到哪一页」，再置 `playing`。反了就会闪一下全屏播放器。
        //
        // `store.playing` 的 didSet 会在「不在任何观看页作用域里」时把
        // `presentingPlayer = true`（见 `Store.playing` 的注释）—— 那是给
        // 「从设置页深链起播」这类路径用的兜底。坞里点卡片时：
        //   · 有详情页 → 调用方紧接着会压选集页，届时 `isWatchPageMounted` /
        //     `watchPageScopes` 才登记；didSet 那一刻还不在，于是会先把全屏播放器弹出来，
        //     下一帧再被选集页盖掉 —— 用户看到的是「点卡片闪一下播放器」。
        // 所以在赋 `playing` **之前**就把标记摆好。
        store.isWatchPageMounted = true
        store.presentingPlayer = false
        guard let video = task.video, let client = task.client else {
            // 没有详情页（云文件 / 直播）：退回全屏播放器，这是它唯一合理的去处。
            // 解掉上面那道标记，否则 `playing` 的 didSet 会以为观看页挂着、不肯弹播放器。
            store.isWatchPageMounted = false
            store.playing = task.channel
            store.presentingPlayer = true
            return nil
        }
        store.playing = task.channel
        return (video, client)
    }
}

// MARK: - 左滑返回的信号

/// 「这次返回是左滑手势」的全局信号。
///
/// 用户对选集页的返回有两种语义，必须分开（要求 4）：
///   · 返回键 / 程序化 dismiss → **关掉音频**；
///   · 左滑返回 → 画面收进迷你播放器，**继续播**。
///
/// 系统的手势 pop 不会调用 `dismiss()`，页面只在 `onDisappear` 里被动得知「我走了」，
/// 拿不到原因。所以在手势开始那一刻留一个短时标记，`onDisappear` 读它区分这两条路。
/// 用时间窗而不是布尔：布尔会被「手势取消」留下脏值，下一次正常返回就会被误判成左滑。
@MainActor enum SwipeBack {
    private static var pendingUntil = Date.distantPast
    /// 700 ms：够覆盖一次 pop 过渡（约 350 ms）加上系统延迟，又短到不会串到下一次返回。
    static func begin() { pendingUntil = Date().addingTimeInterval(0.7) }
    static var isPending: Bool { Date() < pendingUntil }
    /// QA / 诊断用：确认手势确实被识别到。
    static var lastBeginAt: Date?

    /// 全局左滑返回的总闸。选集页在全屏时关掉它 —— 全屏里左滑该由播放器自己处理，
    /// 而不是把整页弹走。由 `VideoDetailView` 在自己的全屏状态变化里写。
    static var blocked = false
}

#if os(iOS)
// MARK: - 全局左滑返回

/// 给**每一个被压栈的页面**装上左滑返回。
///
/// 为什么不能只靠系统那条手势：系统自带的边缘 pop 只在**导航栏可见**时生效，
/// 而本仓大量页面为了沉浸式版式把导航栏隐藏了（`HomeView`、`DiscoverDetailView`、
/// `SiteView`…）。那些页面一旦被压栈，左滑就完全没反应 ——
/// 用户说的「全局需要支持左滑返回」正是这件事。
///
/// 实现取舍（走过弯路，写下来免得再踩）：
///
///  · ❌ 先试的是「接管 `interactivePopGestureRecognizer` 的 delegate」。这条路有两个死结：
///    ① 系统在每次 push / pop 后会把 delegate 收回，而 UIKit **没有**公开的
///       「didShow」通知可以挂（`UINavigationController.h` 里只有 delegate 方法，
///       没有任何 Navigation 通知），重新接管只能靠 `updateUIViewController` 的偶然调用；
///    ② 与选集页那份 `EdgeSwipeBack` 装的是同一个手势，两份 representable 抢 delegate，
///       后接管的赢，行为变成「看谁后刷新」。
///  · ✅ 现在走「自建一条屏幕左缘手势」，**只在导航栏隐藏时启用**：
///    导航栏可见时系统那条本来就好用，此时我们的手势一律不识别 ——
///    这样两者永不重叠，也就不可能出现「一次滑动 pop 两层」。
///
/// 这个判据（`isNavigationBarHidden`）同时解决了两件事：
///  · 全屏播放器把整页变成沉浸态时，它的 top VC 把导航栏藏了 → 但我们有 `SwipeBack.blocked`；
///  · 设置里的子栈（导航栏可见）→ 交回系统，不重复接管。
struct GlobalSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.refresh() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var edge: UIScreenEdgePanGestureRecognizer?
        /// 这一条手势是不是**从本页面内部起手**的。
        ///
        /// ⛔ 判据不能读 `SwipeBack.isPending`（700ms 时间窗）。
        ///
        /// 那个时间窗是给「选集页区分返回/左滑」用的，语义是「刚刚发生过左滑」。
        /// 拿它当「这条手势合法吗」的门，会产生一个很硬的手感缺陷：
        /// **慢慢拖动超过 0.7 秒，松手时窗口已过期 → 永远不 pop**。
        /// 用户拖到一半屏宽、松手，页面纹丝不动。
        ///
        /// 正确做法：`gestureRecognizerShouldBegin` 通过时记下这条手势自己，
        /// `handle` 里比对是不是同一条。手势取消/重新起手都会换新实例，天然不会串。
        private weak var tracking: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            arm()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // ⛔ 不要在这里 disarm。
            //
            // 手势是装在整个 `nav.view` 上的，服务的是**这个导航栈**。
            // 每次 pop / push 各页的 representable 都会经历 viewWillDisappear，
            // 若那时摘掉，手势就在每次返回后被上一条路径带走 ——
            // 真机日志实测到成对出现：
            //   `Swipe arm SKIP navigationController==nil`  ← 被摘之后又在新页 arm，此时还没入栈
            //   `Swipe arm OK stack=2`                      ← viewDidAppear 时补上
            // 于是「返回一层后，下一次左滑失效」。
            //
            // 戴在 `nav.view` 上就该由 `nav` 的生命周期管：
            // 只有「整个栈真被扔掉」时才摘（`navigationController == nil` 且没有父）。
            if isMovingFromParent, navigationController == nil { disarm() }
        }

        func refresh() {
            // `updateUIViewController` 可能发生在入栈**之前**（SwiftUI 先建视图再交给 nav），
            // 那时 `navigationController` 还是 nil。`viewDidAppear` 会补一次，
            // 但若那一帧 SwiftUI 没再更新，就再没有补的机会。
            // 这里排一次下一 runloop 的重试，覆盖「入栈稍晚于第一帧」的时序。
            arm()
            if edge == nil {
                DispatchQueue.main.async { [weak self] in self?.arm() }
            }
        }

        private func arm() {
            // 探针：验证「左滑返回」到底有没有装上手势。
            // 用户报「没生效」，而旧实现挂在 NavigationStack 外层时 nav 恒为 nil，
            // 这条日志能一眼看出是「没装上」还是「装上了但不响应」。
            guard let nav = navigationController else {
                #if DEBUG
                oneSkinLog("Swipe arm SKIP navigationController==nil（挂错层级）")
                #endif
                return
            }
            #if DEBUG
            oneSkinLog("Swipe arm OK stack=\(nav.viewControllers.count)")
            #endif
            if let edge, edge.view === nav.view { return }
            disarm()
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.edges = .left
            recognizer.delegate = self
            nav.view.addGestureRecognizer(recognizer)
            edge = recognizer
        }

        private func disarm() {
            if let edge { edge.view?.removeGestureRecognizer(edge) }
            edge = nil
        }

        @objc private func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            #if DEBUG
            oneSkinLog("Swipe handle state=\(recognizer.state.rawValue) tx=\(Int(recognizer.translation(in: recognizer.view).x))")
            #endif
            guard let nav = navigationController, nav.viewControllers.count > 1 else { return }
            let width = nav.view.bounds.width
            guard width > 1 else { return }
            let travelled = max(0, recognizer.translation(in: nav.view).x)
            switch recognizer.state {
            case .ended:
                // 走过屏宽 30%，或者甩得够快 —— 与系统手势的手感对齐。
                let fast = recognizer.velocity(in: nav.view).x > 800
                // ⛔ 只认「这条手势是本次起手的」。不用时间窗（慢拖会被误杀）。
                guard tracking === recognizer else { return }
                tracking = nil
                // 通知选集页「这次返回来自左滑」，供它区分「退出/收进小窗」。
                SwipeBack.begin()
                SwipeBack.lastBeginAt = Date()
                if travelled > width * 0.3 || fast {
                    nav.popViewController(animated: true)
                }
            case .cancelled, .failed:
                // 手势被取消：清掉跟踪，且**不**置 `SwipeBack` 标记 ——
                // 否则一次半途而废的滑动会让紧随其后的正常返回被误判成左滑。
                if tracking === recognizer { tracking = nil }
            default:
                break
            }
        }

        /// 只在「系统那条用不上」时启用：导航栏被隐藏，且栈里不止一页，且没被全屏禁用。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard !SwipeBack.blocked,
                  let nav = navigationController,
                  nav.viewControllers.count > 1,
                  nav.isNavigationBarHidden else { return false }
            // 记下这条手势实例：`handle` 里比对它，用来判断「这次手势是合法的起手」。
            // 不用 `SwipeBack` 的时间窗 —— 那会误杀慢速拖动（见 `tracking` 的注释）。
            tracking = gestureRecognizer
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // 左滑优先于页面内的横向拖动（选集行、横向卡片流），否则边缘起手会被它们吃掉。
            other is UIPanGestureRecognizer
        }
    }
}

extension View {
    /// 在被压栈的区域根上挂一次，即覆盖该栈内所有页面。
    func globalSwipeBack() -> some View {
        background { GlobalSwipeBack().frame(width: 0, height: 0) }
    }
}
#endif

// MARK: - 海报长按（点播源 / 订阅源内）

/// 长按海报的两个动作：**直接以迷你播放器播放**、**下载**。
///
/// 为什么做成一个修饰器挂在卡片上而不是进详情页：
/// 用户要的是「不离开当前列表」——点进去再返回会丢掉列表位置与滚动状态。
/// 长按菜单天然满足这一点，而且两个动作都不动前台（要求 6 明确「不影响已有的已打开
/// 迷你播放器」）。
///
/// 平台差异（**这条曾经是个真 bug**）：
///
/// 坞（`VideoTaskDock`）与 `dockForeground()` 全部包在 `#if os(iOS)` 里。
/// 而本修饰器原来只在 tvOS 分支掉，macOS 走 `#else` 会**显示**「Play in Mini Player」菜单 ——
/// 点了会在后台起一路 AVPlayer，但 macOS 上没有坞、没有卡片、没有关闭入口。
/// 用户得到的是「有声音、找不到界面、关不掉」的幽灵播放，比不给菜单糟得多。
///
/// 所以现在**只有 iOS 挂这个菜单**（下载仍走详情页/设置里的既有路径，macOS 本来就有）。
struct CatalogPosterMenu: ViewModifier {
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// 正在为下载准备选集列表（要先去源上取详情）。
    @State private var preparing = false
    /// 取到详情后要弹的下载抽屉。
    @State private var plan: DownloadPlan?

    /// 下载抽屉要的数据。单独一个 `Identifiable` 是因为 `.sheet(item:)` 需要它。
    struct DownloadPlan: Identifiable {
        let id = UUID()
        let episodes: [Episode]
        let flag: String
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.contextMenu {
            Button {
                // 迷你播放器播放：坞里起播，前台那一集不受影响（要求 6）。
                Task { await store.videoTasks.start(video: video, client: client, store: store) }
            } label: {
                Label(L10n.text("Play in Mini Player"), systemImage: "rectangle.inset.bottomright.filled")
            }
            Button {
                Task { await prepareDownload() }
            } label: {
                Label(L10n.text("Download"), systemImage: "arrow.down.circle")
            }
            .disabled(preparing)
        }
        // 下载要整部剧的选集列表，只能先问源要详情（走缓存，通常一次就够）。
        .sheet(item: $plan) { plan in
            DownloadPicker(video: video, site: client.site, flag: plan.flag, episodes: plan.episodes,
                           origin: client.origin) { count in
                guard count > 0 else { return }
                store.notice = L10n.text("Queued %@", String(count))
            }
        }
        #else
        // macOS / tvOS：没有坞，就不给这个菜单（见类型注释里那段幽灵播放的成因）。
        content
        #endif
    }

    private func prepareDownload() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            // `cached: true`：列表页刚拉过的详情就在 MediaCache 里，别再打一次源。
            let detail = try await client.detail(video.id, cached: true)
            guard !detail.episodes.isEmpty else {
                store.notice = L10n.text("This title has no episodes to download.")
                return
            }
            // 用第一条线路，与详情页下载抽屉的默认一致。
            plan = DownloadPlan(episodes: detail.episodes, flag: detail.episodes.first?.flag ?? "")
        } catch {
            Diagnostics.shared.failure("tasks", "poster download detail \(client.reportContext) video=\(video.id)", error)
            store.error = L10n.text("Unable to load this title's episodes: %@", error.localizedDescription)
        }
    }
}

extension View {
    /// 点播源 / 订阅源里的海报：长按给出「迷你播放器播放」「下载」。
    func catalogPosterMenu(_ video: Video, client: CatalogClient) -> some View {
        modifier(CatalogPosterMenu(video: video, client: client))
    }
}

#if os(iOS)
// MARK: - 坞的界面

/// 坞里一张卡片的画面层。
///
/// 与 `PlayerLayerView` 的区别只有画中画那一段：只有**正在出声的那一张**（`pip != nil`）
/// 才把自己这块 layer 交给画中画控制器，其余一律不登记。
///
/// ⛔ 不能让每张卡片各挂一个 `PictureInPicture`。`PictureInPicture.current` 是**全局静态**
/// 的，退场裁决（`PlaybackExit` / `RootView` 的 `pipPossible`）靠它回答「现在浮着没有」。
/// 坞里挂三张卡片就三份控制器抢那一个静态量，前台的退场裁决会读到别人的控制器，
/// 于是「上滑回主界面该浮窗」变成对着一张坞卡片的 layer 去 `startPictureInPicture`。
/// 所以坞共用一个实例，只交接给当前活跃的那一张 —— 用户离开 App 时，浮起来的是
/// 他刚才在操作的那一个，语义正确。
private struct DockPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    /// 只有活跃卡片有；其余为 nil。
    let pip: PictureInPicture?
    /// 前台观看页（或全屏播放器）正在演 —— 这时坞里的画面必须完全让出 player。
    var coveredByForeground: Bool = false

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        pip?.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.videoGravity = gravity
        // 卡片刚变成活跃：把控制器的 contentSource 指到这块新 layer。
        // `attach` 内部就是这么做的（改指向、不重建控制器），见 `PictureInPicture.attach`。
        if let pip { pip.attach(view.playerLayer) }
        // ⛔ 这块 layer 什么时候**必须让出 player**。
        //
        // `AVPlayer` 同一时刻只把像素给**一个** `AVPlayerLayer`。谁最后绑上谁拿到画面，
        // 前一块的 `videoRect` 就变成 0×0 —— 表现就是「那块区域只剩底下的海报虚化」。
        //
        // 真机日志实证（`fixedLayer` 行）：
        //   展开横屏 split 下 `view=523x294 layer=523x294 videoRect=0x0`，
        //   而同一路视频在坞卡片尺寸下曾报 `videoRect=165x294` 正常。
        //   根因就是这里：坞卡片一直绑着 player，把前台观看页那块 layer 饿死成 0×0。
        //
        // 所以「让出」有两个来源，缺一不可：
        //   ① 浮窗（PiP）起着 —— 画面归系统那一层（原有逻辑）；
        //   ② **前台观看页正在演** —— 画面归页面上那块 layer（用户报的「只见海报」）。
        //      这时坞里挂着但看不见，绑着 player 只会抢画面。
        let yieldsToPiP = !(pip?.shouldRender(view.playerLayer) ?? true)
        let yieldsToForeground = coveredByForeground
        let target: AVPlayer? = (yieldsToPiP || yieldsToForeground) ? nil : player
        if view.playerLayer.player !== target { view.playerLayer.player = target }
    }
}

/// 坞里的**一张**卡片：画面 + 名字 + 播放/关闭，点一下回那一集的选集页。
struct VideoTaskCard: View {
    @Environment(Store.self) private var store
    let task: VideoTask
    let width: CGFloat
    let gravity: AVLayerVideoGravity
    /// 它是不是正在出声的那一张（其余静音，卡片描边亮起以示区别）。
    let isActive: Bool
    /// 坞共用的画中画控制器；只交给活跃的那一张。
    let pip: PictureInPicture
    /// 前台观看页在演 —— 这张卡的画面必须让出 `AVPlayer`（见 `DockPlayerLayer.updateUIView`）。
    var coveredByForeground: Bool = false
    /// **这张卡自己**的缩放。坞里多张卡各有一份，不共享 ——
    /// 用户要求「每个窗口单独调整大小」，用坞级一个 `scale` 只会整体变大变小。
    var ownScale: CGFloat = 1
    /// 这张卡捏合时回报新的 scale（由坞写回 `perCardScale[task.id]`）。
    var onScaleChange: ((CGFloat) -> Void)? = nil
    /// 这一张在坞里的**位置**与**总数**（`applyMuting` 用的是同一对值）。
    ///
    /// ⛔ 这两个数必须与 `VideoTasks.applyMuting()` 传给
    /// `DockAudioPolicy.output(isActive:taskIndex:taskCount:override:)` 的**完全一致**。
    /// 曾经这里写死 `taskIndex: 0, taskCount: 1` —— 于是卡片按「坞里只有我一路」算音量，
    /// 而实际出声按真实路数算：
    ///   · `.mixed` 下活跃那路实际是 `1/n`，卡片却显示满格；
    ///   · `.dimmed` / `.focused` 的活跃判断也按「唯一那张」算，图标随之失真。
    /// 用户看到的就是「这一张图标是静音，得按 + 才出声」——
    /// **图标说的和听到的不是一回事**，因为两处口径分叉。
    var taskIndex: Int = 0
    var taskCount: Int = 1

    private var scaledWidth: CGFloat { width * ownScale }
    private var height: CGFloat { scaledWidth / task.aspectRatio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPlayerLayer(player: task.session.player, gravity: gravity, pip: isActive ? pip : nil,
                            coveredByForeground: coveredByForeground)
                .frame(width: scaledWidth, height: height)
                .clipped()
                .overlay {
                    // 加载中：黑底 + 转圈，别让用户对着一张纯黑卡片判断「是不是卡死了」。
                    if task.isLoading {
                        ZStack { Color.black; ProgressView().tint(.white) }
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 左上角一组：播放/暂停 + 这一张的声音。
                    //
                    // 声音键放在这里（画面内、与暂停并排）而不是卡片外沿，是有意的：
                    // 它是**高频的临时操作**（切一下声音），不是破坏性的；
                    // 外沿那颗（右上）是销毁任务，两者必须在位置上分开。
                    HStack(spacing: 6) {
                        Button { task.session.togglePlayback() } label: {
                            Image(systemName: task.isPaused ? "play.fill" : "pause.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.5), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(task.isPaused ? "Play" : "Pause"))

                        DockVolumeButton(task: task, isActive: isActive,
                                         taskIndex: taskIndex, taskCount: taskCount)
                    }
                    .padding(6)
                }
                // ⛔ 退出键**不再放在画面内部**（此前是 topTrailing + 28pt 圆圈）。
                //
                // 那时它和左上角「暂停」同款同尺寸、同在画面里，用户分不清哪个是
                // 播放控制、哪个会销毁任务；视频亮色内容上 0.5 黑底也发灰看不清。
                //
                // 新设计见卡片外层的 `dockCloseButton`：贴在**卡片右上外沿**、
                // 红底 + 白 X、32pt 热区、与画面无重叠。
                // 进度细线：坞里同时挂好几个时，用户靠它一眼分清「哪个在看、看到哪」。
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Rectangle().fill(.white.opacity(0.85))
                            .frame(width: geo.size.width * task.fraction, height: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.caption.weight(.semibold)).lineLimit(1)
                if !task.subtitle.isEmpty {
                    Text(task.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.1),
                              lineWidth: isActive ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        // ── 退出键：贴在卡片**右上外沿**，不与画面重叠 ──
        //
        // 设计要点（对着旧版的问题逐条改）：
        //   ① **位置**：卡片右上角外沿（offset 半出界），不再压在视频画面上。
        //      多个卡片纵向排列时，一排红点沿右侧对齐，扫视即可定位。
        //   ② **形状/颜色**：实心红底 + 白 X。左上角「暂停」仍是黑色半透明圆。
        //      破坏性操作与播放控制在颜色上就分开，不会点错。
        //   ③ **热区 32pt**：比视觉尺寸大，拇指好按；视觉 22pt 不喧宾夺主。
        //   ④ **长按确认**：`.onLongPressGesture` 才真正销毁 —— 轻点只提示，
        //      避免误触把正在看的任务清掉（坞里可能有好几个）。
        .overlay(alignment: .topTrailing) {
            DockCloseButton { store.videoTasks.remove(task.id) }
                .offset(x: 8, y: -8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { open() }
        // ★ 每张卡**自己**可以捏合缩放。
        //
        // 用户要求：「迷你小窗每个窗口要能单独调整大小，而不是黏成一块」。
        // 手势必须挂在**卡片**上而不是坞上：挂在坞上时一次捏合会改所有卡，
        // 而 `MagnificationGesture` 的倍率是相对起手值的，多卡共用一个会互相打架。
        .simultaneousGesture(
            MagnificationGesture().onChanged { value in
                guard let onScaleChange else { return }
                onScaleChange(min(max(value, 0.6), 2.2))
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(task.title))
    }

    /// 点卡片回到**那一集的选集页**。
    ///
    /// 会话交接的顺序见 `VideoTaskCenter.take`：先 `adoptSession` 把同一个 `AVPlayer`
    /// 交给前台，再置 `playing`，最后把「压哪一页」作为请求交给自己所在分区的栈。
    private func open() {
        // ⛔ 「切声音」与「回到那一页」必须在**同一次点击**里按这个顺序做完。
        //
        // 拆成两处（卡片 `.onTapGesture{open()}` + 坞 `.simultaneousGesture{TapGesture→activate}`）
        // 时顺序不可靠：`open()` 会把这个 task 从坞里摘掉，若 `activate` 后跑，
        // 它拿到的是一个已不在坞里的 id，`activate` 的 guard 直接返回 ——
        // 结果是「点回来之后，声音留在坞里的另一张卡片上」，而用户明明点的是这一张。
        store.videoTasks.activate(task.id)
        guard let target = store.videoTasks.take(task.id, store: store) else { return }
        store.pendingTaskRoute = Route {
            AnyView(VideoDetailView(video: target.video, client: target.client))
        }
    }
}

/// **单张卡片**的声音键：点开一个滑杆 + 静音开关。
///
/// 用户要求：「在迷你播放的窗口上可以进行单独小窗的声音设定」+「还要加一档静音」。
/// 所以两件事都在这里：
///   · **静音**（`.muted`）：这一张一点声都不出，哪怕它是当前选中的那张；
///   · **音量**（`.level`）：这一张固定在一个音量，不受全局档位摆布；
///   · **跟随全局**（nil）—— 用户把它拖回默认时的状态。
///
/// 为什么用 `Menu` 而不是自己画一个浮层：菜单能拿到系统级的事件处理
/// （点外面自动关、外接键盘、VoiceOver），手搓浮层在坞这种**可拖动浮层**上
/// 容易与拖动/缩放手势打架 —— 坞的外层就挂着 `DragGesture` 和 `MagnificationGesture`。
///
/// 图标反映**当前实际状态**（不是「设定值」）：静音就显示斜杠喇叭，
/// 否则按音量显示三档之一。用户扫一眼就知道哪一张在出声。
private struct DockVolumeButton: View {
    @Environment(Store.self) private var store
    let task: VideoTask
    /// 它是不是当前选中的那一张（全局 `.focused` 下只有这张出声）。
    let isActive: Bool
    /// 这一张在坞里的位置与总数 —— **必须与 `applyMuting()` 用同一对值**，
    /// 否则图标/滑杆与实际听到的声音分叉（见 `VideoTaskCard.taskIndex` 的注释）。
    var taskIndex: Int = 0
    var taskCount: Int = 1

    /// 这一张现在**实际**的音量（0…1），用于图标分档与滑杆初值。
    ///
    /// 优先级与 `DockAudioPolicy.output` 一致：卡片设定 → 全局档位。
    private var effectiveVolume: Float {
        let out = DockAudioPolicy.current
            .output(isActive: isActive, taskIndex: taskIndex, taskCount: taskCount,
                    override: task.audioOverride)
        #if DEBUG
        // 探针（真机判据）：UI 侧算出来的音量与它用的入参。
        // #14 的缺陷形态正是「入参两套」——这里若与 applyMuting 的真实
        // index/count 不一致，图标/滑杆就会与实际听到的声音分叉。
        // 真机验收：坞里挂 2 张卡 → 日志里两张卡的 idx/count 必须分别是 0/2、1/2，
        // 且 muted 与图标一致。旧的写死版本恒为 0/1。
        oneSkinLog("DOCKVOL idx=\(taskIndex) count=\(taskCount) active=\(isActive) "
            + "muted=\(out.isMuted) vol=\(String(format: "%.3f", out.volume)) "
            + "override=\(task.audioOverride.map { "\($0)" } ?? "nil")")
        #endif
        return out.volume
    }

    /// 现在到底出不出声。`isMuted` 与 `volume == 0` 都算「不出声」——
    /// 图标要按用户听到的结果画，不能只信其中一个字段。
    private var isSilent: Bool {
        let output = DockAudioPolicy.current
            .output(isActive: isActive, taskIndex: taskIndex, taskCount: taskCount,
                    override: task.audioOverride)
        return output.isMuted || output.volume <= 0.001
    }

    private var symbol: String {
        if isSilent { return "speaker.slash.fill" }
        let volume = effectiveVolume
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Menu {
            Button {
                // 静音与「解除静音」是同一个开关的两种方向：点一下切过去。
                // 解除时回到「跟随全局」，而不是回到某个猜测的音量 ——
                // 用户没有表达过「我要 60%」，替他猜一个数只会让人莫名其妙。
                if isSilent {
                    store.videoTasks.setAudio(nil, for: task.id)
                } else {
                    store.videoTasks.setAudio(.muted, for: task.id)
                }
            } label: {
                Label(isSilent ? L10n.text("Unmute This One") : L10n.text("Mute This One"),
                      systemImage: isSilent ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }

            Divider()

            // 滑杆直接改这一张的音量。设成 `.level(...)` 就等于接管了全局档位。
            //
            // 用 `Slider` 放在菜单里：iOS 允许，且比「点几次加减」好按。
            // `step: 0.05` 让手感有一格一格的感觉，避免拖出 0.4237 这种数。
            Slider(
                value: Binding(
                    get: { Double(effectiveVolume) },
                    set: { store.videoTasks.setAudio(.level(Float($0)), for: task.id) }
                ),
                in: 0...1, step: 0.05
            ) {
                Text("Volume")
            }
            .accessibilityLabel(Text(L10n.text("Volume for this one")))

            Divider()

            Button {
                // 「跟随全局」= 清掉这一张的覆盖。必须给这个出口：
                // 否则用户单独设过之后，就再也回不到「跟着设置走」的状态。
                store.videoTasks.setAudio(nil, for: task.id)
            } label: {
                Label(L10n.text("Follow the Global Setting"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(task.audioOverride == nil)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                // 单独设过声音的那一张加一点底光：坞里几张卡片长得很像，
                // 「哪一张被单独调过」要看得出来，否则用户忘了自己改过什么。
                .overlay {
                    if task.audioOverride != nil {
                        Circle().strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                    }
                }
        }
        .accessibilityLabel(Text(L10n.text(isSilent ? "This one is silent" : "Sound for this one")))
    }
}

/// 迷你播放器的**退出键**（破坏性操作，与播放控制明显区分）。
///
/// 为什么不用普通 `Button` 直接干掉任务：
///   坞里可能同时有好几个任务（要求 5），误触一次就永久丢掉一个正在看的进度。
///   所以：**轻点 = 抖动提示**（告诉用户「这是要长按的」），**长按 = 真正销毁**。
///
/// 视觉：**用项目调色板**，不用系统红 —— 红色在 One 的暗色体系里很突兀。
///   · 底：`OneSkinPalette.button`（#4F4D4D，与「继续播放」按钮同一档）
///   · X：`OneSkinPalette.primary`（#F8F8F8）
///   · 描边：`buttonStroke`（白 16%）
/// 与左上角「暂停」的区分靠**位置**（卡片外沿）和**形状**（更小、带描边），
/// 而不是靠颜色跳出来 —— 坞是常驻浮层，不该有刺眼的红点。
private struct DockCloseButton: View {
    let action: () -> Void
    @State private var nudge = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(OneSkinPalette.primary)
            .frame(width: 20, height: 20)
            .background(OneSkinPalette.button.opacity(0.95), in: Circle())
            .overlay(Circle().strokeBorder(OneSkinPalette.buttonStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 2.5, y: 1)
            .rotationEffect(.degrees(nudge ? 8 : 0))
            .animation(.spring(response: 0.18, dampingFraction: 0.4), value: nudge)
            // 热区 32pt：视觉 20pt 不喧宾夺主，热区够拇指按
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            // ⛔ 不要再做成「长按才关」。
            //
            // 上一版是「轻点抖动提示 / 长按 0.45s 才销毁」，用户实测反馈
            // **「关闭按钮没有反应，关闭不了」** —— 因为预期就是点一下关掉。
            // 防护误触应该靠**热区做小 + 位置在卡片外沿**，不是靠隐藏单击。
            .onTapGesture {
                nudge = true
                action()
            }
            .accessibilityLabel(Text("Close"))
            .accessibilityAddTraits(.isButton)
    }
}

/// 坞本体：一列可拖动、可捏合缩放的卡片，贴在右下角。
///
/// 为什么是「一列」而不是「叠成一摞」：坞里可以同时挂多个（要求 5），一列让用户一眼
/// 看全「现在还有哪几个在看」。叠放会让上面那张的点击区盖住下面的，
/// 而这一版的诉求正是「随时选择回到哪一个」。
struct VideoTaskDock: View {
    @Environment(Store.self) private var store
    let gravity: AVLayerVideoGravity
    let pip: PictureInPicture
    /// 前台观看页在演 —— 坞里所有卡的画面都让出 `AVPlayer`（见 `DockPlayerLayer`）。
    var coveredByForeground: Bool = false
    /// **每张卡各自的缩放**（键是 `VideoTask.id`）。缺省 1。
    @State private var perCardScale: [UUID: CGFloat] = [:]
    /// **每张卡各自的位置**（相对右下角的偏移）。缺省 `.zero`。
    ///
    /// ⛔ 这是用户报的「拉着一个走，另外一个也走」的根因：
    /// 原来 `offset` 是坞级一个 `@Binding`，挂在包住所有卡的 `VStack` 上，
    /// 一拖就是整列一起动。现在位置按 `task.id` 分开存，每张卡只动自己。
    @State private var perCardOffset: [UUID: CGSize] = [:]
    /// 拖动中的累计量。`DragGesture.translation` 是**相对起手的累计**，
    /// 直接当位置用会让卡片每帧累加、越拖越远；这里用差分量补正。
    @State private var lastDrag: [UUID: CGSize] = [:]
    /// 坞整体的位置（没有卡片自己的偏移时作起点）。由 `RootView` 持有以便换形态重钳。
    @Binding var offset: CGSize
    /// 坞整体缩放（仅作**基础宽度**；单卡缩放另算，见 `perCardScale`）。
    @Binding var scale: CGFloat

    var body: some View {
        GeometryReader { geo in
            if !store.videoTasks.tasks.isEmpty {
                let landscape = geo.size.width > geo.size.height
                let baseWidth = landscape ? min(geo.size.width * 0.34, 320) : min(geo.size.width * 0.62, 240)
                // ⛔ 不要再用「多张就整体缩到 72%」。
                //
                // 用户明确要求：「迷你小窗每个窗口要能单独调整大小，而不是黏成一块」。
                // 原来这里是坞级一个 `packed` 系数，所有卡片共用一个 `width` ——
                // 改大小只能整列一起变，且多张时被强制压到 72%，视觉上就「黏成一块」。
                // 现在每张卡有自己的 `perCardScale`，坞只提供「基础宽度」。
                let width = min(max(baseWidth * scale, 120), geo.size.width - 24)
                // ★ 每张卡是**独立的浮窗**，不是一个列表里的行。
                //
                // 用户的诉求原话：「迷你小窗每个窗口要能单独调整大小，而不是黏成一块」、
                // 「我拉着一个走，另外一个也走，缩放一个另外一个也缩放」。
                // 所以这里不再用 `VStack` 排成一列 —— 那样天然共享父级 offset/手势。
                //
                // 现在：`ZStack` 里每张卡各自 `.offset(自己的位置)`、各自带
                // `DragGesture` 与 `MagnificationGesture`，位置与大小都按 `task.id` 分开存。
                // 初次出现时给一个错开的默认落点（右下角往上排），之后完全由用户摆布。
                ZStack(alignment: .bottomTrailing) {
                    ForEach(Array(store.videoTasks.tasks.enumerated()), id: \.element.id) { index, task in
                        let slot = CGSize(width: 0, height: -CGFloat(index) * (width * 0.78 + 12))
                        VideoTaskCard(task: task, width: width, gravity: gravity,
                                      isActive: task.id == store.videoTasks.activeTaskID, pip: pip,
                                      coveredByForeground: coveredByForeground,
                                      ownScale: perCardScale[task.id] ?? 1,
                                      onScaleChange: { perCardScale[task.id] = $0 },
                                      taskIndex: index,
                                      taskCount: store.videoTasks.tasks.count)
                            .offset(perCardOffset[task.id] ?? slot)
                            .gesture(
                                // 只挪这一张。`translation` 是相对**起手点**的累计量，
                                // 必须叠加到已有位置上，否则松手前一拖就跳回原点。
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        let base = perCardOffset[task.id] ?? slot
                                        perCardOffset[task.id] = CGSize(
                                            width: base.width + value.translation.width - lastDrag[task.id, default: .zero].width,
                                            height: base.height + value.translation.height - lastDrag[task.id, default: .zero].height
                                        )
                                        lastDrag[task.id] = value.translation
                                    }
                                    .onEnded { _ in lastDrag[task.id] = .zero }
                            )
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.22), value: store.videoTasks.tasks.map(\.id))
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
                .padding(12)
            }
        }
    }
}
#endif
