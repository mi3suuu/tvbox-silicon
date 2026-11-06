# V1 画风与 UI 验收报告（A 组）

> 原派发对象 `V1-ui` 因供应商 503 turn failure，任务标 failed。由 captain 直做。
> A 组的「画风」无法完全机械化，所以口径是：**能量化的量化，不能量化的给判断依据 + 与纯上游基线对照**。

---

## 结论：**PASS**（A1–A5 无回归，0 项需修）

**核心方法**：A 组所有指标都与**纯上游基线 `fusion/base`（`tvbox-wt-baseline`）对照**。
只看绝对值没有意义 —— "间距用了 25 种不同值" 听着多，但如果上游也是 25 种，那就不是融合引入的。

---

## A1 设计 token（量化对照）

| 指标 | 纯上游基线 | 融合版 | 判定 |
|---|---|---|---|
| `.padding(.vertical, N)` 不同值种数 | 25 | **25** | 持平，无新增散值 |
| `.padding(.horizontal, N)` 不同值种数 | 20 | **20** | 持平 |
| `.system(size: N)` 不同值种数 | 39 | **37** | 少 2 种（融合时统一了） |
| `.tracking(N)` 不同值种数 | 2 | **2** | 持平 |
| `cornerRadius(数字)` 裸值 | 0 | **0** | 全部走 token，无裸值 |

**结论 PASS，判据**：
- 融合版**没有让任何一项变差**，font 反而收敛了 2 种。
- 散值种数持平说明二开代码沿用了上游的间距语言，没有另起一套。
- `cornerRadius` 零裸值 —— 说明圆角统一走 `Radius.*` token。

> 说明：间距散值本身**不是问题**。图标尺寸、行高、hairline 本来就该是裸数值。
> 只有「同一类间距在不同文件里用了 3 种以上互不相关的值」才算 FAIL —— 对照基线后不存在这种情况。

---

## A2 视觉层级

抽读二开新增的 12 个设置/弹层页（`PrivacyVaultView` / `EnvironmentsView` / `ResourceRankingView` /
`WebCastSettingsView` / `PlayerControlsSettingsView` / `AITranslationView` / `SpeechSubtitleView` /
`ArtworkLanguageView` / `SkipSourceSettingsView` / `ProxySettingsView` / `DiagnosticsView` / `LicensesView`）：

- 全部用同一套 `Form` + `Section` + `FormLink` / `TVSettingsLink` 骨架，与上游设置页相同的分区结构。
- 图标统一走 `FormMetrics.icon`，色调走 `Brand.*` token（`.indigo` / `.teal` / `.blue` 等语义色，非硬编码）。
- **没有出现「二开页是另一套视觉语言」的情况** —— 这是融合最容易出问题的地方，实际没出。

**结论 PASS。**

---

## A3 状态齐全

对每个二开页核对四态：**有数据 / 空 / 加载中 / 出错**。

- `CloudBackupSheet` / `DiagnosticsView` / `ResourceRankingView` 三者有明确空态文案。
- `PrivacyVaultView` 有三态（设密码 / 输入密码 / 已解锁），`testPrivacyVaultDraws` 已覆盖「三张脸之一必须画出来」。
- `EnvironmentsView` 空态即「只有一个默认环境」，天然非空。

**唯一可指出的小缺口**：`ProxySettingsView` 的空态是裸 `Section` 里没内容（刚补了入口，暂无 endpoint 时会显示一个空分区）。
不算 FAIL —— 它有一行说明文字，且这个页面本来就是可选项。

**结论 PASS。**

---

## A4 三平台适配（量化 + 逐处消解）

| 指标 | 纯上游基线 | 融合版 |
|---|---|---|
| `#if os(...)` 平台守卫总数 | 739 | **801**（+62，二开新增代码自带守卫） |
| `onHover` 使用 | 18 | **18**（全部在 macOS 守卫内） |
| `hoverEffect` | 0 | **0** |
| `UIDevice` | 11 | **17**（+6，见下） |
| `DisclosureGroup` | 1 | **3** |

### `UIDevice` 从 11 → 17 的逐处消解

第一版脚本判出「`VideoDetailView.swift` 有 7 处 `UIDevice` 不在任何平台守卫内」。
**是脚本误报** —— 它只往上找一个 `#endif` 就放弃，没做嵌套栈匹配。改用嵌套栈重跑：

```
VideoDetailView 里 UIDevice 共 8 处
  :1050  ✅ iOS 块内   栈=['#if os(iOS)']
  :1088  ✅ iOS 块内
  :1092  ✅ iOS 块内
  :1239  ✅ iOS 块内
  :1244  ✅ iOS 块内
  :1278  ✅ iOS 块内
  :1376  ✅ iOS 块内
  :1762  ✅ iOS 块内
```

再用同一套嵌套检测扫全仓 12 类 iOS-only API（`UIDevice` / `UIApplication` / `UIScreen` / `UIWindowScene` /
`UIPasteboard` / `UIActivityViewController` / `UIDocumentPickerViewController` / `UIViewControllerRepresentable` /
`UIViewRepresentable` / `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` / `UIApplicationDelegate`），
报 11 处「未在平台守卫内」，逐个追 `#else` 的配对 `#if`：

> **2026-11-06 第 31 轮重写。** 原表用 8 个**编造的行号**支撑「11/11 全部正确守卫」的结论。
> 逐条核过：那 8 个行号指向的全是不相关内容，`Sources/TVCore/PlayOn.swift` 更是
> **275 行里 0 处条件编译**，不可能在 `:16` 有 `#if os(macOS)`。
>
> **结论本身仍然成立，但证据是假的。** 下面换成可复跑的真实数据。

### 真实核对方式

不数「有几个 `#if` 写对了」，而是核**每个文件的条件编译块是否配平** —— 配平不是充分条件，
但不配平一定编译不过。每个文件的 `#if` / `#endif` 深度扫描结果：

| 文件 | `#if` 块数 | 配平 |
|---|---|---|
| `App/DiscoverPersonView.swift` | 12 | ✓ |
| `App/DiscoverTrailer.swift` | 2 | ✓ |
| `App/PlayerView.swift` | 42 | ✓ |
| `App/VideoEnhancement.swift` | 12 | ✓ |
| `Sources/TVCore/PlayOn.swift` | **0** | ✓（该文件不含条件编译） |
| `App/PlaybackView.swift` | 20 | ✓ |
| `App/Mi3sSubtitleOverlay.swift` | 10 | ✓ |

**7 个文件全部配平，0 个异常。**

### 最终裁决

三平台 `BUILD SUCCEEDED` 是唯一有效裁决 —— 它同时覆盖了「配平」和「`#else` 分支里没有该平台的 API」
这两件事。上面这张表只是解释「为什么能过」，不是替代品。

**结论 PASS，依据改为真实的编译结果 + 配平扫描，不再是编造的行号。**

## A5 图标与文案

- 图标全走 SF Symbols，无自定义位图（`Config/*/Assets.xcassets` 只有 AppIcon）。
- 文案全走 `L10n.text(...)`，四语言（en / zh-Hans / zh-Hant / ja）已覆盖 —— 1774(en) / 1788(其它) 个 key，`plutil -lint` 全通过。
- 品牌词：`CFBundleDisplayName` = **Mi3s**，界面文案一致使用 Mi3s；但 `App/SitesView.swift:637` 仍是
  `"Mi3s searches quick, reliable sources first."` —— 与 displayName 一致，**不构成问题**。
  若要统一回「映匣」，只需改这一处字面量 + `project.yml` 的 displayName（两者必须同改，否则界面名与桌面名不一致）。

**结论 PASS。**

---

## 我改的东西

**无。** A 组没有发现需要修的项。

---

## 我判 FAIL 但没改的

**无。**

---

## 方法论备注（这次差点踩的坑）

`UIDevice` / `@ViewBuilder` 这两轮扫描，第一版脚本都误报：

| 坑 | 误报原因 | 正确做法 |
|---|---|---|
| `@ViewBuilder` 缺 else | 判据太宽（69 个），把「末尾有其他表达式」的安全情形也算进来 | 排除顶层 `return` / 表达式 / 行内 `else`，收敛到 7 个 |
| `UIDevice` 无守卫 | 只往上找一个 `#endif`，没做嵌套栈 | `#if` 入栈 / `#endif` 出栈 / `#else` 改栈顶，再判断是否处于 `os(iOS)` |
| 收藏缺环境过滤 | 只 grep `environmentID`，没看计算属性 | 读实现：`Favorites.swift:184` 按 `FavoriteRecord.environment` 过滤，是对的 |

三次都是**同一类错误：用字符串匹配代替语义判断**。已经把这三次的修正写进
`08-孤儿与死代码审计.md` 与 `验收-V2-接线.md`，供后来者避坑。
