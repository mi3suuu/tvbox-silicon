# git 钩子（入库版）

`Scripts/hooks/pre-commit` 是本仓库 pre-commit 闸门的**唯一真源**。
部署方式：由 `Scripts/install-hooks.sh` **复制到 `<common-dir>/hooks/pre-commit`**。

## 覆盖范围（事实，非承诺）

本仓库 **21 个 worktree 共享同一个 common-dir**（已实测）：

```
tvbox-silicon-fusion/.git        ← 全部 21 棵树共用
```

因此装一次 = 全部 21 棵树生效，**不依赖各棵树是否检出本目录**。
新建 clone / 新机器需各跑一次 `./Scripts/install-hooks.sh`。

## 启用

```bash
./Scripts/install-hooks.sh
```

验证：在任意 worktree 提交一次，输出应出现

```
== lint-agent-diff · base=HEAD ==
== ① oneSkin* 字面量唯一性 ==
```

## ⚠️ 为什么不用 `core.hooksPath`（本轮实际踩过，已撤销）

实测 git 2.54.0：

| 状态 | common hooks 是否运行 |
|---|---|
| 未设 `core.hooksPath` | ✅ 运行 |
| `core.hooksPath` = **缺失目录** | ❌ **静默不运行** |
| `core.hooksPath` = 存在目录 | 新钩子运行 |

`core.hooksPath` 是**每仓库**配置（21 棵树共享）。当它指向的目录尚未检出的树提交时，
git **不回落** `<common-dir>/hooks`，而是认为「无钩子」并**完全静默**——
那些树会同时失去新旧两道门且没有任何提示。

本轮曾把 `core.hooksPath = Scripts/hooks` 写入，导致 20 棵未合并的树闸门静默消失，
已撤销止血。**复制到 common hooks 不依赖任何路径存在性，该陷阱在结构上不存在。**

## 门闩（⓿ 段）

钩子自身第一段做**功能自检**：必须能在自己体内找到

- `lint-agent-diff.sh`（① 断言强度门）
- `audit-oneskin-keys.sh`（② One 键名门）

缺任一段 = 旧版或被人手工裁剪 → 打红并 `exit 1`。

**为什么是功能自检而不是 sha256 比对入库版**：各 worktree 停在不同 commit，
本树文件版本各异，而 common hooks 只可能装一个版本 ⇒ sha256 比对必然误拦某棵树
（实测：临时树基于旧提交建，被门闩拦下合法提交）。功能自检与版本号无关，跨树恒成立。

## 两道门各自缺失时的行为

| 情况 | 行为 |
|---|---|
| `~/.dsh/discipline/lint-agent-diff.sh` 不存在 | **出声**：本次提交未校验断言强度 |
| `Scripts/audit-oneskin-keys.sh` 不存在（分支未合并的树）+ 本次提交触及 One 文件 | **出声**：本树无键名闸门，列出涉及文件，不阻断 |
| 同上但未触及 One 文件 | 静默（噪音式告警会让真告警进盲区） |
| 钩子被降级/裁剪 | 门闩拦截，`exit 1` |

跳过全部门：`AIGATE_SKIP=1 git commit ...`（会打印留痕）。
