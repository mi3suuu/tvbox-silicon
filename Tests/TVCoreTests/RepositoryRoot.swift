// [mi3s] 二开：从测试文件位置向上找到仓库根。
//
// 上游两处测试用「固定三段上级目录」推算仓库根，前提是包根 == 仓库根。
// 本仓库为了让 Xcode 集成，在 `Packages/TVCore/` 放了一套指向 `../../` 的符号链接
// （Package.swift / Sources / Vendor，Tests 是硬链接副本），
// 于是 `swift test --package-path Packages/TVCore` 编译出来的 `#filePath` 是
// `.../Packages/TVCore/Tests/TVCoreTests/X.swift`：三段上溯落到 `Packages/TVCore`，
// 比真实仓库根少两级，两处测试因此找不到 `Runtime/` 与 `Services/`。
//
// 这里改成向上搜索标志文件，不依赖层级深度；从仓库根跑（`swift test`）时行为与上游一致。

import Foundation

enum RepositoryRoot {
    /// Walks up from `file` until it finds a directory holding both `Runtime` and `Sources`.
    static func find(from file: String = #filePath) -> URL {
        var directory = URL(filePath: file).deletingLastPathComponent()
        let manager = FileManager.default
        while directory.path != "/" {
            if manager.fileExists(atPath: directory.appending(path: "Runtime").path),
               manager.fileExists(atPath: directory.appending(path: "Sources").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return directory
    }
}
