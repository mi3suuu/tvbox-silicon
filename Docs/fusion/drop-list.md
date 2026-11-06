# 未纳入清单（drop list）· 单一权威汇总

> **这是目标里要求的 `Docs/fusion/drop-list.md`。**
> 内容不是新写的 —— 是把 `02-未纳入清单.md` 里散在五节（A 档 / B 档 / C 档 / 各线追加 / 社区 Duo）
> 的全部条目抽出来放在一处，方便一眼看全。**`02` 仍是逐条的详版（含完整理由与重开条件）**，本文件是索引式汇总。

---

## 一、口径

| 前缀 | 含义 | 反悔成本 |
|---|---|---|
| **D-** | 丢弃：上游已有等价实现，我方版本不接 | 低（上游那套已在用） |
| **P-** | 待定：需逐条 diff 后再定 —— **现已全部关闭** | — |
| **DUO-** | 社区 Duo 适配审计出来的未解决项 | 中（要真机验） |
| **N-** | 未接入：能力在，但缺调用方 / 缺平台 | 中（补线即可） |
| **V-** | 验收发现的缺口 | 低-中 |

**总计 34 条：D 14 / DUO 7 / N 8 / V 3 / P 2（已关闭）。**

---

## 二、D 组 · 丢弃（14 条）

> 判据统一是「上游已有等价或更完整实现」。每条在 `02` 里都写了**重开条件**。

| # | 丢弃内容 | 上游对应 | 一句话理由 | 重开条件 |
|---|---|---|---|---|
| D-01 | `Sources/TVCore/Bilibili.swift` / `BilibiliCast.swift` / `BilibiliLiveChat.swift` | 上游 `BilibiliMark` + `Catalog`/`LiveCatalog` 数据驱动 | 上游 1.8.11 已用数据驱动直播取代旧 B 站专用实现 | 上游丢掉 B 站支持，或我方需要 B 站专属弹幕/投屏协议时 |
| D-02 | `Sources/TVCore/CloudSources.swift` | 上游云源 builtin（`CloudStreams` / 内建源） | 上游已云化 | 上游云源不可用时 |
| D-03 | `Sources/TVCore/ScriptAssets/sites/{Bili,Hema,Hongguo,Xifan}.js` + `sites/hongguo/*` + `sites/index.json` | 上游云端 `ScriptAssets/sites/index.json` | 本地脚本已被云端清单取代 | 需要离线源，或云端清单不可达时 |
| D-04 | `Sources/TVCore/DouyinAccount.swift`（我方版） | 上游 `DouyinAccount` 登录签名 | 上游同名文件已含更完整实现 | 上游签到流程变更且我方版更稳 |
| D-05 | `App/SitesView.swift` 全量重写（2342 行 → 我方 713 行拆分为多文件） | 上游 `SitesView` + 我方 `SourceEditors`/`SourceMovesView`/`SettingsTV` 等独立文件 | 我方把源管理拆成独立文件，符合「独立成文件」目标，但**主视图不重写** | — |
| D-06 | `App/SettingsView.swift` 1901 行删减 | 上游 `SettingsView` + 我方 `SettingsForm/SettingsPlayback/SettingsPrivacy/SettingsTV/SettingsContributors/SettingsDiagnostics` 7 文件 | 同上：拆分为独立文件，主文件保持上游 | — |
| D-07 | `App/GlassKit.swift` 删减 490 行 | 上游 `GlassKit` | 上游玻璃体系完整，我方删减属历史包袱 | — |
| D-08 | `App/MobilePlayer.swift` 的选集入口（可编排顶栏 `PlayerControl.episodes`，默认在 `standardTop`） | 上游 1.8.11 #524：`showsEpisodes` 状态 + `.playerEpisodesSheet` + `stepButtons` 行内 `PlayerEpisodesButton` | 我方实现更强：控件可由用户拖拽编排（`PlayerControlsLayout`），面板呈现按 `PlayerSurface` 三种 Duo 形态分派，折叠/展开可保持开启；门控 `MobilePlayer.swift:987` 与上游 `PlayerEpisodesSheet.offered` 语义等价。同一功能出现两入口反而有害 | 上游移除 `PlayerControls` 可编排能力，或验证员判定我方顶栏方案不可用时 |
| D-09 | `App/PlayerView.swift` 的 `subtitles:` 参数与 `NativePlayerView` / `DesktopNativePlayer` 的 PiP 字幕委托（上游 1.8.11 新增 3 处） | 上游自带 `PlaybackSession.subtitles: SubtitleCues` | 依赖 `PlaybackSession.subtitles`，而 `App/PlaybackView.swift` 归 W5-subtitle 且正处 M6 裁决；本线不改该文件 | W5 给出 M6 结论（路线 A 改名独立文件 / 路线 C 以上游为准）并落 `session.subtitles` 后，回填本线 3 处参数 + 2 处 PiP 委托 |
| D-10 | `App/LoadState.swift` 的 `LoadStateView<Value, Content>` | 无（上游无对应类型） | 全仓零调用点：只有 `LoadState` 枚举被 `CloudBackupView.swift:114` / `DiscoverPersonView.swift:13` 使用，`LoadStateView` 从未被实例化 | 需要统一 loading/error/retry 外壳时直接复用，无需重写 |
| D-11 | 上游 `SiteView` 的「滚动到底自动续页 + `loadMoreFooter`（Load More / Try Again / Loading…）」 | 上游把 `SiteView` 塞在 `SitesView.swift` 里；我方已按「独立成文件」拆到 `App/SiteView.swift`，该文件属 W6 边界，W3 认领清单不含它 | 上游再改续页逻辑，或 W6 接手该文件时按 `CatalogBrowser.hasMore/loadingMore/moreError`（已在 `Sources/TVCore/CatalogBrowser.swift:20/28/29` 就绪）平移 |
| D-12 | 上游 `SitesView` 的 `pager` 翻页条（我方 `App/SiteView.swift:171` 仍是页码条） | 与 D-08 互斥：两种翻页交互混装会同时渲染页脚与页码条。**建议采用上游（D-08）**，因为 `catalogLoadMoreAppendsPagesUntilTheSourceRunsOut` 单测已覆盖 loadMore 路径 | 与 D-08 同一决策，二选一；由 captain 或 W6 落 |
| D-13 | 上游 `#517` 的 `UserDefaults` 键 `sources.foldedGroups`（折叠持久化） | 我方用 `SourceFoldState`（`sourceFoldState.v1`），语义等价且更克制：picker 场景不读写主页面的折叠，避免「选源时分组被主页面折叠吞掉」 | 上游若把折叠状态搬进 Store / CloudSync，需在存储层合并（我方 `SourceFoldState` 是无状态 struct，改造点只在 `App/SitesView.swift`） |
| D-14 | `Sources/TVCore/RemuxPlan.swift` 里「把 tone-map 判断重构进 `HDRDisplay`」 | 上游 `RemuxPlan.videoTrack` 内联判断（`!device.hdr && [16,18].contains(colorTransfer) && doviProfile != 5`） | **实测回退**：换成我方版后 `hevcInTransportStreamHLSPlaysRepackaged` 与 `liveHEVCInTransportStreamFollowsItsPlaylist` 两个 AVPlayer 集成测试由绿转红（`played.status != .readyToPlay`），上游版全绿。两者对 fixture 的真实流产出不同 plan，说明「等价重构」不成立。按铁律「D 类改上游逻辑、回归即回退」，保留上游版。注意：`Sources/TVCore/HDRDisplay.swift` **本身保留**（独立新能力，`App/MobilePlayer.swift:204-207` 在用），只是不再驱动 RemuxPlan | 想把 tone-map 决策统一到 HDRDisplay 时，必须先补一条「同一 fixture 下两者产出同一 RemuxPlan」的对照测试，再改 |

---

## 三、DUO 组 · 社区 Duo 适配审计（7 条）

> 来源：`sven-ericmolzahn/iphone-duo-skill` / `VankerWu/iPhone-Duo-Apps` / `sunimp/TabBar` 三份社区成果。
> 逐条对照见 `Docs/duo/适配对照表.md`（已做 15 / 未做有意 5 / 不适用 8 / 需跟进 4）。

| # | 项目 | 判定 |
|---|---|---|
| DUO-01 | pushed `Route` 页面隐藏导航栏 → Duo 纵向栏里没有 Back | 全仓 14 处 `.toolbar(.hidden, for: .navigationBar)`（`audit.sh` MEDIUM），含 `App/GlassKit.swift:245,266`、`App/HomeView.swift:27,97`、`App/DiscoverView.swift:1219,1684` 等 | **高**：外屏/内屏横持下用户可能退不回去。社区明确「hidden bar = 手搓 chrome，pushed 页尤危」 | 在 `PushedRouteTabSafeArea` 里区分 root / pushed：pushed 页不隐藏导航栏，或确保每页有自绘返回且可达 |
| DUO-02 | `connectedScenes.first` 2 处 | `App/PlaybackWaitView.swift:184`、`App/PlayerView.swift:850` | **中**：Duo 是首个多 scene 的 iPhone（`ExternalDisplay`），`.first` 可能拿到非 App 场景 | 改成 `foregroundActive`，或用视图自己的 `windowScene` |
| DUO-03 | 播放页按 `interfaceOrientation` 布局 8 处 | `App/MobilePlayer.swift:878`、`App/PlayerView.swift:755,802,855`、`App/VideoDetailView.swift:1064,1092,1376`、`App/PlaybackWaitView.swift:188` | **低（有理由）**：size class 无法区分「内屏横握 / 内屏竖握」（都是 regular×regular），而控制栏必须切 | 保留；在每处补注释写明「size class 无法区分，故用 interfaceOrientation」，避免后来者按社区建议误改 |
| DUO-04 | `UIScreen.main.potentialEDRHeadroom` | `Sources/TVCore/HDRDisplay.swift:143` | **低**：HDR 能力按设备不按屏 | 换成 `view.window?.windowScene?.screen`；或保留并注释理由 |
| DUO-05 | 网格列数为常量，未按容器宽算 | `Layout.cardColumns`（DesignSystem） | **低**：内屏 951pt 宽下可能列数偏少、封面偏大 | 按实测宽度算列数，有折叠时优先偶数（社区 audit-checklist §1） |
| DUO-06 | iOS 27 纵向栏下 badge 晚到可能不刷 | `App/RootView.swift:tabBadge(_:)` 只传 `Text`，未做 symbol swap | **低**：`badge` 只用于「有新版本」，不是实时的 | 按社区实测补 `bell.fill → bell.badge.fill` 式 symbol 兜底（本条未在本机验证） |
| DUO-07 | P2 折展回原分区改动**未获独立复现证据** | `Docs/duo/Duo适配报告.md` §2.2：深链路径改前改后一致（MAD 0.43 都回到 sites） | **低**：代码逻辑闭合了真实缺口，未改变任何既有分支 | 真机手动验「展开态停在 Sites → 折叠 → 展开」；验不过则回退 P2 改动，只保留白屏修复 |

---

## 四、N 组 · 未接入（8 条）

> 「能力在，但缺调用方 / 缺平台」。都写明了建议解法。

| # | 项目 | 判定 |
|---|---|---|
| N-01 | `Config/sign.entitlements` | 保留在本仓库（签名用），不上推上游 |
| N-02 | `Scripts/install-duo.sh` / `shoot-duo.sh` / `test-duo-ui.sh` / `verify-ipa.sh` / `audit-*.sh` / `audit-pixels.py` / `contact-sheet.py` / `e2e-verify.sh` | 全部保留（零冲突） |
| N-03 | `Scripts/qa-fixture/*`（fixture 视频/字幕/服务器） | 保留 |
| N-04 | `Scripts/hinge/*`（Duo 折叠模拟） | 保留 |
| N-05 | `Docs/*二开审计/验收/迁移*` | 保留 |
| N-06 | `Services/tmdb-match/*` | 保留（我方 TMDB 服务） |
| N-07 | `Design/icon-sources/*` + `Design/preview-s-variants.swift` | 保留（Mi3s 图标源图） |
| N-08 | `.gitignore` / `AGENTS.md` | 取并集，不覆盖上游 |

---

## 五、V 组 · 验收发现的缺口（3 条）

| # | 项目 | 判定 |
|---|---|---|
| V-01 | `App/DiscoveryView.swift` 全局搜索「按隐私保险库过滤源」 | `DiscoveryView.swift` 属 W4-playback 边界（`06-线边界与工作树.md` 第 108 行），W1 不越界修改。我方旧版（`import/ours:App/DiscoveryView.swift:623`）在 `model.search` 的过滤闭包里是 `store.hiddenSources.contains(...) \|\| !store.vault.permits(site:fallback:)`；融合版 `App/DiscoveryView.swift:622` 只剩前一项。**不等价**：`hiddenSources` 是「用户手动隐藏」，`vault` 是「密码保护的隐藏」，无密码时两者一致，设了密码后搜索结果仍会漏出被保险库藏的源。 | W4 在 `App/DiscoveryView.swift:622` 的过滤闭包补 `\|\| !store.vault.permits(site: site, fallback: config.origin)` |
| V-02 | `Sources/TVCore/Environments.swift` 独立单测 | 我方旧版也没有 `EnvironmentsTests.swift`（`git ls-tree -r import/ours` 确认无该文件），非融合丢失。当前 148 行仅有间接覆盖（`PlaybackHistoryTests` / `SubscriptionTests` 走环境过滤路径）。环境隔离是护城河能力之一，缺直接单测属风险敞口。 | 补 `Tests/TVCoreTests/EnvironmentsTests.swift`：`add`/`remove`（默认环境不可删）/`activate`（未知 ID 返回 false）/`shows(nil)` 归默认/`stamp`/`setSyncsExternally` 互斥 六组 |
| V-03 | iOS 以外平台的「全量备份 / 恢复」按钮入口 | `App/SettingsForm.swift:301` 起备份四按钮整体在 `#if os(iOS)` 内；macOS/tvOS 走 `#else` 的 `subscriptionActions`，不含备份。**与我方旧版一致**（`import/ours:App/SettingsForm.swift` 同位置同 gate），非融合回归。数据层 `exportFullBackup`/`importFullBackup` 全平台可用，只缺 UI 入口。 | 需要在 Mac / Apple TV 上手动备份时：把 `SettingsForm.swift:315-336` 四个 Button + keychain Toggle 提出 `#if os(iOS)`，或给 `subscriptionActions` 补 `#if !os(iOS)` 分支 |

---

## 六、P 组 · 待定（2 条，**均已关闭**）

> 这两条在 W2-cloud 实证后被推翻，已划删除线。留在这里是为了保留「当时为什么怀疑、后来怎么否证」的痕迹。

| # | 项目 | 判定 |
|---|---|---|
| P-03 | `App/SubtitleOverlay.swift`（我方 307 行）vs 上游（164 行） | add/add 冲突：双方都做字幕自绘 | **M6 专项**：渲染引擎用上游 `SubtitleStyle`，数据源用我方 `SubtitleTrack`/`SubtitleTranslator` |
| P-04 | `Sources/TVCore/SubtitleStyle.swift`（我方 189 行）vs 上游（166 行） | 同上，同名同目标 | **以上游为准**；我方独有字段逐个评估后作为增量补回 |

---

## 七、复述：本次融合的边界

**接进来的：**
- 二开纯新增代码类文件 **111 个全部落地**（`git ls-tree` 对照 `import/ours`，缺失 0）
- 二开独占修改的 63 个文件
- 39 个重叠文件按 L1 跟随上游 / L2 我方为准 / L3 手工合，全部落定

**没接的：** 就是上面这 34 条。

**侵入上游的：** 24 处，全部带 `// [mi3s]` 标记 + 登记在 `03-侵入点登记表.md`（含「上游更新时如何复核」）。

**测试：** 融合版 783 项 vs 纯上游基线 589 项，失败集**完全相同**（2–4 项，全是仓库布局与并发竞争）。
详见 `09-测试基线对照.md`。
