# 映匣 × tvbox-silicon 融合重构 · 总入口

> 本目录是这次融合重构的**唯一权威文档集**。任何 AI / 人接手，先读这份 README。
> 最后更新：2026-11-06

---

## 一分钟结论

| 项 | 状态 |
|---|---|
| 本地 git 仓库 | ✅ `tvsilicon/tvbox-silicon-fusion`（上游 1.8.11 为真身） |
| 二开新增文件迁入 | ✅ 146 / 146 |
| 二开独占修改文件 | ✅ 63 / 63 |
| 重叠文件（39）决策 | ✅ 全部落定（L1 跟随 / L2 我方为准 / L3 手工合） |
| **macOS / tvOS / iOS 编译** | ✅ **三平台全绿** |
| TVCore 单测 | 766 项，2 项失败（纯上游基线同样失败，非融合引入） |
| 侵入上游文件 | **24 处**，全部带 `// [mi3s]` 标记 + 登记 |
| 未纳入清单 | 14 条丢弃 + 5 条未接入，全部有重开条件 |
| Duo 外屏横持白屏 | ✅ 根因定位并修复（成对像素证据） |

---

## 文档导航

| 文件 | 什么时候看 |
|---|---|
| **`00-融合总纲.md`** | 想改代码前 —— 命名约定、四类改动裁决口径、三平台编译命令 |
| **`01-功能清单与归属.md`** | 想知道「某条二开能力现在在哪」—— 90 条台账，逐条映射文件 |
| **`02-未纳入清单.md`** | 想知道「什么没接、为什么没接」—— 每条带重开条件 |
| **`03-侵入点登记表.md`** | 上游更新时要复核什么 —— 17 个侵入点，含上游变更时的处理方式 |
| **`04-验收清单.md`** | 验收怎么做 —— A 组画风 UI（20 项）/ B 组逻辑接线（17 项） |
| **`05-子代理上下文包.md`** | 要派子代理时 —— 标准上下文、已否证路径、排障速查、交付格式 |
| **`06-线边界与工作树.md`** | 分线作业时 —— 每条线的文件清单、captain 独占文件、验收门 |
| **`07-交接账本.md`** | 换上下文窗口时 —— 最新状态、已修阻塞、下一步 |
| `lines/*.md` | 六条线各自的交付详情（含每个接线点的文件:行号） |
| `验收-V1-画风UI.md` / `验收-V2-接线.md` | 两位验收员的报告 |
| `delta-matrix.tsv` | 机器生成的差分矩阵（39 both / 227 ours-only / 58 upstream-only） |

外部文档：
- `../Docs/duo/Duo适配报告.md` —— Duo 适配（白屏根因 + 社区 skill 对照 + 三态验证矩阵）
- `../../映匣/映匣功能清单.md` —— 全项目二开能力台账（App + Rex + LibreTV + 网页版）
- `../../映匣/项目铁律.md` —— 六条铁律

---

## 三条铁律（违反即返工）

1. **上游文件是别人的文件。** 新增能力→新文件；给上游类型加方法→`extension` 写 `Xxx+Mi3s.swift`；必须加存储属性→侵入主类，写 `// [mi3s] 二开：<原因>`，登记进 03。
2. **`TVBox.xcodeproj/project.pbxproj` 绝不手改。** 只改 `project.yml` + `xcodegen generate`。
3. **上游已有等价实现的，丢我方版**，写进 02（含重开条件）。

---

## 快速验证（唯一口径）

```bash
cd /Users/mi3s/WorkBuddy/2026-10-21-13-54-46/tvsilicon/tvbox-silicon-fusion

# TVCore
swift build --package-path Packages/TVCore --target TVCore
swift test  --package-path Packages/TVCore 2>&1 | grep -E "✘ Test |Test run with"

# 三平台
xcodegen generate --spec project.yml
xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Debug -derivedDataPath build/DD-mac build
xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS  -configuration Debug -derivedDataPath build/DD-tv  -destination 'generic/platform=tvOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS   -configuration Debug -derivedDataPath build/DD-ios -destination 'generic/platform=iOS'  build CODE_SIGNING_ALLOWED=NO
```

**基线允许失败项**：`JavaHostVersionTests`、`FeedbackAttachmentsTests`（在纯上游 `fusion/base` 上同样失败，属仓库布局问题）。

**环境依赖**：`build/{FFmpeg,AppleRuntime,JavaHost/*}` 是指向旧仓库 `/tvsilicon/tvbox-silicon/build/` 的符号链接。旧仓库删了，iOS/tvOS 就编不过（报 `'jni.h' file not found`，与源码无关）。需要时按 `Scripts/build-universal-hosts.sh` 重建。

---

## 上游更新时怎么办

```bash
git fetch upstream
git log --oneline upstream/main -20          # 看上上游改了什么
git diff fusion/main...upstream/main --stat  # 看冲突面

# 冲突面只有两类：
#  ① 01 里标「已接」的独立新文件 —— 上游不会碰，零冲突
#  ② 03 里登记的 17 个侵入点 —— 按每条登记的「上游变更时如何复核」处理
```

**不要做的事**：不要在 `fusion/main` 上 `git merge upstream/main` 期望自动解决。39 个重叠文件里有 5 个巨型文件（Store / PlayerView / MobilePlayer / SitesView / SettingsView），正面 merge 会失控 —— 这是本项目已经实测否证过的路径。

---

## 一条命令核对全部（`Scripts/verify-fusion.sh`）

目标要求的五项，一次跑完，每项给可复跑的数值：

```bash
Scripts/verify-fusion.sh
```

实测输出（2026-11-06 第 8 轮）：

```
① 二开文件融入     代码类新增 111 个 / 按 D-03 主动丢弃 8 个 / 真缺失 0 ✓
② 侵入登记（双向）  24 条 / 20 文件 / 43 处标记 / 缺标记 0 / 未登记 0 ✓
③ drop-list        34 条
④ 验收报告          2 份
⑤ manifest          90 条 / 编号 1-90 / 缺号 无 ✓
⑥ 站点脚本恒等式    index 引用 45 个缺失 0 / 磁盘孤儿 3 个全为共享库 ✓
```

### 判据里两个容易写错的地方

**① 不能直接算 `ours - base`**

那会把我方**主动删掉**的东西也算成「缺失」。第 7 轮清掉的 8 个 D-03 死脚本，
第 8 轮直接被这条判据报成「缺失 8」。正确写法是先排除 drop-list 里明确丢弃的。

**② 侵入登记必须双向**

`登记 → 代码`（每条都有 `// [mi3s]`）**和** `代码 → 登记`（每个标记都有条目），
两边都要 0。只查单向会漏 —— 第 6 轮就是这样漏了 7 条。
