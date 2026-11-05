### 线名：W3-source（源管理 / 线路 / 探测 / 排序）
**认领文件**（06 节「W3-source」全量 17 + 12 测试）
```
App/SitesView.swift  App/SourceEditor.swift  App/SourceEditors.swift  App/SourceMovesView.swift
App/ResourceRankingView.swift  App/SkipSourceSettingsView.swift  App/Store+SourceAdmin.swift
Sources/TVCore/{SourceRouting,SourceReassignment,SourceOverrides,SourceProbe,SourceHealth,
                SourceFoldState,SourceGroups,LineSettings,LineRotation,ResourceRanking}.swift
Tests/TVCoreTests/{Source*,Line*}Tests.swift   ← 12 个，全绿
```
**状态**：完成（线内 17/17 落地 + 三平台可达，macOS/tvOS 编译门禁通过；单测 764/766，2 项为已知基线失败）

---

#### 已接入（文件 → 能力 → 真实接线点 文件:行号）

| 文件 | 能力 | 真实接线点 |
|---|---|---|
| `App/SitesView.swift` | 源页主视图：分组折叠 + 探针入口 + 死线路批处理 + 排序 + 改派入口 | `App/RootView.swift:452`（tab）、`App/DiscoveryView.swift:906`（picker） |
| `App/SitesView.swift:120-121` | **Probe All / Stop Probing** 双向按钮（同一按钮两职责） | `store.probeRun` → `Store.startProbingAllSources()` / `cancelProbingAllSources()`（`App/Store.swift:1308/1334`） |
| `App/SitesView.swift:135-142` | **Fix Dead Lines** 三分支（proxy / direct / hide） | `store.batchFixUnreachableLines(.proxy/.direct/.hide)`（`App/Store.swift:1450` 读 `SourceProbeStore.unreadableLines()`） |
| `App/SitesView.swift:151` | **Sort by Measured Quality** | `store.rankSourcesByMeasuredQuality()` → `App/Store+SourceAdmin.swift:105` → `ResourceRanking.sort` + `sourceOrder.save` |
| `App/SitesView.swift:161` | **Moved Sources** 入口（仅 moveCount>0 时出现） | `movedSourcesButton` → `SourceMovesView()`；计数来自 `sourceReassignment.moveCount` |
| `App/SitesView.swift:66,187-231` | **拖拽改派**：卡片 → 订阅头 / 「其他来源」 | `.draggable(SourceDrag)` → `store.reassignSourceByKey` → `Store+SourceAdmin.swift:17` → `SourceReassignment.reassign` |
| `App/SitesView.swift:71-72` | **改派菜单 / 线路菜单**（TV 无拖拽，走菜单） | `SourceMoveMenu` → `Store+SourceAdmin.swift:88`；`SourceRouteMenu` → `sourceRouting.set`（`App/Store.swift:1247`） |
| `App/SitesView.swift:110-114` | **源编辑弹窗**（改名 / 改 API） | `SourceEditorSheet(site:origin:)` → `store.sourceOverrides.rename/setAPI`（`App/SourceEditor.swift:55-56`（写）/ `:41-42`（清）→ `Sources/TVCore/SourceOverrides.swift:46,55`） |
| `App/SitesView.swift:369,394,417` | 卡片「Customized」标记（改名/改 API/强制线路三种覆盖可见） | `store.sourceOverrides.override` + `store.sourceRouting.route` |
| `App/SitesView.swift:344-368` | 健康点用**图形**区分三态（不靠色相独辨） | `SourceHealthDot` → `store.health(of:)` → `SourceHealth.shared.status` |
| `App/SitesView.swift:356-...`（`SourceGroups.make` 侧见 I-08） | 隐私保险库锁定期间源**整体消失**（不进「隐藏源」组，否则泄露保险库容量） | `SourceGroups.make(privacyHidden:)` ← `App/Store.swift:1528` |
| `Sources/TVCore/SourceGroups.swift` | 分组（pinned / builtIn / subscription / hidden / **other**）+ 地址重定向映射 | `App/Store.swift:1523-1538 sourceGroups(includeHidden:)`（带 stamp 缓存） |
| `Sources/TVCore/SourceFoldState.swift` | 折叠状态持久化 | `App/SitesView.swift:20 foldState` + `:194`/`:258 save` + `:277 applyDefaultFold` + `:34` 首帧播种 |
| `Sources/TVCore/SourceRouting.swift` | 逐源默认线路（auto/direct/proxy） | `Store.applySourceRouting`（`App/Store.swift:1120-1150`，写回 `site.routed(_:)`）；卡片标记 `SitesView.swift:396` |
| `Sources/TVCore/SourceHealth.swift` | 健康三态 + 冷却 + 失败计数 | 记录：`Sources/TVCore/Catalog.swift:260/264`；消费：`SearchModel.swift:171/251`、`DiscoveryView.swift:524/811`、`Store.swift:1139`、`Store+SourceAdmin.swift:44` |
| `Sources/TVCore/SourceProbe.swift` | 探针结果库 + 主机轮转（`HostRotation`）+ 学习（`HostLearning`）+ 并发上限 | 全站批量：`Store.swift:1319 record(...)`、`:1452 unreadableLines()`；单线路：`App/EpisodePicker.swift:47,75-86,96-98`（begin/succeed/fail/cancel/cooldown 五口全接） |
| `Sources/TVCore/LineSettings.swift` | 逐线路覆盖（强制 direct/某代理 + 隐藏） | `App/EpisodePicker.swift:137,342,397-412`（隐藏/恢复/改线）；`App/PlaybackView.swift:617`（播放选线）；`Store.swift:1478-1482`（批量修） |
| `Sources/TVCore/LineRotation.swift` | `HostRotation` 退避/冷却/并发状态机 + `HostLearning` | 由 `SourceProbeStore` 持有（`SourceProbe.swift:134/136`），`EpisodePicker` 间接驱动 |
| `Sources/TVCore/ResourceRanking.swift` | 多键加权排序（分辨率/码率/体积/HDR），**缺失值 = unknown，不视作最差** | `Store+SourceAdmin.swift:105-121`；设置入口 `App/SettingsForm.swift:200,411`、`App/SettingsTV.swift:116` |
| `Sources/TVCore/SourceReassignment.swift` | 源跨订阅改派 + 维护清单 + 旧记录迁移 | `Store.swift:1151-1161 adoptLegacyMoves`、`:1110`、`:1239/1261/1267`；UI `App/SourceMovesView.swift` |
| `Sources/TVCore/SourceOverrides.swift` | 改名 / 改 API（不写订阅文件，刷新不掉） | `Store.swift:1196 apply(to:)`、`:472 SourceOverrides.shared =`；UI `App/SourceEditor.swift` |
| `App/ResourceRankingView.swift` | 属性排序编辑器 | `App/SettingsForm.swift:411`、`App/SettingsTV.swift:116` |
| `App/SourceMovesView.swift` | 改派维护清单 | `App/SitesView.swift:265`、`App/SettingsForm.swift:298` |
| `App/SkipSourceSettingsView.swift` | 片头/片尾源设置 | `App/SettingsForm.swift:412` |
| `App/SourceEditors.swift` | `SourceOrderEditor` / `HiddenSourcesEditor` / `SourceOrderRow` | `App/SitesView.swift:105-106`（两个 sheet） |
| `App/Store+SourceAdmin.swift` | Store 侧薄封装（**extension，不碰 Store 主类**） | 见上各行 |

**Upstream 增量并入（L2 文件 `App/SitesView.swift`）**：上游 8 个改动 hunk 中，属于本线职责的 `#517` 折叠持久化语义已由我方 `SourceFoldState` 等价覆盖（且键名独立，不与上游 `sources.foldedGroups` 抢存储）；`EpisodeRow` 去 `private`（I-06）已在 `App/VideoDetailView.swift:1928` 保持 `internal`。

---

#### 未接入（已同步追加进 02-未纳入清单.md，编号 D-08 ~ D-10）

| 能力 | 原因 | 重开条件 |
|---|---|---|
| **D-08** 上游 `SiteView` 的「滚动到底自动续页 + Load More 页脚」 | 该视图在我方已拆到 `App/SiteView.swift`（W6 边界的同类文件，非本线认领清单），本线不改 | 上游再改续页逻辑，或 W6 交接该文件时按 `CatalogBrowser.hasMore/loadingMore/moreError` 平移 |
| **D-09** 上游 `SitesView` 的 `pager` 翻页条（我方 `SiteView.swift` 仍为分页器） | 同上，且两种翻页交互**不能共存**（会同时出现页脚与页码条） | 与 D-08 同一决策，二选一 |
| **D-10** 上游 `#517` `UserDefaults("sources.foldedGroups")` 键 | 我方用 `SourceFoldState("sourceFoldState.v1")`，语义等价但更克制（picker 不污染主页面折叠，见下「本线修复」） | 上游若把折叠状态搬到 Store/CloudSync，需合并存储层 |

> 说明：D-08/D-09 不是「丢了」，而是**落点不在我这条线**——上游把 `SiteView`/`VideoDetailView` 塞在 `SitesView.swift` 里，我方已按「独立成文件」拆成 `App/SiteView.swift`、`App/VideoDetailView.swift`，此二文件属 W6。建议 captain 把这两条派给 W6 或自己收口。

---

#### 侵入上游（已同步追加进 03-侵入点登记表.md，编号 I-08 / I-09）

| 文件 | 锚点 | 内容 | 原因 | 上游变更时如何复核 |
|---|---|---|---|---|
| I-08 | `Sources/TVCore/SourceGroups.swift` | `Kind` 枚举尾部 `case other`（L15 起，含 `// [mi3s]` 标记）；`make(...)` 新增 `privacyHidden:` 与 `reassign:` 两个**带默认值**的尾参（L40）；`eligible()` 加 `!privacyHidden(site)`（L66）；hidden 组过滤加 `!privacyHidden($0)`（L88） | ① 改派来源落不到任何订阅时仍需可见（否则「源存在却看不见」＝ bug 观感）；② 保险库锁定期间源必须整体消失，否则「隐藏源 N 条」泄露库存；③ 分组要按「改派后的目标」归位 | 上游 8b9519b→22180e4 未动此文件（`git log 8b9519b..22180e4 -- Sources/TVCore/SourceGroups.swift` 为空）。上游若新增 `Kind` case，我方 `other` 放**末尾**，手工合并 `switch`；`make` 若加参数，我方两个**带默认值**参数保持最后两位 |
| I-09 | `Sources/TVCore/SourceHealth.swift` | `init(file:)` 的加载段（L42-52，含 `// [mi3s]` 标记） | ① `JSONFileStore` 统一落盘（原子写）；② **cooldown 是本次运行的墙钟期限**，跨重启持久化会把已恢复的源长期排除——加载时清 `cooldownUntil`，但保留 `failures` 让它仍读作 unstable | 同上，上游未动此文件。上游若改 `Record` 字段，保留「加载时清 cooldown」这一条语义 |

> 两个文件都是**上游自 8b9519b 之后从未修改**的文件（已用 `git log` 证实），侵入风险最低；且 `make(...)` 的两个新参都有默认值，上游调用方可零改动编译。

---

#### 本线在融合时修掉的两个真 bug（不是上游的锅，是我方二开版遗留）

1. **折叠状态跨场景污染**（`App/SitesView.swift:278`）——`applyDefaultFold()` 无条件读 `foldState.collapsed`，导致从 Watch Now 推荐「选源」进来时，用户在源页折叠掉的分组**在选源列表里也消失**，选不到源。而 `SourceFoldState` 自己的文档注释就写着「页面一进来就折叠，会读成这页没有源」。已改为 `pick == nil ? (foldState.collapsed ?? []) : []`。
2. **折叠状态被 picker 写回**（`App/SitesView.swift:194`、`:258`）——在 picker 里折叠分组会把结果写进主页面保存的折叠，等于借个页面用却改了它的布局。已改为 `if pick == nil { foldState.save(...) }`。
3. 顺带：折叠状态改在 `init` 里播种（`App/SitesView.swift:34`），不再等 `.task`——原先首帧先画「全展开」再跳成折叠，看得见闪一下。

**为什么选「不动 foldState、只加 pick==nil 门」而不是「给 SourceFoldState 加 picker 专用 key」**：加 key 会让存储层出现「谁在什么场景读哪个键」的隐式约定，将来第三个入口进来又要加 key；把场景判断留在唯一知道场景的视图里（`pick` 就在手边）更省。另一条路写在这里，供 captain 否决。

---

#### 需要 captain 做

**1) Store 主类加存储属性**：无。本线全部能力通过 `App/Store+SourceAdmin.swift` 的 `extension Store` 落地，未向 `App/Store.swift` 提任何字段需求。

**2) 本地化 key**：无新增。本线所有 `L10n.text(...)` 字面量在四语言 `Localizable.strings` 中均已存在（已逐条 grep 验证，见下表）。唯一需要 captain 裁的是**品牌词**：`App/SitesView.swift:637` 用的是 `"Mi3s searches quick, reliable sources first."`，而 lproj 里 **`Mi3s ...` 与 `Yingxia ...` 两条 key 都在**（`zh-Hans.lproj/Localizable.strings:1067` 与 `:1833`）。`project.yml` 的 `CFBundleDisplayName: Mi3s`，故当前显示一致；若 captain 决定文案统一回「映匣」，需改 `SitesView.swift:629` 一处字面量（**本线未擅改**，因为这属于 i18n 汇总口径）。

| key | 消费点 |
|---|---|
| `Probe All` / `Stop Probing` | `SitesView.swift:131,132` |
| `Fix Dead Lines` / `Route Unreachable Lines Through Proxy` / `Force Unreachable Lines Direct` / `Hide Unreachable Lines` | `SitesView.swift:135-142` |
| `Sort` / `Sort by Measured Quality` | `SitesView.swift:152,156` |
| `Moved Sources` | `SitesView.swift:265` |
| `Expand All` / `Collapse All` | `SitesView.swift:247-249` |
| `Customized` / `Edit Source` | `SitesView.swift:75,417` |
| `Name` / `Address` / `The source's API address…` / `Reset` | `SourceEditor.swift:28-64` |
| `Resource Order` / `Segment Sources` | `SettingsTV.swift:116` / `SettingsForm.swift:412` |

**3) project.yml**：无需求（未新增源文件以外的构建输入；`build/AppleRuntime` 已为 `xcodebuild` 门禁建了指向主树的符号链接，`.gitignore` 已忽略 `build/`，不入库）。

**4) 决策请求（判负权归你）**：D-08/D-09 二选一——`SiteView` 到底用上游的「自动续页+Load More 页脚」还是我方的「页码条」。两种都属于「翻页」，混装会同时渲染页脚与页码条。建议**采用上游**（少维护一套分页状态，且 `CatalogBrowser.loadMore` 已在 `Sources/TVCore/CatalogBrowser.swift:60/144` 就绪，本线 144 项单测里已有 `catalogLoadMoreAppendsPagesUntilTheSourceRunsOut` 覆盖）。

---

#### 验证证据（命令输出尾部）

```
$ swift build --package-path Packages/TVCore --target TVCore 2>&1 | tail -3
[Using on-disk description]
[2 / 13]
Build complete! (0.46秒)

$ swift test --package-path Packages/TVCore 2>&1 | tail -6
✔ Suite CloudStreamsTests passed after 16.325 seconds.
✘ Test run with 766 tests in 42 suites failed after 16.327 seconds with 2 issues.
  - ✘ javaHostVersionChangesWithTheConverter()  JavaHostVersionTests.swift:14:24
  - ✘ feedbackSizeLimitsMatchTheServer()       FeedbackAttachmentsTests.swift:154:2
    （两项均为已知基线失败：纯上游 fusion/base 上同样失败，仓库布局问题）

$ swift test --package-path Packages/TVCore --filter "Source|Line|ResourceRanking" 2>&1 | tail -3
✔ Test searchResultsLoadLaterPagesUntilASourceRunsDry() passed after 0.187 seconds.
✔ Test libvioExchangesLineTokensForTheMediaAddress() passed after 0.287 seconds.
✔ Test run with 144 tests in 17 suites passed after 0.368 seconds.     ← 本线 144 项全绿

$ xcodegen generate --spec project.yml && xcodebuild -project TVBox.xcodeproj \
    -scheme TVBox-macOS -configuration Debug -derivedDataPath build/DD-line build 2>&1 | tail -3
** BUILD SUCCEEDED **

$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS -configuration Debug \
    -derivedDataPath build/DD-tvos -destination 'generic/platform=tvOS' \
    build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
** BUILD SUCCEEDED **
```

**平台覆盖**：macOS ✅ / tvOS ✅（两处 `#if !os(tvOS)` 拖拽分支已核：`SitesView.swift:65` 卡片拖拽、`:218` 分组头 dropDestination，tvOS 走 `SourceMoveMenu`/`SourceRouteMenu`）。iOS 未在本机跑（缺 `build/AppleRuntime/iphoneos` 之外的签名链），但本线无 iOS-only API；`SitesView` 里唯一的 UIKit 依赖是在 `VideoDetailView.swift`，不在本线。

---

#### 边界自查

- 未改 `App/Store.swift`：`git diff fusion-main -- App/Store.swift` 为空。全部 Store 侧能力经 `App/Store+SourceAdmin.swift`（extension）。
- 未改 `Sources/TVCore/Resources/*.lproj/Localizable.strings`、`project.yml`、`TVBox.xcodeproj/project.pbxproj`、`Docs/fusion/00~06`。
- 未碰 `App/SiteView.swift` / `App/VideoDetailView.swift` / `App/SettingsForm.swift` / `App/SettingsTV.swift`（他线文件，仅读取用于接线取证）。
- 本线改动仅 3 个文件：`App/SitesView.swift`、`Sources/TVCore/SourceGroups.swift`、`Sources/TVCore/SourceHealth.swift`（后两个为补 `// [mi3s]` 标记，逻辑为已存在的二开内容）。
