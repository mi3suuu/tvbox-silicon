# One 1.7.1 播放页（VideoDetailPage）控件清单与布局常量

日期：2026-11-11 · 输入：`One_1.7.1_致敬韩寒.ipa` / `Payload/One.app/One`（arm64，UUID `EED31CAE-2CBF-3A7A-9A74-CB7A3E26CB0E`）

全文分三类证据，行内逐条标注，不混用：

- **【二】** 二进制实证 —— `swift-section interface` / `dump` / `strings` / 十六进制常量扫描，可复现
- **【测】** 截图程序化实测 —— 像素剖面 + 连通域 + OCR 复核，但**截图对象是 clone 不是 One**（见 §0）
- **【推】** 推断 —— 无直接证据，只给方向不给数字

---

## §0 先纠正一个前提：材料里的 4 张截图不是 One

这一条改变了 B/C 两项的意义，先写在最前面。

`Docs/duo/evidence-2026-11-11/` 下的 6 张 PNG 全部是**我们自己 clone（映匣 OneSkin）**的运行截图，不是 One 1.7.1 原版。三条独立证据：

| # | 证据 | 结论 |
|---|---|---|
| 1 | 截图 OCR 出 8 个 tab：`现在观看 / 发现 / 直播 / 全局搜索 / 音乐 / 点播源 / 网盘文件 / 更多`。这 8 个 key 全部命中 `Packages/TVCore/.../zh-Hans.lproj/Localizable.strings`（`"Watch Now"=现在观看` L7、`"Global Search"=全局搜索` L206、`"Sources"=点播源` L9、`"Cloud Files"=网盘文件` L989）；One 二进制里 `现在观看`/`全局搜索`/`音乐`/`点播源`/`网盘文件` **全部 0 命中**。One 的 `MainTabView` Body 类型只声明 **5 个 tab**（`HomeView / DiscoverView / VodView / FavoritesView / MeView`），数量也不符。 | **【二】** |
| 2 | 截图控制条是 `倍速 1x / 循环 / 适应 / 线路 1`。One 二进制里 `倍速`、`循环`、`适应`、`选集` **各 0 命中**（UTF-8 与 UTF-16-LE 均试）。反向：`"Fit"=适应`、`"Loop Playback"=循环播放`、`"Episodes"=选集` 都在 clone 的 `Localizable.strings`（L2213 / L150 / L331），`App/OneSkinPlayerChrome.swift` 是画这排 chip 的文件。 | **【二】** |
| 3 | 影片标题是 `QA Fixture Movie` —— clone 的 QA fixture；One 二进制 `QA Fixture`/`Fixture` 各 0。同目录 `runtime-layout.log` 通篇 `[OneSkin] stage box=669x951 …` 前缀只存在于 clone，且日志中的 `669x951 / 466x678 / 951x669` 与 6 张图尺寸逐一对上。 | **【二】** |

**因此**：B/C 实测数据只能作为 **clone 回归基线**（记录"我们现在画成什么样"，用于 diff），**不能当 One 的复刻目标**。本文件所有【测】行都按此标注。

真 One 的布局硬数字来自项目记忆 2026-11-08「双 VM 对照」（Fig=One 本体 `com.ios151.one` / Fig-clone=我们），整理见 §4。

---

## §1 A —— 二进制实证控件清单

### 1.1 `VideoDetailPage` 完整存储成员【二】

`swift-section dump --emit-type-layout` 原样输出，顺序即二进制字段顺序：

```swift
struct One.VideoDetailPage {                       // Type Layout: size 480, stride 480, align 8
    var _model: SwiftUI.ObservedObject<One.DetailModel>
    let detail: One.ArticleDetail
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
    var _wide: One.LargeCanvas
    var __pageSize: SwiftUI.State<__C.CGSize>
    var __division: SwiftUI.State<Swift.Optional<__C.CGRect>>
    var _playLines: SwiftUI.StateObject<One.PlayLines>
    var __playing: SwiftUI.State<Swift.Bool>
    var __autoPlayAfterSwitch: SwiftUI.State<Swift.Bool>
    var __useBuiltinOnce: SwiftUI.State<Swift.Bool>
    var __showEpisodes: SwiftUI.State<Swift.Bool>
    var __bodyExpanded: SwiftUI.State<Swift.Bool>
}
```

字段偏移：`detail` 之外全部 `unknown`（`SwiftUI.ObservedObject` 等类型描述符不在镜像内，`dump` 无法串起偏移链）。**没有 `Button`/`Toggle`/`Slider`/`Menu` 类存储属性** —— 控件全部是 body 内的局部视图，没有以字段形式存在的控件句柄。这直接决定了「控件清单」只能从 body 的类型树反推，不能从字段表读。

### 1.2 body 是 opaque，控件从类型树反推【二】

`extension One.VideoDetailPage: SwiftUI.View` 的 `typealias Body = accessor function at 44012`（`0x10000ABEC`）。该地址是 `ModifiedContent.metadata_accessor` thunk，`br x16` 经 GOT 跳 SwiftUI —— **body 的 SwiftUI 类型树在二进制里没有落地**，无法像 `EditorialDetail` 那样直接数 widget。

**这说明 `VideoDetailPage` 的 body 被编译器整体折叠过**（这也是「magic number 被内联/优化」同一机制的另一面）。能定的只有它引用的子视图类型。

### 1.3 播放页实际引用的视图类型【二】

按「谁的类型出现在谁的 Body 里」建图 + `strings` 交叉验证：

| 视图 | 成员（节选） | 角色 |
|---|---|---|
| `VideoPlayerCard` | `cover`, `mediaPath`, `subtitleURL`, `maxSurfaceHeight: CGFloat`, `_model: StateObject<VideoPlayerModel>`, `_lines: ObservedObject<PlayLines>`, `_settingsStore`, `__showSubtitleStyle: State<Bool>` | 播放器外壳。**`maxSurfaceHeight` 是唯一以参数形式出现在类型里的像素量** |
| `VideoSurface` | `player: AVPlayer`, `fill`, `autoFullscreen`, `subtitleText`, `subtitleFontSize: Double`, `subtitleOpacity: Double`, `subtitleBackgroundOpacity: Double`, `orientationOwner`, `onFullscreen` | `UIViewRepresentable`（`Body = Swift.Never`）→ **实际画面是 UIKit，不是 SwiftUI** |
| `VideoPlayerModel` | 见 §1.4 | 播放状态机全部在这里 |
| `EpisodesSheet` | `episodes: [CollectionEpisode]`, `currentId: Int`, `onSelect`, `_dismiss` | 选集弹层：`NavigationStack > List > ForEach > Button<EpisodeRow>` + `.toolbar` 一个 `Button<Text>` |
| `EpisodeCard` | `item`, `cover`, `current: Bool`, `progress: Double?` | 集数卡：`ZStack(RemoteImage, LinearGradient)` + `.frame` + 3 层 `.overlay`（集号胶囊 / 图标 / `ProgressView`）+ `.clipShape(RoundedRectangle)` + 描边 |
| `EpisodeRow` | `item`, `current: Bool` | 选集行 |
| `LineMenu<A>` | `_lines: ObservedObject<PlayLines>`, `label: () -> A` | 线路菜单：泛型 label + PlayLines |
| `PlayLine` | `url`, `index`, `latency: Int?`, `failed: Bool` | 单条线路 |
| `FavoriteButton` | — | 收藏：`Menu<Image>`，两项 `MenuStyle = .borderlessButton` |
| `DownloadCard` | `detail`, `coverURL`, `_center`, `__resolving`, `__errorText` | 下载卡：`VStack(Text, DownloadItemRow | Button<Label>, Text)` |
| `DownloadIconButton` | `detail`, `coverURL`, `_center` | 下载图标：`Button<Image>` + `.plain` |
| `TagChips` | — | 标签：`_VariadicView.Tree<_LayoutRoot<FlowLayout>>` + ForEach + NavigationLink + capsule 背景 |
| `FlowLayout` | `spacing: CGFloat`, `lineSpacing: CGFloat` | 自定义 `Layout`（标签换行） |
| `AmbientBackground` | `cover: String` | 背景：`ZStack(Color, RemoteImage×scale+opacity, LinearGradient)` + `ignoresSafeArea` |
| `SubtitleStyleSheet` | `_settingsStore`, `_dismiss` | 字幕样式：3 组 `HStack(Text, Spacer, Text)` + **`Slider<Text,Text>` ×3** |

### 1.4 播放控制栏的真实组成【二】

`VideoPlayerModel`（节选，全部 `Combine.Published`）：

```
_hasSource: Bool      _source: Source(.local/.hls/.mp4)   _error: String
_failure: Error?      _currentLineURL: String             _speed: Double
_loop: Bool           _fill: Bool                         _autoFullscreen: Bool
_resumeAt: Double     _hasSubtitle: Bool                  _subtitlesEnabled: Bool
_subtitleText: String _stats: String
```

→ 控制栏的**语义能力**是：**播放/暂停（`__playing`）· 倍速（`_speed`）· 循环（`_loop`）· 填充/适应（`_fill`）· 线路选择（`LineMenu` + `PlayLines`）· 字幕（`_hasSubtitle`/`_subtitlesEnabled`/`subtitleFontSize`/`subtitleOpacity`）· 自动全屏（`_autoFullscreen`）· 续播（`_resumeAt`）**。

**没有**：弹幕、画质切换、音轨切换 —— `VideoPlayerModel` 与全部 284 类型里均无对应字段，`strings` 里 `弹幕`/`音轨`/`画质` 各 0 命中。**这三个是 clone 后来加的，不在 One 1.7.1 内。**

One 唯一的 `Slider` 出现在 `RadioPlayerBar`（电台条：`Slider<EmptyView,EmptyView>` + `Text` 时间对）与 `SubtitleStyleSheet`，**播放器进度条不是 SwiftUI `Slider`** —— `VideoSurface` 是 UIKit（`Body = Swift.Never`），进度条在 `AVPlayerViewController` 内部。这一条很重要：**One 的播放器控件栏不在 SwiftUI 里，像素级复刻不可能靠读 SwiftUI 类型得到**。

### 1.5 全库控件类型计数【二】

`One-1.7.1.interface.swift` 全文出现次数：`Button` 117 · `HStack` 80 · `Label` 68 · `VStack` 65 · `ZStack` 10 · `TextField` 10 · `Picker` 9 · `ProgressView` 8 · `ScrollView` 5 · **`Slider` 4** · **`Menu` 4** · `Divider` 4 · `TabView` 3 · `LazyVStack` 3 · `LazyVGrid` 2 · **`GeometryReader` 2**。

`GeometryReader` 全库仅 2 处，且两处都是 `ContentTopProbe` / `ScrollZoneReader`（滚动位置探针），**播放页零 `GeometryReader`** —— 与既有结论一致。

**排除项（浏览器/WebView）**：`strings` 有 `TrustedSessionDelegate { requireSameHost: Bool }`、`NoRedirect`，属内置浏览器会话守卫，与播放页无关，不列入。

---

## §2 布局常量：二进制里确实没有（但比"内联"更精确的说法）【二】

做了三层扫描，结论比「magic number 被优化掉」更具体：

1. **全文件 double 扫描**：遍历整镜像 4 字节对齐的全部 8 字节，落在 `[0.05, 1.0]` 区间的**只有 57 个不同值**。目标常量的近邻命中：`0.868`/`0.856`/`0.928`/`0.455`/`0.513`/`0.5167`/`0.5334`/`0.538`/`0.339`/`0.625`/`0.251`/`0.68` **全部 0 命中**；只有 `0.55`(×2)、`0.4`(×1)、`0.36`(×1)、`0.09`/`0.0928` 存在。
2. **`__TEXT` 段内 `[0.05,1.0]` 双精度：0 个**。即播放页的比例常量连字面量池都没进。
3. **`__const`(`0x10022B500`, 88708B) 里现存的比例簇**是 `0.5/1.0/0.08/0.85/0.92/0.55/0.88` 与 `0.22/0.12/0.086/0.0508` 等，**无一与播放页观测比例对应**。

→ **One 1.7.1 里不存在一份"播放页布局常量表"可供提取。** 比例要么由 `FoldSplitLayout` / `CappedAspectLayout`（都是自定义 `Layout`，`sizeThatFits`/`placeSubviews`）在运行时算，要么由 `SwiftUI` 内置 modifier 隐式决定。**这一项无法从二进制补全，只能实测。**

`FoldSplitLayout` / `CappedAspectLayout` / `FlowLayout` 三个自定义 `Layout` 的存在【二】值得记一笔：`FoldSplitLayout` 字段是 `spacing / fold: FoldGap? / containerWidth: CGFloat / leading / trailing` —— One 的双栏切分是**自己实现的 Layout**，不是 `HStack` + 比例 frame。

---

## §3 B/C —— 截图实测（基准 = clone/OneSkin 回归基线）

方法：`PIL` 逐行/逐列颜色剖面求边界 → 亮墨迹（`mean gray > 95`）连通域求每控件 bbox → 每一条带单独裁剪后 `vision_ocr` 复核文字，**确保标签与坐标不错行**。1px = 1/3 pt。

### 3.1 形态 2：`2-unfolded-upright-669x951.png`（669×951pt，单列）

| 控件 | y (pt) | y 比例 | x (pt) | x 比例 | 高度 (pt) | 基准 |
|---|---|---|---|---|---|---|
| 顶栏（纯色条，无可见控件） | 0.0 – 50.7 | 0.000 – 0.053 | 0 – 669 | 0.000 – 1.000 | 50.7 | 整屏 |
| **播放器块** | 50.7 – 583.0 | 0.053 – 0.613 | 0 – 669 | 0.000 – 1.000 | 532.3 | 整屏 |
| 控制条 chip 行（`倍速 1x 循环 适应 线路 1`） | 504.0 – 515.3 | **0.530 – 0.542** | 46.0 – 609.3 | 0.069 – 0.911 | 11.3 | 播放器块内 |
| 标题 `QA Fixture Movie` | 594.3 – 608.3 | 0.625 – 0.640 | 27.0 – 159.7 | 0.040 – 0.239 | 14.0 | 整屏 |
| 集信息 `第 1 集 · 第 1 集` | 622.0 – 632.7 | 0.654 – 0.665 | 26.7 – 105.7 | 0.040 – 0.158 | 10.7 | 整屏 |
| 元信息 `2024 · 共 1 集` | 643.3 – 652.3 | 0.676 – 0.686 | 27.0 – 97.0 | 0.040 – 0.145 | 9.0 | 整屏 |
| **播放按钮 + 4 个动作图标** | 669.0 – 714.7 | 0.703 – 0.751 | 26.0 – 319.3 | 0.039 – 0.477 | 45.7 | 整屏 |
| 标签胶囊 `2024` | 736.3 – 743.3 | 0.774 – 0.782 | 36.7 – 60.0 | 0.055 – 0.090 | 7.0 | 整屏 |
| 简介 `Fixture.` | 768.3 – 776.0 | 0.808 – 0.816 | 27.0 – 63.7 | 0.040 – 0.095 | 7.7 | 整屏 |
| `合集 · 共 1 集` + `选集 ▼` | 791.3 – 808.7 | 0.832 – 0.850 | 26.3 – 601.3 | 0.039 – 0.899 | 17.3 | 整屏 |
| 底部 dock（8 tab） | 824.7 – 950.7 | 0.867 – 1.000 | 26.0 – 534.3 | 0.039 – 0.799 | 126.0 | 整屏 |

播放按钮行横向分段（连通域，判「播放键 / 收藏 / 下载 / 分享 / 更多」5 组）：`26.0–185.7`（播放胶囊，w 159.7）· `210.3–223.7` · `243.7–253.7` · `275.0–287.0` · `306.7–319.0`，**单位 x 比例 = 0.039–0.278 / 0.314–0.334 / 0.364–0.379 / 0.411–0.429 / 0.458–0.477**。

**注意两个必须记住的事实**：
- 控制条 chip 行在 **播放器块内部**（y 比例 0.530），不在整屏底部 —— 与 clone 代码里「chip 行贴画面列下沿」的设计一致，与「0.868 固定底栏」不是同一回事（见 §4 冲突项）。
- 播放器块 **669×532.3 = 比例 1.257**，不是 16:9。若按 669 宽 16:9 应为 376.3pt 高，**上下各余 78pt**（letterbox）。这确认「窗口尺寸固定、片源比例交给 videoGravity」的设计【测】。

### 3.2 形态 5：`5-fullscreen-portrait-466x678.png`（466×678pt，全屏竖持）

| 控件 | y (pt) | y 比例 | x 比例 | 高度 (pt) | 基准 |
|---|---|---|---|---|---|
| 顶栏 | 0.0 – 50.7 | 0.000 – 0.075 | 0.000 – 0.999 | 50.7 | 整屏 |
| 播放器块 | 51.0 – 347.0 | 0.075 – 0.512 | 全宽 | 296.0 | 整屏 |
| chip 行 `倍速 1x 循环 适应 线路 1` | 351.0 – 362.3 | **0.518 – 0.534** | 0.089 – 0.906 | 11.3 | 播放器块内 |
| 标题 `QA Fixture Movie` | 365 – 377 | 0.538 – 0.556 | — | ~12 | 整屏 |
| 集信息 | 380 – 389 | 0.560 – 0.574 | — | 9 | 整屏 |
| 元信息 | 389 – 405 | 0.574 – 0.597 | — | 16 | 整屏 |
| 播放/动作行 | 410 – 433 | 0.605 – 0.639 | — | 23 | 整屏 |
| 标签 / 简介 / 合集 / 选集 | 451 – 497 | 0.665 – 0.732 | — | 46 | 整屏 |

全屏态 **画面块铺满整列**（`winW=colW, winH=colH`），与 clone 代码 `fullScreen → winW=colW/winH=colH` 一致【测】。控制 chip 行仍在画面块内（0.518），**不出现在全屏底部**。

### 3.3 形态 1 / 6：`1-cover-466x678.png`、`6-cover-landscape-678x466.png`（678×466pt 横向）

两张图**内容实质相同**（`1-` 与 `6-` 逐像素仅 2092px 差异，为时钟/重绘噪声），是一块**几乎空的蓝色渐变**：

- 行剖面只有 2 段：`y 0–221.3` / `221.3–466`；列剖面在 `x=71.7pt`(0.106) 与 `x=215.7pt`(0.317) 有强边（`Δ=86.6`），其余平坦；`0.5334` 处**左右均值差 0.00**（完全不可见）。
- 可视内容仅左侧竖排浮动工具栏（5 个图标）+ 底部一块卡片轮廓。
- **没有播放器窗口、没有控制条、没有标题文字。**

→ 形态 1/6 **不能提供任何播放页控件坐标**。它们是「未进入详情 / 骨架态」或纯背景帧。**明确标注：这两张对本任务无信息量，不编造。**

（`4-fullscreen-landscape-678x466.png` 同为纯渐变，`bright px = 2299`、`dark px = 9`，同样无控件。）

### 3.4 明确「不确定」的项

| 项 | 状态 |
|---|---|
| 左列/右列宽度比例（clone 横向） | **无法测得** —— 形态 1/6 的 `0.5334` 处像素差为 0.00，该形态下没有可分辨的栏边界 |
| 顶栏内是否有返回/标题/更多按钮 | **不确定** —— 顶栏是高 50.7pt 的**纯色块**，亮墨迹连通域只有 1 个整行块，`mean gray` 无局部峰。判定为「无可见控件」，但不排除控件是同色系低对比 |
| 播放器块内进度条/时间码 | **未观测到** —— 该帧画面是纯色（player band 内 `max brightness` 除 chip 行外全 ≤75，无进度条亮线）。视频未起播，控件未出现 |
| 标签胶囊的完整宽度 | 仅读到 `2024` 文字 bbox（7.0pt 高），胶囊背景与文字同色系，边界不可分 |

---

## §4 D —— 真 One 实测值对照表（来自 2026-11-08 双 VM 对照）+ 代码冲突

以下数字来源是项目记忆（Fig = One 本体 `com.ios151.one`，同一台 Fig VM 上逐控件量），**不是**本轮截图。标 **【记】**。

| # | One 实测（Fig 2034×1398 ÷3 = pt） | 出处 | 当前 clone 代码 | 一致性 |
|---|---|---|---|---|
| 1 | 画面右边界 = **51.3%**（x1044px） | 【记】 | `Metrics.columnLeft = 0.5334` | 一致（51.3% vs 53.34%，同一量不同次测量，差 2.04pt@678） |
| 2 | 画面内容**垂直居中**（y331–888px） | 【记】 | 顶到顶 y0 | **不一致**（已知问题） |
| 3 | 详情栏 **15 段清晰分层**：标题 y28 / 继续播放 y129 / 标签 y273–309 / 选集 y349–403 | 【记】 | — | 见下方单位陷阱 |
| 4 | 背景 One 深色（左 `RGB 14,12,13` 右 `52,50,50`） | 【记】 | 亮色（左 46 右 110） | **不一致**（已知） |
| 5 | 左列播放器窗口 **171×318pt**，宽高比 **0.538**，占左列宽 **33.9%–62.5%**、高 **25.1%–68.0%** | 【记】 | `insetLandscape=0.0333`、`landscapeCentre=0.455` | 部分（0.0333 = 33.9% 的左缩进对得上；窗口宽高比见 #6） |
| 6 | 左列公式：`高 = max(colH×0.4, 360)`、`宽 = 高×aspectRatio`、垂直中心 `colH×0.455`、水平居中 | 【记】后被 2026-11-08 17:48 条目**自我否证**：竖屏 `2034×0.4=814` vs 实测 `735`，差 11% → 真公式改为 `winW = 列宽 − 2×inset`、`winH = winW ÷ aspectRatio`（横屏 `1015÷1.819=558` ✅、竖屏 `1332÷1.811=735` ✅） | `windowAspect = 1.819`、`minPictureHeight = 120` | **已更新**：`0.4`/`360` 为废止结论，勿再用 |
| 7 | 底部胶囊条固定 `colH × 0.856` | 【记】 | **`0.868`**（`App/OneSkin.swift:1758` `ratio.height * (1 - 0.868)`） | **冲突，差 0.012** |

### 4.1 关于 `0.856` vs `0.868` 的明确结论

- 记忆里的 **0.856** 与代码里的 **0.868** 都**不能**被图标测复核：形态 2 的 chip 行落在 **0.530–0.542**（画面块内），形态 5 落在 **0.518–0.534** —— 两者都不是 0.856/0.868 量级。也就是说，**0.868 这个常量在当前两形态下根本不是 chip 行的位置**。
- 二进制侧：`0.856` 与 `0.868` 均 **0 命中**（§2），无法裁决。
- **判定**：`0.856`（记忆）是 One 横屏双列下胶囊条的**列高比例**；`0.868`（代码）只在 `landscapeNow` 分支生效（`ratio.height * (1 - 0.868)` 用作 `bottom padding`）。两者是**同一个量的两次独立取值**，且代码里的注释写着「2026-11-09 改成跟画面列走」，说明 0.868 是针对另一形态引入的。**这不是笔误冲突，而是「同一个名字挂了两个不同形态的位置」，建议拆成两个具名常量（横屏底栏 / 竖屏画面下沿），并各自与 One 实测对齐后再定值。** 在拿到真 One 截图前，`0.856` 优先（它是直接实测值，0.868 是推导值）。

### 4.2 记忆条目的单位陷阱（必须继承）

【记】2026-11-08 18:21 条目：One 的 y 值是「**容器 466pt 下的 pt**」，不能再乘 `colH/466`，否则线性放大 1.437 倍（实测 标题 24→42、播放 167→248、评论 312→456）。改用 `at(y) = y - 8`（8pt = ScrollView 内容顶部 inset，恒定偏移）。§4 表 #3 的 y28/129/273/349 属这一套坐标系。

---

## §5 可直接写进 SwiftUI 的常量表

### 5.1 可直接落地（基准 = clone 回归基线，非 One）

仅列【测】中**内部自洽且 OCR 已复核**的量。比例保留 3 位小数。

```swift
// ── 回归基线：clone(OneSkin) 实测，2026-11-11，非 One 原版 ──
// 形态 2 (669×951pt, 单列)
enum CloneBaseForm2 {
    static let topBarHeightRatio: CGFloat      = 0.053   // 50.7 / 951
    static let playerTopRatio: CGFloat         = 0.053
    static let playerHeightRatio: CGFloat      = 0.560   // 532.3 / 951
    static let chipRowYRatio: CGFloat          = 0.530   // 画面块内（非整屏底部）
    static let chipRowInsetLeftRatio: CGFloat  = 0.069
    static let chipRowInsetRightRatio: CGFloat = 0.089   // 1 - 0.911
    static let titleYRatio: CGFloat            = 0.625
    static let episodeYRatio: CGFloat          = 0.654
    static let metaYRatio: CGFloat             = 0.676
    static let playRowYRatio: CGFloat          = 0.703
    static let playRowHeightRatio: CGFloat     = 0.048   // 45.7 / 951
    static let tagYRatio: CGFloat              = 0.774
    static let synopsisYRatio: CGFloat         = 0.808
    static let collectionYRatio: CGFloat       = 0.832
    static let dockTopRatio: CGFloat           = 0.867
    static let contentInsetLeftRatio: CGFloat  = 0.039   // 26pt / 669
}
// 形态 5 (466×678pt, 全屏竖持)
enum CloneBaseForm5 {
    static let topBarHeightRatio: CGFloat = 0.075  // 50.7 / 678
    static let playerHeightRatio: CGFloat = 0.437  // 296 / 678
    static let chipRowYRatio: CGFloat     = 0.518
}
```

### 5.2 需要真 One 截图才能定值（禁止现在编数）

| 常量 | 为什么不能定 |
|---|---|
| 横屏左列宽 / 间隙 / 右栏宽 三件套 | 形态 1/6 无栏边界（`0.5334` 处像素差 0.00） |
| 播放器窗口的垂直中心 | 形态 2 是单列铺满，测不出「居中」与否 |
| 详情栏 15 段分层的 y | 只有【记】的 4 个点（28/129/273/349），其余 11 段无数据 |
| 胶囊条 0.856 / 0.868 | 二进制 0 命中，两形态实测均不落在该量级（§4.1） |
| 进度条 / 时间码 / 播放键三键 | 该帧视频未起播，控件未绘制 |
| 任何字号、圆角、间距 | 截图无对应可测边界 |

---

## §6 复现命令

```bash
unzip -q "One_1.7.1_致敬韩寒.ipa" -d /tmp/one171
B=rea/MachOSwiftSection/bin/swift-section

# 成员 + 布局 + 字段偏移
$B dump /tmp/one171/Payload/One.app/One \
   --emit-field-offsets --emit-type-layout --preferred-binary-order \
   -s types -o /tmp/one171_types.txt

# 全量 interface
$B interface /tmp/one171/Payload/One.app/One --emit-header > /tmp/one171.interface.swift

# 常量扫描（§2 三层）
python3 -c "
import struct
f=open('/tmp/one171/Payload/One.app/One','rb').read()
for t in [0.868,0.856,0.928,0.455,0.513,0.5334,0.538,0.339,0.625,0.251,0.68]:
    print(t, f.count(struct.pack('<d',t)))"

# clone 判定（§0）
python3 -c "
d=open('/tmp/one171/Payload/One.app/One','rb').read()
for w in ['现在观看','全局搜索','点播源','网盘文件','倍速','循环','适应','选集','QA Fixture']:
    print(w, d.count(w.encode()), d.count(w.encode('utf-16-le')))"
```

截图测量脚本要点（§3）：行/列颜色剖面（`max channel delta > 5` 分段）→ 亮墨迹 `mean gray > 95` 连通域 → 每条带单独裁剪后 OCR 复核。**不复核必错行**（本轮初测曾把 chip 行错标到标题带，OCR 才发现）。

---

## §7 一页结论

1. **A 完成**：`VideoDetailPage` 13 个存储成员全部拿到；控件清单靠子视图类型树给全（`VideoPlayerCard` / `EpisodeCard` / `LineMenu` / `TagChips` / `DownloadCard` / `FavoriteButton` / `SubtitleStyleSheet`）。
2. **One 的播放器控件栏不在 SwiftUI 里** —— `VideoSurface` 是 UIKit（`Body = Swift.Never`），进度条/时间码在 `AVPlayerViewController` 内部。**任何「读 SwiftUI 类型复刻播放器控件」的路线从根上不成立。**
3. **二进制里没有布局常量表**，且这不是「被优化掉」而是「从未以字面量存在」（`__TEXT` 内 `[0.05,1.0]` double = 0 个）。One 靠自定义 `FoldSplitLayout`/`CappedAspectLayout` 在运行时算。**布局只能实测。**
4. **材料里没有一张 One 原版播放页截图**，6 张全是 clone。故 B/C 是 clone 回归基线，不是复刻目标。真 One 的硬数字只有【记】的 7 条（§4），其中 #6 已被自我否证、#7 与代码冲突。
5. **下一步唯一有意义的动作**：在 Fig VM（`com.ios151.one` 已装）按 `1-cover / 2-unfolded-upright / 3-unfolded-sideways / 5-fullscreen-portrait` 四形态补拍真 One 截图，然后用本文件 §3 同一套脚本重跑，直接替换 §5.2 的空格。在此之前，任何填入 §5.2 的数字都是编的。
