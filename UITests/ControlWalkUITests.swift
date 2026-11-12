#if os(iOS)
import XCTest

/// 控件遍历审计：对每个根 section 深链打开后，枚举其可交互控件（按钮/开关/文本域），
/// 逐个触发并截图，捕捉「点击后」的 UI 状态（弹 sheet、跳子页、切 toggle）供视觉审计。
///
/// 与 DuoAcceptanceUITests 同 runner（Scripts/test-duo-ui.sh --simulator/--device），驱动已装好的映匣。
/// 只读优先：仅 tap 可逆的控件（打开 sheet 后点「取消」/「完成」/滑动关闭），不提交任何破坏性动作。
///
/// bundle id 不写在这里：由 `QATarget.appBundleID` 在构建期注入（见 UITests/QATargetBundle.swift）。
/// 模拟器装的是 `wda.prdc.yingxia.guji`、真机是 `wda.prdc.yingxia.dev`，两者签名 Team 不同，
/// 写死任何一个都会在另一台机器上指向一个没装的应用。
final class ControlWalkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: try QATarget.appBundleID)
    }

    /// 对每个 section：打开 → 枚举控件 → 逐个 tap（可逆）→ 截图。
    /// 用 -qaWalkControls 1 控制步进，一次只走一个 section，避免一次跑太久被 runner 杀掉。
    func testWalkOneSectionControls() throws {
        // 哪个 section 由环境变量传入；默认 settings（控件最密集）。
        let section = ProcessInfo.processInfo.environment["WALK_SECTION"] ?? "settings"
        launch(section: section)

        // 等 section 就位
        let title = ["home": "Watch Now", "discover": "Discover", "live": "Live TV", "sites": "Sources",
                     "favorites": "Favorites", "downloads": "Downloads", "settings": "Settings", "more": "More"][section] ?? section
        let marker = app.descendants(matching: .any).matching(identifier: "section.\(title)").firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "\(section) 未打开")
        Thread.sleep(forTimeInterval: 2)
        attach("\(section)-before")

        // 枚举可交互控件：按钮 + 开关 + 文本域
        let controls = app.buttons.allElementsBoundByIndex + app.switches.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex
        // 只保留当前可见（有 frame）的，过滤掉导航栏等系统控件
        let visible = controls.filter { $0.isHittable && !$0.frame.isEmpty && $0.frame.minY > 0 && $0.frame.maxY < app.frame.height }
        print("[ControlWalk] \(section) 可见控件 \(visible.count) 个")

        for (i, ctrl) in visible.prefix(20).enumerated() {
            let ident = ctrl.identifier.isEmpty ? (ctrl.label.isEmpty ? "unnamed-\(i)" : ctrl.label) : ctrl.identifier
            let name = ident.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_").prefix(40)
            // 跳过破坏性/导航类控件，避免状态被带偏
            if ident.contains("删除") || ident.contains("清除") || ident.contains("退出") || ident.contains("重置") { continue }
            guard ctrl.isHittable else { continue }
            ctrl.tap()
            Thread.sleep(forTimeInterval: 1.2)
            attach("\(section)-tap\(i)-\(name)")
            // 若弹出 sheet/alert，拍完关掉，回到原页
            dismissSheetOrAlert()
        }
        app.terminate()
    }

    // MARK: - Helpers

    private func launch(section: String) {
        app.launchArguments = ["-qaSection", section, "-qaKeepAwake", "1",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 关闭可能弹出的 sheet / alert，让后续控件 tap 回到原页。
    private func dismissSheetOrAlert() {
        let cancel = ["取消", "Cancel", "关闭", "完成", "Done", "Close"].compactMap { app.buttons[$0].exists ? app.buttons[$0] : nil }.first
        if let cancel { cancel.tap(); Thread.sleep(forTimeInterval: 0.5); return }
        // sheet 下滑关闭
        if app.sheets.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
    }
}
#endif
