#if os(iOS)
import XCTest

/// 被测 App 的 bundle id 的唯一来源。**源码里不写死字面量。**
///
/// 为什么必须注入而不是硬编码：同一套用例要在两种装机上跑，两者的 bundle id 不同，而且是
/// 不同 Team 签的，application-identifier 不通用。
///   · 模拟器：`wda.prdc.yingxia.guji`（`Config/DeviceTest.xcconfig` 里的 PRODUCT_BUNDLE_IDENTIFIER）
///   · 真机：  `wda.prdc.yingxia.dev`
/// 以前这里写死 `.dev`，于是模拟器上 `XCUIApplication(bundleIdentifier:)` 永远指向一个没装的
/// 应用，145 条断言一次都没真正跑过。
///
/// 注入通道：`Scripts/test-duo-ui.sh` 生成临时工程时给测试 target 的 Info.plist 写
/// `UITargetBundleID: $(UITARGET_BUNDLE_ID)`，再用 xcodebuild 的 `UITARGET_BUNDLE_ID=<id>`
/// 构建设置把值烧进 Info.plist。所以**运行期读 Info.plist 就能拿到本次构建选定的 id**，
/// 同一个 Swift 源码不需要为两个平台分叉。
///
/// 取值优先级（与 `Scripts/test-duo-ui.sh` 文件头一致，脚本负责挑，这里只负责读）：
///   1. 测试 bundle Info.plist 的 `UITargetBundleID`（构建期注入，正常路径）
///   2. 环境变量 `QA_TARGET_BUNDLE_ID`（Xcode 里手动调试 runner 时的后门）
///
/// ⛔ 两条通道都拿不到时**抛错让每个用例变红**，不要加静默默认值，也不要 `XCTSkip`。
///    静默默认值会把「注入断了」伪装成「跑过了」；skip 则等于宣布「UI 测试跑不起来是正常的」。
///    这两种做法都让门禁变成装饰。
enum QATarget {

    /// 放一个 class 只为拿到测试 bundle 本身：`Bundle(for:)` 要 AnyClass。
    private final class BundleAnchor {}

    static let infoPlistKey = "UITargetBundleID"
    static let environmentKey = "QA_TARGET_BUNDLE_ID"

    enum LookupError: LocalizedError, CustomStringConvertible {
        /// Info.plist 和环境变量都没有值。
        case missing
        /// 有值，但仍是未被替换的构建变量（如 `$(UITARGET_BUNDLE_ID)`）。
        case unsubstituted(String)

        var description: String {
            switch self {
            case .missing:
                return """
                拿不到被测 App 的 bundle id：测试 bundle 的 Info.plist 没有 \(QATarget.infoPlistKey)，\
                环境变量也没有 \(QATarget.environmentKey)。
                正确入口是 `Scripts/test-duo-ui.sh`（它把 UITARGET_BUNDLE_ID 构建设置注进 Info.plist）；
                直接 `xcodebuild test` 那个临时工程不会注入，用例必然红。
                """
            case .unsubstituted(let raw):
                return """
                被测 App 的 bundle id 是未替换的构建变量 "\(raw)"：xcodebuild 没收到 UITARGET_BUNDLE_ID。
                给 Scripts/test-duo-ui.sh 传 --bundle-id <id>，或设 GATE_BUNDLE_ID 环境变量。
                """
            }
        }

        var errorDescription: String? { description }
    }

    /// 本次运行应该驱动的 App。
    static var appBundleID: String {
        get throws {
            if let raw = Bundle(for: BundleAnchor.self)
                .object(forInfoDictionaryKey: infoPlistKey) as? String {
                return try validated(raw, source: "测试 bundle Info.plist 的 \(infoPlistKey)")
            }
            if let raw = ProcessInfo.processInfo.environment[environmentKey], !raw.isEmpty {
                return try validated(raw, source: "环境变量 \(environmentKey)")
            }
            throw LookupError.missing
        }
    }

    /// 拦两类会让用例「看起来跑了其实没跑」的值：未替换的 `$(...)`，和空串。
    private static func validated(_ raw: String, source: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("$(") {
            throw LookupError.unsubstituted(raw)
        }
        return value
    }
}
#endif
