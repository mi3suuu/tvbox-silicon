# git 钩子（入库版）

本目录是**版本库内**的 git 钩子目录，由 `core.hooksPath` 指向。

## 为什么入库

钩子原本只装在 `<common-dir>/hooks/`，即「只在某一个克隆/某台机器」：

| 路径 | 状态 | 后果 |
|---|---|---|
| `Scripts/audit-oneskin-keys.sh` | TRACKED | 随分支合并，各处都有 |
| `<common-dir>/hooks/pre-commit` | **NOT_TRACKED** | clone / worktree 后**不存在，且无任何告警** |

「缺脚本」是可见的缺（钩子在、会告警、只是那门没生效）；
「缺钩子」是不可见的无（什么都不发生）。
后者还无法被第三方评审——评审员看的是版本库，看不到某人机器上的钩子。

## 启用（每个新 clone 一次）

```bash
./Scripts/install-hooks.sh
```

`core.hooksPath` 是**每仓库**配置，不是每 worktree。
设置一次，本仓库所有现有与未来的 worktree 都生效。

## ⚠️ 顺序陷阱（已实测，git 2.54.0）

`core.hooksPath` 指向**不存在的目录**时，git **不回落** `<common-dir>/hooks`，
而是认为「无钩子」并**完全静默**：

| 状态 | 旧 common 钩子是否运行 |
|---|---|
| 未设 `core.hooksPath` | ✅ 运行 |
| `core.hooksPath` = 缺失目录 | ❌ **静默不运行**（现有门一并失效） |
| `core.hooksPath` = 存在目录 | 新钩子运行 |

因此 `install-hooks.sh` **先校验钩子存在且可执行，才允许设置**，并在设置后回读比对。
不要手工 `git config core.hooksPath` 跳过这一步。

## 本钩子跑哪两道门

1. **断言强度**（`~/.dsh/discipline/lint-agent-diff.sh`）——通用，防删断言/自比对/抬分母。
   该工具不存在时**出声说明本次未校验**，不再静默 `exit 0`。
2. **One 皮肤键名**（`Scripts/audit-oneskin-keys.sh`）——`oneSkin*` 字面量唯一性 + 键名落盘契约。
   该脚本随分支 `fix/tvos-platform-guards` 提交；未合并的树里没有它，此时若本次提交触及
   One 相关文件则**显式告警**（不阻断），否则静默——噪音式告警会让真告警进盲区。

跳过全部门：`AIGATE_SKIP=1 git commit ...`（会打印留痕）。
