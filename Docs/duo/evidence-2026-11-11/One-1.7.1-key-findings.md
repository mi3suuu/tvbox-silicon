# One 1.7.1 原版结构证据（MachOSwiftSection 提取）

工具：`rea/MachOSwiftSection/bin/swift-section interface`
输入：`One_1.7.1_致敬韩寒.ipa` → `Payload/One.app/One`
输出：284 Swift 类型 / 478 协议一致性 / 270 成功解析

## 决定性证据 1：VideoDetailPage 的真实字段

```swift
struct VideoDetailPage {
    var _model: SwiftUI.ObservedObject<One.DetailModel>
    let detail: One.ArticleDetail
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
    var _wide: One.LargeCanvas                       // ← 宽屏判据
    var __pageSize: SwiftUI.State<__C.CGSize>        // ← 页面尺寸（State）
    var __division: SwiftUI.State<__C.CGRect?>       // ← 分界区（折叠带）
    var _playLines: SwiftUI.StateObject<One.PlayLines>
    var __playing: SwiftUI.State<Swift.Bool>
    var __autoPlayAfterSwitch: SwiftUI.State<Swift.Bool>
    var __useBuiltinOnce: SwiftUI.State<Swift.Bool>
    var __showEpisodes: SwiftUI.State<Swift.Bool>
    var __bodyExpanded: SwiftUI.State<Swift.Bool>
}
```

## 决定性证据 2：LargeCanvas 只读 size class

```swift
struct LargeCanvas {
    var _horizontal: SwiftUI.Environment<SwiftUI.UserInterfaceSizeClass?>
    var _vertical:   SwiftUI.Environment<SwiftUI.UserInterfaceSizeClass?>
}
```

**没有任何像素级字段**。One 判「宽屏」用的是 size class，
**不是** `GeometryReader` 逐帧量宽高比。

## 这对我们的意义（结论）

| | One 1.7.1 原版 | 我们的实现 |
|---|---|---|
| 宽屏判据 | `LargeCanvas`（size class） | `GeometryReader` 量宽高比 + interfaceOrientation |
| 页面尺寸 | `__pageSize: State<CGSize>`（一次写入） | `frozenBox` + 每帧 `proxy.size` |
| GeometryReader 数量 | **0**（类型骨架里无一次逐帧几何依赖） | **14 个** |
| 折叠带 | `__division: State<CGRect?>` | `FoldGap` + 每帧探针 |

**我们方向错了**：One 用「离散量（size class）+ 一次写入的 pageSize」，
我们用「连续量（proxy.size）+ 每次 body 求值重算」。
连续量驱动布局 = 自反馈环的温床。

## 反推：我们的 294 从哪来

- `screen=951×669`（静态、正确）
- `proxy.height=294`（连续、波动）
- `669 - 294 = 375pt`，无法用任何系统安全区解释（Home 34 / TabBar 49 / 导航 44 / 状态 59）
- ⇒ `294` 是 **`GeometryReader` 在高度未定的父级里，用子视图理想高度反推**得到的

`stage()` 的 5 个 `if/else` 分支返回高度不同的视图，其中 `halfFold`/`fullBleed`
的分支没有 `.frame(height:)` —— 它们的自然高度就是 294。`GeometryReader`
读到的正是这个「内容想要的高度」，然后用它去排版已经钉死 951×669 的内容 → 环。

## 复现命令

```bash
unzip -q "One_1.7.1_致敬韩寒.ipa" -d /tmp/one171
rea/MachOSwiftSection/bin/swift-section interface /tmp/one171/Payload/One.app/One
```
