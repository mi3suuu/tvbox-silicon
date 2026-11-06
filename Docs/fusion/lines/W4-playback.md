### 线名：W4-playback（播放 / 投屏 / 音乐 / 发现）

**起点**：`7d57d67` → rebase 到 `fusion/main` `357da7b`
**状态**：**部分**（可编可跑的主体已接满；两条真实断点已修，两处仍需 captain/上游定夺）

---

#### 一、线内判定总表（34 个认领文件，逐个对过三参照）

`8b9519b`（base）/ `22180e4`（上游 1.1 真身）/ `import/ours`（我方原料）三方求 SHA 与 `git diff`，逐条判：

| 文件 | 三方状态 | 处置 |
|---|---|---|
| `App/PlaybackView.swift` | base→双改 | **M1，不动**（见下文 §5） |
| `App/PlaybackHistoryView.swift` | 双改，零冲突 | **三方合并**（我方 `visibleHistory` + 上游 `episodeLabel` 并存） |
| `App/DiscoveryView.swift` | 双改，零冲突 | **三方合并**（我方 5 处增量全部落地） |
| `App/DiscoverView.swift` | 双改，零冲突 | **三方合并**（我方 `brandFilter` 可选化 + 上游 `HeroPagerCollectionView` 并存） |
| `App/MusicView.swift` | 双改，零冲突 | **三方合并**（上游新增 108 行 Liked Songs 保留） |
| `App/MusicMacPlayer.swift` | 双改，零冲突 | **三方合并**（上游 `FavoriteMenuButton` 保留） |
| `App/MusicNowPlayingScreen.swift` | 双改，零冲突 | **三方合并**（上游 `FavoriteMenuButton` 保留） |
| `App/LiveView.swift` | 双改，零冲突 | **三方合并**（我方 `visibleFavorites` + 上游「Liked Songs」标题） |
| `App/CatalogDanmakuView.swift` | 双改，零冲突 | **三方合并**（我方 6 项性能/状态修正 + 上游 `first: CatPawDanmaku.comments`） |
| `App/PlaybackHistoryView` 其余、`LiveView` 其余 | — | 同上 |
| `App/PlayOn.swift` / `Announcements.swift` / `Updates.swift` / `FeedbackView.swift` / `HomeView.swift` / `TMDBViews.swift` | 我方独占（上游同文件无改动） | 保留我方版（已在 HEAD） |
| `App/Discover*.swift`（7 个）/ `App/Music*.swift`（5 个） | 我方纯新增 | 保留 |
| `Sources/TVCore/` 19 个（PlaybackHistory / Watchdog / PlayOn / WebCastServer / WebCastSettings / RemuxPlan / HDRDisplay / SkipSegmentSources / SeriesSuggestion / Danmaku / LiveCatalog / ExternalPlayer / MusicExtensions / MusicLXSources / MusicProviders / TMDBMatch …） | 我方独占 | 保留我方版 |
| `Sources/TVCore/Catalog.swift` | 双改 | **以上游为准**；我方净增量仅 `MediaCache.data` 挪到 `Task.detached` 一处 → 本线丢弃（见 §3 D-08） |
| `Tests/TVCoreTests/{PlaybackHistory,HDRDisplay}Tests.swift` | 我方独占 | 保留，17 项全绿 |

---

#### 二、已接入（文件 → 能力 → 真实接线点）

> 全部为 grep 出来的**实际调用点行号**，不是「文件存在」推断。

| 文件 | 能力 | 真实接线点 |
|---|---|---|
| `App/PlaybackHistoryView.swift` | 播放历史页（环境分区 + 保险库过滤 + 删除带 environment） | `App/RootView.swift:456` `case .history:` |
| `App/HomeView.swift` | 继续观看（消费 `store.visibleHistory`） | `App/RootView.swift:446` `case .home:`；`HomeView.swift:109/119/137/327` |
| `App/LiveView.swift` | 直播页 + 收藏页（`store.visibleFavorites` 过滤，保险库隐藏源不出屏） | `App/RootView.swift:449` `case .live:`；`LiveView.swift:418-419` |
| `App/PlayOn.swift` | 跨设备续播（Bonjour 收发） | `TVBoxApp.swift:70` / `:102` `PlayOnController.shared.start(store)`；`RootView.swift:174` `PlayOnIncoming()`；`PlayerView.swift:1282`、`MobilePlayer.swift:1053/1491` `PlayOnButton` |
| `App/Store+WebCast.swift` + `App/WebCastController.swift` | 投屏 Web Cast（HTTP 服务 + 设置） | `App/Store.swift:94` `let webCast = WebCastController()`；`:558` `webCast.start(with: self)`（captain 独占文件，已接好） |
| `App/WebCastSettingsView.swift` | Web Cast 设置页 | `App/SettingsForm.swift:499` `FormLink(...) { WebCastSettingsView() }` |
| `App/CatalogDanmakuView.swift` | 弹幕模型（自动匹配 / 手选 / 导入 / 缓存） | `PlaybackView.swift:1036` `catalogDanmaku.startAutomatic(channel.historyContext)`；`CatalogPlaybackActions.swift:83` 设置页 |
| `App/DanmakuView.swift` | 弹幕渲染层 `DanmakuOverlay` | `PlayerView.swift:719/1042/1207`、`MobilePlayer.swift:387` |
| `App/SkipSegmentButton.swift` | 跳过片头/片尾按钮 | `MobilePlayer.swift:406` |
| `App/SeriesEndScreen.swift` | 剧终推荐卡 | `PlayerView.swift:414`、`ExternalDisplay.swift:122` |
| `App/SeriesSuggestionSheet.swift` | 整季换源建议 | `CatalogPlaybackActions.swift:79` |
| `App/TMDBViews.swift` | TMDB 详情/演职员/相关（`TMDBBadge`、`TMDBRelatedList`、`TMDBCastRow` …） | `VideoDetailView.swift:72` `@State tmdb = TMDBLookup()`、`:417 startTMDB()`；`DiscoverView.swift` 内 `TMDBBadge` |
| `App/DiscoverView.swift` | 发现首页（Hero、货架、厂牌、TV 焦点） | `RootView.swift:447` `case .discover:` |
| `App/DiscoverBrowseView.swift` | 厂牌/类型浏览 | `DiscoverView.swift:389/402` `DiscoverBrowseView(title:filter:logo:)` |
| `App/DiscoverDetailView.swift` | 发现详情 | 6 处引用（`DiscoverView` / `DiscoverPersonView` / `DiscoverTrailer`） |
| `App/DiscoverPersonView.swift` | 影人页 | 4 处引用 |
| `App/DiscoverSearchView.swift` / `DiscoverSearchFilters` | 发现搜索 | 各 1~2 处引用 |
| `App/DiscoverCalendarView.swift` | 上映日历 | 1 处引用 |
| `App/DiscoverTrailer.swift` | 预告片 | 2 处引用 |
| `App/DiscoverTVLayout.swift` | TV 端货架/Hero/搜索（`DiscoverTVHeroPager` / `DiscoverTVNativeShelf` / `DiscoverTVSearchView`） | 分别 2/4/2 处引用 |
| `App/DiscoveryView.swift` | 全站搜索 + 推荐（我方 5 处增量） | `RootView.swift` `GlobalSearchView()`；`DiscoveryView.swift:593 persistKeychainBackup()`、`:618 model.select(nil)`、`:621 vault.permits` |
| `App/MusicView.swift` | 音乐页 + 上游 Liked Songs | `RootView.swift:450` `case .music:` |
| `App/MusicMacBrowse.swift` | Mac 音乐浏览（货架/合集/表格/菜单） | `MusicTopResults`/`MusicBrowseShelves`/`MusicSongTable` 各 2~3 处 |
| `App/MusicMacPlayer.swift` / `MusicMacMiniPlayer.swift` | Mac 播放器 + 迷你条 | `MusicMiniPlayerTrigger` @ `RootView.swift:134` |
| `App/MusicMiniPlayer.swift` / `MusicPlayerViews.swift` | iPhone/iPad 迷你条 + Now Playing 面板 | `MusicPlayerViews.swift:27` `MusicMiniPlayer()`、`:32/35` `MusicNowPlaying()`、`:126` `MusicLyricsView()` |
| `App/MusicNowPlayingScreen.swift` / `MusicTVScreen.swift` / `MusicTVPlayer.swift` | 全屏播放（iOS / tvOS） | `RootView.swift:165` `.fullScreenCover { MusicPlayerScreen() }` |
| `App/MusicPlaybackSession.swift` | 播放会话（`canAdvance`、队列、渠道切换） | 8 处引用；`MusicResolution.swift:267` 解析器接线 |
| `App/MusicRemoteControl.swift` | 锁屏/遥控中心 | `canAdvance` 驱动 `nextTrackCommand.isEnabled` |
| `Sources/TVCore/PlaybackHistory.swift` | 历史存储（环境分区 `entries(in:)`、`remove(_:environment:)`） | `Store.swift:169-170` `visibleHistory` |
| `Sources/TVCore/PlaybackWatchdog.swift` | 卡顿看门狗 + 四时间戳 | `MobilePlayer.swift:2304` `StallWatchdog()`、`:2306` `PlaybackMarks()`、`:2408` `watchdog.report(position:)` |
| `Sources/TVCore/RemuxPlan.swift` | 重封装规划（cue/VTT/音轨） | `RemuxSession.swift:30/99/139`；`Rewrap.swift:74` |
| `Sources/TVCore/HDRDisplay.swift` | HDR/DoVi 决策 | `MobilePlayer.swift:204-207`；`RemuxPlan.swift:116` |
| `Sources/TVCore/SkipSegmentSources.swift` | 片头片尾段位来源仲裁 | `MobilePlayer.swift:123/144-155` |
| `Sources/TVCore/SeriesSuggestion.swift` | 换源建议 | `SeriesSuggestionSheet.swift:19/65/107` |
| `Sources/TVCore/Danmaku.swift` | 弹幕解析/渲染模型 | `DanmakuOverlay`（4 处）、`DanmakuStylePickers`（3 处） |
| `Sources/TVCore/LiveCatalog.swift` | 直播目录 + 房间解析 | 9 处引用；`PlaybackView.swift` 直播分支 |
| `Sources/TVCore/ExternalPlayer.swift` + **`App/ExternalPlayerMenu.swift`（本线新建）** | 外置播放器交接 | `MobilePlayer.swift:523` `.sheet { ExternalPlayerMenu(stream:headers:) }` |
| `Sources/TVCore/MusicProviders.swift` | 音源提供者（VKeys/GDStudio/HYW/Nianxin/Xinghai + Migu） | `MusicResolution.swift:275-283` 按偏好装配 |
| `Sources/TVCore/MusicLXSources.swift` | LX 自定义音源 | `MusicResolution.swift:282` `LXMusicProvider(sources: LXSourceLibrary.shared.enabled)` |
| `Sources/TVCore/MusicExtensions.swift` | 音源扩展 | `MusicResolution.swift:276` |
| `Sources/TVCore/TMDBMatch.swift` | TMDB 匹配（26 处引用） | `VideoDetailView.swift:418-419` `TMDBLookup` / `TMDBMatchStore` |
| `Sources/TVCore/WebCastServer.swift` / `WebCastSettings.swift` | Web Cast 服务端 | `WebCastController.swift:26/38/44` |
| `Sources/TVCore/PlayOn.swift` | Bonjour 协议 | `App/PlayOn.swift:24` `PlayOnController` |
| `Sources/TVCore/Catalog.swift` | 目录客户端（**以上游为准**） | `CatalogClient` 全站 |
| `Tests/TVCoreTests/PlaybackHistoryTests.swift` / `HDRDisplayTests.swift` | 单测 17 项 | `swift test --filter "PlaybackHistory\|HDRDisplay"` 全绿 |

---

#### 三、本线修掉的两个真实断点（不是新功能，是补齐）

**断点 1（阻塞 iOS 编译）：`ExternalPlayerMenu` 类型在融合后消失了。**

- 事实链：我方 `import/ours:App/SubtitleOverlay.swift:199-302` 定义了 `ExternalPlayerMenu` + `ExternalPlayer.installed()/open()`（UIKit 胶水）。
- M6 裁决「字幕以**上游** `SubtitleOverlay` 为准」→ 我方整份被替换 → 顺带把**投屏交接页**一起冲掉。
- 而 `App/MobilePlayer.swift:523`（W6 文件）仍在调它。
- `git grep ExternalPlayerMenu 22180e4` = 空；`git grep ... import/ours` = 2 处；HEAD = 只在 MobilePlayer 里留了个悬空调用。
- 处置：按总纲 **A 类（纯新增 → 独立文件）** 新建 `App/ExternalPlayerMenu.swift`，内容与 `import/ours` 逐字一致，只加文件头说明。
- **为什么不放回 `SubtitleOverlay`**：上游与我方 `SubtitleOverlay` 同名同目标（P-03 已登记为 M6 冲突），任何人下次对齐字幕都会再冲掉一次；独立文件是对齐后唯一不会被反复踩的落点。

**断点 2（功能静默失效）：`MusicNowPlayingScreen:152` 的「下一首」按钮判据过期。**

- 我方 `MusicPlaybackSession.swift:197` 的 `canAdvance` 含「重复全部」逻辑（`repeatMode == .all && count > 1`）；上游那句仍用 `queue?.hasNext != true`。
- 融合后 `repeatMode` 是我方语义，按钮会在循环模式下错误置灰。已改为 `!music.canAdvance`，与 `MusicMacPlayer`（2 处）、`MusicPlayerMini`、`MusicRemoteControl` 的既有判据一致。

**另补：`App/MusicView.swift` 品牌词回退。**
我方把空状态文案里的 `Yingxia` 改成 `Mi3s`，但 `Sources/TVCore/Resources/*.lproj/Localizable.strings` 四语言仍是 `Yingxia` key ⇒ 改完会**丢翻译**（key 不命中回退英文原文）。本线无权改 lproj，因此**代码回退成 `Yingxia`**，并在 §5 列为 captain 决策项（改名必须代码 + 四语言同时改）。

---

#### 四、未接入

> **注意**：`Docs/fusion/00-06` 属 captain 独占（06 号线边界 + 本任务铁律 7），本线**未写入** `02`/`03`。
> 下面给出可直接粘贴的行，由 captain 汇总。这与 `00-融合总纲 §三`「各线追加」不一致——以 06 的独占声明为准，冲突时按更严格者执行。

| # | 能力 | 原因 | 重开条件 |
|---|---|---|---|
| D-08 | `Catalog.swift` 我方 `MediaCache.shared.data(...)` 挪进 `Task.detached` | 上游 1.8.11 同函数已改为 `HTMLText.synopsis` + `CatPawDanmaku.remember`，我方该处只是「读缓存避免主线程阻塞」的微优化，与上游 Manga/弹幕两条主线同区域；按铁律 3「上游更完整者丢我方」 | 若真机实测详情页在缓存命中时掉帧，再以本文件末追加 `extension` 或独立 `CatalogCacheOffmain.swift` 补回，**不覆盖**上游函数体 |
| D-09 | 我方 `Catalog.synopsis` 版（剥 http/www/线路/弹幕字样） | 上游 1.8.11 亦有 `synopsis`，语义更保守（只剥纯布局行，保留插件自有地址，见上游注释 `#360`）。我方版会把 `127.0.0.1`/`localhost` 之外的一切 URL 抹掉，与上游该决策冲突 | 上游若回退到 `plain`，或真机样本证明噪声确实污染详情页 |
| D-10 | `App/MusicView.swift` 品牌词 `Mi3s` 版 | key 与 lproj 不一致会丢翻译（见 §五） | captain 一次性完成「代码 + 四语言 lproj」同步改名后 |

---

#### 五、需要 captain 做（本线无权改）

**A. 本地化 key（`Sources/TVCore/Resources/*.lproj/Localizable.strings`）**

本线**未新增任何 key**——`App/ExternalPlayerMenu.swift` 用到的 8 个 key 四语言已齐（`Address Copied` / `Copy Address` / `Installed Players` / `Not Installed` / `Open in Another Player` / `Some formats the built-in player cannot decode. …` / `Install one of these to open formats the built-in player cannot.` / `This stream needs headers, …`，全部 `grep -c = 1`）。

需要 captain 裁的**改名**（不是新增）：

| 现 key（代码与四语言一致） | 我方旧版 was | 影响 |
|---|---|---|
| `Type a song's name, or its name and the artist. Yingxia finds the recording…` | `… Mi3s finds the recording …` | 若统一改 `Mi3s`，须四语言 key + 值同时改，并同步全仓其余 44 处 `Yingxia` |

**B. `Project.yml` / Info.plist —— 投屏交接页的探测能力缺口（建议项，非阻塞）**

`ExternalPlayer.installed()` 依赖 `UIApplication.canOpenURL`，而 iOS 只对 `LSApplicationQueriesSchemes` 里列出的 scheme 作答。当前**三份 Info.plist 与 `project.yml` 均无该键**（上游、我方、HEAD 都没有：`git grep -l LSApplicationQueriesSchemes 22180e4` 与 `import/ours` 均空）。

→ 后果：外置播放器列表**恒为空**，只剩「复制地址」。菜单不崩，但投屏能力实际不可用。

建议在 `project.yml` 的 `SharedApp.info.properties` 加（需 captain 改 `project.yml` + `xcodegen generate`）：

```yaml
LSApplicationQueriesSchemes:
  - infuse
  - vlc-x-callback
  - nplayer-http
  - senplayer
```

scheme 来源：`Sources/TVCore/ExternalPlayer.swift` 的 `known` 4 项，已逐个核对（`grep 'scheme: "'`）。

**C. 合并后请跑一次 `xcodegen generate --spec project.yml`（必须）**

本线新增 `App/ExternalPlayerMenu.swift`。我**没有**把 `TVBox.xcodeproj/project.pbxproj` 的改动带进提交（06 号文件把它列为 captain 独占）。我在本 worktree 跑过 xcodegen 验证：生成结果只多 8 行（1 个 `PBXFileReference` + 3 个 `PBXBuildFile` + 1 个 group 成员 + 3 个 `in Sources`），macOS 三平台均 `BUILD SUCCEEDED`；验证完已把 pbxproj 还原。

→ **captain 把本线 merge 进 `fusion/main` 后，跑一次 `xcodegen generate`，该文件即入工程。** 这也是 00 §五的常规步骤，不需要额外动作。

**D. `App/PlaybackView.swift`（M1，本线不碰）**

M1 的 `LiveReopen` 接线已完成且与我方 `recoverLiveAfterDrop` 并存，本线只复核不动。仅记录一处**观察**（留给 captain 判，不是缺陷结论）：`retryLive` 的诊断串上游含 `played=` 时长、我方删掉了该字段，三方合并时该行取 HEAD（含 `played=`），语义更全，保持不动。

---

#### 六、侵入上游文件

**本线零侵入。** 未在任何上游文件里写 `// [mi3s]`，未加存储属性，未动 `App/Store.swift` / lproj / `project.yml` / `TVBox.xcodeproj` / `Docs/fusion/00-06`。

- `Sources/TVCore/Catalog.swift`：保持上游原样，我方增量按 D-08/D-09 丢弃（不是侵入后回退，是根本没写进去）。
- `App/PlaybackView.swift`：`git diff 8b9519b import/ours` 的 3 处与我方增量冲突，全部**取 HEAD（M1 已完成态）**，未新增任何行。

`03-侵入点登记表.md` 无需追加（本线 0 条）。

---

#### 七、验证证据

```
$ swift build --package-path Packages/TVCore --target TVCore 2>&1 | tail -3
[264/264] TVCore
Build complete! (15.55秒)

$ swift test --package-path Packages/TVCore --filter "PlaybackHistory|HDRDisplay" 2>&1 | tail -3
✔ Suite HDRDisplayTests passed after 0.009 seconds.
✔ Test run with 17 tests in 1 suite passed after 0.309 seconds.

$ xcodegen generate --spec project.yml   → exit 0

$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Debug \
    -derivedDataPath build/DD-line build 2>&1 | tail -3
** BUILD SUCCEEDED **

$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS -configuration Debug \
    -derivedDataPath build/DD-tvos -destination 'generic/platform=tvOS' build \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
** BUILD SUCCEEDED **

$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -configuration Debug \
    -derivedDataPath build/DD-ios -destination 'generic/platform=iOS' build \
    CODE_SIGNING_ALLOWED=NO 2>&1 | grep error: | sort -u
macro expansion @State:2:23: error: type 'SubtitleStyle' has no member 'standard'
macro expansion @State:2:9: error: cannot find 'SubtitlePositionMemory' in scope
```

> iOS 剩余错误**全部是 M6 字幕符号**（`SubtitleStyle.standard` / `SubtitlePositionMemory`），W5 裁决中，与本线无关。
> 本线修 `ExternalPlayerMenu` 前，iOS 同一条链上还有第三类错误；修完后只剩 M6。
> `build/AppleRuntime` 我在本 worktree 建了软链指向主工作树，仅为让 tvOS 能编；该目录在 `.gitignore` 内，不入库。

---

## ⚠️ 并入主线时的变更（captain 追加，2026-11-06）

本文件下方「断点 1」记录的是**本线当时**的处置：新建 `App/ExternalPlayerMenu.swift`。
**实际并入 `fusion/main` 时改成了另一条路**，读下文前先看这里：

| | 本线原方案 | 并入后实际 |
|---|---|---|
| 文件 | `App/ExternalPlayerMenu.swift`（本线新建） | **不存在**（该文件被跳过，未提交） |
| 类型 | `ExternalPlayerMenu` | **`Mi3sExternalPlayerMenu`** |
| 位置 | 独立文件 | `App/Mi3sSubtitleOverlay.swift:205` |
| 调用 | `MobilePlayer.swift:523` | `MobilePlayer.swift:533` |

**为什么改**：M6 字幕体系裁决（路线 A）把我方 `App/SubtitleOverlay.swift` 整文件改名为
`App/Mi3sSubtitleOverlay.swift`，里面的 `SubtitleOverlay` / `SubtitleSettingsView` / `ExternalPlayerMenu`
三类一并加 `Mi3s` 前缀。那份改名后的文件里**本来就有** `Mi3sExternalPlayerMenu` 的完整实现，
字号、排序、`ExternalPlayer.installed()` 全部在内。

所以本线新建的 `App/ExternalPlayerMenu.swift` 会与它**重复定义同名类型**，冲突。跳过是对的。

> 结论：本线对「外置播放器交接」这个能力的所有结论**仍然成立**（能力在、有调用点、能编译），
> 只是文件路径与类型名不同。下游若要查这个能力，认 `Mi3sExternalPlayerMenu` 这个名字。

---

