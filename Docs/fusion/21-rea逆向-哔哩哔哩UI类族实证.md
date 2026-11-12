# 用 rea 逆向哔哩哔哩 9.18.0 的播放器 UI 类族

## 方法（rea，不是截图猜）
```bash
# 1. Mach-O 结构（无需 GUI）
rea inspect-macho <app>/bili-universal

# 2. ObjC/Swift 分派元数据（无需 GUI，`native-macos` provider，无副作用）
rea inspect-native-dispatch-metadata <app>/bili-universal \
  --max-input-bytes 1073741824 --max-records 20000

# 3. 类名（该二进制 Swift 声明未被 reader 解码，改从 __swift5 字符串池取）
strings -a bili-universal | grep -oE 'BBPlayer[A-Za-z0-9]+Widget' | sort -u
```

> `rea search` / `rea analyze` 默认绑 Hopper，需 GUI 且大二进制会 120s 超时。
> 本目标用 `native-macos` 的 `inspect_macho` + `inspect_native_dispatch_metadata`
> + 字符串池，全部无副作用、可复现。

## 1. 三屏族 = 四角色区（决定性结构）

类名直接给出分区：
```
BBPlayerPortraitScreen{Top,Bottom}Widget              ← 竖屏：**只有 2 个区**
BBPlayerHalfScreen{Top,Bottom,Left,Right}Widget       ← 半屏：4 个区
BBPlayerFullScreen{Top,Bottom,Left,Right}Widget       ← 全屏：4 个区
```

**结论：播放器不是「一行/两行/三行」流式布局，是 Top/Bottom/Left/Right 四个独立角色区。**
竖屏少 Left/Right —— 这就是竖屏控件比横屏少的原因。

## 2. 全屏专属控件（`BBPlayerFullScreen*`）
```
BBPlayerFullScreenTopWidget
BBPlayerFullScreenBottomWidget
BBPlayerFullScreenLeftWidget
BBPlayerFullScreenRightWidget
BBPlayerFullScreenCoinBtnWidget
BBPlayerFullScreenShareBtnWidget
BBPlayerFullScreenEpisodeBtnWidget
BBPlayerFullScreenEndPageWidget
BBPlayerFullScreenState
```
另有：`BBPlayerLockScreenWidget` / `BBPlayerUnlockScreenWidget` /
`BBPlayerMiniScreenButtonWidget` / `BBPlayerSwitchScreenWidget` / `BBPlayerRestoreScreenWidget`

## 3. 播放设置面板 = **三类 Cell**（不是九行列表）

```
BBPlayerPlaySettingWidget / BBPlayerPlaySettingWidgetV2
├── BBPlayerPlaySettingPlaybackRateCell     ← 倍速列
├── BBPlayerPlaySettingPlaybackModeCell     ← 播放模式列
├── BBPlayerPlaySettingScaleCell            ← 画面比例列
└── BBPlayerPlaySettingConfigCell           ← 通用配置项
```
配套 Model：`BBPlayerPlaySettingPlaybackModeModel` / `BBPlayerPlaySettingScaleModel`
枚举：`BBPlayerPlaySettingMode` / `BBPlayerPlaySettingOperation`

**结论：原图的三列（Speed / Timer / 右三栏）对应的是不同 Cell 类型，各自纵向排。
之前实现成「9 项滚动列表」结构错误。**

## 4. 完整 `playersetting_*` 键（26 个）
```
播放模式   actionloop actionnext actionnextloop actionquit
倍速       speed05 speed075 speed10 speed125 speed15 speed20 speed30   (7 档)
画面比例   ratio16_9 ratio4_3 ratioadjustcontent ratioadjustscreen ratiocentercrop  (5 种)
开关类     backgroundenable horizontalflip dm_setting subtitle shake color_filter
其它       timer castscreen feedback optionsedit
```

## 5. 弹幕设置（独立体系，非播放设置）
```
BBPlayerDanmakuSettingWidgetV2     BBPlayerDanmakuSettingViewModel
BBPlayerDanmakuSettingConfig       BBPlayerDanmakuSettingCollectionCell
BBPlayerDanmakuSettingServiceV2    BBPlayerDanmakuSettingEntranceWidget
BBPlayerDanmakuConfigPanel         BBPlayerDanmakuPostPanelModelV2
```

## 6. 我当前实现的偏差（必须改）

| 项 | 真实（rea 实证） | 我做的 | 判定 |
|---|---|---|---|
| 分区模型 | Top/Bottom/Left/Right 四角色区 | 三行流式 + 绝对定位 | ❌ 结构错 |
| 竖屏区数 | 2（Top+Bottom） | 3 行 | ❌ |
| 设置面板 | 3 类 Cell 各自纵向成列 | 9 项单列滚动 | ❌ 结构错 |
| 倍速档 | 7 档 | 7 档 | ✅ |
| 画面比例 | 5 种 | 5 种 | ✅ |
| 锁屏/小窗/截图 | 独立 Widget | 塞进 sideRail | ⚠️ 位置对，归类可再校 |
