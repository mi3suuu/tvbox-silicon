import Foundation
import Testing
@testable import TVCore

/// 锁住「选集面板懒加载」这条产品约束：**用户不点线路，就一个探针都不发。**
///
/// ## 为什么用源码级判据
///
/// `EpisodePicker` 是 SwiftUI View，在 `TVCoreTests` 这个 SPM 测试目标里编不进来
/// （它属于 App target，依赖 UIKit/SwiftUI 宿主）。而这条约束恰恰是**调用结构**上的：
/// 「面板出现时不调探测函数」。所以判据只能落在调用关系上 ——
/// 读源码，断言 `.task` 块里没有探测调用。
///
/// 这不是"测实现细节"的坏味道：这条约束一旦被改回去，症状是**用户看不见的**
/// （下行被悄悄吃掉、起播变慢），没有任何 UI 断言能抓到它。源码判据是唯一能守住它的地方。
///
/// 若将来把 `EpisodePicker` 搬进可测 target，应当把这两条换成行为测试并删掉本文件。
@Suite struct EpisodePickerLazyProbeTests {

    /// 本仓库根目录。
    ///
    /// ⛔ 不能用 `FileManager.default.currentDirectoryPath`：`swift test --package-path
    /// Packages/TVCore` 时 cwd 落到 `Packages/TVCore/`，而那一层只为 `Package.swift` /
    /// `Sources` / `Vendor` 建了符号链接，**没有 `App`**，于是读到的是
    /// `Packages/TVCore/App/EpisodePicker.swift` → 文件不存在 → 整个套件红。
    /// （2026-11-12 实测：4 条全红，报 CocoaError 260。）
    ///
    /// 改用仓库已有的 `RepositoryRoot.find()`：向上搜索同时含 `Runtime` 与 `Sources`
    /// 的目录，与 `--package-path` 的写法无关。
    private static var pickerSource: URL {
        RepositoryRoot.find()
            .appendingPathComponent("App/EpisodePicker.swift")
    }

    private static func loadSource() throws -> String {
        try String(contentsOf: pickerSource, encoding: .utf8)
    }

    /// 源码必须先能被读到 —— 否则下面的"没找到"全是假阴性。
    ///
    /// ⛔ 没有这一条，路径一改（或测试工作目录一换）整个套件会静默通过，
    /// 而它本该守的那条规则早就没人看了。这是「0 命中必须附正对照」在本地的形态。
    @Test func thePickerSourceIsReadable() throws {
        let source = try Self.loadSource()
        #expect(source.count > 1_000, "EpisodePicker.swift 读到的内容太短，判据会失效")
        #expect(source.contains("struct EpisodePicker"), "读到的不是选集面板")
    }

    /// 面板打开（`.task(id: activeLine)`）时只能读缓存，不许探测。
    ///
    /// 这是用户明确要求的：**当用户不点击线路时则不进行探测**。
    /// 面板在 iOS 上是进页面自动弹出来的，所以这里的任何一次探测都会发生在
    /// 用户还没做决定的时候，直接与起播抢带宽。
    @Test func openingThePickerProbesNothing() throws {
        let source = try Self.loadSource()

        // 取出 `.task(id: activeLine) { ... }` 这一段（到下一个同缩进的 `}` 为止）。
        let marker = ".task(id: activeLine) {"
        let start = try #require(source.range(of: marker), "找不到 `.task(id: activeLine)` —— 面板的打开钩子被改名了，本判据需同步更新")
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\n        }"), "找不到 `.task` 块的结束位置，本判据需同步更新")
        let block = String(tail[..<end.lowerBound])

        // 去掉注释再判：注释里提到 `probeVisibleLines()` 是在解释历史，不算调用。
        let code = block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slash = line.range(of: "//") else { return String(line) }
                return String(line[..<slash.lowerBound])
            }
            .joined(separator: "\n")

        #expect(!code.contains("probeVisibleLines"), "打开面板不许自动探测全部线路")
        #expect(!code.contains("probeAll"), "打开面板不许自动探测全部线路")
        #expect(!code.contains("probeIfNeeded"), "打开面板不许自动探测")
        #expect(!code.contains("retestLines"), "打开面板不许触发重测（那是用户按按钮的动作）")
        // 正对照：它必须仍然做那一件该做的事，否则「零请求」可能只是因为它什么都没干。
        #expect(code.contains("loadReadings"), "打开面板仍须把缓存读数铺上去")
    }

    /// 点线路 chip 应当立刻测这一条（懒加载的"按需"那一半）。
    @Test func tappingALineMeasuresThatLine() throws {
        let source = try Self.loadSource()
        let start = try #require(source.range(of: "private func lineChip(_ flag: String)"),
                                 "找不到 lineChip —— 本判据需同步更新")
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "private func lineRow") ?? tail.range(of: "\n    private func "),
                               "找不到 lineChip 的结束位置")
        let block = String(tail[..<end.lowerBound])

        #expect(block.contains("activeLine = flag"), "点 chip 要先切到这条线路")
        #expect(block.contains("probeLines([flag])"),
                "点 chip 要走 probeLines([flag]) —— 这条路才会注入 `resolve`")
    }

    /// 点 chip 必须走**经 resolve** 的那条路，不能拿裸 `episode.address` 去测。
    ///
    /// ⛔ 这是本轮修掉的真实缺陷：type 3/4 源的 `address` 是 play 参数（`第1集$abc123`），
    ///    `ProbePlanTarget.isRequestable` 对相对 URL 返回 false，于是点击**静默无效**。
    ///    当前订阅 756 个源里 605 个是 type 3（80%）—— 「点线路测速」几乎全坏。
    ///
    /// 判据：面板里不许再出现「把裸 address 直接喂给 probeIfNeeded」的调用形态。
    @Test func thePickerNeverMeasuresARawAddress() throws {
        let source = try Self.loadSource()

        // 正对照：resolve 这条正路必须还在，否则下面的"没找到"是假阴性。
        #expect(source.contains("state.resolve = "), "必须仍然注入 resolve")
        #expect(source.contains("await resolve?(episode)"), "必须仍然经 resolve 解析地址")

        // 唯一允许**调用** `probeIfNeeded` 的地方是 `probeOne`，且喂给它的是
        // resolve 之后的 `sample.url.absoluteString`。裸 `episode.address` 不算。
        //
        // 计数口径：把全文件里 `probeIfNeeded(` 的出现次数，与「紧跟着
        // `sample.url.absoluteString` 的那一处」对齐。定义体（`func probeIfNeeded(`）
        // 与注释里提到的历史做法规避掉。
        let callLines = source
            .split(separator: "\n")
            .filter { $0.contains("probeIfNeeded(") && !$0.contains("func probeIfNeeded(") && !$0.contains("///") }

        #expect(callLines.count == 1, "`probeIfNeeded` 应当只有一处真调用（在 probeOne 里），实际 \(callLines.count) 处")
        for line in callLines {
            #expect(line.contains("sample.url.absoluteString"),
                    "probeIfNeeded 必须收到 resolve 之后的真实地址，不能是裸 address：\(line)")
        }

        // 反向确认：**代码里**不存在「把 episode.address 直接当测速地址」的写法。
        // 只看代码行 —— 注释里引用这个坏写法是解释历史，不算违规。
        let codeOnly = source
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.contains("///") }
            .joined(separator: "\n")
        #expect(!codeOnly.contains("address: episode.address"),
                "不许把 episode.address 直接当测速地址（type 3/4 上它是 play 参数）")

        // ★ 把「为什么这算缺陷」钉到类型层：
        //   type 3/4 的 address 会被 `isRequestable` 判掉，喂进去必然静默失败。
        //   这条测试的价值是让「裸 address」这条路**在类型层面就被证明走不通**，
        //   而不只是靠约定俗成的注释警告。
        let playParameters = ["第1集$abc123", "abc123", "/play/123-1-1"]
        for address in playParameters {
            #expect(!ProbePlanTarget.isRequestable(address),
                    "\(address) 是 play 参数，不该被当成可测地址 —— 面板若直接喂它，就是静默失败")
        }
    }
}
