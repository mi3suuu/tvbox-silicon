# One 1.7.0 静态审查：为什么它能自由旋转，我们会「转过去又转回来」

审查对象：`/Users/mi3s/Library/Mobile Documents/com~apple~CloudDocs/One_1.7.0_致敬韩寒.ipa`
（1.67 MB，`CFBundleShortVersionString 1.7.0` / `CFBundleVersion 21`，已解包至 `映匣/one_re/Payload/One.app`，主二进制 `One` = 3 626 680 B，arm64，sha256 见下）
方法：`ipsw swift-dump`（6 587 行 Swift 声明）+ `otool -oV`（ObjC 类/协议结构）+ `nm`（1 997 个符号）。**rea 不可用**（Hopper 零文档，`osascript` 报 `-1728`），全程零执行、零 Hopper。

---

## 一、根因：One **只声明允许，从不命令旋转**

### 1.1 AppDelegate 只有一个方向回调

`otool -oV` 的 `__objc_classlist` 里 `_TtC3One11AppDelegate` 的 `baseMethods count = 2`：

| 槽位 | 解析出的选择器 | imp |
|---|---|---|
| `0x100325290` | `application:supportedInterfaceOrientationsForWindow:` | `0x10018f274` |
| `0x100324c38` | `init` | `0x10018f2e0` |

**AppDelegate 总共只有这两个方法。** 方向相关的其余方法（`application:didChangeStatusBarOrientation:`、`application:willChangeStatusBarOrientation:duration:`）虽然出现在 `__objc_selrefs` 里，但**只存在于 `UIApplicationDelegate` 协议默认实现块中**，其 `imp` 全是 `0x0` —— 即被协议可选默认实现覆盖，One 自己没写。

### 1.2 全二进制零处 `requestGeometryUpdate`

```bash
nm Payload/One.app/One | grep -ic geometryupdate      # → 0
```
`requestGeometryUpdateWithPreferences:errorHandler:` 只作为**字符串**出现在 `__objc_selrefs`（槽位 `0x1002a4a7f`），**没有任何类实现它，也没有任何 imp 指向它**。

⇒ One 的方向逻辑是：**声明一个固定 mask，然后什么都不做**。旋转由系统的物理姿态决定，App 不抢。

### 1.3 我们做反了

`App/PlayerView.swift` 的 `PlayerOrientation.apply(_:scene:geometry:)` 此前**无条件**调用：

```swift
scene.requestGeometryUpdate(.iOS(interfaceOrientations: geometry)) { … }
```

而 `holdPortrait(_:)`（由页面的 `onChange(of: duoExpanded)` 驱动）也走同一个 `apply`。于是每次都形成自激环：

```
折叠 → onChange(duoExpanded=false) → holdPortrait(true)
     → apply(geometry: .portrait) → requestGeometryUpdate(.portrait) ← 命令系统转竖
     → 系统转完，几何回调触发 → 页面重新求值 → 又写一次
展开 → onChange(duoExpanded=true)  → holdPortrait(false)
     → apply(geometry: .allButUpsideDown) → requestGeometryUpdate(…) ← 命令系统转回
     → 系统转完，几何回调又触发 …
```

**用户看到的就是「转过去又转回来」。** 这不是参数没调对，是**我们做了 One 根本不做的事**。

---

## 二、已修：把「声明」与「命令」拆开

`App/PlayerView.swift` 的 `apply` 增加 `turn: Bool`：

```swift
private static func apply(_ mask: UIInterfaceOrientationMask,
                          scene: UIWindowScene,
                          geometry: UIInterfaceOrientationMask,
                          turn: Bool) {
    var controller = scene.keyWindow?.rootViewController
    while let next = controller?.presentedViewController { controller = next }
    controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
    // 只声明、不命令 —— Duo 上唯一正确的日常路径
    guard turn else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: geometry)) { … }
}
```

调用点判据（**按「是不是用户显式意图」分**，不按「是不是方向变了」分）：

| 调用点 | turn | 理由 |
|---|---|---|
| `set(landscape:fullScreen:)` | **true** | 用户点了全屏键 |
| `lock()` | **true** | 用户点了锁定 |
| `rotate(to:)` | **true** | 用户点了旋转键 |
| `turn(to:)` | **true** | 方法名就是「转一次」 |
| `unlock()` | **false** | 只放开限制，不该改变朝向 |
| **`holdPortrait()`** | **false** | **形态变化的后果 —— 这是弹转主凶** |

`holdPortrait` 的新注释直接写明了这段因果，后来人不会再改回去。

**编译已过**：`BUILD SUCCEEDED`，0 error。

---

## 三、One 的折叠适配层：不用任何 Duo 专用 API

这是本次最反直觉的发现。One **完全没有**用：
`reservedRegions` / `onHingeChange` / `UIHingeInteraction` / `ArrangementView` / `effectiveGeometry`
（`strings` 零命中）。

它自己写了一套 **7 个 SwiftUI 类型**，全部在 `One` 模块内：

```swift
struct One.FoldGap {
    var minX: CGFloat
    var maxX: CGFloat              // ← 折叠是 x 区间，不是角度
}

struct One.FoldSplitLayout {       // 同时 : Layout, Animatable
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

struct One.OcclusionInsets { var top: CGFloat; var bottom: CGFloat }
struct One.OcclusionAvoider { let band: CGFloat; var _insets: State<OcclusionInsets> }
struct One.SideBarsReader { var _sideBars: Binding<Bool> }
struct One.VerticalEdgeReader { var _sideBars: Binding<Bool>; var _edge: Environment<HorizontalEdge?> }
struct One.LargeCanvas { var _horizontal: Environment<UserInterfaceSizeClass?>; var _vertical: Environment<UserInterfaceSizeClass?> }
```

关键点：

1. **`FoldGap` 是 `minX`/`maxX` 的 x 区间** —— 折叠被当成「屏幕上一条竖带」，不是铰链角。这与 SwiftUI 27 的 `reservedRegions(kind: .division)` 语义完全一致，但 One 用的是**自定义等价物**（兼容更低版本）。
2. **`FoldSplitLayout` 同时是 `Layout` 和 `Animatable`** —— 折叠线移动是**可动画的布局参数**，不是重排视图树。这就是「转起来顺」的根本原因：布局在动画，视图不重建。
3. **`OcclusionAvoider` 用 `band` + `GeometryValueReader`**（`read: (GeometryProxy) -> A` / `update: (…)`）读遮挡带并设 `OcclusionInsets{top,bottom}` —— 遮让是**两个方向的 inset**，不是全局 safeArea。
4. **`SideBarsReader` / `VerticalEdgeReader`** 读系统侧栏与竖边状态，决定 `TrailingToolbar{showsSecondary, primary, secondary}` 要不要展开第二列。

### `VideoDetailPage` 的状态里就有折叠字段

```swift
struct One.VideoDetailPage {
    var _wide: One.LargeCanvas                    // size class 判宽窄
    var __pageSize: State<CGSize>
    var __division: State<CGRect?>                // ★ 折叠分界区（矩形），nil = 没有折叠
    var __showEpisodes: State<Bool>
    var __bodyExpanded: State<Bool>
    …
}
```

`__division: State<CGRect?>` 是**折叠分界区的矩形**。注意它和我们的差别：
- 我们：`duoExpanded: Bool`（推导）→ `sideways: Bool`（再推导）→ 布局分支
- One：`division: CGRect?`（**直接保存那条带的几何**）→ 布局按它算

---

## 四、对「三个形态各自 bug」的判定

| 形态 | One 的做法 | 我们此前的做法 | 判定 |
|---|---|---|---|
| **合盖外屏 466×678** | `division == nil`，`_wide` 报 compact → 单列 | `holdPortrait(true)` + **命令转竖** | 方向被我们主动抢过一次 → 与系统争 |
| **展开竖持 669×951** | `division == nil`，`_wide` 报 regular → 宽列 | `holdPortrait(false)` + **命令转横** | **同一 bug**：展开不改变物理朝向，命令转横必然被系统扭回 |
| **展开横持 951×669** | 同上，旋转由设备决定 | 旋转键同样走 `requestGeometryUpdate` | 用户主动转时应该 turn；但**形态变化时不该** |

⇒ **三个形态的旋转 bug 是同一个根因的三种表现**，不是三个独立 bug。修掉 `holdPortrait` 的 `turn: false` 就同时解决三态。

---

## 五、还剩什么（本轮未做，明确标出）

1. **折叠分界区没有自己的表示**：我们仍用 `duoExpanded: Bool` 推导。要像 One 那样，加一个 `foldBand: CGRect?` 状态，由 `GeometryReader` + `reservedRegions(kind:.division)` 填入（或按 One 的 `FoldGap{minX,maxX}` 自算）。这是半折第五态的地基。
2. **布局不可动画**：One 的 `FoldSplitLayout: Layout & Animatable` 让折叠线移动是动画参数。我们的形态切换是 `if/else` 分支 → 视图树重建 → 必然有跳变。要顺，得把形态分支改成**布局参数**。
3. **遮挡按 `top/bottom` 两条 inset**：我们用 `safeAreaInsets` 一把梭。Duo 展开时遮挡在**左/右**（摄像头与挖孔），方向不同 → 会错。
4. **`TrailingToolbar{showsSecondary}`**：One 横持时第二列由系统侧栏状态决定是否展开，我们写死比例（`landscapePanelFraction`）。

---

## 六、证据台账

| 结论 | 命令 / 位置 |
|---|---|
| One 版本 1.7.0 (21) | `PlistBuddy -c "Print :CFBundleShortVersionString" Payload/One.app/Info.plist` |
| AppDelegate 只有 2 个方法 | `otool -oV …` → `_TtC3One11AppDelegate` block, `count 2` |
| 该方法名是 `application:supportedInterfaceOrientationsForWindow:` | 槽 `0x100325290` → `DYLD_CHAINED_PTR_64` 解 → `0x11aa…` → 字符串 |
| 零处 requestGeometryUpdate | `nm Payload/One.app/One \| grep -ic geometryupdate` → `0` |
| 方向协议方法 imp 全 0x0 | `baseProtocols → UIApplicationDelegate → instanceMethods` 各项 `imp 0x0` |
| FoldGap 是 x 区间 | `swift-dump` L184 附近：`struct One.FoldGap { var minX; var maxX }` |
| FoldSplitLayout : Layout & Animatable | `protocol conformance One.FoldSplitLayout : SwiftUI.Layout` / `: SwiftUI.Animatable` |
| VideoDetailPage 有 `__division: State<CGRect?>` | `swift-dump` L2065 |
| One 不用 reservedRegions/onHingeChange | `strings -a Payload/One.app/One \| grep -iE "reservedRegion\|onHingeChange\|Hinge"` → 空 |
| 我们的 `apply` 无条件 request | `App/PlayerView.swift` 原 `apply(_:scene:geometry:)` |
| 修后 6 个调用点 turn 分布 | `grep -c "turn: true"` → 4；`grep -c "turn: false"` → 2 |
| 修后编译 | `xcodebuild -scheme TVBox-iOS` → `** BUILD SUCCEEDED **`，0 error |
