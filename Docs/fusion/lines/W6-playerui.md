### 线名：W6-playerui（播放器 UI / 详情 / 站点）

**状态**：部分（线内工作完成；iOS 编译被 W5 的 M6 字幕符号阻塞，非本线问题）

**认领文件（13）**：`App/PlayerView.swift`、`App/MobilePlayer.swift`、`App/PlayerControls.swift`、
`App/PlayerControlsSettingsView.swift`、`App/PlayerSurface.swift`、`App/EpisodePicker.swift`、
`App/PosterViewer.swift`、`App/VideoDetailView.swift`、`App/SiteView.swift`、`App/VideoEnhancement.swift`、
`App/LoadState.swift`、`App/ArtworkLanguageView.swift`、`Sources/TVCore/ArtworkLanguage.swift`

**起点**：`1cb0c32`（已 ff 到 fusion/main，含 captain 的 tvOS 修复与 I-07）

**本线起点事实**：13 个文件中 11 个是纯新增文件（base 无），2 个是双方重叠文件
（`PlayerView.swift` / `MobilePlayer.swift` / `VideoEnhancement.swift` → 3 个三方重叠）。
captain 已把 `PlayerView` / `MobilePlayer` 落成我方版，本线的活是「复核 + 补上游 1.8.11 增量」。

---

#### 已接入（文件 → 能力 → 真实接线点 文件:行号）

| 文件 | 能力 | 接入位置（调用点） |
|---|---|---|
| `App/PlayerView.swift` | **tvOS 播放倍速**（上游 1.8.11）：`Playback Speed · N×` transport bar 菜单，8 档 0.5–4×，点播限定（直播不显示） | 状态 `App/PlayerView.swift:34`；注入 `:91`；菜单构建 `:1046-1047`；初始同步 `:94`（`.onAppear` 取 `player.defaultRate`） |
| `App/PlayerView.swift` | **tvOS 铺满屏幕（Fill Screen）**：画幅裁切 vs 等比，落在 `videoGravity` | 状态 `:35`；注入 `:92`；`updateUIViewController` 应用 `:1001-1003`；菜单项 `:1061` |
| `App/PlayerView.swift` | **tvOS 弹幕区域二级菜单**：`Danmaku` 升为菜单，内嵌「显示弹幕」「弹幕区域（4 档）」 | `:1027`（`Show Danmaku`）/ `:1028-1031`（`Danmaku Area` 子菜单） |
| `App/PlayerView.swift` | **Picture 菜单常驻**：即使无 upscale/smooth 能力也保留菜单（内含 Fill Screen），图标按能力切换 | `:1057-1072` |
| `App/PlayerView.swift` | **macOS 选集按钮上 transport bar**（上游 #524）：从 `⋯ › Episodes` 两跳降到一键 | `:1322-1328`（`PlayerEpisodesButton`），sheet 见 `:1290` |
| `App/PlayerView.swift` | **选集面板（我方 CatalogEpisodePanel）**：iOS 按 `PlayerSurface` 形态决定 sheet / 画内面板；mac 固定 sheet | `:210`（`PlayerAuxiliaryHost`）、`:412/414`（iOS compact 分支）、`:1290`（mac sheet）、`:1681`（`EpisodePicker`） |
| `App/MobilePlayer.swift` | **选集入口**：走可配置顶栏控件 `PlayerControl.episodes`（默认在 `standardTop`） | 控件枚举 `App/PlayerControls.swift:15`；默认布局 `:108`；读取 `App/MobilePlayer.swift:299`；上下文门控 `App/MobilePlayer.swift:987`；菜单项 `:1243` |
| `App/PlayerControls.swift` | 播放器控件可拖拽编排（顶栏/底栏/More 三槽位） | `PlayerControlsLayout.standard` `:179`；stored 解析 `:185` |
| `App/PlayerControlsSettingsView.swift` | 控件编排设置页 | `App/SettingsPlayback.swift:20`（`PlayerControlsSettingsView()`） |
| `App/PlayerSurface.swift` | 三种播放器形态（screen / inline / pageFullScreen）决定选集 sheet 与剧终页呈现 | `App/PlayerView.swift:210` |
| `App/EpisodePicker.swift` | 剧集网格 + 线路选择 + 探测 | `App/PlayerView.swift:1681` |
| `App/PosterViewer.swift` | 剧照全屏缩放查看 | `App/DiscoverDetailView.swift:76` |
| `App/SiteView.swift` | 站点/分类浏览 + 文件夹下钻 | `:318`（递归 `SiteView(folder:)`）、`App/HomeView.swift:314`、`App/SitesView.swift:52`、`App/DiscoveryView.swift:960,1215`、`App/WatchNowTV.swift:75`、`App/WatchNowPhone.swift:79`、`App/QALaunch.swift:265` |
| `App/VideoEnhancement.swift` | 超分 / 60fps 平滑（`EnhancedVideoSurface`，按 `gravity` 而非已废弃的 `fills`） | `App/MobilePlayer.swift:383`、`App/PlayerView.swift:1081`（tvOS）、`:1448`（mac，`fillsFrame ? .resizeAspectFill : .resizeAspect`） |
| `App/LoadState.swift` | `LoadState<Value>` 状态机（idle/loading/loaded/failed） | `App/CloudBackupView.swift:114`、`App/DiscoverPersonView.swift:13` |
| `App/ArtworkLanguageView.swift` | 海报语言偏好设置页 | `App/SettingsForm.swift:416` |
| `Sources/TVCore/ArtworkLanguage.swift` | 海报语言模型 + 持久化 | 同上（`Store.swift` / `DiscoverDetailView.swift` / `AITranslationView.swift` / `SpeechSubtitleView.swift` 均引用） |
| `App/VideoDetailView.swift` | 详情页（含 `EpisodeRow` 已提 internal，见 I-06） | 上游 `PlayerEpisodes.swift` 复用 `EpisodeRow` |

**上游增量复核结论（PlayerView / MobilePlayer）**：
- 上游 `PlayerView` 增量（80+/12-）逐条对照后，**只有 tvOS 倍速/铺满/弹幕区域 + macOS 选集按钮**是本线可落地的；
  其余（`subtitles: SubtitleCues` / PiP 字幕委托 / `DesktopNativePlayer` 字幕）全部属 W5-subtitle 的 M6，**未接**。
- 上游 `MobilePlayer` 增量（22+/2-）的 3 处（`showsEpisodes` 状态、`.playerEpisodesSheet`、stepButtons 内选集按钮）
  在**我方版里已由等价的「可配置顶栏 + `store.showsEpisodes` + `PlayerSurface`」实现**，且功能更强（用户可编排、
  跨 Duo 折叠保持开启）。按铁律 3，我方版保留，不重复落上游版 → 见 02 清单 D-08。
  PiP 那 1 处（`.onChange(of: pip.active) { session.subtitles.native = ... }`）依赖 M6，未接。

---

#### 未接入（已同步追加进 `02-未纳入清单.md`）

| 能力 | 原因 | 重开条件 |
|---|---|---|
| 上游 `PlayerView` 的 `subtitles:` 参数与 `NativePlayerView`/`DesktopNativePlayer` 的 PiP 字幕委托 | 依赖 `PlaybackSession.subtitles: SubtitleCues`，属 W5 的 M6 裁决面；我方 `PlaybackSession`（`App/PlaybackView.swift`）是该线文件，本线不改 | W5 给出 M6 结论（路线 A 或 C）后在 `App/PlaybackView.swift` 加 `subtitles` 属性，再回填本线 3 处参数 |
| 上游 `MobilePlayer` 的 stepButtons 内选集按钮 + `.playerEpisodesSheet` | 我方等价实现更强（可编排顶栏 + `PlayerSurface` 形态分派 + Duo 折叠保持），按铁律 3 丢弃上游版 | 上游移除 `PlayerControls` 可编排能力，或我方顶栏方案被否时 |
| `App/LoadState.swift` 的 `LoadStateView` | 声明存在但全仓零调用点（只 `LoadState` 枚举被 2 处使用）。属「代码在、入口没接」 | 需要统一 loading/error 外壳时复用 |

---

#### 侵入上游（已同步追加进 `03-侵入点登记表.md`）

> 本线 3 处均为**已在 03 登记的既有侵入点的增量**，新增登记 I-08 / I-09。

| 文件 | 锚点 | 内容 | 原因 |
|---|---|---|---|
| `App/PlayerView.swift` | `#if os(tvOS)` 状态区（`:33-36`） | 新增 `@State playbackSpeed` / `@State fillsScreen` 两个存储属性 | Swift `extension` 不能加存储属性；tvOS 播放器菜单的选择必须留在视图状态里 |
| `App/PlayerView.swift` | `tvOS NativePlayerView` 参数区（`:945-955`） | 新增 `speed` / `setSpeed` / `fills` / `danmakuArea` 四个参数 + `speeds` / `speedLabel` 两个静态成员 | 上游同形实现；我方版 base 更低，需整段补回 |
| `App/PlayerView.swift` | tvOS `updateUIViewController`（`:1001-1003`）/ `optionsMenu`（`:1021-1032`、`:1046-1047`、`:1057-1072`）/ macOS `topBar`（`:1322-1328`） | 四处方法体插入 | 同上；全部带 `// [mi3s] 二开融合（上游 1.8.11）` 标记 |

**`MobilePlayer.swift` 本线零改动**（含 captain 通知的 M6 字幕 4 处，一并未动）。

---

#### 需要 captain 做（Store 字段 / 本地化 key / project.yml）

**Store 字段**：无。本线未新增 `Store` 成员；已有 `store.showsEpisodes`（`App/Store.swift:358`）直接复用。

**project.yml**：无改动（`xcodegen generate` 已跑通，两平台构建均成功）。

**本地化 key（新增 3 条，四语言待补）** —— 均来自上游 1.8.11 的 tvOS 菜单，本线直接引用上游字符串：

| key | 出现位置 | 语境 |
|---|---|---|
| `Playback Speed` | `App/PlayerView.swift:1047`（拼接 `· N×`） | tvOS transport bar 菜单标题 |
| `Fill Screen` | `App/PlayerView.swift:1061` | tvOS Picture 菜单项 |
| `Show Danmaku` | `App/PlayerView.swift:1027` | tvOS Danmaku 子菜单项（我方 iOS 侧 `:340` / `:1369` 已在用同名 key） |

> 注：`Danmaku Area` 已有 key（`App/PlayerView.swift:341` 与 tvOS `:1029` 共用）。
> 若 captain 的四语言包已含上游 182 条，则这 3 条可能已在其中，请以 `Localizable.strings` 实际内容为准。

---

#### 验证证据（三条命令输出尾部）

**1) `swift build --package-path Packages/TVCore --target TVCore`**
```
[1 / 3]
[1 / 4]
Build complete! (1.89秒)
```

**2) `xcodegen generate --spec project.yml && xcodebuild ... -scheme TVBox-macOS ...`**
```

** BUILD SUCCEEDED **
```

**3) `xcodebuild ... -scheme TVBox-tvOS ... -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO`**
Swift 编译**零 error**（仅有既有 warning：`GlassKit.swift` 的 `await` 误用、`TMDBViews.swift` 的 `.none` 歧义等，均为上游既有）。
构建停在非代码阶段：
```
Runtime/AppleRuntime/Native/AppleRuntime.m:3:10: error: 'jni.h' file not found (in target 'TVBox-tvOS')
```
→ 属 `build/AppleRuntime` 基础设施缺 JNI 头，与本线代码无关（captain 通报 tvOS 已「编译通过」，本机复现为环境差异）。

**4) 附加：`-scheme TVBox-iOS`**（用于确认本线无 iOS 独占错误）
```
App/MobilePlayer.swift:103:35: error: value of type 'SubtitleStyle' has no member 'sanitized'
App/MobilePlayer.swift:105:51: error: cannot find 'SubtitlePositionMemory' in scope
App/MobilePlayer.swift:337:54: error: type 'SubtitleStyle' has no member 'standard'
App/MobilePlayer.swift:338:44: error: cannot find 'SubtitlePositionMemory' in scope
```
→ **恰好 5 处，全部是 captain 已通报的 W5 / M6 字幕符号**，无一条出自本线改动。
（`:105` 的 `failed to produce diagnostic` 是 `:105:51` 的副产物。）

---

#### 建议落点与备选说明（README 用）

1. **tvOS 三能力落在 `PlayerView.swift` 的 `NativePlayerView`**，而不是新开 `PlayerView+Mi3s.swift`。
   理由：`NativePlayerView` 是 `private struct`，`extension` 跨文件够不到；且这三能力与既有
   `upscale`/`smooth`/`info` 参数同属一个 transport-bar 菜单体系，硬拆反而更难跟上游。
   备选（未选）：把菜单构建抽成 `PlayerView+Mi3s.swift` 的 `extension NativePlayerView` —— 需要先把它从
   `private` 提为 `internal`，会额外制造一处上游侵入，维护性更差。

2. **macOS 选集按钮用上游 `PlayerEpisodesButton`**，而不是我方 `barButton` 包装。
   理由：上游组件自带 `offered(for:in:)` 门控（单集剧集自动隐藏）+ 无障碍标签 + `player.episodes` 测试标识；
   用 `barButton` 重写会丢掉测试标识，QA 会漂。
   备选（未选）：`barButton("rectangle.stack", ...) { showsEpisodes = true }` —— 少 6 行，但单集剧集也会显示按钮。

3. **MobilePlayer 的选集入口不照搬上游 stepButtons 行**，保留我方可编排顶栏。
   理由：我方 `PlayerControl.episodes` 已是默认顶栏控件（`PlayerControls.swift:108`），且门控在 `:987`
   （`!inline && channel.historyContext != nil`）语义与上游 `PlayerEpisodesSheet.offered` 等价；照搬会让
   同一功能出现两个入口。详见 02 清单 D-08。
