### 线名：W1-vault（隐私保险库 + 备份恢复 + 多环境隔离）

**状态**：完成

**起点**：`357da7b`（已按 captain 要求 rebase 到 `fusion/main`，含 `1cb0c32`）

**认领文件（06 第「W1-vault」节全量）**：12 个源文件 + 5 个测试文件，全部到位、全部有真实接线点。

---

#### 已接入（文件 → 能力 → 真实接线点）

| 文件 | 能力 | 接入位置（调用点） |
|---|---|---|
| `Sources/TVCore/PrivacyVault.swift`（508 行） | 保险库核心：PBKDF2 密码、隐藏源/订阅、超时解锁、冷却 | `App/Store.swift:81` `var vault = PrivacyVault()`；`Store.swift:145-160` 截图/录屏回锁；`Store.swift:169/230/235/248` 四个可见性包装 |
| `App/PrivacyVaultView.swift`（498 行） | 保险库页面：设密码 / 解锁 / 逐源逐订阅开关 / 搜索 | `SettingsForm.swift:510`（macOS/tvOS Advanced 区）、`SettingsPrivacy.swift:15`（iOS 隐私页）、`SettingsTV.swift:115`（tvOS 链接） |
| `App/SettingsPrivacy.swift`（39 行） | iOS 隐私页：保险库入口 + 三个开关 | `SettingsForm.swift:512` `PrivacySettingsView()`（`#if os(iOS)`） |
| `App/PrivacyShade.swift`（87 行） | App Switcher 缩略图遮罩 | **本次补齐**：`App/TVBoxApp.swift:43` `.privacyShade(enabled: coversAppSwitcher)` |
| `App/Store+vault扩展.swift`（31 行，新增） | 保险库 App 生命周期 leg：后台回锁 | **本次新建**：`TVBoxApp.swift:100` `store.relockVaultOnBackground()` |
| `Sources/TVCore/FullBackup.swift`（299 行） | 全量备份模型：分区、白名单 key、schema 版本 | `Store+FullBackup.swift:21/71` 导出/导入；`SettingsForm.swift:225-229/652-672` 文件导入导出 |
| `Sources/TVCore/KeychainBackup.swift`（175 行） | Keychain 分片自动备份，重装可恢复 | `Store.swift:134` `persistKeychainBackup` 写；`Store.swift:579` 空库自动读回 |
| `Sources/TVCore/CloudDriveBackup.swift`（91 行） | 云盘备份通道（`Mi3sBackup` 目录、时间戳命名） | `Store+FullBackup.swift:192/200`；`CloudBackupView.swift:87/188` |
| `App/Store+FullBackup.swift`（208 行） | 备份编排：accounts/history/favorites/vault/preferences 五片 | `SettingsForm.swift:671` `store.exportFullBackup(categories:)`；`813` `importFullBackup`；`CloudBackupView.swift:87/188` |
| `App/CloudBackupView.swift`（195 行） | 云盘备份/恢复选盘选文件 | `SettingsForm.swift:660` `.sheet(item: $cloudBackupMode) { CloudBackupView }` |
| `Sources/TVCore/Environments.swift`（148 行） | 多环境：分区、活动环境、上报/外链互斥 | `Store.swift:116-117/175-201/484-498` 全链路；`EnvironmentsView.swift` 全部操作 |
| `App/EnvironmentsView.swift`（109 行） | 环境增删改名/切活动/上报开关 | `SettingsForm.swift:417` `FormLink(...) { EnvironmentsView() }` |
| `App/Store+Subscriptions.swift`（32 行） | 环境内订阅导出 + 文件导入 | `SettingsForm.swift:843/962` `store.importSubscriptionFile(file)`；`exportConfig` 供 `SettingsForm` 导出 |
| `App/MoreView.swift`（改 3 行） | 角标计数走可见性过滤 | **本次补齐**：`MoreView.swift:186-188` |

**逐条证据（grep 命中）**

```
PrivacyVaultView  →  SettingsForm.swift:510 / SettingsPrivacy.swift:15 / SettingsTV.swift:115
PrivacyShade      →  TVBoxApp.swift:43（修复前：0 处，只有定义）
EnvironmentsView  →  SettingsForm.swift:417
CloudBackupSheet  →  SettingsForm.swift:660
relockVaultOnBg   →  TVBoxApp.swift:100 → Store+vault扩展.swift:25
vault.visibleX    →  DownloadsView:21 / HomeView:112,125,338 / WatchNowPhone:90 / LiveView:418 / MoreView:186-188
```

---

#### 本次修的三处断线（修前有定义、修后才有调用）

**断线 1：隐私遮罩从未生效（最严重）**

- 现状：`App/PrivacyShade.swift` 定义完整，但融合后的 `App/TVBoxApp.swift` 里 **0 处调用**。
- 对照 `import/ours`：`App/TVBoxApp.swift:39` 原本有 `.privacyShade(enabled: coversAppSwitcher)`。
- 后果：iOS 后台快照会拍到正在播的影片画面、海报墙、或藏起来的源列表 —— 保险库的「隐藏」在缩略图面前是失效的。
- 修法：`TVBoxApp.swift:15` 补 `@AppStorage(PrivacyShade.key) private var coversAppSwitcher`，`TVBoxApp.swift:43` 补 modifier。
- 为什么挂根视图：系统在进入后台的瞬间截图，晚挂的 view 进不了快照（`PrivacyShade.swift:8-14` 已有此说明）。

**断线 2：保险库后台不回锁**

- 现状：融合后 `TVBoxApp.swift` 里 **没有任何 `vault` 引用**。
- 对照 `import/ours`：`App/TVBoxApp.swift:118` 有 `if store.vault.hasPasscode { store.vault.lock(); store.saveVault() }`。
- 后果：`unlockDuration` 默认 300 秒，把手机递出去时被隐藏的源/订阅一直可见。
- 修法：不写进 `Store.swift`（captain 独占），改在 **新建** `App/Store+vault扩展.swift` 里写 `relockVaultOnBackground()`，`TVBoxApp.swift:100` 调用。
- 为什么用 extension：需要的是方法而非存储属性，Swift 允许；符合总纲 §6 的 B 类。

**断线 3：首页角标把隐藏内容数出来了**

- 现状：`MoreView.swift:182-184` 用 `playbackHistory.entries.count` / `favorites.items.count` / `DownloadLibrary.shared.items.count` —— 三个都绕过保险库。
- 对照 `import/ours`：三个都用 `store.visibleHistory` / `store.visibleFavorites` / `store.vault.visibleDownloads(...)`。
- 后果：列表里 5 条、角标写 7 条，等于把「这里还藏着东西」写在首页上。
- 修法：`MoreView.swift:186-188` 换回可见性版本。

---

#### 未接入（已同步追加进 `02-未纳入清单.md` 的 W1 段）

| 能力 | 原因 | 重开条件 |
|---|---|---|
| `App/DiscoveryView.swift` 全局搜索「按隐私过滤源」 | **该文件属 W4-playback 边界**（`06` 第 108 行），我不越界。我方旧版在 `model.search` 的过滤闭包里追加了 `!store.vault.permits(site:fallback:)`，融合版只剩 `hiddenSources.contains`。**注意不完全等价**：`hiddenSources` 是「用户手藏」，`vault` 是「密码保护的藏」，无密码时两者一致，设了密码后搜索结果仍会漏出被保险库藏的源。 | W4 在 `DiscoveryView.swift:622` 的过滤闭包补 `\|\| !store.vault.permits(site: site, fallback: config.origin)` |
| `Sources/TVCore/Environments` 无独立单测 | 我方旧版也没有 `EnvironmentsTests.swift`（`git ls-tree import/ours` 确认），不是融合丢失。当前 148 行只有间接覆盖（`PlaybackHistoryTests` / `SubscriptionTests` 走环境过滤）。 | 环境隔离作为护城河能力，建议独立补测：`add/remove/activate/shows/stamp/setSyncsExternally` 六条 + 默认环境不可删 |
| iOS 文件选择器的备份入口 | `SettingsForm.swift:301` 的备份四个按钮整体在 `#if os(iOS)` 内 —— **与我方旧版一致**（`import/ours:App/SettingsForm.swift` 同一位置同一 gate），不是融合回归。macOS/tvOS 走的是 `#else` 分支的 `subscriptionActions`，不含备份。 | 需要在 Mac/Apple TV 上手动备份时，把 4 个按钮提出 `#if`，并给 `subscriptionActions` 补平台分支 |

---

#### 侵入上游（已同步追加进 `03-侵入点登记表.md`）

| # | 文件 | 位置锚点 | 二开内容 | 侵入原因 | 上游变更时如何复核 |
|---|---|---|---|---|---|
| I-08 | `App/TVBoxApp.swift` | `@State private var announcements` 之后 | `@AppStorage(PrivacyShade.key) private var coversAppSwitcher = true`（带 `// [mi3s] 二开` 标记） | Swift 的 extension 不能给 `App` 结构体加存储属性，`@AppStorage` 必须落在结构体上 | 上游若增删 App 级 `@State`/`@AppStorage`，保留我方这一行；key 常量在 `PrivacyShade.swift:86` |
| I-09 | `App/TVBoxApp.swift` | `RootView()...` 之后、`.tint(Brand.accent)` 之前 | `.privacyShade(enabled: coversAppSwitcher)` | 遮罩必须挂在根视图且常驻视图树 | 上游改 `WindowGroup` 根视图链时，把这一行重新插在根视图正后方 |
| I-10 | `App/TVBoxApp.swift` | `scenePhase` 的 `if phase == .background` 块内 | `store.relockVaultOnBackground()` | 后台回锁需 App 生命周期钩子，无其他挂点 | 上游改该 `onChange` 时，保留这一行（放 `.flushPending()` 之后） |
| I-11 | `App/MoreView.swift` | `count(_:)` 的 `switch` | `.history/.favorites/.downloads` 三个 case 改用 `visibleHistory` / `visibleFavorites` / `vault.visibleDownloads` | 三个 case 是上游原行的直接替换（D 类），无法用 extension 绕过 | 上游改角标计数时，按「与列表可见性一致」原则合并 |

> I-08/I-09/I-10 三处均带 `// [mi3s] 二开：` 单行标记。

---

#### 需要 captain 做

**Store 字段**：无需新增。本次改动全部落在 extension（`Store+vault扩展.swift`）与 App 结构体本地 `@AppStorage`，`Store.swift` 一行未动。

**本地化 key**：以下 key 在 `PrivacyShade.swift` / `SettingsPrivacy.swift` / `PrivacyVaultView.swift` 中被 `L10n.text(...)` 使用，四语言 `.lproj` 里**当前均缺失**（`grep -c` 全部 0）。中英已由 key 本身或既有条目覆盖，需要 captain 补：

| key | 出现位置 | 建议 en | 建议 zh-Hans |
|---|---|---|---|
| `Locked` | `PrivacyShade.swift:48` | Locked | 已锁定 |
| `Hide Content in the App Switcher` | `SettingsPrivacy.swift:19` | Hide Content in the App Switcher | 在应用切换器中隐藏内容 |
| `Privacy` | `SettingsPrivacy.swift:12` | Privacy | 隐私 |
| `Set a Passcode` | `PrivacyVaultView.swift:188` | Set a Passcode | 设置密码 |
| `Needed before anything can be hidden.` | `PrivacyVaultView.swift:189` | Needed before anything can be hidden. | 先设密码才能隐藏任何内容 |
| `Environments` | `SettingsForm.swift:417` / `EnvironmentsView.swift` | Environments | 观看环境 |
| `Back Up to Cloud Drive` | `CloudBackupView.swift:65` | Back Up to Cloud Drive | 备份到云盘 |
| `Restore from Cloud Drive` | `CloudBackupView.swift:65` | Restore from Cloud Drive | 从云盘恢复 |
| `No Cloud Drive` | `CloudBackupView.swift:30` | No Cloud Drive | 未登录云盘 |
| `Into a signed-in Quark, UC, 115, AList or WebDAV` | `SettingsForm.swift:325` | Into a signed-in Quark, UC, 115, AList or WebDAV | 存入已登录的夸克 / UC / 115 / AList / WebDAV |

> 说明：这些 key 在 `import/ours` 时代同样未被翻译（不是我引入的漏配），但 `PrivacyShade` 的三条现在是新接线、会真正显示，优先级从上到下递减。

**project.yml**：无需改动。`App` 目录是整目录 glob（`project.yml:39`），新建的 `App/Store+vault扩展.swift` 已自动纳入（`project.pbxproj` 命中 8 处）。

---

#### 验证证据

```
$ swift build --package-path Packages/TVCore --target TVCore 2>&1 | tail -3
[6/7] TVCore_TVCore
Build complete! (0.54秒)

$ xcodegen generate --spec project.yml >/dev/null 2>&1   # Created project at .../TVBox.xcodeproj

$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Debug \
    -derivedDataPath build/DD-line build 2>&1 | tail -3
** BUILD SUCCEEDED **

$ xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS -configuration Debug \
    -derivedDataPath build/DD-tvos -destination 'generic/platform=tvOS' build \
    CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
** BUILD SUCCEEDED **

$ swift test --package-path Packages/TVCore \
    --filter "PrivacyVault|FullBackup|KeychainBackup|CloudDriveBackup" 2>&1 | tail -3
✔ Suite "云盘备份通道" passed after 0.015 seconds.
✔ Test run with 61 tests in 3 suites passed after 0.015 seconds.
```

**tvOS 备注**：首次失败在 `Runtime/AppleRuntime/Native/AppleRuntime.m:3:10: error: 'jni.h' file not found`，原因是 `build/` 被 `.gitignore` 排除，worktree 里没有预构建的 `build/AppleRuntime/`。从主工作树 `rsync` 该目录（只读来源，未改任何源文件）后 tvOS 通过。这不是代码问题。

**iOS**：按 captain 通报，iOS 只差 M6 字幕符号（`SubtitleStyle.standard`/`sanitized`/`SubtitlePositionMemory`），W5 在裁决，属他线。W1 的 12 个文件全部有 `#if os(...)` 判断：`SettingsPrivacy.swift` 整体 `#if !os(tvOS)`、`PrivacyShade.swift` 有 `#if os(iOS)/macOS/else`、`CloudBackupView.swift:60/66` 有 `#if os(iOS)`、`EnvironmentsView`/`PrivacyVaultView` 用 `#if !os(tvOS)` 包裹 tvOS 不可用控件。

---

#### 判负口径自查

- **未改 captain 独占文件**：`App/Store.swift` 零改动（`git diff` 确认）、`Localizable.strings` 零改动、`project.yml`/`project.pbxproj` 零改动（pbxproj 由 xcodegen 生成）、`Docs/fusion/00-06` 零改动。
- **未越界**：没碰 W2/W3/W4/W5/W6 任何文件。`DiscoveryView.swift` 的功能缺口**只登记不修改**，因为它在 `06` 的 W4 清单里。
- **两条接法取舍**：后台回锁有两条路 —— (A) 写进 `App/Store.swift` 的 `init`/`deinit` 观察 scenePhase；(B) extension 方法 + `TVBoxApp` 调用。选 B，因为 `Store.swift` 是 captain 独占，且 scenePhase 本来就在 App 层，B 不留跨层耦合。不选 A 的理由是它会破坏「Store 主类不承载二开逻辑」这条铁律。
