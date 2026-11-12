# 播放页基准表（14 张，按形态×状态）

## 生成方法

```bash
# 素材：/Users/mi3s/Desktop/*.png（16 张真机 One 截图，用户已按语义重命名）
# 工具：tools/onemeasure/classify.py（幂等+准确已验证：最大误差 0.17pt）
python3 - <<'PY'
import classify
classify.analyze(path)   # rotation_hint=None 走内容推断（Fig 采集按物理屏存储）
PY
```

## 产出

| 文件 | 源截图 | 画布 | blocks | 暗缝 |
|---|---|---|---|---|
| `posture-cover-portrait__idle.json` | 外屏未播放 | 466×678 | 35 | absent |
| `posture-cover-portrait__playing.json` | 外屏暂停播放 | 466×678 | 35 | absent |
| `posture-cover-portrait__episodes.json` | 外屏选集 | 466×678 | 9 | absent |
| `posture-inner-landscape__idle.json` | 展开横屏双栏 未播放 | 951×669 | 16 | **detected** |
| `posture-inner-landscape__playing.json` | 展开横屏双栏 播放暂停中 | 951×669 | 27 | detected-partial |
| `posture-inner-landscape__episodes.json` | 展开横屏双栏 播放暂停中选集 | 951×669 | 4 | covered-by-overlay |
| `posture-inner-landscape__lines.json` | 展开横屏双栏 暂停选线路 | 951×669 | 15 | covered-by-overlay |
| `posture-inner-landscape__triggers.json` | 展开横屏双栏 暂停选触发按钮 | 951×669 | 8 | detected-partial |
| `posture-inner-portrait__idle.json` | 展开竖屏 未播放 | 669×951 | 17 | absent |
| `posture-inner-portrait__playing.json` | 展开竖屏 暂停播放 | 669×951 | 49 | absent |
| `posture-inner-portrait__episodes.json` | 展开竖屏 暂停播放选集 | 669×951 | 11 | absent |
| `posture-inner-portrait__lines.json` | 展开竖屏 选线路 | 669×951 | 11 | absent |
| `posture-device-portrait__playing.json` | 竖屏暂停播放 | 669×951 | 34 | absent |
| `posture-device-portrait__lines.json` | 竖屏选线路 | 669×951 | 18 | absent |

## 关键验证：工具判定与文件名语义 100% 吻合

```
展开横屏双栏 5 张 → rot=90, logical=951×669, dual=True
展开竖屏     4 张 → rot=0,  logical=669×951, dual=False
外屏         4 张 → rot=0,  logical=466×678, dual=False
竖屏(合盖)   3 张 → rot=0,  logical=669×951, dual=False
```

**`dual_column=True` 只在「展开横屏双栏」出现，与 One 的真实双栏语义一致。**

## ★ 工具局限（必须知道，否则会误用）

**像素量测无法还原「语义段」。**

实测：内屏横持·未播放测出 16 个像素块，但 AX 实测右栏只有 8 个语义段：
```
AX 段        量测对应
标题         无直接对应（被并入 card-or-video 大块）
副标题       无
元信息       无
统计         无
继续播放     无
标签行1      无
标签行2      无
说明         无
```

**原因**：像素量测按墨迹连通性切块，一行文字会被切成多块（"2026"、"11-03"、"作者"各一块），
而语义上是一段。

**正确用法分工**：
- **语义结构（有几段、什么顺序）** → 对齐 **AX 树**（`ui.tree`）
- **坐标精确值（x/y/w/h 到 1pt）** → 用**像素量测**校验
- 两者互相印证，不可互相替代
