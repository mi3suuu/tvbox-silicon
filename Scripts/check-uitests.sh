#!/bin/bash
# UITests 类型检查门禁。
#
# 主工程没有 UI 测试 target（XCUITest 的 bundle 必须挂在某个 app target 上），
# 所以 `xcodebuild -scheme TVBox-*` 永远编译不到 UITests/。这意味着：
#   · 改了 UITests/ 里的代码，三平台 BUILD SUCCEEDED 也不会报错
#   · `swiftc -parse` 只做语法检查，**不解析成员访问**，`section.key` 这种类型错误它能放过
#
# 2026-11-06 实测踩过：新加的白屏回归测试 `for section in ["home", ...] { section.key }`
# —— String 没有 .key，`-parse` 通过、真正编译失败。所以这个脚本现场生成一个
# 只含「占位宿主 + UI 测试 bundle」的临时工程，走真正的 type-check。
#
#   Scripts/check-uitests.sh            # 只编译，不跑
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${UITEST_CHECK_OUT:-$ROOT/build/UITestCheck}"

rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/QAAnchor.swift" <<'SWIFT'
import SwiftUI
@main
struct QAAnchor: App { var body: some Scene { WindowGroup { Text("QA Anchor") } } }
SWIFT
cat > "$OUT/project.yml" <<YAML
name: UITestCheck
options:
  deploymentTarget:
    iOS: '17.0'
targets:
  QAAnchor:
    type: application
    platform: iOS
    sources: [QAAnchor.swift]
    settings: { SWIFT_VERSION: '6.0', PRODUCT_BUNDLE_IDENTIFIER: wda.prdc.check.host }
    info:
      path: AnchorInfo.plist
      properties: { CFBundleDisplayName: QA Anchor, UILaunchScreen: {} }
  UITests_C:
    type: bundle.ui-testing
    platform: iOS
    sources: [$ROOT/UITests]
    dependencies: [{ target: QAAnchor }]
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: wda.prdc.check.tests
      GENERATE_INFOPLIST_FILE: YES
      TEST_TARGET_NAME: QAAnchor
YAML
( cd "$OUT" && xcodegen generate --spec project.yml >/dev/null )
xcodebuild -project "$OUT/UITestCheck.xcodeproj" -target UITests_C \
    -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | sort -u
