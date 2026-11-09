# QA 深链参数表（端到端验证用）

> 这些参数是 App 的调试启动参数（`App/QALaunch.swift` 定义，`#if DEBUG` 生效），通过 launch
> arguments 传入，落到 `UserDefaults` 的 argument 域，**不持久化**、不污染真实数据。
> 源码 `App/QALaunch.swift` 是权威；本表只列端到端验证最常用的核心，其余散落在各 View 的
> `UserDefaults.standard.*(forKey: "qa…")`。

## 三种传参方式

```bash
# 1. 模拟器 —— simctl launch
xcrun simctl launch <UDID> wda.prdc.yingxia.dev -qaSection sites -qaIsolatedData 1

# 2. 真机 —— devicectl process launch（无线也行，只能启动+截图，不能点）
xcrun devicectl device process launch --device <UDID> wda.prdc.yingxia.dev -- -qaPage vault -qaIsolatedData 1

# 3. XCUITest —— launchArguments（能点、能断言，真机需 USB）
app.launchArguments = ["-qaSection", "sites", "-qaIsolatedData", "1"]
```

## -qaSection（分区）

小写 key（`QALaunch.sectionByKey` 处理），值对应 `AppSection`：

```
home  discover  live  music  search  sites  files  favorites  history  downloads  settings  messages  more
```

## -qaPage（直达某一屏，`QALaunch.page(for:)` 的 switch）

| 值 | 打开的页面 |
|---|---|
| `player` | 全屏播放器（播 `127.0.0.1:8765/clip.mp4`，需本地 QA 服务器） |
| `player-error` / `player-stall` | 播放失败 / 卡住的直播（QA 服务器喂数据） |
| `detail:<site>:<video>` | 视频详情页 / 选集播放页（配 `-qaVideoName` 等 fake 元数据，只需 site 存在） |
| `open-detail:<site>:<video>` | 同上，但经一个「Open video」按钮（`qa.open-detail`） |
| `site:<key>` | 某个源的视频列表（`SiteView`） |
| `channels:<N>` | 直播频道列表第 N 组 |
| `live:<douyu\|huya\|douyin\|bilibili>` | 直播平台页（配 `-qaQuery` 搜索） |
| `folder:<drive>:<folder>` | 云盘文件夹 |
| `cloud-accounts` / `cloud-login:<service>` | 云盘账号页 / 登录 |
| `privacy` / `vault` | 隐私设置 / 隐私保险箱 |
| `resource-order` / `segment-sources` / `speech-subtitles` | 资源排序 / 片头片尾源 / 语音字幕 |
| `playback` / `cache` | 播放设置 / 缓存设置 |
| `web-sign-in:<service>` / `plugin-sign-in:<service>` / `catpaw-sign-in` | 各登录 sheet |
| `bilibili-account` / `douyin-account` / `douyin-login` / `douyin-handoff` | 账号页 / 登录 / 投屏 |
| `runtime` / `logs` / `feedback` / `alist-add` / `danmaku-list` | 诊断页 |

## 常用的其他 -qa 参数

| 参数 | 作用 |
|---|---|
| `-qaSubscription <url>` | 指定订阅地址（否则走默认 `Store.defaultURL`） |
| `-qaIsolatedData 1` | 隔离数据：读写到 `com.tvbox.yingxia.qa.player` 独立 suite，不碰真实数据 |
| `-qaKeepAwake 1` | 保持屏幕常亮（截图期间防息屏） |
| `-qaPlay <site>:<video>[:<ep>]` | 直接播放某源某视频某集（打开全屏播放器） |
| `-qaPlayURL <url>` | 直接播任意媒体地址 |
| `-qaPlayLive [<platform>:]<room>` | 直接开直播房间 |
| `-qaDownload <site>:<video>[:<count>]` | 加入下载队列 |
| `-qaQuery <text>` | 搜索词（配合 `site:`/`live:`/discover） |
| `-qaVideoName` / `-qaVideoPoster` / `-qaVideoRemarks` | `detail:` 页的假标题 / 海报 / 备注 |
| `-qaStartAt <seconds>` | 播放起跳位置 |
| `-qaMute 1` / `-qaSpeed <f>` / `-qaSeek <s>` | 静音 / 倍速 / 定位 |
| `-qaOneSkinWide 1` | 强制「展开宽屏」形态（上半屏全出血 + 下半屏详情抽屉） |
| `-qaOneSkinSideways 1` | 强制「展开横屏」形态（左右双列）；与上一项成对回归两态是否区分 |
| `-qaSwitchEpisode <秒>` | 详情页自动播第 1 集、延时播第 2 集（回归换集后画面是否刷新） |
| `-qaEpisodesSheet 1` | 详情页直接弹出**选集抽屉**（截图用，免点击） |
| `-qaDownloadPicker 1` | 详情页直接弹出**下载抽屉**（同上） |

## 关键提醒

- 参数只在 **Debug 构建**生效（`#if DEBUG`）；`install-duo.sh` / `e2e-verify.sh` 出的都是 Debug 包。
- ⚠️ `-qaPage` **必须同时给 `-qaSection`**：`QALaunch.overrides(_:)` 里第一句是
  `guard section == self.section`，而 `self.section` 只从 `-qaSection` 来。只给 `-qaPage`
  时它等于和 nil 比，永远不成立 —— 表现为「参数没生效，停在首页」。
- 抽屉类页面用 `-qaSection home -qaPage detail:<site>:<video> -qaEpisodesSheet 1`，
  配 `Scripts/qa-fixture/server.py` 的 `qa2` 源（24 集 × 2 线路）才撑得开列表。
- `-qaSection` 的 key 是**小写**（`sectionByKey`），而 `yingxia://section/<name>` 深链用的是
  `AppSection.rawValue`（大写，如 `Settings`）——两者别混。
- `-qaPage detail:<site>:<video>` 的 `<site>` 必须是订阅里真实存在的 key；`<video>` 任意（详情用
  `-qaVideoName` 等 fake 数据，不真的拉详情）。
- 完整参数散见 `App/QALaunch.swift`、`App/RootView.swift`、`App/PlaybackView.swift` 等的 `"qa…"` 字面量。
- `-qaRotateCycle <秒>`（Debug / iOS）：进观看页后**进程内**每隔 N 秒真旋转一次
  （横 → 竖 → 横 …），用 `PlayerOrientation.rotate(to:)` 走系统 `requestGeometryUpdate`。
  回归「横竖屏来回切，界面 / 控件是否累积推移、是否要重启 App 才恢复」：连拍截图，
  量化双列竖直分界线的 x 坐标，同一方向的多轮应**完全一致**。
  `onAppear` 在转屏时会重复触发，钩子内有 `@MainActor static` 单实例闸，别删。
- `-qaLogGeometry 1`：`VideoDetailView` 的 `GEO probe=… derived=… sig=…` 走 `NSLog`，
  用来核对「量到的容器尺寸」与「实际用于布局的派生尺寸」是否解耦（后者不该跟着前者逐帧变）。
