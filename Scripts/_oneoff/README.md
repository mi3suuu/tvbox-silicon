# 一次性改写脚本（历史，勿重复运行）

这些脚本是「用 Python 字符串替换批量改源码」的一次性工具，**都已经执行过**。

| 脚本 | 目标文件 | 状态 |
|---|---|---|
| `patch_pump.py` / `patch_pump2.py` / `patch_get.py` | `Sources/TVCore/DownloadTransfer.swift` | 已应用（旧串已不存在） |
| `patch_file_fn.py` | `App/SourceSpeedLab.swift` | 已应用（旧串已不存在） |
| `add-keys.py` / `add-keys2.py` / `add-keys-i18n.py` | `Sources/TVCore/Resources/*.lproj/Localizable.strings` | 已应用 |
| `check-keys2.py` / `check-new-keys.py` | 上表的校验器 | 只读校验，可作参考 |

**为什么留着**：作为「那批改动是怎么做出来的」的记录。它们不是工具，不要当成工具用。

**为什么不删**：删了无法追溯当初的批量改写口径。但**再跑一次不会生效**（旧串已被替换掉），
若有人改回旧串再跑，会静默产生预期外结果。

**正确做法**：要改这些地方，直接改源码 + 加测试，不要用这些脚本。
