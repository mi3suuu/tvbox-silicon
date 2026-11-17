import Foundation
import Testing
@testable import TVCore

// MARK: - 真构建的 JAR 闸状态（不是 mock）

/// 这一组不注入任何偏好，量的是**当前这个构建**的真实闸位。
/// 它回答用户报的那个现象：「点资源闪退」到底还会不会发生。
///
/// ⛔ 判据写法教训：第一版把断言写在 `guard shippedRuntimeIsBroken else { return }` 里，
/// 于是「把 shippedRuntimeIsBroken 改成 false」这个负对照**照样全绿** ——
/// 判据被包在早退壳里，条件一变就整段跳过，等于没有判据。
/// 现在改成：无论那个常量是什么，都必须有可断言的结论。
@Suite("JarGateRealBuild")
struct JarGateRealBuildTests {

    /// 闸位必须与「运行时是否被判坏」**一致**：坏了→关，没坏→开。
    ///
    /// 这样正反两个方向都能撞出问题：
    ///   · 运行时坏了却把闸开着 → 点 jar 源会 abort（用户报的闪退）
    ///   · 运行时没坏却把闸关着 → 七成源白废
    @Test func theGateAgreesWithTheShippedVerdict() {
        let suite = UserDefaults(suiteName: "JarGate.verdict.\(UUID().uuidString)")!
        let saved = JarRuntimeHealth.defaults
        JarRuntimeHealth.defaults = suite
        defer { JarRuntimeHealth.defaults = saved }

        let broken = JarRuntimeHealth.shippedRuntimeIsBroken
        // 默认（用户没手动改过）时：闸位 = !broken
        #expect(JarRuntimeHealth.userEnabled == !broken,
                "已知起不来的运行时必须默认关闭，否则每次点 jar 源都会 abort；没判坏时也不该替用户关掉")
        #expect(JarRuntimeHealth.isEnabled == !broken)
    }

    /// 闸关着时，`EmbeddedJarHost.isEnabled` 也必须是 false ——
    /// 这是 `request(...)` 里 `guard` 实际读的那一个，读错对象就等于没闸。
    @Test func theHostGateFollowsTheHealthGate() {
        let suite = UserDefaults(suiteName: "JarGate.host.\(UUID().uuidString)")!
        let saved = JarRuntimeHealth.defaults
        JarRuntimeHealth.defaults = suite
        defer { JarRuntimeHealth.defaults = saved }

        #expect(EmbeddedJarHost.isEnabled == (EmbeddedJarHost.available && JarRuntimeHealth.isEnabled),
                "EmbeddedJarHost.isEnabled 必须反映 JarRuntimeHealth.isEnabled，否则 guard 守错对象")
    }
}
