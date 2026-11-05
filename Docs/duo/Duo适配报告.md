# iPhone Duo 适配报告

> 线：Duo 专职（`fusion/main`）
> 环境：Xcode 27.1 (27A9275) · iOS 27.1 SDK · 模拟器 `DuoTest`（`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, `iPhone19,4`）
> 姿态参数：外屏 466×678pt（合拢竖）/ 678×466pt（合拢横）/ 内屏 669×951pt（展开）

---

## 一、白屏根因（因果链 + 证据）

### 结论

**不是布局算错，是页面压根没被构建。** `App/RootView.swift` 的 `tabSafeArea(_:vertical:)` 是 `@ViewBuilder`，iOS 26 分支里只有两个命中条件；**compact × compact（Duo 外屏横持）两个都不命中，函数返回 `EmptyView`**。而它被挂在**每个 tab 页的根**上，于是整页被替换成空视图。

### 因果链

```
Duo 合拢 + 横持
  → sizeClass = (horizontal: .compact, vertical: .compact)
  → tabPage(item) 给每个 section 挂 .tabSafeArea(.compact, vertical: .compact)
  → tabSafeArea 的 @ViewBuilder body:
        if #available(iOS 26, *) {
            if horizontal == .regular { … }        ← 不命中
            else if vertical == .regular { … }     ← 不命中
            // ← 这里原本只有一行注释，没有 else
        }
  → @ViewBuilder 在没有任何分支命中时返回 EmptyView
  → 整页 = EmptyView
  → 屏幕上只剩：系统侧边标签栏胶囊（TabView 自己画的）+ 底部 mini player（overlay 在 TabView 外面）
```

### 为什么三个「已知线索」全都指向别处

| 线索 | 为什么会误导 |
|---|---|
| 窗口 `678×466` 正确 | 几何本来就没问题——`EmptyView` 也会被正确布局成 678×466 |
| `TABPAGE x=84 w=594 h=432` 正确 | 同上：容器尺寸是对的，只是容器里没有内容 |
| `.sidebarAdaptable` 改 `.tabBarOnly` 无效 | TabView 样式跟这件事无关——**问题在这个 modifier 里面，不在 TabView** |

### 排除实验（逐步二分，全部实测）

| 步骤 | 改动 | 结果 | 结论 |
|---|---|---|---|
| 0 | 现状 | 内容区 16/16 采样点纯白 | 复现 |
| 1 | 关 `PrivacyShade`（`-privacyShade.enabled.v1 0`） | 仍 16/16 白 | 不是遮罩 |
| 2 | 去掉 `.tabViewStyle(.sidebarAdaptable)`（裸 TabView） | 仍 16/16 白 | 不是 TabView 样式 |
| 3 | 去掉 `.minimizesTabBarOnScroll()` + `.musicAccessory(...)` | 仍 16/16 白 | 不是 TabBar 修饰符 |
| 4 | `platformTabs` → `content(store.section)`（**绕过 TabView 且不套 `tabSafeArea`**） | **0/16 白**，页面完全正常 | 页面本身没问题 |
| 5 | `platformTabs` → `tabPage(store.section)`（**保留 NavigationStack + `tabSafeArea`**） | 16/16 白 | **锁定在 `tabSafeArea`** |
| 6 | 读源码 | 找到缺失的 `else` | 根因确认 |

**第 4 / 第 5 步是决定性的**：同样的内容，只差一层 `tabSafeArea`，一个正常一个全白。

### 关键反证：内屏改前就正常

内屏展开（669×951，`regular × regular`）**改前就是正常的**——内容区 0/16 白，背景是 App 自己的 `244,246,251`（`Backdrop`）。

这条把根因从「全平台布局问题」收窄成「**恰好两个 `if` 都不命中的那个缺口**」，正好对应 `@ViewBuilder` 默认返回 `EmptyView` 的语义。

### 像素证据

判据：内容区取 16 个采样点（x ∈ {0.3, 0.5, 0.7, 0.9} × y ∈ {0.2, 0.4, 0.6, 0.8}），`min(r,g,b) > 250` 记作纯白。
**为什么是「纯白 255」而不是 App 背景 `244,246,251`** —— 这本身就是判据：连背景都没画，说明整个视图树没构建。

| 分区 | 改前 | 改后 |
|---|---|---|
| home | 16/16 白 | **0/16** |
| discover | 16/16 白 | **0/16** |
| settings | 16/16 白 | **0/16** |
| more | 16/16 白 | **0/16** |
| music | 16/16 白 | **0/16** |
| live | 16/16 白 | **0/16** |
| sites | 16/16 白 | **0/16** |

截图：
- 改前：`Docs/duo/evidence/L-*.png`（2034×1398，横持）
- 改后：`Docs/duo/evidence/AFTER-*.png`（2034×1398，横持）
- 内屏对照（改前即正常）：`Docs/duo/evidence/I-open-home.png`（2007×2853）

---

## 二、修复内容

### 2.1 白屏（`App/RootView.swift` · `tabSafeArea`）

**改了什么**：iOS 26 分支末尾补 `} else { self }`。

**为什么**：`@ViewBuilder` 需要一个「什么都没命中时」的兜底分支。compact × compact 不该被改动（系统窄底胶囊在那里本来就不好看），所以兜底就是 `self` —— 原样返回，不加任何 padding。

```swift
} else {
    // compact × compact (the Duo's folded outer display held sideways) is left alone: …
    //
    // [mi3s] 二开：这一支必须有，且必须 `self`。…
    self
}
```

**提交**：`c62c49e`（captain 提交，与本人独立诊断一致）。

### 2.2 P2 · 折展时分区从标签栏掉进 More 后不回来（`App/RootView.swift`）

**改了什么**：加 `@State private var movedToMoreBySlotChange: AppSection?`，并在三处 `onChange` 里维护它。

**为什么**：

`barSlots`（标签栏格数）在折叠时 7→4、展开时 4→7。4 格装不下 `Sites / Music / Manga`，它们掉进 More，`store.section` 被改写成 `.more`。展开时格子回到 7 个，但 **`phoneTabs` 没变**（Duo 折着展开着都是 phone），所以原有的恢复分支

```swift
if !phone && store.section == .more { store.section = …
```

**永远不触发** → 用户停在 More，回不到原来的页。

**为什么需要一个标记**：不能无脑在 `barSlots` 变化时恢复，否则会把**用户自己点进 More** 的也拽回来。所以记下「是被谁搬过来的」：

| 场景 | `movedToMoreBySlotChange` |
|---|---|
| 折展把分区掉进 More | 记下该分区 |
| 用户/深链主动选了一个在 More 里的分区 | 清空 |
| `phoneTabs` 变化（切到/离开手机标签栏） | 清空 |
| 展开后恢复成功 | 清空 |

**验证结果（如实记录局限）**

`-qaSection sites` 深链测试**改前改后都是「展开后回到 Sites」**，`MAD` 对比完全一致：

| 步骤 | vs sites 参考 | vs more 参考 |
|---|---|---|
| 展开态 + sites（初始） | 0.02 | 11.07 |
| 折叠后 | 13.78（外屏，尺寸不同，不可比） | 10.66 |
| **再展开** | **0.43（= sites）** | 10.96 |

**为什么没复现**：深链是在**启动时**直接设 `store.section = .sites`，此时 7 格，sites 在 bar 里，不经过 `onChange`；折叠时走进「掉进 More」，`movedToMoreBySlotChange` 被设上；展开时**新分支**把它放回去——**改前也应该走的是同一个既有路径**（因为 `barSlots` 变化时 `store.section == .more`，而 `.more` 不在 `inMore` 里，两边都不做事，理论上应该停在 More）。

**未复现的可能原因**（未进一步证实）：`hinge close→open` 过程中 `TabView` 可能重算了 `tabs` 数组，SwiftUI 对 `store.section` 的 `@Observable` 观察在 `barSlots` 变化后重放了一次，导致 `.more` 被系统本身纠正。**这是推断，不是证据。**

**状态**：代码改动**保留**（逻辑上闭合了真实的缺口，且不改变任何既有分支行为），但**标记为「未获独立复现证据」**，需要在真机上手动「展开态停在 Sites → 折叠 → 展开」验证。

### 2.3 未改动的部分

- `App/Store.swift`：**未碰**（captain 独占）
- `Sources/TVCore/Resources/*.lproj/Localizable.strings`：**未碰**
- `project.yml` / `project.pbxproj`：**未碰**
- `tabSafeArea` 的 `else { self }`：**未再改动**（captain 已提交）
- 上游文件：**未碰**

---

## 三、社区成果对照表

完整版见 `Docs/duo/适配对照表.md`（已做 15 条 / 未做（有意）5 条 / 不适用 8 条 / **需跟进 4 条**）。此处只列结论。

### 3.1 iphone-duo-skill（18★）

**它最有价值的两条，映匣一条做到了、一条有意违背：**

| 它的原则 | 映匣 | 判定 |
|---|---|---|
| 按 size class + 容器尺寸，不按 idiom / orientation / `UIScreen.main` | 框架层做到了；**播放页 8 处按 `interfaceOrientation`** | **有意违背**：size class 无法区分「内屏横握」和「内屏竖握」（都是 regular×regular），而播放器控制栏必须切。这是映匣超出它覆盖范围的地方 |
| 内屏是「regular 宽 **on a phone**」 | `PhoneTabs.inUse` 明确处理 | **已做** |

**它的 7 条 ArrangementView trap，映匣有 2 条是「概念同源」踩过的**（trap 3「minWidth 装不进半屏 → 整片空白」与本次白屏是同一类错误：**条件不成立时 `@ViewBuilder` 静默返回空视图**）。

**它的 `scripts/audit.sh` 对映匣的扫描**（本机实跑）：
- HIGH 23 处（`UIScreen.main` 3 / idiom 7 / orientation 8 / `connectedScenes.first` 2）
- 逐条判读后：**2 处真缺口（A、B）**，其余为误报、有意为之、或仅 macOS 分支

### 3.2 sunimp/TabBar（31★）

它手搓 `layoutGuide(for: .bar(onEdge:extent:))` 是因为**绕开了系统 `UITabBarController`**。映匣用系统 `TabView`，这部分不需要抄。

**但它有一个隐含约束值得抄：三态下 items 不变。** 映匣的 items 会变（4 格 ↔ 7 格），这正是 P2 那个 bug 的来源。已如实记录在对照表 §6.4。

### 3.3 VankerWu/iPhone-Duo-Apps（1★）

不给代码标准，给**证据分级**。它的三条硬规矩直接采纳：

1. 「能运行 / 最近更新 / 有商店页」**都不算**已适配
2. 不同版本 / 地区 / 内外屏姿态表现**可能不同** → 必须按姿态分列
3. 自动同步**不得**凭关键词把条目改成「已确认适配」

→ 本报告 §四 的三态矩阵**按姿态分行、每格独立判读**，不给「总体已适配」这种合并结论。这是本次从它那里吸收的最有价值的东西。

---

## 四、三态验证矩阵

判据：`hinge` 控形态，`simctl launch` 传深链，`hinge screenshot` 截活动屏，PIL 采样判读（纯白 / 非白 + 与参考图 MAD）。

| 页面 | 外屏合拢竖<br>466×678 | 外屏横持<br>678×466 | 内屏展开<br>669×951 |
|---|---|---|---|
| Home | ✅ 正常（早前已验证） | ✅ **本次修复** | ✅ 正常（改前即正常） |
| Discover | — | ✅ **本次修复** | — |
| Settings | — | ✅ **本次修复** | ✅ 正常 |
| More | — | ✅ **本次修复** | ✅ 正常 |
| Music | — | ✅ **本次修复** | — |
| Live TV | — | ✅ **本次修复** | — |
| Sources | — | ✅ **本次修复** | ✅ 正常 |
| 播放页三形态 | 见 `映匣功能清单.md` §2.2 | 见 §2.2 | 见 §2.2 |

> 「—」= 本次未逐格截图（该格不属于本次改动的影响面，且改动点 `tabSafeArea` 在三个形态里只有 compact×compact 分支行为变了）。
> **不声称「全部通过」**：按 VankerWu 的规矩，没截的就是没截。

### 改动影响面（为什么敢说其他格不受影响）

`tabSafeArea` 只在一个条件下改变了行为：**iOS 26+ 且 compact × compact**。
- `horizontal == .regular`（内屏、iPad）→ 走原分支，不变
- `vertical == .regular`（外屏竖持）→ 走原分支，不变
- iOS < 26 → 走原 `safeAreaPadding(.bottom)`，不变
- 普通 iPhone 竖（compact×regular）→ 走 `vertical == .regular` 分支，不变
- 普通 iPhone 横（compact×compact）→ **行为变了**：以前返回 `EmptyView`（也会白屏！），现在返回 `self`

> ⚠️ **一个额外的发现**：普通 iPhone 横屏也是 compact×compact，所以**这个白屏在普通 iPhone 上同样存在**——这次修的是跨设备的 bug，不只是 Duo。这一点原本没人报，因为大多数人在 iPhone 上是竖着用的。

---

## 五、未解决 / 需他线配合

| # | 项 | 归属 | 说明 |
|---|---|---|---|
| 1 | P2 折展回原分区**未获独立复现证据** | Duo 线 | 深链路径改前改后一致，需真机手动验证。代码保留 |
| 2 | pushed `Route` 页面隐藏导航栏 → 纵向栏无 Back | **待排期** | 14 处 `.toolbar(.hidden, for: .navigationBar)`，需逐个确认 pushed 页有自绘返回键。对照表 §A |
| 3 | `connectedScenes.first` 2 处 | **待排期** | Duo 有外接屏 scene，`.first` 可能拿错。对照表 §B |
| 4 | 播放页按 `interfaceOrientation`（8 处） | **有意保留** | 需在代码里补理由注释 |
| 5 | `UIScreen.main.potentialEDRHeadroom` | **低优先** | 对照表 §D |
| 6 | 网格列数按容器宽算（社区建议 2.5） | **待排期** | `Layout.cardColumns` 是常量 |
| 7 | iOS 27 纵向栏 badge 晚到不刷 | **待验证** | 社区实测；需补 symbol swap 兜底。对照表 §3.8 |

> 已同步写入 `Docs/fusion/02-未纳入清单.md`（见 §五·附录）。

---

## 六、需要 captain 做

### 6.1 Store 字段

**无。** P2 的状态 `movedToMoreBySlotChange` 是 `RootView` 的 `@State`（纯视图态，不需要跨会话持久化），没有往 `Store` 加任何东西。

### 6.2 l10n key

**无。** 本次没有新增任何用户可见文案。

### 6.3 工程改动

**无。** 没有改 `project.yml`，没有改 `project.pbxproj`，没有新增源文件（`Docs/duo/*` 是文档，不进编译）。

### 6.4 建议 captain 决策

| # | 事项 | 建议 |
|---|---|---|
| 1 | P2 改动是否随本次合并 | **保留**。逻辑闭合了真实缺口，且不改任何既有分支行为。但请在真机上手动验一次再标「已验」 |
| 2 | 是否补一个回归测试防白屏 | **建议补**。`tabSafeArea` 这类 `@ViewBuilder` 缺兜底分支的 bug **编译期不报、运行期全白**，极难发现。可以在 `UITests/DuoAcceptanceUITests.swift` 加一条：compact×compact 下断言 `section.home` 存在且可截图非纯白 |

---

## 七、验证证据

### 7.1 三平台构建（本机实跑，尾部输出）

```
$ xcodegen generate --spec project.yml
gen-ok

$ xcodebuild -scheme TVBox-tvOS -derivedDataPath build/DD-duotv \
    -destination 'generic/platform=tvOS' build CODE_SIGNING_ALLOWED=NO
** BUILD SUCCEEDED **

$ xcodebuild -scheme TVBox-macOS -derivedDataPath build/DD-duomac build
** BUILD SUCCEEDED **

$ xcodebuild -scheme TVBox-iOS -derivedDataPath build/DD-duo \
    -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
** BUILD SUCCEEDED **
```

> iOS **模拟器**目标构建通过（M6 字幕符号在本 revision 已改为 `Mi3sSubtitleStyle`，不再阻塞）。
> 按要求的三条命令中，iOS 仍建议由 captain 用 `generic/platform=iOS`（设备目标）复跑一次。

### 7.2 白屏成对证据

| 文件 | 姿态 | 判读 |
|---|---|---|
| `Docs/duo/evidence/L-home.png` | 外屏横持 · 改前 | 16/16 纯白 |
| `Docs/duo/evidence/L-discover.png` | 同上 | 16/16 纯白 |
| `Docs/duo/evidence/L-settings.png` | 同上 | 16/16 纯白 |
| `Docs/duo/evidence/L-more.png` | 同上 | 16/16 纯白 |
| `Docs/duo/evidence/L-live.png` | 同上 | 16/16 纯白 |
| `Docs/duo/evidence/L-sites.png` | 同上 | 16/16 纯白 |
| `Docs/duo/evidence/AFTER-home.png` | 外屏横持 · 改后 | **0/16** |
| `Docs/duo/evidence/AFTER-discover.png` | 同上 | **0/16** |
| `Docs/duo/evidence/AFTER-settings.png` | 同上 | **0/16** |
| `Docs/duo/evidence/AFTER-more.png` | 同上 | **0/16** |
| `Docs/duo/evidence/AFTER-music.png` | 同上 | **0/16** |
| `Docs/duo/evidence/AFTER-live.png` | 同上 | **0/16** |
| `Docs/duo/evidence/AFTER-sites.png` | 同上 | **0/16** |
| `Docs/duo/evidence/I-open-home.png` | 内屏展开 · 改前 | **0/16**（反证：改前即正常） |

### 7.3 诊断过程留档

| 文件 | 用途 |
|---|---|
| `DIAG-nostyle.png` | 去掉 `.sidebarAdaptable` 后仍白屏 |
| `DIAG-noPrivacyShade.png` | 关遮罩后仍白屏 |
| `DIAG-noTabMods.png` | 去掉 TabBar 修饰符后仍白屏 |
| `DIAG-bypassTabView.png` | **绕过 TabView 后正常**（关键一步） |
| `DIAG-tabPageOnly.png` | **只保留 `tabPage` 后白屏**（锁定 `tabSafeArea`） |

### 7.4 P2 证据

| 文件 | 说明 |
|---|---|
| `P2REF-inner-sites.png` / `P2REF-inner-more.png` | 内屏 sites / More 参考图（两者 MAD = 11.07，可区分） |
| `P2BEFORE-1-open-sites.png` | 展开态 + sites（MAD vs sites = 0.02） |
| `P2BEFORE-2-closed.png` | 折叠后（外屏，尺寸不同不可比） |
| `P2BEFORE-3-reopened.png` | 再展开（MAD vs sites = 0.43）**← 改前就已回到 sites，未复现** |

### 7.5 复现命令（可重跑）

```bash
D=<UDID>; H=Scripts/hinge/scripts/hinge
$H -d $D close && $H -d $D orient landscape-left && sleep 2
xcrun simctl launch $D com.jo32.yingxia.ios -qaSection home -qaKeepAwake 1
sleep 7 && $H -d $D screenshot out.png
python3 -c "
from PIL import Image
im=Image.open('out.png').convert('RGB'); w,h=im.size
xs=[int(w*t) for t in (.3,.5,.7,.9)]; ys=[int(h*t) for t in (.2,.4,.6,.8)]
v=[im.getpixel((x,y)) for x in xs for y in ys]
print('white =', sum(1 for p in v if min(p)>250), '/', len(v))"
```
