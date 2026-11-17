import Foundation

/// 记录「内嵌 Java 运行时上一次启动是否把整个 App 带走了」。
///
/// 为什么需要它
/// ----------
/// 内嵌 JVM 是零解释器（Zero）的静态端口。它出问题时**不是抛异常，而是 `abort()`**：
/// 宿主的 `abortHook` 直接把进程杀掉 —— Swift 侧没有任何 catch 的机会。
/// 于是「点一个需要 jar 插件的源」在用户眼里就是**闪退**，而且每次点都闪退，
/// 因为下一次启动还会去创建那个 VM，再死一次。
///
/// 能做的只有一件事：**在创建之前留一个痕，起来之后擦掉**。
///   · 痕还在 → 上个进程死在了「创建 JVM → VM 应答」这段窗口里。
///     这不是订阅的问题、不是网络的问题，是这个运行时在这台设备上起不来。
///   · 既然起不来，就别再拿用户的每一次点击去撞它：停用，给一句人话说明。
/// 下次装新版本（`CFBundleVersion` 变了）自动重试一次 —— 修好了就跟上，不用用户去翻开关。
///
/// 判据用**构建号**而不是时间：同一个包重装不该反复崩一次；
/// 换了包才值得再试，因为运行时是随包走的。
public enum JarRuntimeHealth {

    private enum Keys {
        static let starting = "jarRuntime.starting"
        static let failures = "jarRuntime.failures"
        static let blockedBuild = "jarRuntime.blockedBuild"
        static let userEnabled = "jarRuntime.userEnabled"
    }

    /// 这一版 App 的标识（版本 + 构建号）。运行时随包走，所以它变了才值得重试。
    public static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))"
    }

    /// 存储位置。测试里换成一个独立 suite，免得把开发者自己的偏好写脏。
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// 这一版随包的内嵌运行时**在启动阶段就自举失败**，改为默认关闭。
    ///
    /// 证据（2026-11-16，模拟器 + lldb 实测）：
    ///   `JNI_CreateJavaVM` → `Threads::create_vm` → `initialize_java_lang_classes`
    ///   → `System.<clinit>` → `System.registerNatives`（native）
    ///   → `ZeroInterpreter::main_loop` 里 `ldr x8,[x1]` 而 **x1 == 0** → `EXC_BAD_ACCESS (0x0)`
    ///   —— 解释器对一个还没装好的 `from_interpreted_entry()` 做了空指针调用。
    /// JVM 随即走 `os::abort()`（宿主装了 abortHook），进程直接消失，没有可捕获的异常。
    /// hs_err 里留的是 `os_bsd_zero.cpp:91 ShouldNotCall()`（Zero 端口没有
    /// `ucontext_get_pc`，所以连信号都描述不了，只能 abort）。
    ///
    /// 重编 `Runtime/AppleRuntime` 的运行时（`Scripts/build-apple-jvm.sh`）修好之后，
    /// 把这里改回 `false` —— 那之后「启动失败自动停用」的看门狗仍然生效，
    /// 但不再替所有人预先关掉一个可能已经修好的能力。
    ///
    /// ⛔ 2026-11-16 12:59 这里曾被改成 `false`（同批还有一次把 `AppleRuntime.m` 的
    /// VM 参数砍掉的试验：去掉 `-XX:CompressedClassSpaceSize`、`--add-opens`、`abort`/`exit` 钩子）。
    /// 那次没有修好任何东西 —— 12:59 重编的模拟器运行库在 13:01 / 13:03 / 13:04 / 13:08
    /// 又崩了四次，栈一模一样：`JNI_CreateJavaVM` → `System.<clinit>` →
    /// `ZeroInterpreter::main_loop` → `report_should_not_call`。
    /// 现在改回 `true`：闸关上，点 jar 源只出说明，进程不再被带走。
    /// 真要放开，先把运行库重编并**在真机上**跑通一次，再动这一行。
    ///
    /// ## 2026-11-16 改为 `false`：从「预先关掉」改成「崩了再关」
    ///
    /// 上面记的四次崩溃都是真的，运行库也确实还没修好。但**预先关掉**的代价被低估了：
    /// 内置 1522 个源里 **1060 个是 jar 源**（`api` 既非 `.js` 也非 `.py`，`type == 3`），
    /// 闸一关它们全变成「点进去只有一句说明」—— 为了躲一次崩溃，废掉七成内容。
    ///
    /// 现在改由 `Runtime/AppleRuntime/Native/AppleRuntime.m` 的**崩溃隔离**兜底：
    /// JVM 的 `abortHook` 不再直接 `abort()`，而是 `siglongjmp` 回请求入口
    /// （`TVAppleRuntimeRequest` 里的 `sigsetjmp`），于是：
    ///   · JVM 起不来 → 那一次请求返回错误，**App 照常活着**；
    ///   · 事后把 `runtimeBroken` 置真，后续请求立刻短路，不再反复撞；
    ///   · 用户看到的是「这个源打不开」，不是闪退。
    ///
    /// ⇒ 能跑通的源照常跑（真机上先验证）；跑不通的只是打不开，不会带走 App。
    /// 这比「一律关掉」严格更优：能力该开着，护栏放在崩溃那一层。
    ///
    /// ⚠️ 如果真机上发现 JVM 崩溃隔离没接住（仍然闪退），把它改回 `true` —— 那时说明
    /// 崩在隔离窗口之外（例如 VM 创建前的 C++ 静态初始化），需要另外处理。
    public static let shippedRuntimeIsBroken = false

    /// 用户在设置里是否允许使用插件运行时。
    ///
    /// 没有显式选择时跟随 `shippedRuntimeIsBroken`：已知起不来的那一版默认不碰，
    /// 读者仍可在「设置 › JAR 运行时」里一键试一次（会真的去创建 VM，可能再崩）。
    public static var userEnabled: Bool {
        get {
            if let saved = defaults.object(forKey: Keys.userEnabled) as? Bool { return saved }
            return !shippedRuntimeIsBroken
        }
        set { defaults.set(newValue, forKey: Keys.userEnabled) }
    }

    /// 上一次启动死在 JVM 创建上的是不是**当前这一版**。换包即失效（自动重试一次）。
    public static var blockedBuild: String? {
        defaults.string(forKey: Keys.blockedBuild)
    }

    /// 这一版里运行时是不是已经被判定为「起不来」。
    public static var blockedHere: Bool { blockedBuild == currentBuild }

    /// 现在能不能去碰这个运行时。
    public static var isEnabled: Bool { userEnabled && !blockedHere }

    /// 连续失败次数（跨版本累计，只用于诊断上报）。
    public static var failures: Int { defaults.integer(forKey: Keys.failures) }

    // MARK: - 生命周期

    /// 这个进程里的状态：痕落过没有 / VM 已经起来了没有。
    ///
    /// 为什么要在内存里记：`noteStarting()` 会 `synchronize()`（等它落盘，因为这行之后进程可能就没了）。
    /// 每次请求都做一次同步写盘是不可接受的 —— 一页目录能发几十个请求。VM 只创建一次，
    /// 所以痕也只需要落一次。
    nonisolated(unsafe) private static var marked = false
    nonisolated(unsafe) private static var confirmed = false

    /// 创建 JVM **之前**调用。这一行写下去而没能擦掉，就说明进程死在了里面。
    ///
    /// 用 `synchronize()` 而不是等系统自己刷盘：这段窗口的长度是「几十毫秒之后进程就没了」，
    /// 延迟写等于没写。
    public static func noteStarting() {
        guard !marked, !confirmed else { return }
        marked = true
        defaults.set(true, forKey: Keys.starting)
        defaults.synchronize()
    }

    /// VM 起来并应答了第一个请求 → 擦掉痕。之后这个进程里怎么崩都与「起不来」无关了。
    public static func noteStarted() {
        guard !confirmed else { return }
        confirmed = true
        guard marked else { return }
        marked = false
        defaults.set(false, forKey: Keys.starting)
        defaults.synchronize()
    }

    /// 只给测试用：清掉进程内状态。生产里一个进程只创建一次 VM，不存在「重置」这回事。
    static func resetProcessStateForTests() { marked = false; confirmed = false }

    /// App 启动时调用一次：把上一次没擦掉的痕结账。
    ///
    /// - Returns: 上次是不是死在 JVM 启动窗口里（这一版因此被停用时为 `true`）。
    @discardableResult
    public static func audit() -> Bool {
        guard defaults.bool(forKey: Keys.starting) else { return false }
        defaults.set(false, forKey: Keys.starting)
        defaults.set(failures + 1, forKey: Keys.failures)
        defaults.set(currentBuild, forKey: Keys.blockedBuild)
        defaults.synchronize()
        return true
    }

    /// 设置页里「再试一次」：清掉停用标记，下一次请求会重新创建 VM（可能再崩一次，这是用户自己选的）。
    public static func retryInThisBuild() {
        defaults.removeObject(forKey: Keys.blockedBuild)
        defaults.set(true, forKey: Keys.userEnabled)
        defaults.synchronize()
    }

    /// 给读者看的一句话。写清楚「发生了什么」「还能不能好」。
    public static var disabledMessage: String {
        L10n.text("The plugin runtime (Java) is turned off: starting it ended the app. Sources that need it cannot open until it works again. Settings › JAR Runtime can try once more.")
    }
}
