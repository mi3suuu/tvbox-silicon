# One vs 哔哩哔哩：架构对照与冗余判定

审查依据：
- One 1.7.1 接口 dump：`Docs/duo/evidence-2026-11-11/One-1.7.1.interface.swift`
- 哔哩哔哩 9.18.0 rea 实证：`Docs/fusion/21-rea逆向-哔哩哔哩UI类族实证.md`
- 我们代码：8 文件 / 7878 行

## 一、两家真实架构

### One：**折缝驱动的单一 Layout**

```swift
struct FoldSplitLayout: SwiftUI.Layout, SwiftUI.Animatable {
    var spacing: CGFloat
    var fold: FoldGap?          // 系统 reservedRegions 给的折缝
    var containerWidth: CGFloat
    func sizeThatFits(...)
    func placeSubviews(...)
}
struct FoldSplit<A,B> {
    var spacing, fold, containerWidth
    var leading: A, trailing: B
}
extension FoldSplit: View {
    typealias Body = _VariadicView.Tree<_LayoutRoot<FoldSplitLayout>, TupleView<(A,B)>>
}
struct LargeCanvas {                                  // 横竖判据：只有 sizeClass
    var _horizontal: Environment<UserInterfaceSizeClass?>
    var _vertical:   Environment<UserInterfaceSizeClass?>
}
struct VideoDetailPage {
    var _wide: LargeCanvas
    var __pageSize: State<CGSize>       // 尺寸：一个 State
    var __division: State<CGRect?>      // 折缝：一个 State
}
```

**核心：形态判据 = `FoldGap`（系统物理事实）；布局 = 一个 Layout 摆两栏；没有形态枚举。**

### 哔哩哔哩：**Top/Bottom/Left/Right 四角色区**

```
BBPlayerPortraitScreen{Top,Bottom}Widget          ← 竖屏只有 2 区
BBPlayerHalfScreen{Top,Bottom,Left,Right}Widget   ← 半屏 4 区
BBPlayerFullScreen{Top,Bottom,Left,Right}Widget   ← 全屏 4 区
```
**核心：不是流式布局，是四个独立角色区；竖屏少 Left/Right，所以控件更少。**

## 二、我们实现的对照

| 角色类型 | 定义 | 使用 | 判定 |
|---|---|---|---|
| `FoldGap` | ✅ | **14 处** | ✅ 已落地 |
| `OcclusionInsets` | ✅ | **12 处** | ✅ 已落地 |
| **`FoldSplitLayout`** | ✅ `FoldRegion.swift:233` | **0 处** | ❌ **写了不用（死代码）** |
| `OcclusionAvoider` | ❌ | 0 | ❌ 未实现 |
| `SideBarsReader` | ❌ | 0 | ❌ 未实现 |
| `VerticalEdgeReader` | ❌ | 0 | ❌ 未实现 |
| `TrailingToolbar` | ❌ | 0 | ❌ 未实现 |
| `GeometryValueReader` | ❌ | 0 | ❌ 未实现 |
| `CappedAspectLayout` | ❌ | 0 | ❌ 未实现 |
| `LargeCanvas` | ❌ | 0 | ❌ 未实现（用容器宽高比自造判据） |

## 三、冗余判定（明确回答）

### 冗余一：`FoldSplitLayout` 写了但没用 — 全额冗余

```swift
// App/FoldRegion.swift:233  完整实现 Layout + Animatable
struct FoldSplitLayout: SwiftUI.Layout, Animatable {
    func sizeThatFits(...)      // 有
    func placeSubviews(...)     // 有
    var animatableData: AnimatablePair<...>  // 有
}
// 全仓使用次数：0
```

**同时**，半折实际用的是手写 VStack 按比例切：
```swift
// OneSkin.swift:1823
let splitRatio = halfFoldSplitRatio
let topH = max(box.height * splitRatio, 1)
VStack(alignment: .center, spacing: 0) { ... }
```

**结论：One 的正确机制（FoldSplitLayout 摆栏）已写好躺在那，而实际跑的是手写比例切分。这是最大的冗余，也是「双栏判不出来」的根因——真正的 Layout 没接线。**

### 冗余二：横竖判据两套 — 部分冗余

| 我们的做法 | One 的做法 |
|---|---|
| 容器宽高比 + 阈值 1.15 + isLargeScreen + 滞回 + QA 覆盖 | `LargeCanvas` 只读 sizeClass + `FoldGap` |

我们把 One 的「一个 sizeClass 读」扩展成了「宽高比 + 5 个补救参数」。**这层扩展本身是冗余**，且每加一个阈值就多一条错路。

### 冗余三：尺寸源三套 — 全额冗余

```
OneSkin.fixedScreenSize()        读 keyWindow.bounds
OneSkin.availableScreenSize(_:)  读 scene.screen.bounds
layoutSize（VideoDetailView）    读 keyWindow.bounds
```
One 只有一个 `__pageSize: State<CGSize>`。

### 冗余四：形态判定分散 4 处 — 部分冗余

```
oneSkinShape → shape 参数 → shapeNow(@State 镜像) → effectiveShape
```
`shapeNow` 实测 `mirror=LAG`（滞后一帧），是振荡源。One 没有镜像是因为**它没有形态枚举**。

## 四、哔哩哔哩那边的冗余（同一套代码里的第二个皮肤）

| 项 | B站真实 | 我们实现 | 判定 |
|---|---|---|---|
| 分区模型 | Top/Bottom/Left/Right 四角色区 | 三行流式 + 绝对定位 | ❌ 结构冗余（自造了一套流式） |
| 竖屏区数 | 2 | 3 行 | ❌ |
| 设置面板 | 3 类 Cell 各自成列 | 9 项单列滚动 | ❌ 结构冗余 |

**注意：B站与 One 的结构不能混用。**
- One = 单一 FoldSplit Layout + 折缝
- B站 = 四角色区（Top/Bottom/Left/Right）

我们现在的 One 皮肤里，既有「按 One 的比例常量」，又有「B站式的 sideRail 绝对定位」。**这是跨皮肤混用造成的冗余。**

## 五、结论

**是的，现有代码设计有明确冗余，共 4 类：**

| # | 冗余 | 严重度 | 后果 |
|---|---|---|---|
| 1 | **`FoldSplitLayout` 已实现但 0 引用**，实际跑手写比例切分 | **HIGH** | 双栏判据失效，这就是今天对不上的根因 |
| 2 | 尺寸源 3 套（fixedScreenSize / availableScreenSize / layoutSize） | **HIGH** | 坐标基准漂移 |
| 3 | 横竖判据从 1 个 sizeClass 扩成 5 个参数 | MEDIUM | 每加一个阈值多一条错路 |
| 4 | One 皮肤里混入 B站式 sideRail 绝对定位 | MEDIUM | 两套布局哲学打架 |

**最小整改路径（不重写）：**
1. 把半折/双栏的 `VStack + splitRatio` 换回 `FoldSplitLayout`（已写好，接线即可）
2. `availableScreenSize()` 改为调用 `fixedScreenSize()`（消第二源）
3. 删除 `shapeNow` 镜像
4. `isLargeScreen` 等补救参数随 FoldSplitLayout 接线一并删除

**预计消掉 800–1200 行**，且把「判据」从推断改回系统事实。
