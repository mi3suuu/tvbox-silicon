# 三种播放皮肤 × 三种 Duo 形态 —— UI 错绘与小窗误开审查

审查对象：`tvbox-silicon-fusion` @ `fusion/restructure-A`(`5a9ff94`)
审查视角：iPhone Duo `iPhone19,4` / iOS 27.1，静态代码 + SDK 27.2 头文件实证
皮肤：`native`（上游原版）/ `one`（One）/ `bilibili`（哔哩哔哩），由 `playSkin` 三选一
形态：① 合起外屏 466×678 ② 展开竖持 669×951 ③ 展开横持 951×669
（尺寸取自 `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/.../capabilities.plist`：screenID 1 = 1398×2034@3 = **466×678**；screenID 3 = 2007×2853@3 = **669×951**）

---

## 0. 先拉到的 GitHub 适配 skill（3 个，已本地克隆）

克隆到 `映匣/duo-skills/`：

| 仓库 | 体量 | 真正可用的部分 | 使用风险 |
|---|---|---|---|
| `hiETsang/iphone-duo-adapter-skill` | SKILL.md 13KB + 6 篇 references + 31KB 总指南 | 六阶段流程、`reservedRegions`/`onHingeChange`/`ArrangementView` 用法、API cheatsheet | **含不存在的 API**（见下），照抄会编译不过 |
| `vanohezy/iPhone-Duo-adaptation` | SKILL.md 6.6KB + 5 篇 references + `audit_layout.py` | 证据分层纪律、`audit_layout.py` 只读扫描器（实测可跑，本仓 324 条候选） | 偏设计规范，无本项目可用的代码 |
| `Damon-DDD/iphone-duo-swiftui-adaptation` | SKILL.md 8.4KB + `duo-metrics.md` | **屏幕尺寸/形态判定/安全区三条硬结论**，与本次实测完全一致 | 只覆盖单/双列布局，不涉及播放器与 PiP |

### 0.1 skill 声称的 API 逐条核过 SDK（iPhoneOS27.2.sdk）

| skill 写法 | SDK 实际 | 结论 |
|---|---|---|
| `proxy.reservedRegions(kind: .division)` / `.occlusion` | `SwiftUICore.View.reservedRegions(kind:options:layoutDirectionBehavior:) -> [ReservedRegion]`，`ReservedRegion.Kind.division/.occlusion` 均存在，`@available(anyAppleOS 27.1)` | ✅ 可用（需 27.1 门） |
| `.onHingeChange { _, ctx in ctx.hinge }` | `onHingeChange(isEnabled:_:) -> View`，闭包收 `(DeviceHingeContext, DeviceHingeContext)`，`DeviceHingeContext.hinge: DeviceHinge?` | ✅ 可用（需 27.1 门） |
| `ArrangementView { } secondary: { }` | `ArrangementView.init(primary:secondary:)`、`.arrangementViewStyle(_:)`、`.split.axes(...)` 均在 SwiftUICore | ✅ 可用 |
| `.axisBehavior(.verticalPreferred)` / `.topBarPinnedTrailing` / `.visibilityPriority(.high)` | SwiftUI 均存在 | ✅ 可用 |
| **`.toolbarCompressionBehavior(.prefersToolbarItems)`** | **全 SDK 无此符号**；真名是 `toolbarVerticalCompressionBehavior(_:)` + `ToolbarVerticalCompressionBehavior` | ❌ **skill 写错，禁止照抄** |
| `AVCaptureDeviceType.builtInOuterUltraWideCamera` / `...InnerUltraWide` | AVFoundation 存在，`API_AVAILABLE(ios(27.1))` | ✅ 可用（本项目不用相机） |

> 教训：这三个 skill 都是 LLM 生成的二手资料，**任何 API 名在使用前必须过一遍 SDK swiftinterface**。本次只靠 `grep` 就抓到 1 个伪造 API。

### 0.2 本项目与 Duo 专用 API 的距离

* `project.yml` 的 `deploymentTarget.iOS = '17.0'`。
* 全仓 `reservedRegions` / `ArrangementView` / `onHingeChange` / `UIHingeInteraction` / `effectiveGeometry` **一个都没用**（grep 零命中）。
* 也就是说：**本项目对 Duo 的适配全部靠 size class + `interfaceOrientation` + 硬编码实测值，没有用到任何 Duo 的铰链/保留区 API**。这既是当前 bug 的根，也是后续修法的入口。

---

## 1. 三皮肤 × 三形态的能力矩阵（先看这张，后面所有 bug 都从这里长出来）

| | 画面宿主 | 应用外小窗（PiP） | 应用内小窗 |
|---|---|---|---|
| **native** | `OneStylePlayerSurface` → `AVPlayerViewController`（AVKit 托管） | AVKit 自动浮起 `automaticPiP: true`（`MobilePlayer.swift:1702`） | `PlayerView.miniplayer()` → `miniPlayerActive = true` |
| **one** | `OneSkinFixedPicture` → 裸 `AVPlayerLayer` | 自建 `AVPictureInPictureController`，`pip.attach()` 逐次登记 | `onMiniPlayer` → `miniPlayerActive = true`（`VideoDetailView.swift:2714`） |
| **bilibili** | `BiliSkinPicture` → 裸 `AVPlayerLayer` | **完全没有**（`BiliSkinPicture` 无 `pip` 参数） | **完全没有**（全屏「小窗」键误接 PiP，见 BUG-01） |

---

## 2. BUG 清单（按严重度）

### BUG-01 · blocker · 哔哩哔哩皮肤的「小窗」键既不开应用内小窗、也开不出应用外小窗

`App/VideoDetailView.swift:2423`
```swift
onMiniScreen: { PictureInPicture.startCurrent() },
```
`App/MobilePlayer.swift` `startCurrent()`：
```swift
guard let controller = current, !controller.isPictureInPictureActive,
      controller.isPictureInPicturePossible else { return }
```
而 `PictureInPicture.current` 的唯一赋值点在 `pictureInPictureControllerWillStartPictureInPicture`
（`MobilePlayer.swift:2479`），它只可能被 **已 attach 的 controller** 触发；
哔哩哔哩的画面走 `BiliSkinPicture`（`App/BiliSkin.swift:314`），结构体里**没有 `pip` 参数、从不 `attach`**。
⇒ `controller == nil`，`startCurrent()` 是**空函数**。用户在哔哩哔哩全屏点右侧那颗 `pip` 图标，**永远没有任何反应**。

同时，哔哩哔哩皮肤**没有** `onMiniPlayer` 入口（`biliSkinBody` 全套参数里没有该项），
所以这个皮肤下「应用内小窗」这条功能**整条不可达**。

**连带后果（更严重）**：`App/RootView.swift:743`
```swift
pipPossible: PictureInPicture.current != nil,
```
哔哩哔哩皮肤下恒为 `false` → `PlaybackExit.decide` 走 ③b 分支返回 `.keep`
→ **离开 App 时不浮窗、也不登出，音频在后台空转**，用户既看不到浮窗也没有入口停。
这正是 `PlaybackExit.swift` 头部注释里说要消灭的「第四态」，在哔哩哔哩皮肤下**仍然存在**。

> 修法方向：给 `BiliSkinPicture` 加 `pip: PictureInPicture?` 参数并在 `makeUIView/updateUIView` 里 `attach`（照抄 `OneSkinFixedPlayerLayer` 的写法，注意 `shouldRender` 闸）；同时把 `onMiniScreen` 改成真正的应用内小窗入口（`store.miniPlayerActive = true` + `dismiss()`），PiP 单独给一颗按钮。

---

### BUG-02 · blocker · 「换向/折叠时临时关掉自动浮起」的防护函数**不存在**，注释是空头支票

三处注释都指向 `suspendAutomaticFloating()` / `resumeAutomaticFloating()`：
`App/MobilePlayer.swift:2450`、`:2355`、`App/OneStylePlayerSurface.swift:26`。

```bash
grep -rn "func suspendAutomaticFloating\|func resumeAutomaticFloating" --include=*.swift .
# → 无任何定义，只有注释引用
```

而两条浮起通路**都恒开**：
* `App/MobilePlayer.swift:2452`　`controller.canStartPictureInPictureAutomaticallyFromInline = true`
* `App/MobilePlayer.swift:1702`　`OneStylePlayerSurface(automaticPiP: true)`

⇒ 「折叠 / 展开 / 转屏时 AVKit 把 inline layer 消失当成离开 App 而起浮窗」这个原始 bug
**从来没有被真正挡住过**，只是判定「是不是离开 App」的另一条路（`PlaybackExit`）加了闸，
而 AVKit 自动浮起这条路**不受 `PlaybackExit` 管辖**。

**三种形态下的具体表现**：
* 合盖（外屏 466×678）→ 展开竖持（669×951）：`OneStylePlayerSurface` / `OneSkinFixedPicture` 的宿主 VC 被重建，旧 layer 离窗口
* 展开竖持 → 展开横持：同样重建
* 反向同理

任一次重建都可能让 AVKit 起一次浮窗 —— 即用户报的「转个横屏/展开一下，飞出一个小窗」。

> 修法方向：真写这两个函数（`for controller in PictureInPicture 所有活跃实例 { controller.canStartPictureInPictureAutomaticallyFromInline = false }`），
> 在 `onChange(of: duoExpanded)` / 转屏前后各挂一次「关 → 下一帧恢复」。

---

### BUG-03 · high · 折叠那一刻 `fullScreen` 被写回 false，但方向闸门没解锁 → 再展开后方向锁永久失效

`App/VideoDetailView.swift:2893`
```swift
.onChange(of: duoExpanded) { _, expanded in
    PlayerOrientation.holdPortrait(oneSkinActive ? false : !expanded)
    if !expanded && fullScreen { fullScreen = false }   // ← 直接写 @AppStorage
}
```
`fullScreen = false` 绕过了 `setFullScreen(landscape:)` / `exitFullScreen()`，
而 `PlayerOrientation.fullScreenOwnsOrientation` 只在两处被清：
`VideoDetailView.swift:424`（整页 disappear）、`VideoDetailView.swift:3038`（`setFullScreenHeld(entering)`）。

`PlayerView.swift` `holdPortrait(_:)` 第一行：
```swift
guard !fullScreenOwnsOrientation else { return }
```

⇒ **全屏中合盖的顺序是**：`fullScreen=false`（闸门仍 `true`）→ `holdPortrait(!expanded=true)` 被 guard 丢掉
→ 外屏本应钉竖屏却没有钉 → 再展开时 `holdPortrait(false)` 同样被丢
→ 之后所有「折叠钉竖屏 / 展开松手」的规则**全部静默失效**，直到整页 disappear。

这是「三种形态来回切之后方向就乱了、要重启才恢复」的一个确定性成因，**三皮肤全中**。

> 修法：这一行改调 `exitFullScreen()`，或在写 `fullScreen = false` 前先 `setFullScreenHeld(false)`。

---

### BUG-04 · high · 合盖⇄展开竖持时「版式变化」检测不到 → 会被判成「离开 App」而起 PiP

`App/RootView.swift:631`
```swift
.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
    let rotated = lastSize != .zero && (lastSize.width > lastSize.height) != (size.width > size.height)
    if rotated { layoutChangedAt = Date() }
    lastSize = size
}
```
合盖 **466×678（竖）** → 展开竖持 **669×951（竖）**：宽高关系**没变**（都是 w<h）→ `rotated == false`
→ `layoutChangedAt` 不更新 → `PlaybackExit.decide` 里 `layoutJustChanged == false`。

而 `hasInlinePicture` 依赖 `store.presentingPlayer || store.playsInWatchPage(...)`，
这两个都由 SwiftUI `onAppear/onDisappear` 维护，折叠重挂那一帧会是 `false`。

⇒ 只要这一刻恰好 `scenePhase == .background`（用户合盖正好收起手机 / 切后台），
`decide` 就会走到 ③ 返回 `.startPictureInPicture` —— **展开一下就浮出一个 PiP 窗**。

`PlaybackExit.swift` 明确写了两条用户边界：「转屏 / 折叠 / 展开绝不能起 PiP」。
这条判据对**合盖⇄展开竖持**这一对（恰好是用户最常做的动作）**是漏的**。

> 修法：`layoutChangedAt` 的触发条件从「宽高关系翻转」改成「尺寸变化超过阈值」（如面积变化 >8%），
> 或直接订阅 `duoExpanded` 的变化并写入 `layoutChangedAt`。

---

### BUG-05 · high · 哔哩哔哩三形态的全部布局常量是「外屏 466×678」实测值，展开后照搬

`App/BiliMetrics.swift` 头部写得很清楚：所有数值来自 466 宽外屏的 `ui.tree` 实测。
展开到 669×951 / 951×669 后**一个都没换**：

| 常量 | 值 | 外屏正确 | 展开后错在哪 |
|---|---|---|---|
| `portraitPlayerHeight` (`BiliPortraitPage.swift:181`) | 250 | ✅ 466:250 | 展开竖持 669 宽 → 窗口 669×250，16:9 片源 `resizeAspect` 后仅 444×250，**左右各留 112pt 黑边**，观感是「小画 + 大黑框」 |
| `duoCameraInset` (`BiliPortraitPage.swift:164`、`BiliFullScreenPage.swift:281`) | 84 | ✅ 避开挖孔 | **内屏没有挖孔**，展开后顶栏右端硬留 84pt 空白，右上三个按钮整体左移 |
| `fullscreenTitleMaxWidth` | 180 | ✅ | 展开横持 951 宽仍只给标题 180pt |
| `backWidth/backHeight` | 54×44 | ✅ | 展开后触控区偏小，但可接受 |

---

### BUG-06 · blocker · 20 处 `UIScreen.main` 在 Duo 上量的是**外屏**，展开态面板全部按外屏比例算

`UIScreen.main` 在 Duo 双屏时指向**外屏 466×678**，而 App 跑在内屏 669×951（`OneSkin.swift:81` 的注释已经踩过这个坑，但只修了 One 皮肤自己那一条路）。

未修的 20 处里，**直接影响三形态 UI 错绘**的：

| 位置 | 代码 | 展开横持（951×669）实际算成 |
|---|---|---|
| `VideoDetailView.swift:2327` | `.frame(width: UIScreen.main.bounds.width * 0.495)` | 466×0.495 = **231pt**（应 336pt，实测占 49.5%）→ 右侧设置面板只有应有宽度的 69%，「Timer」那排又被裁掉 |
| `VideoDetailView.swift:2271` | `UIScreen.main.bounds.width * BiliMetrics.landscapePanelFraction` | 466×0.3667 = **171pt**（应 951×0.3667=349pt） |
| `VideoDetailView.swift:2088` | `minHeight: UIScreen.main.bounds.height * 0.60` | 678×0.60 = **407pt**（屏高 669，只铺 61%；应 401pt 反而近似，竖持时 951×0.6=570 vs 实际 678×0.6=407 → **欠 163pt，面板不到底**） |
| `VideoDetailView.swift:2227` | `maxHeight: UIScreen.main.bounds.height * 0.62` | 同上口径错 |
| `VideoDetailView.swift:2099` | `.padding(.horizontal, UIScreen.main.bounds.width * 0.20)` | 外屏 93pt vs 内屏应 190pt → 横屏菜单左右缩进只有一半 |
| `BiliPanels.swift:993-1000` | 弹窗上沿 `0.594` × 外屏高 | 展开竖持 951 高时上沿落在 y=403 而非 y=565 → **弹窗多占 162pt** |
| `BiliPortraitPage.swift:116` | 抽屉 `maxHeight: 高 × 0.72` | 展开竖持应 685pt，实给 488pt → **抽屉矮 197pt** |

⇒ 展开态下哔哩哔哩的**所有弹出面板尺寸与落点都是外屏口径**。这是「展开后 UI 错绘」最系统性的一处。

> 修法：统一换成 `UIApplication.shared.appWindowScene?.screen.bounds`（`ExternalDisplay.swift:8` 已有 `appWindowScene`），或直接在 `GeometryReader` 里取容器尺寸。

---

### BUG-07 · high · One 皮肤展开竖持（fullBleed）画面高度写死 56%，不随片源比例

`App/OneSkin.swift:1300` 附近
```swift
} else if effectiveShape == .fullBleed {
    let picH = box.height * 0.56
    let detailH = max(box.height - picH, 1)
```
展开竖持 669×951 → `picH = 532`。16:9 片源按宽 669 适配只有 376pt 高
→ 画面列里上下各 78pt 纯黑 letterbox，详情列被压到 419pt。

对照 One 参考图（`映匣/duo-三形态/1-展开竖持-669x951.png` 复核）：画面内容垂直居中、下方详情栏 15 段清晰分层。
本项目在 669 宽下把 56% 全给画面列、其中 156pt 是黑边 —— 即用户能看到的「画面占比反而变小、下半屏内容被挤」。

> 修法：`picH` 改由 `min(box.width / aspectRatio, box.height * 0.56)` 取小值，余量还给详情列。

---

### BUG-08 · medium · 非全屏时浮动标签栏压住右栏/底部内容（`oneSkinTabReserve` 恒为 0）

`App/VideoDetailView.swift:1677`
```swift
private var oneSkinTabReserve: (bottom: CGFloat, trailing: CGFloat) {
    guard !fullScreen else { return (0, 0) }
    if landscapeScreen { return (0, 0) }
    return (0, 0)        // ← 三个分支全归零
}
```
`App/WatchPageChrome.swift:82` 的 `WatchTabBarReserve`（bottom 36 / trailing 64）
```bash
grep -rn "WatchTabBarReserve\." --include=*.swift App   # → 零命中，纯死代码
```
而 `WatchSystemChrome` 只在 `fullScreen` 时收 tabBar：
```swift
.setBarVisibility(fullScreen ? .hidden : .visible, for: .tabBar)
```
⇒ 非全屏时 iOS 26 浮动胶囊仍然渲染，但**没有任何一边给它让位**。
展开横持（951×669）时它会收成贴右缘的竖排胶囊，正压右栏的选集按钮（这正是 `WatchTabBarReserve.trailing = 64` 当初要解决的问题，写完却没接线）。

---

### BUG-09 · medium · 应用内小窗的 `offset` 只在拖动结束时 clamp，折叠/展开后停在屏外

`App/RootView.swift:380` `.offset(miniDrag)`
`App/RootView.swift:393-402` 只在 `DragGesture.onEnded` 里做
```swift
let minX = -geo.size.width / 2 + halfW + 8 ...
miniDrag = CGSize(width: x, height: y)
```
`geo.size` 变化（合盖 466×678 → 展开 669×951）**不会**重跑这段 clamp。

⇒ 在外屏把小窗拖到右下角（`miniDrag ≈ (+180, +260)`），展开到 669×951 后
小窗中心跑到新屏的偏左下 240pt 处甚至越界 —— 表现为「切换形态后小窗飘到奇怪位置/半个出屏」。
另外 `miniScale` 同理不重算，展开后 2.5× 缩放可能超出屏宽。

> 修法：`onGeometryChange` 里对新尺寸重跑同一套 clamp。

---

### BUG-10 · medium · PiP 活跃时折叠，新 layer 不会 `attach`，`rebind()` 指向已销毁的 layer

`App/OneSkinWindowGeometry.swift` `OneSkinFixedPlayerLayer.updateUIView`：
```swift
if let pip, !pip.shouldRender(view.renderLayer) {
    view.update(player: nil, gravity: videoGravity)     // ← 没有 pip.attach
} else {
    view.update(player: player, gravity: videoGravity)
    pip?.attach(view.renderLayer)
}
```
PiP 正在跑时折叠 → 新 layer `shouldRender == false` → 走第一支 → **新 layer 从不登记**
→ 用户此时点「退出 PiP」→ `didStopPictureInPicture` 调 `rebind()`（`:2468`）
→ `makeController(for: self.layer)`，而 `self.layer` 仍是**旧图层的弱引用（已销毁）**
→ 新 controller 绑到死 layer，`isPictureInPicturePossible` 恒 false，直到下一次 `updateUIView` 才自愈。

表现为「折叠一次再退出小窗后，PiP 按钮灰掉/点了没反应」，需要再切一次页面才恢复。

---

### BUG-11 · medium · 三皮肤 PiP 状态共享，切皮肤可能读到上一个皮肤的宿主

`App/MobilePlayer.swift:2432` `private(set) static weak var avkitHost: AVPlayerViewController?`
`App/MobilePlayer.swift:2261` `private(set) static var current: AVPictureInPictureController?`
`PictureInPicture.isActive` 也是 static。

在设置里把 `playSkin` 从 `native` 切到 `one` / `bilibili`，旧宿主的 ARC 释放时机不确定
（`register(host: nil)` 只在 `dismantleUIViewController` 里调）；
`canToggle`（`:2253`）读的是实例的 `possible || active`，`OneSkinPlayerChrome.swift:605`
`case .pictureInPicture: return kit.pip.supported` —— 只判平台支持，不判「当前皮肤有没有能力」。
⇒ 哔哩哔哩皮肤下 PiP 按钮会显示为**可点**（因为 `supported` 恒真），点了永远无反应（同 BUG-01）。

---

### BUG-12 · low · One 皮肤 `OneSkinPlayerChrome.swift:1889/2011` 的 PiP 键也只会静默失败

`heroButton("pip", "PiP") { PictureInPicture.startCurrent() }` ——
在 One 皮肤下这条路径**是通的**（`OneSkinFixedPicture` 会 `attach`），
但若当前处在「PiP 未 attach 完成的窗口」（页面刚进、`updateUIView` 还没跑）同样是空操作，没有 disabled 态兜底。

---

## 3. 三形态 × 三皮肤 的具体表现速查

| 形态 | native | one | bilibili |
|---|---|---|---|
| **合起外屏 466×678 竖** | 基本正常 | 基本正常（`frozenBox` 取短边） | 250pt 播放器 + 84pt 挖孔避让，**参数全部正确** |
| **展开竖持 669×951** | 上游 `upstreamWatchBody` 单列 | `fullBleed`：画面 56% 含 156pt 黑边（BUG-07） | **250pt 播放器 + 112pt 左右黑边**（BUG-05）；面板按外屏高算（BUG-06） |
| **展开横持 951×669** | 上游 `split`，`detailWidth` 有 clamp（相对最稳） | `split` 三栏比例 53.34/1.67/44.99，OK | 右栏 350pt OK；**设置面板 231pt（应 336）**（BUG-06）；浮动胶囊压右栏（BUG-08） |
| **任一形态切换瞬间** | AVKit 可能自动起 PiP（BUG-02） | 同 + `fullScreen` 写回不解闸（BUG-03） | 折叠⇄展开竖持可能被判「离开」起 PiP（BUG-04） |
| **应用内小窗** | 可用 | 可用 | **不可用**（BUG-01） |
| **应用外小窗** | AVKit 托管，能力在 | 自建 controller，能力在（但有 BUG-10/11） | **完全无能力**，且会被误判为空转（BUG-01） |

---

## 4. 修复优先级（建议顺序）

1. **BUG-02 + BUG-04**（小窗误开的两条根）—— 先补 `suspendAutomaticFloating()` 真实现，再把 `layoutChangedAt` 的触发条件改成尺寸阈值/`duoExpanded` 订阅。
2. **BUG-03**（一行改动，解方向锁死循环）。
3. **BUG-01**（哔哩哔哩小窗能力 + `pipPossible` 语义）—— 顺带修 BUG-11 的按钮可用态。
4. **BUG-06**（20 处 `UIScreen.main` → `appWindowScene.screen`，可脚本批量但锚点须逐个核）。
5. **BUG-05 + BUG-07**（形态相关尺寸改为「按片源比例 + 容器尺寸」推导，不再写死）。
6. **BUG-08 / BUG-09 / BUG-10**（让位条接线、小窗 clamp、attach 补齐）。

---

## 5. 复现与验证口径

模拟器无 PiP（`isPictureInPictureSupported == NO`，2026-11-10 已抓到 AVKit 原话），
**BUG-01/02/04/10/11 的「浮窗」现象只能在真机 iPhone Duo（`00008160-0002698C0A900036`）验证**；
UI 错绘类（BUG-05/06/07/08/09）可在模拟器三形态截图逐像素核对：

```bash
xcrun simctl io "iPhone Duo" screenshot --display 1 /tmp/cover.png    # 外屏
xcrun simctl io "iPhone Duo" screenshot --display 3 /tmp/inner.png    # 内屏（需已展开）
```

`--display 3` 全黑 = 折叠态，需在 DeviceHub 重新展开（重启模拟器会复位为折叠）。

形态判定的运行时真相要取 `App/VideoDetailView.swift:167` 已有的诊断串：
```swift
"h\(sizeClass)|v\(verticalSizeClass)|o\(interfaceOrientation)|fs\(fullScreen)|skin\(oneSkinActive)"
```
三种形态下各抓一次，确认 `duoExpanded` / `sideways` 的判据在三形态下与预期一致
（注释里已记录：展开横持实测报 `regular × regular`，不翻成 `.compact`）。

---

# 修复记录（2026-11-11 02:30）

12 条全部落地。iOS `BUILD SUCCEEDED`；`TVCoreTests/PlaybackExitTests` **23 项全绿**（原 20 + 新增 3）。

## 逐条落地位置

| BUG | 文件 | 关键符号 |
|---|---|---|
| 01 | `BiliSkin.swift` / `VideoDetailView.swift` | `BiliSkinPicture.pip`、`makeUIView/updateUIView` 里 `attach`、`biliPip`、`collapseToMiniPlayer()` |
| 02 | `MobilePlayer.swift` / `OneStylePlayerSurface.swift` / `RootView.swift` / `VideoDetailView.swift` | `suspendAutomaticFloating(resumeAfter:)`、`resumeAutomaticFloating()`、`registry`（弱表）、`wantsAutomaticFloating`、`isAutomaticFloatingSuspended` |
| 03 | `VideoDetailView.swift` | 折叠改走 `exitFullScreen()`；`exitFullScreen()` 补 `setFullScreenHeld(false)` |
| 04 | `RootView.swift` | `areaChanged`（面积差 > 8%），并在同一帧调 `suspendAutomaticFloating()` |
| 05 | `BiliMetrics.swift` + 三页 | `cameraInset(forWidth:)`、`fullscreenTitleMaxWidth(forWidth:)`、`portraitHeight(width:aspectRatio:screenHeight:)`、`effectiveCardWidth` |
| 06 | `ExternalDisplay.swift` + 4 个文件 | `UIApplication.appScreenBounds`（22 处替换，代码层零 `UIScreen.main`） |
| 07 | `OneSkin.swift` | fullBleed `picH = min(max(box.width/片源比, 0.28H), 0.56H)` |
| 08 | `VideoDetailView.swift` | `oneSkinTabReserve` 按形态返回 `WatchTabBarReserve` |
| 09 | `RootView.swift` | 小窗 `onGeometryChange` 重钳 `miniDrag` |
| 10 | `OneSkinWindowGeometry.swift` | `updateUIView` 无条件 `pip?.attach` |
| 11/12 | `OneSkinPlayerChrome.swift` | `canToggle` 决定 disabled；`iconButton(enabled:)` |

## 数值核对（纯算术）

**BUG-05**（哔哩哔哩形态常量）

| 形态 | 挖孔避让 | 标题上限 | 竖屏播放器高 |
|---|---|---|---|
| 合盖外屏 466×678 | 84pt（不变） | 180pt（不变） | 250pt（不变） |
| 展开竖持 669×951 | 0（原 84） | 258pt（原 180） | 376pt（原 250，**消掉 126pt 黑边**） |
| 展开横持 951×669 | 0（原 84） | 367pt（原 180） | 415pt（原 250） |

**BUG-06**（`UIScreen.main` → `appScreenBounds`，展开态）

| 位置 | 修复前 | 修复后 |
|---|---|---|
| 全屏设置面板宽 `.495×w` | 231pt | 471pt |
| 横屏面板 `landscapePanelFraction` | 171pt | 349pt |
| 横屏菜单左缩进 `.20×w` | 93pt | 190pt |
| 弹窗最小高 `.60×h` | 407pt | 571pt |
| 抽屉 `.72×h` | 488pt | 685pt |

**BUG-07**（One fullBleed，展开竖持 669×951，16:9 片源）
- 修复前 `picH = 532.6` → 上下各 **78pt** 纯黑黑边，详情列 418pt
- 修复后 `picH = 376.3` → **零黑边**，详情列 575pt（+156pt 归还内容）
- 竖片 9:16 仍被 0.56 上限压到 532.6，不会挤没详情列

## 新增回归测试

`Packages/TVCore/Tests/TVCoreTests/PlaybackExitTests.swift`：

- `aFoldThatKeepsTheAspectRatioStillCountsAsALayoutChange()` —— 合盖⇄展开竖持（宽高关系不变）与展开竖持⇄横持，两种都必须 `.keep`
- `aLayoutChangeOutranksEveryLeavingSignal()` —— 版式变化优先于「PiP 已开」
- `aFoldRebuildingItsLayersIsNotALogOut()` —— 宽限窗内载体为空不许登出

## 未修的既有问题（与本轮无关，已核）

1. **macOS 目标编译失败** —— `App/OneSkinBackdrop.swift:21 import UIKit`，缺 `#if os(iOS)` 守卫。**用 HEAD 版本复现同样错误**（`git show HEAD:App/OneSkinBackdrop.swift` 也有 `import UIKit`），是既有问题。
2. **tvOS 目标编译失败** —— `App/BiliPanels.swift:926` 之后的 `BiliFullscreenPopup` 段落在 `#endif` 之外；`App/BiliMetrics.swift` 的 `#if os(iOS)` 只覆盖 1–284，305+ 的 `BiliPopupMetrics` 无守卫。**本轮改动分别落在 47–83 行（守卫内）与 996–1000 行（既有未守卫段）**，不在这些缺陷的来源上。
3. **`TVCore` 全量 suite 有 5 组既有红**（`BitmapSubtitleTests` / `jsonPlayURL` / `pluginOutputFlood` / `aResumedDownload…` / `altStoreSourceLists…`）—— 这些代码本轮一行未动，属既有基线。

## 待真机验证（模拟器无法覆盖）

PiP 相关（BUG-01/02/04/10/11）需在真机 Duo `00008160-0002698C0A900036` 上过：

1. 三皮肤各播一集 → 合盖 → 展开竖持 → 展开横持 → 反向，全程**不得出现任何 PiP 浮窗**
2. 全屏播放 → 返回键退全屏 → 折叠 → 再展开：方向应恢复「折叠钉竖屏 / 展开松手」
3. 哔哩哔哩全屏右缘 `pip` 键 → 应浮出应用外小窗；`More → PiP` 同上
4. 哔哩哔哩全屏右缘「小窗」键 → 应**缩成应用内卡片并回到主页**，不是起 PiP
5. 应用内小窗拖到右下角 → 合盖 → 展开：卡片应仍在屏内
6. PiP 运行中折叠 → 退出 PiP → 再点 PiP：按钮应仍可用（不再永久灰掉）
