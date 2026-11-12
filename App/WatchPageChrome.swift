//
//  WatchPageChrome.swift
//  映匣 / Mi3s
//
//  「选集播放页该不该有系统栏」的**唯一出口**。
//
//  为什么必须单独一处：
//  `VideoDetailView.watchBody` 有两条渲染分支 —— One 皮肤（`oneSkinBody`）与
//  上游原版（`upstreamWatchBody`）。两边历史上各抄了一遍系统栏位修饰符：
//
//      .statusBarHidden / .persistentSystemOverlays
//      .setBarVisibility(_:for: .navigationBar) / .navigationBarBackButtonHidden
//      .setBarVisibility(_:for: .tabBar)    / .hidesAppTabBar
//
//  抄两份的直接后果是判据会分叉：One 分支曾经写着「皮肤开着一律隐藏」，
//  上游分支写着「Duo 展开隐藏、竖持保留」，于是同一个页面在折叠 / 展开、
//  横持 / 竖持下有四套表现，用户看到的是「横屏没有菜单栏、竖屏又有」。
//  改一处必然漏另一处，这类 bug 只要两份代码还在，就一定会再长出来。
//
//  现在判据只有 `fullScreen` 一个：
//    · 底部菜单栏（标签栏）：选集页**一直保留** —— 折叠/展开、横屏/竖屏完全一样，
//      只有进入全屏播放才收掉（液态玻璃胶囊不能压在满屏画面上）。
//    · 顶部导航栏：**一律让位**。皮肤自己画了顶栏（返回 / 全屏 / 旋转 / 合拢），
//      上游播放页同样自带；系统那条会顶掉 44pt 把 One 的逐像素版式整体下移，
//      标题还会和皮肤重复（Duo 展开时顶上那条「测试影片 1」）。
//    · 状态栏 / Home 指示条：全屏时一起收，退全屏自动回来。
//

#if os(iOS)
import SwiftUI

/// 选集播放页的系统栏位。判据只有 `fullScreen`。
struct WatchSystemChrome: ViewModifier {
    let fullScreen: Bool
    /// OneSkin 页的底部菜单**折起**（mi3s 2026-11-09，用户目标清单「底部菜单折起」+
    /// 「竖屏最底部纯色图层删除」）：竖持保留的液态玻璃胶囊会在页面最底部留一块
    /// 恒定暗色玻璃条（实测 RGB 23,31,42，硬边、std≈1.3 的纯色块），压住详情列
    /// 底部内容。OneSkin 页有自绘的完整控件与右栏，系统胶囊只贡献这块色块 ——
    /// 皮肤开着时 tabBar 一律收掉，`fullScreen` 判据照旧（上游分支不受影响）。
    var oneSkin: Bool = false

    func body(content: Content) -> some View {
        content
            // 播放页本来就是沉浸式：状态栏任何时候都不画。
            .statusBarHidden(true)
            // 全屏连 Home 指示条一起收，否则是「伪全屏」。
            .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
            // 顶部导航栏：皮肤/上游都有自绘顶栏，系统这条一律让位。
            .setBarVisibility(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            // 底部菜单栏：**只有全屏才收**。
            //
            // ⛔ 判据不能带 `oneSkin`。用户明确要求「选集播放页保留菜单栏，
            // 横屏竖屏都一样，只有全屏播放才隐藏」—— 写成 `oneSkin || fullScreen`
            // 等于皮肤一开就整条收掉。
            .setBarVisibility(fullScreen ? .hidden : .visible, for: .tabBar)
            // UIKit 层硬开关与上面同一个条件：iOS 26 的浮动标签栏会在旋转 / 进全屏时
            // 被系统重新摆回来，toolbar 偏好不保证跟着重算。传同一判据，
            // 否则退全屏后菜单栏再也不回来。
            .hidesAppTabBar(fullScreen)
            // ★ 全屏播放器要**显式关掉垂直栏**（BUG-P）。
            //
            // iPhone Duo 的系统栏位会变成贴边的**竖向**条（`device-facts`：
            // navigation/controls 移到侧边）。全屏播放是沉浸态，那条竖栏会
            // 压进画面右缘，而且它让安全区变**不对称**（trailing 84 / leading 0），
            // 与「四路径对称」的前提冲突。
            //
            // `duo-media` 规则 8 的原话：全屏播放器用
            // `toolbarVerticalBehavior(.disabled)`，"as a fixed choice for that screen" ——
            // 是这一屏的固定选择，**不要**跟着视图状态切换。
            //
            // API 门槛：`@available(anyAppleOS 27.1, *)`，本工程部署目标 17.0，
            // 所以必须包在 `if #available` 里（已核 iPhoneOS27.2.sdk 的 swiftinterface）。
            .modifier(HideVerticalBarWhenFullScreen(fullScreen: fullScreen))
    }
}

/// 全屏时关掉 Duo 的竖向系统栏；低版本系统上是空操作。
private struct HideVerticalBarWhenFullScreen: ViewModifier {
    let fullScreen: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(fullScreen ? .disabled : .automatic)
        } else {
            content
        }
    }
}

extension View {
    func watchSystemChrome(fullScreen: Bool, oneSkin: Bool = false) -> some View {
        modifier(WatchSystemChrome(fullScreen: fullScreen, oneSkin: oneSkin))
    }
}

/// 浮动标签栏在**内容之上**占了多大 —— 需要额外预留的尺寸（系统安全区之外）。
///
/// iOS 26 的液态玻璃标签栏是**浮层**：它不撑大 `safeAreaInsets`，所以一个
/// 普通 `ScrollView` 只拿到 34pt Home 指示条，内容会从玻璃下面穿过去。
/// `RootView.tabSafeArea` 早就按这个事实给各分区补了位，但播放页是 push 进来的、
/// 又自己 `ignoresSafeArea`，一直没吃到这份预留 —— 于是选集卡片被菜单栏压掉半行。
///
/// ★ 形状随方向变，让的那一边也跟着变（Duo 内屏实测截图）：
///   · 竖持：底部一颗横向浮动胶囊 → 让**底边**；
///   · 横持（height 为 compact）：iOS 26 把标签栏收成**贴右缘的竖排胶囊**（8 颗图标一列）
///     直接压在右栏的「选集」按钮和第 2 集卡片上 → 让**右边**。
/// 只让底边是不够的，这是「横屏内容被菜单栏盖住」的真正形状。
enum WatchTabBarReserve {
    /// 竖持：底部浮动胶囊顶沿高出系统 34pt 指示条的部分，再加 Stage 自己那 28pt 内边距的量。
    /// 截图逐像素量：胶囊高约 49pt、底边距屏底约 48pt，顶沿距屏底约 63pt；
    /// Stage 内部已有 `.padding(.bottom, 28)`，所以这里只需再补 36。
    static let bottom: CGFloat = 36

    /// 横持：右缘竖排胶囊的宽度 + 它与屏幕边的间隙。
    /// 截图逐像素量：胶囊宽约 44pt、距右缘 8pt，再留 12pt 呼吸位。
    static let trailing: CGFloat = 64
}
#endif
