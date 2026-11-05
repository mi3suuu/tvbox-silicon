### 线名：W5-subtitle（字幕 / AI 翻译 / 语音字幕（含 M6 裁决））

**状态**：完成（M6 已由 captain 以 d5092ff 落地，本线收窄为数据层核对 + 入口补线）

---

## 零、M6 裁决的最终归属（先说清楚，避免重复劳动）

captain 已按路线 A 落地（commit `d5092ff`），本线复核后确认该裁决成立，不再另做裁决：

| 文件 | 最终归属 | 依据 |
|---|---|---|
| `Sources/TVCore/SubtitleStyle.swift` | **上游 1.8.11 原版，一字未改**（`git diff 22180e4` 为空） | 上游 #547 已覆盖外观全部字段：`x`/`y`/`size`/`font`/`bold`/`italic`/`color`/`edge`/`backdrop` + `clamped` + `load()`/`save()` |
| `App/SubtitleStyleView.swift` | 上游原版，且在设置页支持下拖拽定位（`SubtitleStyleView.swift:126` `.gesture(drag(in: size), including: draggable ? .all : .none)`） | 上游能力比我方强：多出颜色/描边/底框/字体族 |
| `Sources/TVCore/Mi3sSubtitleStyle.swift` | 我方那套改名保留（189 行，含 `SubtitlePositionMemory`） | 我方唯一真增量：**按标题分别记住拖到哪**；上游 `save()` 只存一份全局 style |
| `App/SubtitleOverlay.swift` | 上游原版（`SubtitleCues` + `SubtitleLines` + `subtitlePlacement`） | 上游挂在 `AVPlayerItemLegibleOutput` 上，是封在片源里的字幕 |
| `App/Mi3sSubtitleOverlay.swift` | 我方自绘层改名保留 | 画的是**解析出来的外部字幕文件**（`channel.subtitles`），走 `SubtitleTrack` 而非 AVPlayer |

**路线 B/C 为什么没选**（供 captain 判负时核对）：

- **路线 B**（用 extension 补 `standard`/`sanitized`）：不可行。`SubtitleStyle` 是 `struct`，extension 加不了存储属性；我方 5 个字段（`fontSize`/`textOpacity`/`backgroundOpacity`/`centerX`/`centerY`）与上游 8 个字段语义不重叠，用 extension 补出来的只是空壳。
- **路线 C**（彻底丢弃我方自绘层）：能力回退。上游 `SubtitleOverlay` 只画 AVPlayer 交出来的 cue，**画不了 code 4 直接给的外部字幕 URL**（`channel.subtitles`）——那条链在 iOS 上是 `MobilePlayer.loadSubtitles()` → `SubtitleTrack.loadAll` → `Mi3sSubtitleOverlay`，与上游管线完全平行。丢了这一层，外部字幕文件在 iOS 播放页就没人画。

---

## 一、已接入（文件 → 能力 → 真实接线点 文件:行号）

### 1.1 字幕解析（我方新增，上游没有）

| 文件 | 能力 | 接线点 |
|---|---|---|
| `Sources/TVCore/SubtitleTrack.swift` | WebVTT / SRT / ASS → 带时间戳的 cue；`cue(atSeconds:)` 查表；`loadAll` 并发装载、按源顺序保序 | `App/MobilePlayer.swift:115` `subtitleTracks = await SubtitleTrack.loadAll(files, headers: channel.headers)` |
| 同一文件 | 依赖上游 `SubtitleFile.cues(_:format:)` 解析器（`Sources/TVCore/SubtitleFile.swift`，上游文件，未改） | `SubtitleTrack.swift:83` `let parsed = SubtitleFile.cues(data, format: format)` |

**签名核对结论**：`loadAll(_ subtitles: [ExternalSubtitle], headers: [String: String] = [:]) async -> [SubtitleTrack]`。调用方传的是 `channel.subtitles`（`Channel` 的 `[ExternalSubtitle]`）与 `channel.headers`，类型完全对上；`await` 返回非可选数组，失败的单条被丢弃而非整体失败（`SubtitleTrack.swift:103` `try? await load(...)`）。

**已接**。能力在、编得过、调用方签名对得上。

### 1.2 播放页自绘层（我方，走 `SubtitleTrack`）

| 文件 | 能力 | 接线点 |
|---|---|---|
| `App/Mi3sSubtitleOverlay.swift` | 把当前 cue 按上游 `SubtitleStyle` 画在画面上、可拖、按标题记忆位置 | `App/MobilePlayer.swift:394` `Mi3sSubtitleOverlay(track: activeSubtitleTrack, position: clock.position, style: $subtitleStyle, positionKey: channel.url.absoluteString, memory: $subtitlePositions)` |
| 同一文件 | 有 track 时关掉 AVPlayer 自己的 legible 轨，避免双份字幕 | `App/MobilePlayer.swift:118` `if !subtitleTracks.isEmpty, let group = tracks.legible { tracks.select(nil, in: group) }` |
| `Sources/TVCore/Mi3sSubtitleStyle.swift` `SubtitlePositionMemory` | 按 key（视频 URL）记住落点，LRU 淘汰，容量 40 | `App/MobilePlayer.swift:109-111` 读出并写回 `style.centerX/centerY`；`:548` 变更即持久化 |

**平台门**：`App/MobilePlayer.swift:1` `#if os(iOS)` —— 整个文件只在 iOS 编译。macOS / tvOS 播放页（`PlayerView.swift` 的 `NativePlayerView` / `DesktopPlaybackView`）不加载外部字幕文件，这是**已知缺口**，见「二、未接入」。

### 1.3 AI 字幕翻译（我方新增，全平台）

| 文件 | 能力 | 接线点 |
|---|---|---|
| `Sources/TVCore/SubtitleTranslator.swift` | OpenAI 兼容 API 批量翻译 cue；`Configuration`（baseURL/model/apiKey/targetLanguage/extraInstructions）+ `Provider.known`（含 Doubao 预设） | 见下两行 |
| `App/AITranslationView.swift` | 配置页：服务下拉、地址/模型/Key、"翻译成"、自定义规则、"测试翻译服务" | 入口 `App/SettingsForm.swift:415` `FormLink(... title: L10n.text("AI Translation"), value: store.aiTranslation.isComplete ? L10n.text("On") : nil) { AITranslationView() }` |
| 同一文件 | 改动即时落库 + 即时重装翻译器 | `AITranslationView.swift:82-88` `store.aiTranslation = new; store.saveVault(); SubtitleTranslationSetup.installAI(...)` |
| `App/SubtitleTranslator.swift` `AITranslatorAdapter` | 把 AI 翻译器接到上游 `SubtitleTranslating` 协议上，重封装侧零改动 | `SubtitleTranslator.swift:216` `SubtitleTranslation.translator = AITranslatorAdapter(configuration: configuration)` |
| `App/SubtitleTranslator.swift` `OnDeviceSubtitleTranslator` + `SubtitleTranslationQueue` | Apple 本机 Translation（iOS 18 / macOS 15 起，tvOS 除外） | `App/TVBoxApp.swift:33` `SubtitleTranslationSetup.install()`；`App/PlayerView.swift:160` `.subtitleTranslation()` 承载 `translationTask` |

**配置存在哪（captain 问的第 1 点）**：

- 存 `Store.aiTranslation`（`App/Store.swift:86`），序列化进 `playbackDefaults` 的 key `"aiSubtitleTranslation"`（`Store.swift:97` / `:110`）。
- 不是 `SubtitleTranslator` 自己持久化——那个类型是纯值 + 无状态翻译器，`Configuration` 只是 `Codable` 值。
- 启动恢复：`Store.swift:477-480` 解码 → `:488` `SubtitleTranslationSetup.installAI(configuration: loadedAI)`。**顺序是对的**：`TVBoxApp.swift:33` 先 `install()` 装本机翻译器，`Store.init` 后跑 `installAI`，有配置就顶掉、没配置就保留本机——与注释（`Store.swift:482-484`）一致。

**有没有真实入口（第 2 点）**：有，`App/SettingsForm.swift:415`，在「What Plays」分组的第 4 行；配置完整时右侧显示「On」。iOS / macOS 都走这个表单（`App/SettingsView.swift:151` `FormSettingsView()`）。

**与 `SubtitleStyleView` 会不会冲突（第 3 点）**：不会，两者不在同一层也不是同一件事——
- `Subtitle Style` = 字幕**长相**（字体/颜色/描边/位置），进 `SubtitleStyleView`（上游）；
- `AI Translation` = 字幕**翻译服务**，进 `AITranslationView`（我方）。
- 我补入口时把它们放进了同一个「What Plays」分组，但 `Subtitle Style` 排在 `Segment Sources` 之后、`AI Translation` 之前，物理上相邻、语义上分属「看什么」与「怎么翻」；没有重复入口。

### 1.4 语音字幕（本机识别，我方新增）

| 文件 | 能力 | 接线点 |
|---|---|---|
| `Sources/TVCore/SpeechSubtitles.swift` | 视频音轨 → `SFSpeechRecognizer`（`requiresOnDeviceRecognition = true`）分片识别 → `SubtitleTrack`；`Failure` 六种失败分类 | `App/MobilePlayer.swift:265` `try await SpeechSubtitles().transcribe(asset:language:name:hint:progress:)` |
| `Sources/TVCore/SpeechSubtitlePreference.swift` | 语言偏好，key `"speechSubtitles.preferredLanguage"`；候选序列去重（viewer 选择 → 系统语言 → zh-Hans-CN/zh-CN/en-US） | 读：`App/MobilePlayer.swift:235` `@AppStorage(SpeechSubtitles.preferredLanguageKey)`；写：`App/SpeechSubtitleView.swift:16` `@AppStorage(SpeechSubtitlePreference.key)` —— **两侧同一个 key**（`SpeechSubtitles.swift:84` `preferredLanguageKey = SpeechSubtitlePreference.key`） |
| `App/SpeechSubtitleView.swift` | 设置页：选识别语言（只列本机有模型的） | 入口 `App/SettingsForm.swift:414` |

**权限请求时机（captain 问的）**：

- 声明：`project.yml:163` `NSSpeechRecognitionUsageDescription: Writes subtitles from a video's own sound track, on this device.` ✅ 已在。
- **不需要** `NSMicrophoneUsageDescription`：本功能读的是**视频文件自带的音轨**（`AVAsset` → `AVAssetExportSession` 导出音轨），不录麦克风。我核对了 `SpeechSubtitles.swift:122` `try await Self.requestAuthorization()` → `:336-339` 只调 `SFSpeechRecognizer.requestAuthorization`，全程无 `AVAudioSession` 录音；`rg "NSMicrophone" project.yml` 空，是正确的。
- 时机：**懒请求**，在 `transcribe()` 里（`SpeechSubtitles.swift:122`），不是启动时。而且**先门控后请求**——`:116` `guard Self.canRecogniseOnDevice(language)` 先查本机有没有该语言模型，`:117-120` 再查 `recogniser.isAvailable`，都过了才请求授权。这样没模型的语言不会弹出权限框问一句再告诉你"没有模型"。
- 入口门控（第 3 点）：`App/MobilePlayer.swift:999` `case .speechSubtitles: speechLanguage != nil` —— 本机没有可用语言时整项不出现；`:242-245` `speechLanguage` 走 `SpeechSubtitles.preferredLanguage(stored:)`，内部 `canRecogniseOnDevice` 门控。
- 设置页入口：`App/SettingsForm.swift:414`（iOS/macOS）+ 播放页三个入口：`MobilePlayer.swift:1134`（控件槽位）、`:1362`（`speechSubtitleEntry` 菜单）、`:1569`。

### 1.5 上游 #547 字幕外观页的入口（captain 问的第 4 点 → **本次补线**）

**问题**：`SubtitleStyleView`（上游文件）在融合后的设置页里**没有任何生产入口**，只有 `App/QALaunch.swift:259` 的 QA 启动参数能到。

**根因**（不是谁的疏忽，是文件归属造成的必然）：
- 上游把入口写在 `App/SettingsView.swift` 里，共 4 处（`git grep -n "SubtitleStyleView" 22180e4 -- '*.swift'`）：
  - `:538` iPhone/iPad `FormLink`
  - `:877` Mac `SettingsGroup` 内 `FormLink`
  - `:1594` tvOS `TVSettingsLink`
  - `:259`（QALaunch）
- 而融合版的 `App/SettingsView.swift` 是我方 164 行的**平台分派壳**（`#if os(tvOS) TVSettingsView() #else FormSettingsView() #endif`），上游那 2097 行的正文没进来——这是 02 清单 D-05/D-06 记录的「我方拆分主视图」策略的必然结果。
- 结论：**上游入口随上游 SettingsView 正文一起丢失**，`SubtitleStyleView` 成了孤儿文件。

**已修（本线改动，两个文件各一行）**：

| 文件 | 行 | 内容 |
|---|---|---|
| `App/SettingsForm.swift` | 417 | `FormLink(symbol: "captions.bubble.fill", tint: .orange, title: L10n.text("Subtitle Style")) { SubtitleStyleView() }` |
| `App/SettingsTV.swift` | 102 | `TVSettingsLink(title: L10n.text("Subtitle Style")) { SubtitleStyleView() }` |

放在「What Plays」分组里、`Segment Sources` 之后（iOS/macOS），以及 tvOS 的「Show Video Info」同节。两处都带注释说明为什么补。

---

## 二、未接入（同步追加进 `02-未纳入清单.md`）

| 能力 | 原因 | 重开条件 |
|---|---|---|
| **N-W5-01** macOS 播放页不加载外部字幕文件 | `SubtitleTrack` / `Mi3sSubtitleOverlay` / 语音字幕的调用方全在 `App/MobilePlayer.swift`，该文件整体 `#if os(iOS)`。macOS 播放页 `App/PlayerView.swift` 的 `DesktopPlaybackView` 从来只用 AVKit 自带的字幕选择（`nativeSubtitleMenu`），从未接过 `channel.subtitles`。属 W4-playback 的 `PlayerView.swift`，非本线文件。 | 要在 Mac 上看外部字幕 / 语音字幕时。落点：`App/PlayerView.swift` 的 `DesktopPlaybackView` 里加 `@State subtitleTracks` + `Mi3sSubtitleOverlay` 覆盖层，约 20 行；或抽一个 `Mi3sSubtitleStage` 视图供两平台共用（维护性更好，推荐）。 |
| **N-W5-02** tvOS 播放页不加载外部字幕文件 | 同上，`MobilePlayer.swift` 是 iOS-only；tvOS 用 `NativePlayerView`（`PlayerView.swift:915`，`AVPlayerViewController` 包装），只走系统字幕菜单。另外 tvOS 上没有拖拽手势（`Mi3sSubtitleOverlay` 的 `drag` 已在 `#if !os(tvOS)` 里），需要遥控器式的位置调整。 | 要在 Apple TV 上看外部字幕时。需先给 `Mi3sSubtitleOverlay` 加遥控器调整路径（参考上游 `SubtitleStyleView` 的 tvOS 分支）。 |
| **N-W5-03** 上游 #547 的 `SubtitleCues` 管线在 `PlaybackView` 里未接线 | `App/PlaybackView.swift:608` `makeItem(_:url:)` 少了上游的两行：`item.textStyleRules = Self.subtitleRules()`（上游 `:604`）与 `subtitles.attach(item)`（上游 `:605`）；`PlaybackSession` 也没有 `let subtitles = SubtitleCues()`（上游 `:491`）。结果是：**设置页里调好的字幕外观，在播放时对封在片源里的字幕不生效**。属 W4-playback 文件，本线不改。 | 立刻可修，三行：① `PlaybackSession` 加 `let subtitles = SubtitleCues()`；② `makeItem` 里 `AVPlayerItem(asset:)` 之后 `subtitles.prepare(item)`；③ item 就绪处 `subtitles.follow(player.currentItem)`。详见「四、需要 captain 做」的代码块。 |

> N-W5-03 是本轮核对发现的**最严重一条**：它不是"少个入口"，是上游一条完整功能链在融合时断在中间。macOS 编译看不见，因为它不影响编译；只有在 macOS 上真播一段带内嵌字幕的片子才会发现设置不生效。

---

## 三、侵入上游（同步追加进 `03-侵入点登记表.md`）

**本线零侵入上游文件。**

- `Sources/TVCore/SubtitleStyle.swift`：`git diff 22180e4 -- Sources/TVCore/SubtitleStyle.swift` 为空。
- `App/SubtitleOverlay.swift`、`App/SubtitleStyleView.swift`：与 `22180e4` 逐字节一致。
- 本线唯一改动落在**我方文件**：`App/SettingsForm.swift`（我方独占，上游无此文件）、`App/SettingsTV.swift`（我方拆分文件）。
- M6 的 `Mi3s*` 改名与 `MobilePlayer.swift` 三处引用由 captain 在 `d5092ff` 落地，已登记为 **I-08**，不重复登记。

---

## 四、需要 captain 做（Store 字段 / 本地化 key / project.yml / W4 交接）

### 4.1 需要 Store 主类加字段：**无**

`Store.aiTranslation` 已存在（`App/Store.swift:86`），`saveVault()` 已覆盖（`:110`），启动恢复已覆盖（`:477-488`）。本线不需要新增任何存储属性。

### 4.2 新增本地化 key：**一个**

| key | 语言 | 说明 |
|---|---|---|
| `Subtitle Style` | en / ja / zh-Hans / zh-Hant | **不是新文案**——上游 `Localizable.strings` 里已有（上游 `SettingsView.swift:538` 用过）。本轮只是把入口补回来，key 复用即可。 |

核对结论：`App/SettingsForm.swift:417` 与 `App/SettingsTV.swift:102` 用的都是 `L10n.text("Subtitle Style")`，与上游同字面，**无需新增任何 key**。

### 4.3 project.yml：**无需改动**

`NSSpeechRecognitionUsageDescription` 已在 `project.yml:163`。`NSMicrophoneUsageDescription` 不需要（理由见 1.4）。

### 4.4 转给 W4-playback：`PlaybackView.swift` 三行接线（N-W5-03）

```
文件：App/PlaybackView.swift

① PlaybackSession 类内（建议紧跟 `let catalogDanmaku = CatalogDanmakuModel()` 之后）
   加法：let subtitles = SubtitleCues()
   理由：Swift extension 加不了存储属性（见铁律 1 的 C 类）

② makeItem(_:url:) 内，`let item = AVPlayerItem(asset: asset)` 之后
   加法：subtitles.prepare(item)
   （等价于上游的两行：item.textStyleRules = Self.subtitleRules()
                            subtitles.attach(item)）

③ item 就绪处（上游是 `:475` 的 ready 观测里）
   加法：subtitles.follow(player.currentItem)

④（可选，改样式立即生效）PlaybackSession 初始化时
   加法：self.styleObserver.start()
   其中 styleObserver = Mi3sSubtitleStyleObserver { [weak self] in
            self?.subtitles.restyle(self?.player.currentItem) }
   配套：deinit / 退出时 styleObserver.stop()
```

`subtitles.prepare(_:)` / `restyle(_:_:)` / `Mi3sSubtitleStyleObserver` 的上游等价代码封装在 `App/SubtitleCues+Mi3s.swift`（我方新文件，**W4 可直接调，不必自己抄上游的 private static**；已随本线提交，三平台编译通过）。

播放页还要显示覆盖层的话，在 `NativePlayerView` 里加（上游写法一致）：
```
if let subtitles { SubtitleOverlay(cues: subtitles).ignoresSafeArea() }
```

> **为什么把封装写成独立文件而不是直接让 W4 抄上游两行**：`subtitleRules()` 是上游 `PlaybackSession` 的 `private static`，W4 抄一遍就是两份实现；而改样式要重新设 `textStyleRules`，这第二处 W4 原本没有。封装成 `SubtitleCues.rules/prepare/restyle` 一处维护，上游将来改 `attributes` 也不用再跟。

---

## 五、验证证据（命令输出尾部）

### 5.1 TVCore 编译

```
$ swift build --package-path Packages/TVCore --target TVCore 2>&1 | tail -3
[14 / 16] TVCore
[16 / 16] TVCore
Build complete! (9.32秒)
```

### 5.2 TVCore 单测（字幕相关 3 个 suite）

```
$ swift test --package-path Packages/TVCore --filter "SpeechSubtitles|SubtitleTranslator|SubtitleStyle" 2>&1 | tail -3
✔ Suite SubtitleTranslatorTests passed after 0.002 seconds.
✔ Suite SpeechSubtitlesTests passed after 0.002 seconds.
✔ Suite SubtitleStyleTests passed after 0.017 seconds.
✔ Test run with 12 tests in 3 suites passed after 0.018 seconds.
```

### 5.3 macOS

```
$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Debug \
    -derivedDataPath build/DD-line build 2>&1 | tail -3
** BUILD SUCCEEDED **
```

### 5.4 tvOS

```
$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS -configuration Debug \
    -derivedDataPath build/DD-line-tvos -destination 'generic/platform=tvOS' \
    build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
** BUILD SUCCEEDED **
```

### 5.5 iOS

```
$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -configuration Debug \
    -derivedDataPath build/DD-line-ios -destination 'generic/platform=iOS' \
    build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
** BUILD SUCCEEDED **
```

> 说明：本 worktree 起初缺 `build/AppleRuntime/`（本地预编译的 JVM/Python 宿主，不入 git），tvOS/iOS 会停在 `Runtime/AppleRuntime/Native/AppleRuntime.m:3: error: 'jni.h' file not found`，与源码无关。已从主工作树 `tvbox-silicon-fusion/build/AppleRuntime/` 同步过来（`rsync -a --exclude '*.o'`），之后三平台均通过。**这不是代码改动，只是把本机编译依赖补齐**——其他线的 worktree 若报同一个错，照此办理即可。

### 5.6 `App/SubtitleCues+Mi3s.swift` 单独确认（N-W5-03 的交付物）

```
$ ls -la App/SubtitleCues+Mi3s.swift
-rw-r--r--  App/SubtitleCues+Mi3s.swift     (约 100 行)

提供的 API（W4 可直调）：
  SubtitleCues.rules(_ style:) -> [AVTextStyleRule]
  SubtitleCues.prepare(_ item:)            // = textStyleRules + attach
  SubtitleCues.restyle(_ item:, _ style:)  // 改样式后重设规则
  Mi3sSubtitleStyleObserver(apply:).start() / .stop()

加这个文件后三平台仍全部 BUILD SUCCEEDED（上面 5.3/5.4/5.5 是加了它之后的输出）。
```

### 5.7 接线静态审计（本线真正的验收手段）

```
$ rg -n "SubtitleStyleView" App/ --type swift
App/SettingsForm.swift:417:  FormLink(... title: L10n.text("Subtitle Style")) { SubtitleStyleView() }   ← 本次新增
App/SettingsTV.swift:102:    TVSettingsLink(title: L10n.text("Subtitle Style")) { SubtitleStyleView() } ← 本次新增
App/QALaunch.swift:259:      SubtitleStyleView()                                                        ← QA 入口
App/SubtitleStyleView.swift:13: struct SubtitleStyleView: View

（补线前：只有 QALaunch 一处 → 生产环境不可达）

$ rg -n "AITranslationView|SpeechSubtitleView" App/SettingsForm.swift
App/SettingsForm.swift:414: FormLink(... "Speech Subtitles") { SpeechSubtitleView() }
App/SettingsForm.swift:415: FormLink(... "AI Translation")  { AITranslationView() }

$ rg -n "SubtitleTrack.loadAll" App/ Sources/
App/MobilePlayer.swift:115: subtitleTracks = await SubtitleTrack.loadAll(files, headers: channel.headers)

$ rg -n "SubtitleTranslationSetup" App/ Sources/
App/TVBoxApp.swift:33:        SubtitleTranslationSetup.install()      ← 启动装本机翻译器
App/Store.swift:488:         SubtitleTranslationSetup.installAI(...) ← 有 AI 配置则顶掉
App/AITranslationView.swift:87: SubtitleTranslationSetup.installAI(...) ← 改动即重装
```

---

## 六、遗留与建议

1. **N-W5-03 优先修**：三行代码，修好之后上游 #547 的字幕外观才真正对用户生效。当前状态下「设置页能进、能调、能保存，但播放不生效」——比入口缺失更有误导性。
2. **N-W5-01/02（Mac / TV 无外部字幕）**：建议做成共享视图 `Mi3sSubtitleStage`，iOS 先用着，Mac/tvOS 后续接；不建议现在为两平台各抄一份。
3. `SpeechSubtitles` 只在 `#if canImport(Speech) && canImport(AVFoundation) && !os(tvOS)` 下编译（`SpeechSubtitles.swift:5`）——tvOS 上 `SFSpeechRecognizer` 整体 unavailable，这是平台事实，不是缺口；但 `SpeechSubtitlePreference` 故意不受该门控（`SpeechSubtitlePreference.swift:5-7` 注释），所以 tvOS 的设置页仍能编译、能记住选择。这个分层是对的，未改。
