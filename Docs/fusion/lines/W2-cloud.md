### 线名：W2-cloud（下载 + 云盘 + 缓存）

**认领文件（06 号文档 W2-cloud 节，14 个）**
```
App/DownloadsView.swift          App/CloudFilesView.swift        App/CloudDriveView.swift
Sources/TVCore/Downloads.swift   Sources/TVCore/DownloadTransfer.swift
Sources/TVCore/MusicDownloads.swift   Sources/TVCore/MediaCache.swift
Sources/TVCore/AList.swift       Sources/TVCore/Pan115Files.swift
Sources/TVCore/QuarkFiles.swift  Sources/TVCore/WebDAV.swift
Sources/TVCore/XunleiSignIn.swift Sources/TVCore/CloudSources.swift
Tests/TVCoreTests/DownloadTests.swift
```

**状态**：完成
（基线 rebase 到 `1cb0c32` 后重验；本线 14 文件与 `fusion/main` 逐字节一致 + 1 处本线新增修正）

---

#### 先说结论：这条线**没有**「我方版 vs 上游版」的取舍问题

我按 05 号文档的三命令口径逐文件核过，结论和 02 号清单里 P-01 / P-02 的**前提相反**：

| 命令 | 结论 |
|---|---|
| `git diff --numstat 8b9519b 22180e4 -- <14文件>` | 上游 1.8.11 对本线**只改了 `App/CloudDriveView.swift` 一个文件**（+81/−4），其余 13 个文件上游一字未动 |
| `git diff --numstat 8b9519b import/ours -- <14文件>` | 我方对 14 个文件都有改动（合计 +370/−72） |
| `git diff 22180e4 -- <14文件>` | 当前工作树 = 上游 + 我方增量，**无一处双向冲突**（唯一例外见下） |

所以 P-01 / P-02 里写的「暂接我方版、待验收对比上游是否已覆盖」这个待定项，**可以关闭**——
本线不存在两个实现二选一，上游没有对应实现，我方增量是新能力，直接叠加在真身上。

唯一真正被上游吃掉的，是 `App/CloudDriveView.swift`（上游 +81/−4 是 #498 云盘登录弹窗可缩放 + 页面自适应缩放，
比我方那 13 行「退出登录二次确认」更完整）。**该文件当前是纯上游版，我方增量丢失**，
本次已按 extension 无法覆盖的方式恢复（见「侵入上游」）。

---

#### 已接入（文件 → 能力 → 真实接线点 文件:行号）

| 文件 | 能力 | 接入位置（调用点，已 grep 证实被调用） |
|---|---|---|
| `Sources/TVCore/Downloads.swift` | `DownloadSource` 带 `origin` / `sourceKey`，供隐私保险库按订阅来源隐藏下载；自定义 `CodingKeys` + `init(from:)` 全 `decodeIfPresent` 兜底（老存档不炸） | `App/DownloadsView.swift:658`（`DownloadPicker.source(_:)` 传入 `origin: origin`）<br>`App/VideoDetailView.swift:243`（`DownloadPicker(..., origin: client.origin)`）<br>`Sources/TVCore/PrivacyVault.swift:485`（`visibleDownloads` 读 `item.source.origin`）<br>`Tests/TVCoreTests/PrivacyVaultTests.swift:174`（用例已通过） |
| `App/DownloadsView.swift` | 下载列表按保险库过滤（隐藏来源的集数整条消失，与历史/收藏同规则）；`DownloadPicker` 新增 `origin` 形参 | `App/DownloadsView.swift:21`（`visibleItems` 统一供 4 处使用：`pending`/`shows`/空态/`onChange`） |
| `Sources/TVCore/Downloads.swift` | `pauseAll()` 补 `schedule()`；`suspend()` 改 `Array(running.keys)` 防遍历中改字典 | `Sources/TVCore/Downloads.swift:223`（`pauseAll`）<br>`Sources/TVCore/Downloads.swift:234`（`suspend`） |
| `Sources/TVCore/Downloads.swift` | 索引读写换 `JSONFileStore`（原子写 + 目录自建 + 尺寸上限） | `Sources/TVCore/Downloads.swift:457`（`store`）→ `:467`（`load`）/ `:479`（`save`） |
| `Sources/TVCore/MusicDownloads.swift` | 同上：`suspend()` 防字典遍历中改；两处索引改 `JSONFileStore` | `Sources/TVCore/MusicDownloads.swift:184`（`suspend`）<br>`Sources/TVCore/MusicDownloads.swift:325-326`（`store` / `collectionStore`）→ `:333`/`:344`/`:357`/`:361` |
| `Sources/TVCore/DownloadTransfer.swift` | 流式下载中途失败**不再重试**（重试会把已落盘的半截文件再追加一遍，写坏文件） | `Sources/TVCore/DownloadTransfer.swift:338`（`.incomplete` 且 `sink != nil` → 抛出）<br>`:350`（网络中断且 `sink != nil` → 抛出） |
| `Sources/TVCore/MediaCache.swift` | **[已修 bug]** 索引持久化区分「结构变化」与「使用时间刷新」：新增/删除/初始化/prune 一律 `persist(force: true)`，只有 `data(for:)` 刷 `used` 才允许 1 秒节流。原实现无条件节流 → 同进程新实例或崩溃重启后读不到刚写的条目，缓存明明在盘上却取不到 | `Sources/TVCore/MediaCache.swift:160`（`persist(force:)` 定义，带 `[mi3s]` 注释）<br>调用点：`:43`、`:62`、`:90`、`:101`、`:111`、`:124`（全部 `force: true`）；`:72`（`data(for:)` 内刷新 `used`，保持节流）<br>`MediaCacheTests` 4 项全通过 |
| `Sources/TVCore/AList.swift` | 整文件 `upload`（`/api/fs/put`，`File-Path` + `Password` 头）/ `download`（`/api/fs/get` 的 `raw_url`） | `Sources/TVCore/CloudDriveBackup.swift:89`（`AList.shared.upload`）<br>`Sources/TVCore/CloudDriveBackup.swift:51`（`AList.shared.download`）<br>单测：`CloudDriveBackupTests`「AList 上传再读回」 |
| `Sources/TVCore/WebDAV.swift` | 整文件 `PUT` / `GET`（原子覆盖同名备份），401 → 登录错误 | `Sources/TVCore/CloudDriveBackup.swift:88`（`WebDAV.shared.upload`）<br>`Sources/TVCore/CloudDriveBackup.swift:50`（`WebDAV.shared.download`）<br>单测：`CloudDriveBackupTests`「WebDAV 上传再读回，字节一致」「WebDAV 上传 401 抛登录错误」 |
| `Sources/TVCore/Pan115Files.swift` | `mkdir`（`/files/add`）/ `upload`（`uplb.115.com` multipart 整包）/ `download`（走 pick code 链接） | `Sources/TVCore/CloudDriveBackup.swift:35`（`Pan115Files.shared.upload`）<br>`Sources/TVCore/CloudDriveBackup.swift:75`（`mkdir`）<br>`Sources/TVCore/CloudDriveBackup.swift:48`（`download`） |
| `Sources/TVCore/QuarkFiles.swift` | `mkdir`（`/file`+`dir=1`）/ `upload`（两步：`/file/upload` 开会话 → POST 字节）/ `download`（原始文件链接） | `Sources/TVCore/CloudDriveBackup.swift:31`、`:33`（quark / uc `upload`）<br>`Sources/TVCore/CloudDriveBackup.swift:73-74`（`mkdir`）<br>`Sources/TVCore/CloudDriveBackup.swift:46-47`（`download`） |
| `Sources/TVCore/XunleiSignIn.swift` | 客户端版本号 / authVersion 收敛到 `Endpoints`（`25.0.6.30`），与 Pan115/Quark UA 同一处管理 | `Sources/TVCore/XunleiSignIn.swift:29-30`（读 `Endpoints.xunleiClientVersion`/`xunleiAuthVersion`） |
| `Sources/TVCore/CloudSources.swift` | 内建源版本不兼容时的提示文案 | `Sources/TVCore/CloudSources.swift:36`（`throw TVError.unsupported(...)`） |
| `App/CloudFilesView.swift` | 云文件行补 `accessibilityLabel`（VoiceOver 能念出「播放 <文件名>」，此前只有 `accessibilityIdentifier`） | `App/CloudFilesView.swift:155`（`.accessibilityLabel(L10n.text("Play %@", file.name))`） |
| `App/CloudDriveView.swift` | 登出二次确认（确认框写明「插件里保存的登录也会一起删掉」）——**本次恢复** | 见下「侵入上游」I-08 |
| `Tests/TVCoreTests/DownloadTests.swift` | 14 项下载/音乐下载/本地 HLS 服务用例 | `swift test --filter DownloadTests` → 14 passed |

**上游与二开在 `App/CloudDriveView.swift` 的取舍说明（给 captain 的裁决依据）**
- 上游 #498 的 `ResizableSheet` + `PageFittingWebView`（弹窗可缩放、UC 登录页 1260pt 宽会被缩到放进 900pt 面板）解决了「二维码被切掉」的**真实可用性缺陷**；
  我方那版只是「去掉固定 900×680 硬编码」的雏形，能力和上游差一个量级。
- **选上游实现**（保留 #498），我方「登出确认」以增量方式补回。
  没选「以我方版为准」的理由：我方版会让 UC/夸克登录二维码重新被裁，属于倒退。

---

#### 未接入（同步追加进 `02-未纳入清单.md`）

| 能力 | 原因 | 重开条件 |
|---|---|---|
| 无 | 本线 14 个文件的二开增量**全部接入**，没有丢弃项 | — |

**另需订正 02 号清单的既有条目**（不是新丢弃，是前提被推翻）：

| 条目 | 原文 | 实测 | 建议处置 |
|---|---|---|---|
| `P-01` | 「上游 1.8.11 新增 `OwnDriveSignIn` / `CloudDriveBridge`，是否已覆盖网盘挂载 → 暂接我方版」 | 这两个是 **Java 运行时**文件（`Runtime/JavaHost/src/main/java/tvbox/runtime/`），上游与我方**都存在且内容相同**，提供的是「插件自建登录 / Wex cookie 注入」，**不提供**原生的 `upload`/`download`/`mkdir`。网盘读写能力上游根本没有对应实现 | **关闭 P-01**：AList / Pan115 / Quark / WebDAV 归本线「已接入」，不作为待定项 |
| `P-02` | 「上游也改了登录页 → 暂接我方版，验收时对比入口是否重复」 | `App/CloudQRLoginView.swift`、`CatPawSignInView.swift`、`XunleiSignInView.swift`、`WebSignInView.swift`、`PluginSignInView.swift` 上游与我方**同名同文件**，且当前工作树里它们都是上游版（我方在这 5 个文件无独占增量）。入口分工清晰：网页登录走 `WebSignInView`，扫码走 `CloudQRLoginView`，插件内嵌走 `PluginSignInView`/`CatPawSignInView`，迅雷走 `XunleiSignInView`，**无重复** | **关闭 P-02**：无「我方版被丢弃」这回事 |

> 这两个条目我没有直接改 `02-未纳入清单.md` 的正文（避免与 captain 并发写冲突），已在此写明；需要落盘请 captain 按上表改写。

---

#### 侵入上游（同步追加进 `03-侵入点登记表.md`）

| # | 文件 | 锚点 | 二开内容 | 侵入原因 | 上游变更时如何复核 |
|---|---|---|---|---|---|
| I-08 | `App/CloudDriveView.swift` | `struct CloudDriveView`（`#if os(macOS)` 版，第 6 行起）与 `#else` 版（第 345 行起），**两个 struct 各改一处** | ① 各加 1 个 `@State private var signingOut: CloudProvider?`（均带 `// [mi3s] 二开：` 注释）<br>② `Sign Out` 按钮由「直接 `signOut(provider)`」改为「`signingOut = provider`」<br>③ 各加一个 `.confirmationDialog`（标题 `Sign out of %@?`，破坏性按钮，正文提示插件登录也会被删） | `@State` 是存储属性，Swift extension 加不了；且上游 #498 已把该文件改得比我方版完整，只能在本文件内以最小增量补回确认框 | 上游若重构 `CloudDriveView` 的登出路径：保留 `signingOut` 状态与 `.confirmationDialog`，把确认后的动作改回等价调用（macOS 版 `provider.clear(&accounts)` + `EmbeddedJarHost.forgetPluginSignIns` + `save()`；iOS/tvOS 版 `signOut(provider)`）。若上游自己加了确认框，删除 I-08 全部改动 |

**验证**：`grep -c signingOut App/CloudDriveView.swift` → **9**（两个 struct 各 4 处引用 + 1 行注释），
`grep -n "^struct CloudDriveView" ` → 6 / 345，说明 macOS 版与 iOS/tvOS 版**都**已覆盖。

---

#### 需要 captain 做（Store 字段 / 本地化 key / project.yml）

**Store 字段**：无。本线完全没有读写 `App/Store.swift` 的独有成员（只用 `store.vault`，该成员上游已有）。

**本地化 key**：I-08 引入 **2 个新 key**（`Sources/TVCore/Resources/*.lproj/Localizable.strings` 由 captain 汇总，我没动）：

| key | 建议 en 文案 |
|---|---|
| `Sign out of %@?` | `Sign out of %@?` |
| `You'll need to sign in again, and the plugin's saved sign-in will be removed too.` | `You'll need to sign in again, and the plugin's saved sign-in will be removed too.` |

> 现状：这两条在四个 lproj 里都**不存在**（已 grep 确认）。`L10n.text` 的兜底是 `value: key`，
> 所以英文环境显示正确，中文/日文会退化成英文。其余本线文件用到的 key 覆盖率 **100%**
> （脚本核对 `App/CloudDriveView.swift` 34 个 key → 缺失 0；四语言各 1774~1788 key 已由 captain 补齐）。

**project.yml / TVBox.xcodeproj**：无改动需求。本线没有新增文件，也没有新增资源。

**一个提醒（不是请求）**：`Sources/TVCore/CloudSources.swift:36` 的文案是 `Update Mi3s to use its built-in sources.`，
四个 lproj 里对应的 key 也是 `Mi3s` 版（1 条/语言），与全仓品牌口径 `Yingxia`（44 条/语言）不一致。
这属于 captain 的品牌统一范畴，我没改（改文案键会牵动 lproj）。若统一为 Yingxia，本文件需同步改 1 行。

---

#### 验证证据（三条命令输出尾部）

```
$ swift build --package-path Packages/TVCore --target TVCore 2>&1 | tail -3
[3 / 14] TVCore_TVCore
[7 / 18]
Build complete! (0.65秒)
```

```
$ xcodegen generate --spec project.yml >/dev/null 2>&1
（无输出；工程由 project.yml 重新生成，未手改 pbxproj）
```

```
$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Debug \
    -derivedDataPath build/DD-line build 2>&1 | tail -3
note: Run script build phase 'Embed Dandanplay API configuration' will be run during every build ...
** BUILD SUCCEEDED **
```

**额外平台门禁（captain 授权的新坐标系，本线也跑了）**

```
$ xcodebuild ... -scheme TVBox-tvOS ... -destination 'generic/platform=tvOS' build CODE_SIGNING_ALLOWED=NO
** BUILD SUCCEEDED **
```
> 首次 tvOS 失败于 `AppleRuntime.m:3:10: error: 'jni.h' file not found` —— 是本 worktree 缺 `build/AppleRuntime/`
> （构建产物，不进 git）。已 `ln -sfn` 指向主树 `tvbox-silicon-fusion/build/AppleRuntime`（`build/` 在 `.gitignore:3`，不入库），
> 之后 tvOS 通过。**这条不是本线代码问题**。tvOS 通过与 `#if os(iOS)`/`#else` 分支共用同一份 iOS/tvOS 代码，
> 等价证明我改的 `#else` 版（含 I-08 的确认框）能编译。

```
$ xcodebuild ... -scheme TVBox-iOS ... -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
App/MobilePlayer.swift -> cannot find 'SubtitlePositionMemory' in scope
App/MobilePlayer.swift -> type 'SubtitleStyle' has no member 'standard'
App/MobilePlayer.swift -> value of type 'SubtitleStyle' has no member 'sanitized'
```
> iOS 仅剩 3 处错误，**全部在 `App/MobilePlayer.swift`**，即 captain 通报的 M6 字幕符号
> （`SubtitleStyle.standard` / `sanitized` / `SubtitlePositionMemory`），归 W5 裁决 / W6 文件，**不在本线边界内**。
> 本线 14 个文件**零 iOS 报错**。

```
$ swift test --package-path Packages/TVCore 2>&1 | tail -3
✘ Test run with 766 tests in 42 suites failed after 23.387 seconds with 2 issues.
  - TVCoreTests (Swift Testing)
```
失败项恰为已知基线两项，与纯上游基线一致，**不算本线**：
- `FeedbackAttachmentsTests.feedbackSizeLimitsMatchTheServer()` —— `Packages/TVCore/Services/error-reports/src/index.ts` 不存在（仓库布局问题）
- `JavaHostVersionTests.javaHostVersionChangesWithTheConverter()` —— `com/googlecode` 目录缺失（同上）

本线相关套件全绿：
```
$ swift test --package-path Packages/TVCore --filter DownloadTests   → 14 tests passed
$ swift test --package-path Packages/TVCore --filter MediaCache      → 4 tests passed
$ swift test --package-path Packages/TVCore --filter CloudFiles      → 26 tests in 2 suites passed
（含 CloudDriveBackupTests：WebDAV 上传/读回/401、备份文件名、固定文件夹名 全部通过）
```

---

#### 给验收员的接线自查清单（grep 可复现）

| 检查 | 命令 | 期望 |
|---|---|---|
| 下载按保险库过滤 | `rg -n "visibleDownloads" App/ Sources/` | `App/DownloadsView.swift:21` 与 `PrivacyVault.swift:481` 两处 |
| 下载来源可隐藏 | `rg -n "origin: origin\|origin: client.origin" App/` | `DownloadsView.swift:658`、`VideoDetailView.swift:243` |
| 四个网盘都能写备份 | `rg -n "\.upload\(" Sources/TVCore/CloudDriveBackup.swift` | quark:31 / uc:33 / pan115:35 / webdav:88 / alist:89 |
| 缓存索引强制落盘 | `rg -n "persist\(" Sources/TVCore/MediaCache.swift` | 6 处 `force: true` + 1 处裸 `persist()`（仅刷 `used`） |
| 登出确认两平台都在 | `grep -c signingOut App/CloudDriveView.swift` | 9 |
| 流式下载不重试 | `rg -n "sink != nil" Sources/TVCore/DownloadTransfer.swift` | 2 处（`.incomplete` 与网络中断） |
