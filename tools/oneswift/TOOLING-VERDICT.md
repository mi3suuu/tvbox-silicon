# 三件工具实测结论（2026-11-12）

## 一、craft-anything-cli

**构建**：`cargo build --release -p craft-anything-cli` → 5m08s，产物 30MB（本机原有 rust 1.98.1）

**能力清单**：`$CA commands` → 展示全部工具；按 toolset 统计
```
apple:   14     ← iOS/macOS 二进制
formats: 36
native:  55
```

**apple toolset 14 个工具**：
```
apple-objc-classes-list      apple-objc-protocols-list
apple-swift-types-list       apple-dispatch-show
apple-ui-action-trace        apple-macho-show
apple-signature-show         apple-plist-show
apple-slices-list            apple-swift-symbols-demangle
apple-nib-decode             apple-archive-decode
apple-assets-list            apple-dylibs-resolve
```

### 实测结果

| 工具 | 结果 | 判定 |
|---|---|---|
| `apple-swift-types-list --pattern FoldSplit` | **0 Swift symbols describing 0 types** | ❌ **不能替代 `swift-section`** |
| `apple-macho-show` | ✅ 2034 imports / 42 libraries / build_versions ios sdk 27.1 / 1755 行 | ✅ 可用 |

**`apple-swift-types-list` 失败原因**：它读符号表（`symbols_examined: 2035`），而 One 是 stripped 的，只剩 2035 个外部符号，没有 `$s3One*`。Swift 类型信息在 `__swift5_types` 段，需要 `swift-section` 那样的专门解析器。

⇒ **两者分工**：
- `craft-anything` 负责 **Mach-O 结构 / imports / plist / 签名 / nib / assets**
- `MachOSwiftSection` 负责 **Swift 类型与 Type Layout**（唯一能解 `__swift5` 段的）

### 净室 vs 深度

默认 **Clean room 拒绝读二进制内部**：
```
error: This looks inside the original (its code, files or page source), which Clean room never does.
fix: Turn on Deep mode: `settings_set deep_mode true`, or `--deep` on the CLI.
```
我们用 `--deep`（这是私下逆向自己的场景，符合它的用途说明）。

### rebuild 闭环（本项目暂无适用场景）

```
rebuild_start      启动：研究 → 构建 → 检查 → 就绪
rebuild_check      成果 vs 原件比对
project_preview    预览
core_evidence_*    证据台账
```
**它需要本机有已登录的编码 agent（Claude Code 优先）。** 我们的目标不是「造一个新项目」，而是「改现有 SwiftUI 代码」，所以 `rebuild` 闭环**不直接适用** —— 但 `rebuild_check` 的比对思路可以借鉴。

## 二、MachOSwiftSection / swift-section

**6 个子命令**：`dump` / `interface` / `diff` / `snapshot` / `evolution` / `objc`

### 实测：`dump --emit-type-layout` ✅ 成功

```bash
$B dump --emit-type-layout /tmp/one171/Payload/One.app/One > /tmp/one_typelayout.txt
# 5928 行 / 671 个 Type Layout 记录
```

**这是现有资料里缺失的关键能力**——之前只有 `interface`（声明），没有 `Type Layout`（字段偏移与 size）。

产出：`tools/oneswift/BASELINE-typelayout.md`

## 三、rea

**CLI 命令**（关键几类）：
```
decompile / decompile-all / function   伪代码
inspect / search                        概览与检索
instructions                           汇编
compare-*                               各域比对
```
**用途**：当 `swift-section` 只有声明、需要看**函数体实现**时用它。
已知限制：Ghidra 首次分析 3.5MB 二进制约 5-10 分钟；Hopper 对该二进制零符号；IDA 可用但只给元数据访问器。

## 四、三件工具的真实分工（结论）

| 需求 | 工具 | 证据 |
|---|---|---|
| Swift 类型结构 + 字段偏移 | **`swift-section dump --emit-type-layout`** | 已产出 671 条 |
| Swift 类型声明/接口 | `swift-section interface` | 已有 5293 行 |
| Mach-O 结构 / imports / 版本 | `craft-anything apple-macho-show` | 已产出 1755 行 |
| plist / 签名 / nib / assets | `craft-anything apple-*` | 工具存在，按需用 |
| 函数体实现（伪代码） | `rea decompile` | 慢但唯一途径 |
| AX 运行期坐标 | vphoned `ui.tree` | 已证明是唯一可信坐标源 |

## 五、独立交叉验证的成果

`craft-anything apple-macho-show` 列出 One 的 **2034 个 import**，其中：

```
grep -icE "hinge|reservedRegion|ArrangementView"  →  0
```

**与既有资料 `strings One | grep -i hinge → 空` 独立互证。**

⇒ **「One 完全不用系统折叠 API，自建 FoldGap{minX,maxX}」这一结论，现在有两个独立来源支撑。**
