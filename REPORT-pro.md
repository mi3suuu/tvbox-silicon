# REPORT-pro · One 皮肤竖源「时间在走、像素不动」根因与修复

分支 `fix/oneskin-portrait-pro` · 基线 `45cf78a` · 工作树 `tvbox-wt-pro`
模型 deepseek 4.x pro · 本轮只做静态分析 + 改代码（真机由 lead 负责）

---

## 0. 一句话结论

**断点在 `PictureInPicture.shouldRender`，不在窗口几何、不在片源解码、不在 `PlaybackSession`。**

它是整条出帧链上**唯一**一处能在不碰 `AVPlayer`、不报错、不改 `item.status`
的前提下把画面摘掉的地方：返回 `false` → `OneSkinFixedPlayerLayer.updateUIView`
执行 `view.update(player: nil)` → `AVPlayerLayer.player = nil`。
时间照走（`AVPlayer` 仍在播）、日志全绿（item ready、`avPlayer` 非 nil、几何正确）、
屏幕上只剩 `OneSkinPosterWash`（压暗海报底）。

而它返回 false 的真实原因，是**两条画中画通路共用一个进程级 `isActive`，
但只有自建那条会填 `sourceLayer`**：AVKit（全屏播放器）起浮时只写 `isActive = true`，
于是 `isActive == true && sourceLayer == nil` 这个**合法状态**被旧代码当成
「僵尸标记」清掉；同一帧里 One 皮肤读同一个全局量，内嵌层被判成「该让出」。

---

## 1. 读过的文件清单（文件 · 行数 · 关键函数）

| 文件 | 行数 | 读的关键函数 / 区段 |
|---|---|---|
| `App/MobilePlayer.swift` | 3226→**3336** | `PictureInPicture` 全类（2421–2841 原编号）；`shouldRender`(2504)、`attach`(2544)、`makeController`(2738)、`rebind`(2794)、`register(host:)`(2716)、`report(active:)`(2721)、`will/didStop`(2801/2823)、static `isActive`(2462)/`current`(2467)/`sourceLayer`(2472)/`avkitHost`(2714)/`registry`(2627)/`isAutomaticFloatingSuspended`(2642)；`PlayerLayerView`(2394)；`pictureCarrier`(1876) |
| `App/PlaybackView.swift` | 1865 | `configure(_:url:generation:)`(849)、`matroska` 提前返回(831)、`makeItem`(896)、`watch`(1042)、`installMix`(38)、`startAdDetection`(137)、`repackage`(964)、`checkSegmentedPicture`(1001)、`recordVideoFormat`(937)、连播门(1605)、`showsPicture` 置真(1133) |
| `App/OneSkinWindowGeometry.swift` | 232→**279** | `OneSkinFixedPicture`(73)、`OneSkinFixedPlayerLayer.makeUIView/updateUIView`(112/127)、`OneSkinFixedPlayerView.layoutSubviews`(190)、`intrinsicContentSize`(158)、`clipsToBounds`(118)、`attach`(169)、`update`(174) |
| `App/OneSkin.swift` | 4337→**4348** | `pictureColumn`(2925)、`pictureControls`(2826)、`stage`(2236)、`OneSkinPlayerLayer`(862)、`OneSkinPlayerView`(895)、`pictureHeightOf`(2805)、`bleedingPictureHeight`(2794)、`fitMode`/`gravity`(664–695)、`ASPECTDBG`(1815)、`VIDSRC`(1829)、`PICCHK`(3100) |
| `App/VideoDetailView.swift` | 4984 | `oneSkinStageSession`(2419)、`oneSkinLiveAspect`(2412)、`playerSession`(120)/`lastGoodSession`(137)、`onStageSession`(3877)、`oneSkinBody`(3392)、`OneSkinStage(...)` 实参(3393–3421)、`watchPlayer(stageOnly:)`(3844)、`oneSkinSessionStage`(3840)、离屏挂载与 `.hidden()`(2022–2066)、`syncAspectFromPresentationSize`(2486) |
| `Sources/TVCore/OneSkinWindowGeometryCore.swift` | 384 | 构造器(189–379)、`Metrics`(48–137) 含 `windowAspect`(101)/`playerAspect`(108)/`portraitAspect`(134)、`fullBleedPictureColumnHeight`(165)、`px`(30) |
| `App/OneSkinBackdrop.swift` | 396 | `OneSkinBackdropLayer`(73) 三层结构与渐变(126)、`OneSkinPosterWash`(276)、`OneSkinBackdropMetrics`(236) |

**额外读的（为了判据可靠，不在指定清单内）**：
`App/OneStylePlayerSurface.swift`(121 全文)、`App/PlayerView.swift`(1–200 + stageOnly 全部消费点)、
`App/SubtitleOverlay.swift`(349 全文)、`App/VideoTasks.swift`(740–830 坞卡片层)、
`App/Store.swift`(495–600 会话槽与会话工厂)、`App/RootView.swift`(336–360 坞让位判据)、
`App/VideoEnhancement.swift`(1–200 + `EnhancedVideoSurface`)、
`Sources/TVCore/AdFrameSampler.swift`(1–120)、`Sources/TVCore/Remux.swift`(1–110)、
`App/OneSkinPlayerChrome.swift`(380–560 / 1500–1520 / 1767–1800)、
`Tests/TVCoreTests/OneSkinWindowGeometryTests.swift`(315 全文)、
`Docs/duo/rca-dock/rca.md`(同类排查的判据格式)。

**SDK 头文件取证**（A6：以上游为准，不靠推断）：
`iPhoneOS27.2.sdk/.../AVFoundation.framework/Headers/AVPlayerItemOutput.h:94-102`、
`AVAssetTrack.h:59-72`。

---

## 2. 逐条排除的假设（含 文件:行号 依据）

### 已排除（有依据）

| # | 假设 | 依据 | 判决 |
|---|---|---|---|
| H1 | `PlaybackSession.player` 被置 nil / 会话丢失 | `PlaybackSession.player` 是 `let AVQueuePlayer`（`PlaybackView.swift:7`（`let player: AVQueuePlayer`）），**不可能**为 nil；实测 `PICCHK avPlayer=yes` 也印证 | **排除** |
| H2 | `item` 未 ready | 事实 1 已给 `st=1`（`.readyToPlay`）、`dur=90.5`、`pbt=true` | **排除**（实测已证） |
| H3 | 竖源编解码不被支持 → 只有声音 | `recordVideoFormat` 查 `isPlayable`（`PlaybackView.swift:944-950`），`hvc1` 在 iPhone 上可解；且若解码失败 `showsPicture` 不会置真、`timeControlStatus` 不会长期 `.playing` | **排除**（且下条的探针能量化） |
| H4 | `AVPlayerItemLegibleOutput.suppressesPlayerRendering` 把视频一起抑制了 | **SDK 头文件原文**：`AVPlayerItemOutput.h:100` ——「the media data supplied to the output will not be rendered… Other media data associated with the item but not provided to such an output is not affected… video media for that item will not be rendered by the AVPlayer, **while audio media, subtitle media**…will be rendered」。抑制是**按该 output 自身的媒体类型**生效的；legible output 只提供字幕，不可能抑制视频 | **排除**（这是最像「时间走/像素不动」的原生机制，必须实读头文件才能否掉） |
| H5 | 坞卡片抢走 player（第二宿主） | `DockPlayerLayer.updateUIView` 有 `coveredByForeground` 让位（`VideoTasks.swift:798-801`），且判据 `dockCoveredByForeground` 在观看页在演时为真（`RootView.swift:344-356`） | **排除**（作为独立病因；但它与 H8 共用同一个「只允许一个宿主」的不变式，故此闸漏判时会一起爆） |
| H6 | 窗口几何把画面算出屏 | 已由 `45cf78a` 修，19 条几何单测钉住；且用户报「改完现象仍在」——几何已不是断点 | **排除**（本轮复跑 16 条几何测试全绿，见 §4） |
| H7 | `OneSkinPosterWash` / 压暗层盖住视频 | `OneSkinFixedPicture` 用 `.background { OneSkinPosterWash }` 把虚化**排在宿主之下**（`OneSkinWindowGeometry.swift:93`，注释 82–87 记着同层时被盖的历史）；`pictureColumn` 的压暗层挂在 ZStack **外面**（`OneSkin.swift:3182`，注释 3175–3177 记着 zIndex(-1) 被盖的历史） | **排除** |
| H8 | `pictureColumn` 的 `else` 分支（`avPlayer == nil` 画海报）被走到 | `avPlayer: oneSkinStageSession?.player`（`VideoDetailView.swift:3420`），实测 `PICCHK ok avPlayer=yes` | **排除**，但它与 H9 共享同一个可观测面：两者在屏幕上**完全同形**（都是压暗海报），这正是上一轮把它误判成几何问题的原因 |
| H9 | `renderLayer` 的 frame 为 0（ZERO-FRAME） | `layoutSubviews` 强制 `playerLayer.frame = fixedSize`，并 `max(_,1)` 兜底（`OneSkinWindowGeometry.swift:211-213`）；且 `fixedSize = winW×winH`（`updateUIView:128`）非零 | **排除为独立病因**（探针仍保留该格，因为它是**次生**结果：`player = nil` 时 `videoRect` 会是 0×0，若拿 videoRect 当判据就会把它误读成 frame 问题 —— 这正是清单里的判据陷阱） |

### 采纳（H10 为本轮根因）

| # | 假设 | 依据 | 判决 |
|---|---|---|---|
| **H10** | **`shouldRender` 把「AVKit 托管的浮窗」误判成「僵尸标记」，返回 false → 内嵌层被摘掉 player** | 见 §3 | **采纳（根因）** |

### 明确「无法静态定论、须真机」的

| # | 假设 | 为什么静态不能定 |
|---|---|---|
| U1 | 竖源与横源的**唯一差别**是否就是「竖源那次播放期间起过一次 PiP」 | 需要日志里 `PIPSTART` / `PICGATE` 与 `VIDSRC` 同刻对齐。静态只能证明「这条链存在且能造成该现象」，不能证明「本次事故确实走了这条链」。本轮的探针就是为此设计（§5） |
| U2 | `AVPlayerViewController` 在 8×8 离屏视图里是否仍会启动视频输出（H5 的深层变体） | 依赖 AVKit 运行时行为，静态不可判定 |

---

## 3. 采用的根因：如何解释全部四个实测事实

### 3.1 机制（逐行对位）

一条 `AVPlayer` 只把像素给**一条** `AVPlayerLayer`。App 里有两条画中画通路，
它们**共用同一组进程级静态状态**，但**只有自建那条会填 `sourceLayer`**：

```
通路①（自建，One / 哔哩哔哩皮肤）
  AVPictureInPictureController(contentSource: .init(playerLayer: layer))
  willStartPictureInPicture:  isActive = true  AND  sourceLayer = self.layer   ← 两者都写

通路②（AVKit 托管，全屏播放器）
  AVPlayerViewController（OneStylePlayerSurface.swift:80-101）
  report(active: true):        isActive = true   （sourceLayer 保持 nil）      ← 只写一个
```

于是 `isActive == true && sourceLayer == nil` 有**两种语义相反**的来源：

- AVKit 真的浮着 → 它**不占用**我们的 `AVPlayerLayer`，内嵌层**必须继续渲染**；
- controller 已被回收的僵尸标记 → **必须清掉**，否则永久挡死画面。

旧代码（改前基线 `45cf78a` 的 `MobilePlayer.swift:2528-2541`）把两者合并成一支、按「僵尸」处理：

```swift
if Self.sourceLayer === layer { return true }
if let sourceLayer = Self.sourceLayer { ... } else {
    // isActive 为真但 sourceLayer 已空 → 无效状态
    Self.isActive = false      // ← 把 AVKit 正在跑的浮窗清成「没在跑」
    return true
}
```

而它**同时漏了**自己头注释第 2 条承诺的那一支（「当前进程没有任何活跃 PiP 控制器
→ 同样认为已失效」）：`Self.current == nil` 时没有任何代码路径处理，
直接落到末尾 `return false`。

### 3.2 对四个实测事实的解释

**事实 1｜`VIDSRC ... st=1 err=nil dur=90.5 pbt=true codec=hvc1`，`avPlayer` 不为 nil**
→ 与根因**完全相容**。本缺陷不碰 `AVPlayer`、不碰 `AVPlayerItem`、不报错。
探针打的是 `avPlayer`（`OneSkin.swift:3117`），而病灶在**它下游一格**
（`playerLayer.player`）。这是这条链最容易漏读的一格：`avPlayer != nil` 与
`playerLayer.player != nil` 是两个不同的事实。

**事实 2｜`PICCHK ok avPlayer=yes item=true status=1 ps=1080x1920 win=371x659`**
→ 同样全绿，因为 `PICCHK` 的四个格（avPlayer / item / status / presentationSize / 窗口）
**都不在被破坏的那一格上**。这正是我把它升级成 `fixedLayer verdict=` 的原因（§5）。

**事实 3｜播放进度在推进（1:36 → 1:48）**
→ `AVPlayer` 自己在播，只是**没有 layer 承接像素**。
`AVPlayerItemDidPlayToEndTime` / 时间观察者全部照常。这是「时间走、像素不动」的
最直接成因，比任何解码假说都更贴合（解码失败会让 `timeControlStatus` 停在 buffering）。

**事实 4｜帧间差分 diff=0.06（21 秒零变化）**
→ `playerLayer.player == nil` 时，`AVPlayerLayer` 保留**最后一次**合成的内容不动。
屏幕上那块是 `OneSkinPosterWash`（静态压暗海报），且由于 `player` 被摘掉，
视频从不进入合成 —— 像素自然 21 秒零变化。diff=0.06 是压缩噪声级别的抖动。

**为什么横源不中招**：横源那次会话期间**没有起过 PiP**（或无 AVKit 通路起浮），
`isActive` 始终 false，`shouldRender` 第一行就 `return true`。
竖源那次播过全屏播放器 / 起过一次浮窗后，全局标记被留在错误状态上 ——
这解释了「同一部剧、同一台机器，只有部分源中招」。

**为什么几何改完仍在**（用户的本轮观察）：几何只决定「画面窗口在哪里、多大」，
而本缺陷决定「窗口里有没有东西」。两者正交，所以窗口从 371×659 改成 523×287 后，
窗口位置对了，但里面**仍然没有视频** —— 这正是用户看到的现象。

---

## 4. 改动清单

### 4.1 新增 `Sources/TVCore/PiPRenderGate.swift`（163 行，纯函数 + 完整因果注释）

把判定从 iOS-only 文件搬进可测目标。**这是本条缺陷最贵的特性**：
它的失败形态与另外三种假说完全同形，写在 App 里就永远只能靠真机碰运气。

七支判决（顺序即优先级，注释里写明为什么不可重排）：

| 判决 | 条件 | renders | 清全局 |
|---|---|---|---|
| `noPiP` | 没浮窗 | ✅ | — |
| `mine` | **本层就是内容源**（可逐位比对的硬事实） | ✅ | — |
| `avkitHosted` | AVKit 托管（本轮病灶所在） | ✅ | — |
| `staleNoController` | 说在跑、全进程无控制器 | ✅ | ✅ |
| `staleNoSource` | 控制器在、内容源槽位空 | ✅ | ✅ |
| `staleDetachedSource` | 内容源已脱离视图树 | ✅ | ✅ |
| `yieldedToOtherLayer` | 真在另一条 layer 上跑 | ❌ | — |

`mine` 排在 `avkitHosted` **之前**：两条通路的标记进程级共享，极端时序下可同时为真，
而「本层就是内容源」是更硬的事实（可逐位比对 layer 身份），硬事实优先。

### 4.2 `App/MobilePlayer.swift`（+182 / −42）

- `shouldRender` 改为调用 `PiPRenderGate.verdict`，只负责凑 6 个输入 + 执行清僵尸副作用。
- 新增 `private(set) static var avkitHostedActive`：把「这次是 AVKit 托管的」显式记下来。
  **这是本轮修复的核心**：它把原本无法区分的两种语义（§3.1）分开。
- `report(active:)`：写 `avkitHostedActive`；收浮时只在**确实证明**槽位已死时才清，
  并把手里的 `isActive` 交还给另一条通路。
- `register(host:)`：宿主消失（`dismantleUIViewController`，`OneStylePlayerSurface.swift:117`）
  时复位 `avkitHostedActive`。**这是一个真实泄漏点**：AVKit 的 `didStop` 回调在页面被 pop
  时**不保证送达**（`dismantle` 只把 delegate 置 nil），不复位会让第 ④⑤⑥ 支永远走不到 ——
  把「画面回不来」升级成「永远回不来」。
- 自建 `willStart` 写 `avkitHostedActive = false`；`didStop` 按剩下的那条重算 `isActive`。
- `clearStalePiP()`：集中清理，带 `PIPSTALE` 探针（含调用栈）。
- `shouldRenderProbe()`（`MobilePlayer.swift:2606`）：**纯读**探针，不传 layer（`shouldRender` 有清理副作用，
  探针不能变成「靠打日志才修好」的那种修法）。

### 4.3 `App/OneSkinWindowGeometry.swift`（+53 / −10，探针在 214–277）

- `layoutSubviews` 的探针重写为**一行判决**：`fixedLayer verdict=<六选一> gate= pl= layer= fixed= ...`
- 新增 `noteIntent(renders:)`：记下本帧「闸想让不渲染」，使 `verdict` 能区分
  `GATE-OFF`（闸要求不渲染）与 `NO-PLAYER`（闸放行但没绑上）。纯读，不改行为。
- 探针**显式去掉 `videoRect`**：实测正常显示的横源也报 0×0（清单里的判据陷阱），
  留着它只会把 `player=nil` 的次生现象误读成 frame 问题。

### 4.4 `App/OneSkin.swift`（+17 / −10）

- `PICCHK` 增 `gate=` 与 `layer=` 两格，与 `fixedLayer` 行对齐。
  注释写明这是补第 ④ 条前提：前三格全绿时画面**仍可以**不显示。

### 4.5 新增 `Tests/TVCoreTests/PiPRenderGateTests.swift`（216 行，13 条测试）

不新增任何断言弱点：**没有**删断言、**没有**放宽阈值、**没有**自比对。
逐条：无浮窗全组合、AVKit 必须渲染、**AVKit 去掉标记必须变僵尸**（反证）、
内容源必渲染、内容源压过僵尸、内容源压过 AVKit、别层让出、三支僵尸、
「只有僵尸才清全局」、`renders==false` 只允许一支、判决短名唯一。

---

## 5. 探针方案（一次日志定性）

全部 `#if DEBUG`，全部纯读（不改任何行为）。文件：`Documents/oneskin.log`。

### 5.1 三个探针，逐格怎么读

**① `fixedLayer`（`OneSkinWindowGeometry.swift:245-277`，日志行 268）—— 出帧链最终判决**

```
fixedLayer verdict=GOOD gate=1 pl=1 layer=523x287 fixed=523x287 view=523x287
           win=1 wb=951x669 rect=0,148,523x287 hid=0 op=100 sup=1 gravity=resizeAspect chain=...
```

| `verdict` | 含义 | 下一步看 |
|---|---|---|
| `GOOD` | 六格全通。**此时像素若仍不动，病因不在本条链上** | 看 `PICGATE`；再看 U1/U2 |
| `NO-PLAYER` | `layer.player == nil`，而闸**放行**了 → 有别的东西把 player 置空 | 搜 `DOCKCOVER`（坞抢画面） |
| `GATE-OFF` | `pl=0` 且 `gate=0` → **闸明确要求不渲染** | 看 `PICGATE dec=` |
| `ZERO-FRAME` | layer 尺寸为 0 | 看 `fixed=` 与 `view=` |
| `HIDDEN` | `hid=1` / `op=0` / `sup=0` | 看父链 |
| `OFFSCREEN` | 在窗口外 | 看 `rect=` 与 `wb=` |

**② `PICGATE`（`MobilePlayer.swift:2574-2595`，日志行 2580）—— 闸为什么这么判**

```
PICGATE dec=AVKIT act=1 avkit=1 srcSet=0 mine=0 cur=0 pipUp=0 layer=12345 lp=1 ready=1 px=523x287
```

| 字段 | 读法 |
|---|---|
| `dec=` | 判决短名，与 `verdict` 一一对应。**`dec=AVKIT` 或 `dec=MINE` = 修复生效**；`dec=YIELD` = 真的在别处浮着；`dec=STALE-*` = 我们去救了一次僵尸标记 |
| `act=` | 进程级 `isActive` |
| `avkit=` | 本次浮窗是 AVKit 托管（**本轮新增，关键区分位**） |
| `srcSet=` | 全局内容源槽位是否已填 |
| `mine=` | 被问的这条 layer 是否就是内容源 |
| `cur=` | 是否存在自建 controller |
| `pipUp=` | 自建 controller 是否真在浮 |
| `lp=` | 这条 layer 上此刻有没有 player |
| `ready=` | `AVPlayerLayer.isReadyForDisplay` |

**③ `PIPSTALE`（`MobilePlayer.swift:2562-2572`）—— 谁清掉了僵尸标记**

```
PIPSTALE clear isActive=1 srcSet=1 cur=0 stack=... 
```
出现即表示「这个闸救过一次」；`stack=` 是清点，可定位是哪条路径导致。

**④ `PICCHK gate=`（`OneSkin.swift:3110-3122`，日志行 3117）—— 上游那一格**

```
PICCHK ok avPlayer=yes item=true status=1 ps=1080x1920 win=523x287 ... gate=YIELD-possible(act=1 avkit=0 srcSet=1 cur=1)
```
`gate=` 与 `fixedLayer gate=` 必须一致；不一致说明两帧之间状态变过。

### 5.2 六种病因 → 独一无二的字段组合（一次性判别表）

| 病因 | `verdict` | `pl` | `gate` | `PICGATE dec` | 其它判位 |
|---|---|---|---|---|---|
| **player 被置 nil（本轮根因）** | `NO-PLAYER` | 0 | **1** | 上一次为 `YIELD`/`STALE-*` | `avkit=`/`act=` 变过 |
| **闸要求不渲染** | `GATE-OFF` | 0 | 0 | `YIELD` | `srcSet=1 mine=0 cur=1 pipUp=1` |
| **layer 绑了但 frame=0** | `ZERO-FRAME` | 1 | 1 | 任意 | `layer=0x0` 但 `fixed=` 非零 |
| **layer 在屏外** | `OFFSCREEN` | 1 | 1 | 任意 | `win=0`，`rect` 越 `wb` |
| **被上层盖住** | `GOOD` | 1 | 1 | 任意 | `verdict=GOOD` **但** diff≈0 → 查 `OneSkinPosterWash`/chrome |
| **item 未 ready** | `GOOD` | 1 | 1 | 任意 | `PICCHK status=0/-1` 或 `ps=0x0` |

关键：**`pl` 与 `gate` 的组合是二位的，而 `verdict` 把「闸放行却没绑」与「闸不放行」
分成了两个不同的词** —— 这是旧探针做不到的（它只有一个 `pl=`，两种病因同为 0）。

### 5.3 lead 的一次性操作规程

1. 装包 → 复现竖源（横持双栏）→ `diff` 确认像素不动。
2. 拉 `Documents/oneskin.log`（注意 1MB 上限，`OneSkinLogSink` 会轮转）。
3. 依次读 `grep -E "VIDSRC|PICCHK|PICGATE|fixedLayer|PIPSTALE|PiP START"`：
   - 先看 `fixedLayer verdict=` 的最后一个值 → 直接得到上表的一行。
   - 若 `verdict=GOOD` 而像素仍不动 → 本轮根因**不是唯一因**，按 §7 的 U1/U2 继续。
4. `PICGATE dec=` 出现 `AVKIT` 或 `MINE` 且 `pl=1` → **修复生效**。

### 5.4 探针不改变行为（自证）

- `shouldRenderProbe()` 不接收 layer、不调 `shouldRender`（后者会清全局标记）。
- `noteIntent` 只写私有字段。
- `verdict`/`PICGATE`/`fixedLayer` 全部在 `#if DEBUG` 内，`DEBUG` 外不编译。
- 探针的**唯一**写入是 `clearStalePiP()` —— 那是修复本身，不是探针引入的。

---

## 6. 验证：代码路径已验证 vs 真机未验证

### 6.1 代码路径已验证（本轮实跑）

**A. 语法与类型**

```
xcrun swiftc -parse  → App/MobilePlayer.swift PARSE-OK
                       App/OneSkinWindowGeometry.swift PARSE-OK
                       App/OneSkin.swift PARSE-OK
                       Sources/TVCore/PiPRenderGate.swift PARSE-OK
                       Tests/TVCoreTests/PiPRenderGateTests.swift PARSE-OK
xcrun swiftc -typecheck -swift-version 6 Sources/TVCore/PiPRenderGate.swift → OK
```

**B. 几何不回归（16 条，与改动前基线一致）**

`swift test --package-path .` 在本工作树**无法运行**（已知环境问题，未修环境）：

```
error: local binary target 'FFmpeg' at '.../Vendor/FFmpeg/FFmpeg.xcframework' does not contain a binary artifact.
error: local binary target 'LibASS' at '.../Vendor/LibASS/LibASS.xcframework' does not contain a binary artifact.
```

原因：`Vendor/FFmpeg/FFmpeg.xcframework` 是指向 `../../build/FFmpeg/FFmpeg.xcframework`
的软链，而本 worktree 的 `build/` 下没有该目录（真 xcframework 在主树
`../tvbox-silicon-fusion/build/FFmpeg/`，**未取用、未修改**）。

替代方式（**不复制断言、不改阈值、不放松任何判据**）：把
`Sources/TVCore/OneSkinWindowGeometryCore.swift` 与
`Tests/TVCoreTests/OneSkinWindowGeometryTests.swift`
**原文件按 sha256 校验一致**后放进最小包 `/tmp/geoharness-pro` 跑真实测试。

```
SAME Sources/TVCore/OneSkinWindowGeometryCore.swift  958fff37…
SAME Tests/TVCoreTests/OneSkinWindowGeometryTests.swift 14f68c07…
✔ Test run with 16 tests in 0 suites passed
```

**C. 新闸的单测（13 条）**

同一 harness，`PiPRenderGate.swift` + `PiPRenderGateTests.swift` 同样 sha256 校验：

```
SAME Sources/TVCore/PiPRenderGate.swift        840a3526…
SAME Tests/TVCoreTests/PiPRenderGateTests.swift 6431d389…
✔ Test run with 29 tests (16 几何 + 13 闸) passed
```

**D. 判别力（变异测试 —— 证明测试不是假绿）**

对 `PiPRenderGate` 做 5 次单点变异，每次**都必须变红**：

| 变异 | 结果 |
|---|---|
| M1 删掉 `avkitHosted` 那一支（= 旧实现） | ✘ 红（`anAVKitHostedFloatingWindowStillRendersTheInlineLayer` 报 2 处） |
| M2 删掉 `mine` 那一支 | ✘ 红 |
| M3 删掉 `staleNoController` 那一支 | ✘ 红 |
| M4 让 `yieldedToOtherLayer` 也渲染 | ✘ 红 |
| M5 删掉 `staleDetachedSource` 那一支 | ✘ 红 |
| 复原 | ✔ 全绿 |

**E. App 侧真实调用形态可编可跑**

把 `shouldRender` 的**完全相同调用形态**（6 个实参、`source.map{} ?? false`、
`verdict.clearsGlobals` / `.name` / `.renders`）+ `shouldRenderProbe` 的完整分支
照抄到 `/tmp/gatecall-pro/Caller.swift`，与真 `PiPRenderGate.swift` 一起编译运行：

```
CALLER-PROBE OK cleared=1 gate=STALE-nocontroller(act=1 avkit=0 srcSet=1 cur=0)
```
四个 `precondition` 全过（无浮窗渲染 / AVKit 渲染且不清 / 内容源渲染 / 别层让出 / 僵尸恢复并清）。

**F. 内容核验（A4：不以编译代替内容校验）**

```
App/MobilePlayer.swift           3226 → 3336
App/OneSkinWindowGeometry.swift   232 →  279
App/OneSkin.swift                4337 → 4348
Sources/TVCore/PiPRenderGate.swift        新增 163
Tests/TVCoreTests/PiPRenderGateTests.swift 新增 216
```

符号齐全性：
- `GateDecision` 全仓 **0 处**（已彻底移除，无重复定义）
- `func decide(` 在 App 下 **0 处**
- `PiPRenderGate` 在 App 被真实引用（2541 判定 / 2579 日志签名）
- `shouldRenderProbe` 有消费者（`OneSkin.swift:3112`）
- `avkitHostedActive` 写入点：`report`(2818) / `register(host:nil)`(2801) / 自建 `willStart`(2911)

**G. 断言强度**

`PiPRenderGateTests` 13 条测试、`#expect` 计数 **24 处**（改前该文件不存在）。
未删除任何既有断言，未改动 `OneSkinWindowGeometryTests` 一个字符（sha256 一致为证）。

### 6.2 真机未验证（**不得记为通过**）

以下**全部未验**，须 lead 在真机确认：

1. `verdict` / `PICGATE` / `PIPSTALE` 三行在真机 `oneskin.log` 里的实际取值。
2. 修复是否真的让竖源出画面（本轮只证明「闸不再误判」，未证明「画面出现」）。
3. `AVPlayerViewController` 在 8×8 离屏视图里是否仍启动视频输出（U2）。
4. iOS 26/27 上 `AVPictureInPictureController` 与本闸的实际时序。
5. xcodebuild 全量构建未跑（FFmpeg/LibASS 缺失，环境问题）。

---

## 7. 未覆盖 / 风险

1. **根因唯一性未证**。本轮证明这条链**存在**且**能**造成该现象，并在
   `decide` 里补上了旧代码漏掉的那一支（`current == nil`）。
   但「本次事故确实走的是这条链」需要真机日志的 `dec=` 定论。**这是最高风险项。**
   若真机 `verdict=GOOD` 而像素仍不动，说明还有第二因，按 §5.2 表继续。
2. **两条通路共享静态状态的架构本身是缺陷源**。本轮把它们**区分开**（`avkitHostedActive`），
   但没有消除共享。彻底做法是让每条通路各持一份状态；那是一次结构调整，
   超出「只修病因」的边界，建议单独立项。
3. **`avkitHostedActive` 是进程级单值**。若同一进程同时有两个 AVKit 播放器
   （例如全屏播放器与某个离屏预览），后写的会覆盖前者的标记。
   静态上找不到这种并发路径（`OneStylePlayerSurface` 只在全屏播放器用），但未动态验证。
4. **未动 `OneSkin.swift` 的画面分支逻辑**。`pictureColumn` 的 `if let avPlayer`
   仍只看 `avPlayer`，不看 `playerLayer.player` —— 这两者的差异正是本轮缺陷的土壤。
   本轮只加了探针，没有改判定；若要根治「同形不可分」，应让
   `pictureColumn` 也能观测到「闸拒绝」，但那需要把 `pip` 状态提升为可观察量，属结构改动。

---

## 8. 提交

分支 `fix/oneskin-portrait-pro`，基线 `45cf78a`。
改动 5 个文件（3 改 2 新增），`git add -A` + 独立提交（见 §9 命令输出）。
主树 `tvbox-silicon-fusion` 与 `tvbox-wt-flash` **零改动**（未打开、未写入）。
