# 仓库并行会话登记（PEERS）

> 由 `tools/qa/peer-probe.sh` 校验（A8 的强制手段）。**不登记 = 探针看不见你 = 冲突照样发生。**
> 这不是文档，是门禁的输入数据：格式坏了会判红。

## 路 A · 质量门禁队

- branch: fusion/restructure-A
- owner: 质量门禁队（lead）
- self: true
- last_seen: 2026-11-13 11:28:58
- claimed:
  - UITests/DuoAcceptanceUITests.swift
  - UITests/ControlWalkUITests.swift
  - UITests/QATargetBundle.swift
  - Scripts/test-duo-ui.sh
  - Scripts/install-duo-test.sh
  - tools/qa/peer-probe.sh
  - tools/qa/peer-gate.sh
  - tools/qa/gate.sh
  - UITests/.protected-assertions.txt
  - PEERS.md
  - Docs/门禁2.7-分码修复-20261113.md
  - Docs/门禁2.7-真冲突实测-20261113.md

## 路 B · 界面反馈修复（另一会话）｜7 项由映霞 git status 比对补登

- branch: 未登记（对方未声明，mtime 证据见 并行会话边界-20261113.md）
- owner: 未知会话（mtime 实测推断，未经本人确认；但 +65/-3 与 +100/-5 是实测事实）
- last_seen: 2026-11-13 03:00:00
- claimed:
  - App/SettingsPlayback.swift
  - App/HalfFoldConsole.swift
  - App/LanguageSettingsView.swift
  - App/OneSkin.swift
  - App/VideoDetailView.swift
  - project.yml
  - TVBox.xcodeproj/project.pbxproj
  - App/QALaunch.swift
  - App/MobilePlayer.swift
  - App/OneSkinWindowGeometry.swift
  - App/Store.swift
  - App/TVBoxApp.swift
  - Sources/TVCore/OneSkinWindowGeometryCore.swift
  - Tests/TVCoreTests/OneSkinWindowGeometryTests.swift
  - App/OneSkinPreview.swift

## 路 C · 下载与 WebBox 融合（另一条线）

- branch: 未登记（未声明；owner 待认领）
- owner: 未认领（下列文件按改动主题推断：下载测速 + WebBox 插件资源）
- last_seen: 2026-11-13 11:00:03
- claimed:
  - Sources/TVCore/DownloadAccelerator.swift
  - Tests/TVCoreTests/DownloadTests.swift
  - Tests/TVCoreTests/SubtitleHintTests.swift
  - Sources/TVCore/ScriptAssets/webox/sites/supjav.webox.js
  - Sources/TVCore/ScriptAssets/webox/sites/黄果.webox.js

## 已声明归属（单文件互斥，避免互相覆盖）

- **tools/qa/gate.sh → 归 Chief**，其他会话不得修改

## 交接记录

| 时间 | 从 | 到 | 内容 |
|---|---|---|---|
| 2026-11-13 02:28 | — | — | 按 A8 建立；路 B 数据来自 mtime 实测，待对方本人认领 |

## 路 C · tvOS 平台可编译性清理（Chief 派活）

- branch: `fix/tvos-platform-guards`（worktree: `tvbox-wt-tvos-guards`）
- owner: lead（受 Chief 委派）
- last_seen: 2026-11-13 12:55
- claimed:
  - App/CustomProxySettings.swift
  - App/FoldRegion.swift
  - App/MobilePlayer.swift
  - App/OneSkin.swift
  - App/OneSkinBackdrop.swift
  - App/OneSkinGeometryDriver.swift
  - App/OneSkinWindowGeometry.swift
  - App/PlayerControls.swift
  - App/QALaunch.swift
  - App/SettingsTV.swift
  - App/SiteView.swift
  - App/SitesView.swift
  - App/VideoDetailView.swift
  - App/WatchPageChrome.swift
- 状态: **已提交 `1f8807c`，BUILD SUCCEEDED**（`5db8179` 中两条已按 Chief 复核意见撤回重做）
- 交付: `交付/tvOS可编译性清理-最终-20261113.md`（分层清单 `…-分层清单-20261113.md` 保留为过程记录）
