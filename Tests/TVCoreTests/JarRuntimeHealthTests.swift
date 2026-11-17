import Foundation
import Testing
@testable import TVCore

/// 「JVM 起不来」这件事只能靠**痕迹**判断：它不会抛异常，它把进程带走。
/// 所以这里测的不是错误处理，而是「上一次启动有没有走完创建那一段」的结算逻辑。
/// 这些用例共享 `JarRuntimeHealth.defaults` 这个全局，必须串行跑 ——
/// 并行时一个用例刚把 suite 换掉，另一个就读到了别人的偏好。
@Suite("JarRuntimeHealth", .serialized)
struct JarRuntimeHealthTests {

    /// 每个用例一份干净的偏好，别互相串。
    private func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        JarRuntimeHealth.defaults = suite
        JarRuntimeHealth.resetProcessStateForTests()
        return suite
    }

    /// 正常路径：落痕 → VM 应答 → 擦痕 → 下次启动什么都不该发生。
    @Test func aCompletedStartLeavesNothingBehind() {
        let defaults = freshDefaults()
        JarRuntimeHealth.noteStarting()
        JarRuntimeHealth.noteStarted()
        #expect(JarRuntimeHealth.audit() == false)
        #expect(JarRuntimeHealth.failures == 0)
        #expect(JarRuntimeHealth.blockedBuild == nil)
        _ = defaults
    }

    /// 事故路径：痕还在 → 上个进程死在创建窗口里 → 这一版停用。
    @Test func aStartThatNeverFinishedBlocksThisBuild() {
        _ = freshDefaults()
        JarRuntimeHealth.noteStarting()
        // 进程在这一行之后消失；下一次启动再做审计。
        #expect(JarRuntimeHealth.audit() == true)
        #expect(JarRuntimeHealth.failures == 1)
        #expect(JarRuntimeHealth.blockedHere)
        #expect(JarRuntimeHealth.isEnabled == false)
        // 再审计一次不该重复计数（痕已经擦掉了）。
        #expect(JarRuntimeHealth.audit() == false)
        #expect(JarRuntimeHealth.failures == 1)
    }

    /// 停用是「这一版」的事：换包（构建号变了）就该重试一次，否则修好了也永远打不开。
    @Test func aNewBuildClearsTheBlock() {
        let defaults = freshDefaults()
        JarRuntimeHealth.userEnabled = true
        JarRuntimeHealth.noteStarting()
        _ = JarRuntimeHealth.audit()
        #expect(JarRuntimeHealth.isEnabled == false)
        defaults.set("0.0(0)", forKey: "jarRuntime.blockedBuild")
        #expect(JarRuntimeHealth.blockedHere == false)
        #expect(JarRuntimeHealth.isEnabled)
    }

    /// 设置里「再试一次」：清掉停用标记并打开开关，下一次请求会真的去创建 VM。
    @Test func retryReopensThisBuild() {
        _ = freshDefaults()
        JarRuntimeHealth.noteStarting()
        _ = JarRuntimeHealth.audit()
        #expect(JarRuntimeHealth.isEnabled == false)
        JarRuntimeHealth.retryInThisBuild()
        #expect(JarRuntimeHealth.blockedHere == false)
        #expect(JarRuntimeHealth.userEnabled)
        #expect(JarRuntimeHealth.isEnabled)
    }

    /// 已知起不来的那一版，默认就是关的 —— 用户不该为了知道这件事先崩一次。
    @Test func theKnownBrokenBuildStartsOff() {
        _ = freshDefaults()
        if JarRuntimeHealth.shippedRuntimeIsBroken {
            #expect(JarRuntimeHealth.userEnabled == false)
            #expect(JarRuntimeHealth.isEnabled == false)
        }
    }
}
