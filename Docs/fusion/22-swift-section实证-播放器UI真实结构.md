# swift-section 实证：哔哩哔哩播放器 UI 的真实结构

> 工具：`MachOSwiftSection`（`swift-section` CLI），对 `bili-universal`（621MB，arm64）导出。
> 产物：`/tmp/bili_types.txt`（506,253 行 Swift 类型，含字段偏移）、
> `/tmp/bili_objc.txt`（1,575,715 行 ObjC 声明）。
>
> **为什么必须用这个**：`strings` 只能捞到类名，捞不到**字段结构与方法签名**。
> 只有 `swift-section objc dump` 能给出「这个 Widget 里到底有几个子容器、
> 每个 Cell 有几个按钮数组、有没有按宽度算行数的方法」。

## 前置修复（必须，否则直接崩）

该 IPA 被 Crack 处理过，`LC_DYLD_CHAINED_FIXUPS` 的 `segment_offset`
已不落在文件范围内，MachOKit 用 `try!` 硬崩：

```
MachOKit/MachOFile+DyldChainedFixups.swift:176:
  Fatal error: 'try!' expression unexpectedly raised an error: offset out of bounds
```

修法（`.build/checkouts/MachOKit/.../MachOFile+DyldChainedFixups.swift`）：
```swift
// 原：let pagesFileSlice = try! machO.fileHandle.fileSlice(...)
// 改：
guard let pagesFileSlice = try? machO.fileHandle.fileSlice(
    offset: machO.headerStartOffset + numericCast(startsInSegment.segment_offset),
    length: pages.count * numericCast(startsInSegment.page_size)
) else { return [] }
```
（`checkouts` 是只读的，先 `chmod u+w`。）

## 一、全屏底栏 = 三个子容器（不是我写的「三行 VStack」）

```objc
@interface BBPlayerFullScreenBottomWidget : BBPlayerBeyondBoundsWidget
    <BBPlayerControlBarOcclusionAvoiding, BBPlayerControlWidgetProtocol> {
    BBPlayerBeyondBoundsFlexContainerWidget *_topControlWidget;   // ← 顶部控制行
    BBPlayerFlexContainerWidget *_leftControlWidget;              // ← 左控制组
    BBPlayerFlexContainerWidget *_rightControlWidget;             // ← 右控制组
    struct UIEdgeInsets _occlusionAvoidInsets;                    // ← 遮挡避让
    BBPlayerServiceProxy<BBPlayerWidgetContainerService> *_containerProxy;
}
- (void)applyOcclusionAvoidInsets:(struct UIEdgeInsets)insets;
```

**结论：底栏 = `topControlWidget` + `leftControlWidget` + `rightControlWidget` 三块。**
我之前实现成「时间行 / 播放行 / 弹幕行」的三行 VStack，结构不对。

## 二、全屏顶栏 = 左右两组

```objc
@interface BBPlayerFullScreenTopWidget : BBPlayerWidget <BBPlayerControlWidgetProtocol> {
    BBPlayerFlexContainerWidget *_leftControlWidget;    // ← 左组（返回 + 标题）
    BBPlayerFlexContainerWidget *_rightControlWidget;   // ← 右组（点赞/分享/更多）
}
```

## 三、设置面板 = 5 个 Cell + 16 个显隐开关

```objc
@interface BBPlayerPlaySettingWidget : BBPlayerOperationWidget {
    BBPlayerOperationListCell            *_operationListCell;   // 操作四键（原图/稍后/画中画/投屏）
    BBPlayerPlaySettingPlaybackRateCell  *_playbackRateCell;    // 倍速
    BBPlayerPlaySettingPlaybackModeCell  *_playbackModeCell;    // 播放模式
    BBPlayerPlaySettingScaleCell         *_scaleCell;           // 画面比例
    BBPlayerPlaySettingConfigCell        *_configCell;          // 配置入口

    // 16 个显隐开关 —— 决定哪些项出现
    BOOL _showBackgroundMusicItem, _showShakeItem, _showMirrorItem, _showCastItem;
    BOOL _showSubtitleItem, _showFeedbackItem, _showMiniScreen, _showCubicPanorama;
    BOOL _showColorFilter, _showPlaybackRateItem, _showTimerItem, _showPlaybackModeItem;
    BOOL _showScaleItem, _showDmConfigItem, _showOnlineItem;
}
```

### 每个 Cell 的内部结构（都是 `BBPlayerOperationCell` 子类）
```objc
// PlaybackRateCell（倍速）
unsigned long long _curBtnNumOfLine;      // ★ 当前每行按钮数
UILabel *_titleLbl;  NSArray *_btnArray;  NSArray *_modelArray;  UIButton *_lastSelectedBtn;
- (unsigned long long)calculateBtnNumOfLineWithWidth:(double)width;  // ★★ 按宽度算每行几个
- (double)defaultHeight;                                            // ★ 默认高度
- (void)playRateBtnClicked:(id)sender;
- (void)updatePlayBackRate:(float)rate;

// PlaybackModeCell（模式）
BOOL _single;  long long _playbackMode;
- (void)updatePlaybackMode:(long long)mode single:(BOOL)single;

// ScaleCell（画面比例）
long long _videoContentMode;  BOOL _support16To9and4To3;
- (void)updateVideoContentMode:(long long)mode support16To9and4To3:(BOOL)flag;

// ConfigCell（配置入口）
UILabel *_titleLabel;  UIButton *_configButton;
- (BOOL)supportEdit;   // ← 对应 optionsedit
- (double)height;
```

### ★ 最重要的发现
```
- (unsigned long long)calculateBtnNumOfLineWithWidth:(double)width;
```
**每行按钮数是按可用宽度动态算出来的**，不是固定列数。
这解释了原图 `/tmp/fs.png` 为什么横向铺开成多组
（`0.5 0.75 1.0 1.25 1.5 2.0` 一行 + `Disabled 15:00 30:00 60:00 Custom` 一行 + 右半区开关组）。

**我此前按「三列 GridItem」或「9 行单列」实现都是错的。**

## 四、三屏族（复核）
```objc
BBPlayerPortraitScreen{Top,Bottom}Widget        ← 竖屏 2 区
BBPlayerHalfScreen{Top,Bottom,Left,Right}Widget ← 半屏 4 区
BBPlayerFullScreen{Top,Bottom,Left,Right}Widget ← 全屏 4 区
```

## 五、工具栏几何是约束驱动，不是常量
```
$__lazy_storage_$_barHeightConstraint
$__lazy_storage_$_bottomToolBarHeightConstraint
$__lazy_storage_$_actionBarHeightConstraint
Td,N,R,VbarHeight       ← readonly double
Td,N,R,VitemSpacing     ← readonly double
TB,N,V_actionBarHeightAdjustEnable
TB,N,V_forceCountInStatuBarHeight
@"<BBPlayerControlSafeAreaLayoutProtocol>"
```
**高度与间距来自 `barHeight` / `itemSpacing` 两个可读属性 + 约束**，
所以「量一次写死」必然错；正确做法是照它的规则算。
