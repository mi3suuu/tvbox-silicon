# 铁律（每次改代码前必读，哈希锁定）

> 本文件由 `tools/qa/check-rules.sh` 校验哈希。哈希不匹配 ⇒ 说明规则被改过，必须重新审阅。

## 一、形态判据（来源：One 1.7.1 二进制实证，不可再推翻）

**One 用三个信号，各司其职。没有阈值、没有宽高比、没有滞回。**

```
1. __pageSize: State<CGSize>
   → 页面尺寸。横竖判定 = width > height 一次比较。

2. __division: State<CGRect?>
   → 折缝矩形（GeometryValueReader 读 FoldGap 回写）。
   → 有折缝 = 双栏，无折缝 = 单栏。

3. _wide: LargeCanvas
   → _horizontal / _vertical 两个 sizeClass。
   → 只管「大屏/小屏」档位，**不参与横竖判定**。
```

**证据（勿忘）**
- `One-1.7.1.interface.swift:1630` `VideoDetailPage._wide: LargeCanvas`
- `:3271` Body 里只有 `GeometryValueReader<FoldGap?>`，无 LargeCanvas 分支
- `LargeCanvas` 结构：只有两个 `Environment<UserInterfaceSizeClass?>`，**无像素字段**
- `swift-section dump --emit-type-layout` 671 条，同样的结论

**结论：展开横屏 951×669 vs 展开竖屏 669×951，区别就是 `w > h`。**

## 二、尺寸源唯一（铁律）

**只允许一个尺寸来源：`GeometryReader` 的 `geo.size`。**

⛔ 禁止：
- `fixedScreenSize()`（在 Fig 上返回 951×669 假值，非显示区）
- `keyWindow.bounds`（内屏竖持时可能仍报横值）
- `liveGeometry.box`（来自 geoDriver，与 geo 不同源，实测 594×432 vs 678×466）
- 任何「比例 × 容器」的换算（One 不做这个）

**理由**：B站皮肤（`App/BiliLandscapePage.swift:67`）用 `geo.size.width` 在同一台 Fig 上显示正常，
证明 `geo.size` 是真实容器尺寸。反馈环的真正成因是「量到值→写 @State→喂回布局」，
不是 GeometryReader 本身。

## 三、日志不可作证据（血泪）

**⚠️ `pictureColumn` 开头的 `_g` 探针曾经不传 `portraitTopInset`，
竖持时永远报 `at=(0,31)`，而真实 `geo` 是 `(0,58)`。这个假值误导了多轮判断。**

判据优先级：
1. **AX `ui.tree` 坐标** — 真实渲染值
2. **`fixedLayer` 日志** — UIView 真实尺寸（`view= / fixed= / layer=`）
3. **代码推导** — 纯数学
4. ~~自打日志~~ — 必须与上面三者交叉验证后才可用

**AX 坐标未缩放**（已用真机截图交叉验证：`继续播放 (16,515) 190×52` 逐位吻合）。
根容器尺寸（如 1331.4 = 951×1.4）只是「含溢出的外框」，不代表内容坐标。

## 四、模拟器转屏：必须用 `rotate`，不是 `orient`

⛔ **`hinge orient landscape-right` 只改 `orientation` 字段，`displays[].rotation` 不变，
截图仍是竖的，App 内部尺寸也不变 —— 用它验证横持永远是假结果。**

✓ **`hinge rotate left` / `rotate right` 才真的旋转屏幕。判据：截图尺寸**

```
$H -d $DUO rotate left
$H -d $DUO screenshot /tmp/s.png
python3 -c "from PIL import Image;print(Image.open('/tmp/s.png').size)"
# 2853x2007 → 951x669 横持 ✓
# 2007x2853 → 669x951 竖持
```

**这条踩过多次，别再犯。** 之前多轮「模拟器验证不了内屏横持」的结论是错的。

## 五、验证通道（唯一可用）

```bash
tools/qa/verify-shapes.sh          # 三形态一次跑完
tools/qa/measure_right_column.py   # 从截图量右栏段落
```

依赖 `-qaPage one-preview`：固定 mock 数据、按真实窗口尺寸渲染、不读订阅不联网。
这是 headless 模拟器下唯一稳定可复现的入口。

## 六、反馈环禁令

⛔ 绝不把「量到的视图自身尺寸」写回 `@State` 再喂回布局。
实测后果：`proxy=22153×13432`（51 倍放大）、3.7ms/帧、51 次翻转。

⛔ `barSlots` 绝不随形态变化（UITabBarController `__NSArrayM insertObject` 崩溃 ×3）。

## 七、真机基准（外屏竖持 466×678，已双重验证）

```
视频      x=16  y=43   w=350  h=197     ← 真机右留 100pt 是浪费，用户要求满宽
控制条    y=353~371                      ← 倍速 1x 在这里
继续播放  (16, 515) 190×52
标题      (16, 348) 317×54
标签行    y=589 / y=633，每条 44 高，步长 58
```

**用户要求（覆盖真机）**：视频满宽、下移到避开摄像头、长度到控制条上方。

## 八、不要问用户「怎么区分横竖屏」

**这个答案在 `Docs/duo/One-1.7.0-旋转与折叠适配审查.md` 和 `evidence-2026-11-11/One-1.7.1.interface.swift` 里，
已经查过至少三次。再问就是没读资料。**
