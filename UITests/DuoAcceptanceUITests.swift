#if os(iOS)
import XCTest

/// Phone acceptance against a real device (Scripts/test-duo-ui.sh).
///
/// Nothing here runs against the QA host app: every test drives the installed Mi3s build
/// (`wda.prdc.yingxia.dev`) through `XCUIApplication(bundleIdentifier:)`, so the screens under test are
/// the user's own — their subscriptions, their settings. The tests therefore only read: they walk to a
/// screen, assert what must be on it, and photograph it. Nothing is toggled, deleted or reordered.
final class DuoAcceptanceUITests: XCTestCase {
    private let bundleID = "wda.prdc.yingxia.dev"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundleID)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Screens

    /// The sections worth photographing on a phone: the two the user reported broken, plus enough of the
    /// rest to prove the shell still navigates.
    ///
    /// Not all twelve. Each launch is a fresh process of an app that carries a JVM, a Python runtime and a
    /// JS runtime, and twelve in a row made the runner die of its own weight ("Restarting after unexpected
    /// exit, crash, or test timeout") — the screen list was fine, the harness was not. Eight is what fits.
    func testEverySectionOpens() throws {
        for section in Self.sections {
            launch(section: section.key)
            // The section's own marker, not `windows.count > 0`. Home satisfies the window assertion —
            // it draws first while a deep link is still landing — so `收藏` and `下载` used to pass by
            // photographing Home (2026-11-04). App/RootView.swift sets `section.<title>` on each root.
            XCTAssertTrue(marker(section.title).waitForExistence(timeout: 30),
                          "\(section.key) never opened: no \(section.title) section marker")
            Thread.sleep(forTimeInterval: 2)
            attach(section.key)
            // Hand the memory back before the next launch, or the runner accumulates eight catalogs.
            app.terminate()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// The Sources screen has to show the subscriptions the user added. This is the regression they hit:
    /// after the fork the section listed only the built-in sources, and turning 隐私锁定 on hid even those.
    ///
    /// A subscription group carries `sources.group.<id>` (App/SitesView.swift). A non-zero count is the
    /// direct evidence that the subscriptions are on screen — counting source rows would also pass on a
    /// build that had lost every subscription and kept the built-ins.
    func testSourcesListsSubscriptions() throws {
        launch(section: "sites")
        XCTAssertTrue(marker("Sources").waitForExistence(timeout: 30), "Sources never opened")
        Thread.sleep(forTimeInterval: 3)
        attach("sites")

        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sources.group.'"))
        XCTAssertGreaterThan(groups.count, 0, "Sources listed no subscription groups at all")
    }

    /// **The white-screen regression.** A page's content must actually be drawn in every size class.
    ///
    /// 2026-11-06: `RootView.tabSafeArea` is a `@ViewBuilder` whose iOS 26 branch only handled
    /// regular-width and regular-height. compact × compact — the Duo's folded outer display held
    /// sideways, **and every ordinary iPhone in landscape** — matched neither, so the branch produced
    /// `EmptyView`. Because that modifier is applied to the root of every tab page, the whole page
    /// (`Home` included) was replaced by nothing: window geometry was correct, `section.<Title>` was on
    /// screen, the tab capsule drew, and the content area came out pure white `(255,255,255)`.
    ///
    /// A marker assertion cannot catch this class of bug: `section.home` still exists as an element
    /// even when the view behind it draws nothing (the marker is an accessibility identifier on the
    /// container, and containers survive their content collapsing). So the assertion here is on the
    /// **screenshot**: sample a grid inside the content area and fail when every sample is pure white.
    ///
    /// `Scripts/audit-duo-ui.sh` drives the same check with the hinge closed and the orientation set to
    /// landscape; run this test from `Scripts/test-duo-ui.sh` so the device is already in that state.
    func testContentIsDrawnInCompactCompact() throws {
        for section in ["home", "discover", "sites", "settings"] {
            launch(section: section.key)
            XCTAssertTrue(marker(section.title).waitForExistence(timeout: 30),
                          "\(section.key) never opened")
            Thread.sleep(forTimeInterval: 2.5)
            attach("drawn-\(section.key)")

            let pureWhite = whiteSamples(in: XCUIScreen.main.screenshot())
            XCTAssertLessThan(pureWhite, 16,
                "\(section.key) drew an empty page: \(pureWhite)/16 sampled points are pure white. "
                + "A whole-page \(EmptyView) from a @ViewBuilder fallback looks exactly like this.")
            app.terminate()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// How many of a 4 × 4 grid of points inside the content area are pure white.
    ///
    /// The content area is inset from the screen edges: the tab bar / sidebar capsule and the status bar
    /// are system chrome and legitimately near-white in light mode, so sampling them would produce false
    /// failures. The band sampled is 15 %–85 % horizontally and 20 %–80 % vertically.
    ///
    /// "Pure white" is `min(r, g, b) > 250`. The app's own background is the `Backdrop` tint
    /// (`244, 246, 251`), whose blue channel sits at 251 but whose red is 244 — so it does not count as
    /// white here, which is exactly what makes "page not built" distinguishable from "page built but
    /// empty".
    private func whiteSamples(in screenshot: XCUIScreenshot) -> Int {
        guard let cg = screenshot.image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bytesPerRow = cg.bytesPerRow
        let bytesPerPixel = cg.bitsPerPixel / 8

        var white = 0
        for row in 0..<4 {
            for column in 0..<4 {
                let fx = 0.15 + (0.85 - 0.15) * (Double(column) + 0.5) / 4
                let fy = 0.20 + (0.80 - 0.20) * (Double(row) + 0.5) / 4
                let x = min(width - 1, max(0, Int(fx * Double(width))))
                let y = min(height - 1, max(0, Int(fy * Double(height))))
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(data) else { continue }
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                if min(r, min(g, b)) > 250 { white += 1 }
            }
        }
        return white
    }

    /// Settings must report a version, which is how a screenshot proves the build under test is the one
    /// that was just installed rather than a stale copy.
    func testSettingsShowsVersion() throws {
        launch(section: "settings")
        XCTAssertTrue(marker("Settings").waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 2)
        attach("settings")
        let version = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1.8")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "Settings does not show a 1.8.x version")
    }

    /// The other half of the same regression: with the vault on, unlocking has to reveal the filtered
    /// sources again. `-qaPage vault` opens it directly (App/QALaunch.swift) — a page inside Privacy
    /// rather than a tab, so there is nothing to find and tap.
    ///
    /// The test never guesses a passcode. Three faces count as drawn, and which one appears depends on the
    /// device: the set-a-passcode row on a fresh install, the passcode field while setting one, and the
    /// unlock pad once a passcode exists.
    func testPrivacyVaultDraws() throws {
        launch(section: "settings", page: "vault")
        XCTAssertTrue(marker("Settings").waitForExistence(timeout: 30), "The vault never opened")
        Thread.sleep(forTimeInterval: 2)
        attach("vault")

        let setup = app.buttons["privacy.setup"]
        let passcode = app.secureTextFields["privacy.passcode"]
        let unlock = app.secureTextFields["privacy.unlock"]
        let drew = setup.waitForExistence(timeout: 10) || passcode.exists || unlock.exists
        XCTAssertTrue(drew, "The vault drew none of: set-a-passcode row, passcode field, unlock pad")
        XCTAssertEqual(app.state, .runningForeground, "The vault dismissed the app")
    }

    // MARK: - Helpers

    /// The eight sections, as `-qaSection <key>` and the `AppSection` title the app marks the page with.
    /// The title is not the key: `-qaSection sites` opens "Sources", whose page carries `section.Sources`.
    private static let sections: [(key: String, title: String)] = [
        ("home", "Watch Now"), ("discover", "Discover"), ("live", "Live TV"), ("sites", "Sources"),
        ("favorites", "Favorites"), ("downloads", "Downloads"), ("settings", "Settings"), ("more", "More"),
    ]

    private func marker(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "section.\(title)").firstMatch
    }

    private func launch(section: String, page: String? = nil) {
        dismissSystemAlerts()
        var arguments = ["-qaSection", section]
        if let page { arguments += ["-qaPage", page] }
        // Keep the screen awake for the length of the run, and pin the language so the screenshots are
        // comparable from one run to the next.
        arguments += ["-qaKeepAwake", "1", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments
        app.launch()
        dismissSystemAlerts()
    }

    /// Apple's own prompts (notifications, background location, “Open in …?”) belong to SpringBoard and sit on top
    /// of everything. Left alone they make every screenshot a picture of the prompt.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<8 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            // Two kinds of prompt show up here and they want opposite answers.
            // "在 xx 中打开?" comes from a stale `simctl openurl`; answering it would hand the app to
            // another bundle, so cancel. Permission prompts want Allow, so they stop coming back.
            let cancel = ["取消", "Cancel"].compactMap { alert.buttons[$0].exists ? alert.buttons[$0] : nil }.first
            let reopens = alert.buttons["打开"].exists || alert.buttons["Open"].exists
            let allow = ["允许", "始终允许", "好", "Allow", "Always Allow", "OK"]
                .compactMap { alert.buttons[$0].exists ? alert.buttons[$0] : nil }
                .first
            if let cancel, reopens { cancel.tap() }
            else if let allow { allow.tap() }
            else if let cancel { cancel.tap() }
            else if alert.buttons.count > 0 { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
