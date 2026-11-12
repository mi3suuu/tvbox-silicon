# One 1.7.1 类型布局基准（二进制级真源）

**产出命令**（可复现）：
```bash
B=/Users/mi3s/Documents/windows11/编程工具/mac/rea/MachOSwiftSection/bin/swift-section
$B dump --emit-type-layout /tmp/one171/Payload/One.app/One > /tmp/one_typelayout.txt
# 产出 5928 行 / 671 个 Type Layout 记录
```

## 一、布局核心类型（One 自建，不用系统 reservedRegions）

```swift
struct One.LargeCanvas {
    var _horizontal: Environment<UserInterfaceSizeClass?>
    var _vertical:   Environment<UserInterfaceSizeClass?>
}

struct One.FoldGap {            // ★ x 区间，不是角度
    var minX: CGFloat
    var maxX: CGFloat
}

struct One.OcclusionInsets {    // ★ 只有上下两条
    var top: CGFloat
    var bottom: CGFloat
}

struct One.OcclusionAvoider {
    let band: CGFloat
    var __insets: State<OcclusionInsets>
}

struct One.SideBarsReader {
    var _sideBars: Binding<Bool>
}

struct One.VerticalEdgeReader {
    var _sideBars: Binding<Bool>
    var _edge: Environment<HorizontalEdge?>
}

struct One.FoldSplitLayout {    // : Layout, Animatable
    var spacing: CGFloat
    var fold: FoldGap?
    var containerWidth: CGFloat
}

struct One.FoldSplit<A: View, B: View> {
    var spacing: CGFloat
    var fold: FoldGap?
    var containerWidth: CGFloat
    var leading: A
    var trailing: B
}
```

## 二、页面与卡片（含二进制 size）

```swift
struct One.VideoDetailPage {                          // Type Layout: size 480, align 8
    var _model: ObservedObject<One.DetailModel>
    let detail: One.ArticleDetail
    var _settingsStore: ObservedObject<One.SettingsStore>
    var _reduceMotion: Environment<Bool>
    var _wide: One.LargeCanvas
    var __pageSize: State<CGSize>
    var __division: State<CGRect?>        // ★ 折缝矩形，直接存
    var _playLines: StateObject<One.PlayLines>
    var __playing: State<Bool>
    var __autoPlayAfterSwitch: State<Bool>
    var __useBuiltinOnce: State<Bool>
    var __showEpisodes: State<Bool>
    var __bodyExpanded: State<Bool>
}

struct One.EpisodeCard {                              // size 112
    let item: One.CollectionEpisode                   // size 112
    let cover: String                                 // size 16
    let current: Bool                                 // size 1
    let progress: Double?                             // size 9, stride 16
}

struct One.VideoPlayerCard {
    let cover: String                                 // size 16
    let mediaPath: String                             // size 16
    let subtitleURL: String                           // size 16
    let maxSurfaceHeight: CGFloat                     // ★ 唯一以参数形式出现的像素量
    var _model: StateObject<One.VideoPlayerModel>
    var _lines: ObservedObject<One.PlayLines>
    var _settingsStore: ObservedObject<One.SettingsStore>
    var __showSubtitleStyle: State<Bool>
}

struct One.HeroImage {
    let url: String
    var maxHeight: CGFloat
    var _loader: StateObject<One.ImageLoader>
}

struct One.CappedAspectLayout {                       // 比例封顶布局
    var ratio: CGFloat
    var maxHeight: CGFloat
}
```

## 三、与我方对应类型的差距

| One 类型 | 我方 | 差距 |
|---|---|---|
| `FoldSplitLayout: Layout & Animatable` | `App/FoldRegion.swift:233` 已实现 | **零引用**，未接线 |
| `FoldGap{minX,maxX}` | `App/FoldRegion.swift` 有 | ✅ 有，但靠 `reservedRegions` 填 |
| `OcclusionInsets{top,bottom}` | `TVCore` 有 `OneSkinOcclusionInsets` | 方向可能不同（Duo 展开遮挡在左右） |
| `LargeCanvas`（只读 sizeClass） | 无 | 我方用容器宽高比 + 5 个补救参数 |
| `SideBarsReader` | 无 | — |
| `VerticalEdgeReader` | 无 | — |
| `CappedAspectLayout` | 无（用 `bleedingPictureHeight` 手算） | — |
| `__division: State<CGRect?>` | `duoExpanded: Bool`（推导） | **结构性差距**：一个是几何，一个是布尔 |
| `maxSurfaceHeight` 参数 | 我方 `winW/winH` 直接算 | One 显式传"最大画面高" |

## 四、由此推出的关键结论

1. **One 的折缝来自自建 `FoldGap{minX,maxX}`，不是 `reservedRegions`**
   （证据：`strings One | grep -iE "reservedRegion|onHingeChange"` → 空）

2. **`__division: State<CGRect?>` 是几何事实，不是布尔推导**
   ⇒ 我方 `duoExpanded: Bool → sideways: Bool → 分支` 三段推导是结构错

3. **`FoldSplitLayout` 同时是 Layout + Animatable**
   ⇒ 折叠线移动是**布局参数动画**，视图树不重建。我方 `if/else` 分支必然跳变

4. **`CappedAspectLayout{ratio, maxHeight}` 是独立布局类型**
   ⇒ 我方用 `bleedingPictureHeight()` 手算一堆系数，One 是声明式的
