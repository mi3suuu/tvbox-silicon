import Foundation
import Testing
@testable import TVCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 播放器窗口几何：**任何输入下都不得越出容器**。
///
/// 用户报的现象是「横切竖的时候播放器越界」。根因不是某一条公式写错，而是
/// **两个数来自不同来源**，转屏那一刻不同步：
///   · `winY` 原来用 `OneSkin.fixedScreenSize()` 的屏幕高 —— `UIScreen.bounds`
///     在旋转动画期间仍报**旧方向**的值；
///   · `winH` 用列宽推 —— 列宽已经按新方向重算过了。
/// 于是「横切竖」的那几帧：winY 是横屏的小高度、winH 是竖屏的大高度，两者相加冲出容器。
///
/// 现在两个分支都只用容器自身的 `colW / colH`（同源同帧）。下面用**矩阵式**断言钉住：
/// 宽高从很小到很大、比例极端，窗口都必须完整落在容器内。

private func geometry(_ size: CGSize, landscape: Bool, fullScreen: Bool = false) -> OneSkinWindowGeometry {
    OneSkinWindowGeometry(size: size, landscape: landscape, fullScreen: fullScreen)
}

private func fitsWithin(_ window: OneSkinWindowGeometry, _ container: CGSize) -> Bool {
    let eps: CGFloat = 0.51          // 允许半点的取整误差
    guard window.winW <= container.width + eps else { return false }
    guard window.winH <= container.height + eps else { return false }
    guard window.winX >= -eps, window.winY >= -eps else { return false }
    guard window.winY + window.winH <= container.height + eps else { return false }
    guard window.winX + window.winW <= container.width + eps else { return false }
    return true
}

// MARK: - 竖屏

/// 竖屏在**任意容器尺寸**下都不越界 —— 这正是「横切竖」时容器先变小、后变正常的那条路径。
@Test func thePortraitWindowNeverLeavesItsContainer() {
    let sizes: [CGSize] = [
        CGSize(width: 80, height: 60),      // 极端：转屏动画的第一帧
        CGSize(width: 120, height: 100),
        CGSize(width: 320, height: 200),    // 转屏动画中：又窄又矮
        CGSize(width: 320, height: 480),
        CGSize(width: 320, height: 700),
        CGSize(width: 393, height: 500),    // 过渡帧
        CGSize(width: 430, height: 932),    // 正常竖屏手机
        CGSize(width: 669, height: 951),    // Duo 展开
        CGSize(width: 834, height: 1194),   // iPad 竖
        CGSize(width: 669, height: 240),    // 极端：容器比窗口需要的还矮
    ]
    for size in sizes {
        let g = geometry(size, landscape: false)
        #expect(fitsWithin(g, size), "竖屏越界 @ \(size) → winY=\(g.winY) winH=\(g.winH) colH=\(size.height)")
    }
}

/// 竖屏窗口不得越过容器底部的控件条区（留 6%）。
@Test func thePortraitWindowLeavesRoomForTheControlBar() {
    for height in [300.0, 500.0, 700.0, 951.0] as [CGFloat] {
        let size = CGSize(width: 430, height: height)
        let g = geometry(size, landscape: false)
        #expect(g.winY + g.winH <= height * 0.94 + 0.51,
                "底部压到控件条 @ h=\(height) → \(g.winY + g.winH) > \(height * 0.94)")
    }
}

/// 竖屏宽度必须满列宽 —— 版式约定，不能因为高度不够就缩窄。
@Test func thePortraitWindowIsAlwaysFullColumnWidth() {
    for height in [240.0, 500.0, 951.0] as [CGFloat] {
        let size = CGSize(width: 430, height: height)
        #expect(geometry(size, landscape: false).winW == 430)
    }
}

// MARK: - 横屏

/// 横屏同样在任意容器尺寸下不越界。
///
/// 重点是**顶边**：原公式 `usableH*centre - fittedH/2` 在 `fittedH` 接近 `usableH`
/// 时会算成负数，窗口顶跑到列外 —— 那就是「往上越界、顶部被切」。
@Test func theLandscapeWindowNeverLeavesItsContainer() {
    let sizes: [CGSize] = [
        // ⛔ 这一组是**回归的真正触发区**：容器高度小于 `minPictureHeight`(120) 时，
        // `fittedH` 被托到 120，而 `usableH*centre - fittedH/2` 会算成**负数**
        // —— 窗口顶跑到列外。我第一版测试最小只到 200，正好漏掉了它，
        // 拿旧公式回填跑仍然全绿（假阴性）。这一组补上之后，旧公式立刻挂。
        CGSize(width: 60, height: 60),
        CGSize(width: 80, height: 80),
        CGSize(width: 100, height: 60),
        CGSize(width: 120, height: 120),
        CGSize(width: 160, height: 100),
        CGSize(width: 200, height: 200),
        CGSize(width: 300, height: 400),
        CGSize(width: 480, height: 320),    // 正常横屏左列
        CGSize(width: 669, height: 951),
        CGSize(width: 600, height: 1200),   // 列很高
        CGSize(width: 500, height: 260),    // 容器比窗口需要的还矮
    ]
    for size in sizes {
        let g = geometry(size, landscape: true)
        #expect(fitsWithin(g, size), "横屏越界 @ \(size) → winY=\(g.winY) winH=\(g.winH) colH=\(size.height)")
    }
}

/// 横屏窗口顶不得为负（原公式的破点）。
@Test func theLandscapeWindowTopIsNeverNegative() {
    for height in [60.0, 80.0, 100.0, 120.0, 160.0, 200.0, 260.0, 320.0, 951.0] as [CGFloat] {
        let g = geometry(CGSize(width: 480, height: height), landscape: true)
        #expect(g.winY >= 0, "窗口顶为负 @ h=\(height) → winY=\(g.winY)")
    }
}

// MARK: - 同源约束（回归的根因）

/// **同一容器尺寸下，横竖两个分支的纵向占用都不得超过容器** —— 这条把「两个来源」
/// 的错法钉死：只要还有一个分支偷偷读 `UIScreen`，转屏的过渡帧就会露馅。
@Test func neitherBranchExceedsTheContainerForTheSameSize() {
    for w in [60.0, 100.0, 160.0, 280.0, 320.0, 393.0, 430.0, 669.0] as [CGFloat] {
        for h in [60.0, 100.0, 160.0, 200.0, 320.0, 480.0, 700.0, 951.0] as [CGFloat] {
            let size = CGSize(width: w, height: h)
            #expect(fitsWithin(geometry(size, landscape: false), size), "竖屏 @ \(w)x\(h)")
            #expect(fitsWithin(geometry(size, landscape: true), size), "横屏 @ \(w)x\(h)")
        }
    }
}

/// 窗口尺寸**与片源比例无关**（锁定约定，2026-11-13 焊死）。
///
/// ⛔ 这条测试原来的写法是「同一构造调两次、比较两个必然相等的结果」——恒真断言，
/// 无论实现是否依赖片源都通过。回归正是从这里漏出去的。
///
/// 现在分两层钉住：
///   ① **类型层**：构造器不收任何 aspect 参数（写了就编不过）；
///   ② **行为层**：窗口只由列宽决定 —— 同宽不同高的容器必须得到同样的 winW/winH。
///
/// ② 之所以不是恒真：曾经有实现用 `innerW / playerAspect` 算高，
/// 那样「同宽不同高」仍相等，但形状会跟着片源跑；所以再加一条显式版式断言。
@Test func theWindowGeometryIsIndependentOfSourceAspect() {
    // 同宽、不同高：窗口尺寸必须一模一样（高度只由宽度推导）。
    // ⛔ 只取「够高、不触发底部控件条夹取」的两档：容器极矮时窗口会被
    //    `controlBarRoom` 压扁，那是尺寸保护，不是片源影响。
    let widths: [CGFloat] = [466, 522, 669]
    for w in widths {
        for landscape in [true, false] {
            let a = geometry(CGSize(width: w, height: 700), landscape: landscape)
            let b = geometry(CGSize(width: w, height: 951), landscape: landscape)
            #expect(a.winW == b.winW && a.winH == b.winH,
                    "列宽 \(w) landscape=\(landscape) 时窗口尺寸随容器高变化：\(a.winW)x\(a.winH) vs \(b.winW)x\(b.winH)")
        }
    }

    // 横屏：画框形状恒等于版式常量 1.819（片源 9:16 也必须是它）。
    for w in [522.0, 951.0] as [CGFloat] {
        let g = geometry(CGSize(width: w, height: 669), landscape: true)
        #expect(abs(g.winW - w) < 1.01, "横屏画框应吃满列宽，实得 \(g.winW)（列 \(w)）")
        #expect(abs(g.winH - (w / OneSkinWindowGeometry.Metrics.windowAspect).rounded()) < 1.01,
                "横屏画框高度应为 列宽 ÷ 1.819，实得 \(g.winH)（列 \(w)）")
    }
}

/// 竖屏窗口的高度**只由列宽决定**（外屏 1.819 / 内屏 2.146），与容器高无关。
///
/// ⛔ 这条测试原来断言「窗口底必须够到控制条 y=353」（2026-11-11 的用户要求）。
/// 2026-11-13 作废，原因不是要求变了，而是那个实现选了**错的表达方式**：
/// 它用「控制条位置」反推窗高，于是同一块屏在不同容器高下算出不同窗高
///（466 宽：289 / 266；669 宽：323 / 439），窗口高度跟着转屏动画一起胀缩。
///
/// 「到控制条上方」现在由**画面列高度**表达（`pictureHeightOf` = 顶边 + 窗高 + 呼吸位），
/// 胶囊条贴画面列下沿 —— 窗高本身必须恒等于 `列宽 ÷ 版式比例`。
@Test func thePortraitWindowKeepsTheFixedFrameHeight() {
    // 外屏竖持 466×678：窗高 = 466 ÷ 1.819 ≈ 256，与容器高无关。
    for h in [678.0, 951.0] as [CGFloat] {
        let g = geometry(CGSize(width: 466, height: h), landscape: false)
        #expect(abs(g.winH - (466 / OneSkinWindowGeometry.Metrics.windowAspect).rounded()) < 1.01,
                "外屏窗高应为 466÷1.819≈256，实际 \(g.winH)（容器高 \(h)）")
    }
    // 内屏竖持 669：走专属 2.146。
    let inner = geometry(CGSize(width: 669, height: 951), landscape: false)
    #expect(abs(inner.winH - (669 / OneSkinWindowGeometry.Metrics.portraitWindowAspectLarge).rounded()) < 1.01,
            "内屏窗高应为 669÷2.146≈312，实际 \(inner.winH)")
    // 无论多高，窗口都不许压到底部控件条。
    for h in [300.0, 500.0, 678.0, 951.0] as [CGFloat] {
        let g = geometry(CGSize(width: 466, height: h), landscape: false)
        #expect(g.winY + g.winH <= h * 0.94 + 0.51, "窗口压到控件条 @ h=\(h)")
    }
}

// MARK: - 竖屏顶边留白必须按**屏幕高**算

/// 竖屏单列时那一列的高度只是「画面区高度」，不是屏高。
///
/// 因此窗口顶边不能再用 `colH × 0.091` —— 那是画面区高度的 9.1%，
/// 比「屏幕高度的 9.1%」小一大截，窗口整体上移，顶栏压进灵动岛/挖孔。
/// 调用方把正确值（`屏高 × 0.091`）显式传进来后，窗口顶边必须**等于它**。
@Test func thePassedTopInsetIsHonouredExactly() {
    for (screen, picH) in [(CGSize(width: 466, height: 678), 435.0),
                           (CGSize(width: 669, height: 951), 615.0)] {
        let wantedTop = screen.height * OneSkinWindowGeometry.Metrics.portraitTop
        let g = OneSkinWindowGeometry(size: CGSize(width: screen.width, height: picH),
                                      landscape: false, fullScreen: false,
                                      portraitTopInset: wantedTop)
        #expect(abs(g.winY - wantedTop) < 0.51,
                "顶边没用传入值：\(g.winY) ≠ \(wantedTop)（\(screen)）")
        // 旧公式给的是画面区高度的 9.1%，明显更小 —— 这就是上移量。
        let oldTop = picH * OneSkinWindowGeometry.Metrics.portraitTop
        #expect(g.winY > oldTop + 1, "新顶边没有下移，等于没修（\(g.winY) vs 旧 \(oldTop)）")
        // 无论怎么下移，窗口都不许溢出这一列。
        #expect(fitsWithin(g, CGSize(width: screen.width, height: picH)),
                "顶边下移后越界：winY=\(g.winY) winH=\(g.winH) colH=\(picH)")
    }
}

/// 不传时不改变老行为（全屏 / 双列 / 其它调用点都不受影响）。
@Test func withoutAnInsetTheOldFormulaStands() {
    let size = CGSize(width: 466, height: 435)
    let withNil = OneSkinWindowGeometry(size: size, landscape: false, fullScreen: false)
    let explicitOld = OneSkinWindowGeometry(size: size, landscape: false, fullScreen: false,
                                            portraitTopInset: 435 * OneSkinWindowGeometry.Metrics.portraitTop)
    #expect(abs(withNil.winY - explicitOld.winY) < 0.01)
}

/// 极端矮容器 + 大顶边：宁可把窗口压扁，也不许顶出列底。
@Test func anOversizedInsetSquashesInsteadOfOverflowing() {
    let size = CGSize(width: 300, height: 200)
    let g = OneSkinWindowGeometry(size: size, landscape: false, fullScreen: false,
                                  portraitTopInset: 180)
    #expect(fitsWithin(g, size), "大顶边把窗口顶出容器：winY=\(g.winY) winH=\(g.winH)")
}

// MARK: - 全屏必须跟随当前方向（横竖都能全屏）

/// 全屏窗口 = 容器全幅，因此**横竖两个方向都必须铺满**。
///
/// 用户要求「全屏也要能横屏也能竖屏」。此前的实现里全屏用的是
/// `frozenBox`（按页面形态冻结的静态盒），它不跟旋转走：
/// 外屏竖持进全屏后转横，盒仍是 466×678 → 横屏里两侧各露 106pt 黑边。
/// 现在全屏直接吃根部可视区，下面把两个方向都钉住。
@Test func fullScreenFillsBothOrientations() {
    // 外屏：竖 466×678 / 横 678×466
    for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466),
                 // 内屏：竖 669×951 / 横 951×669
                 CGSize(width: 669, height: 951), CGSize(width: 951, height: 669)] {
        let g = OneSkinWindowGeometry(size: size, landscape: size.width > size.height,
                                      fullScreen: true)
        #expect(g.winX == 0 && g.winY == 0, "全屏窗口没贴到原点 @ \(size)")
        #expect(abs(g.winW - size.width) < 0.51, "全屏宽没铺满 @ \(size)：\(g.winW)")
        #expect(abs(g.winH - size.height) < 0.51, "全屏高没铺满 @ \(size)：\(g.winH)")
    }
}

/// 而且是**逐方向对称**的：同一块屏转个方向，窗口尺寸必须跟着换过来。
///
/// 这条专门防「用冻结盒」复发 —— 那种写法下两个方向会返回同一个尺寸。
@Test func fullScreenIsSymmetricAcrossAQuarterTurn() {
    let upright = CGSize(width: 466, height: 678)
    let sideways = CGSize(width: 678, height: 466)
    let a = OneSkinWindowGeometry(size: upright, landscape: false, fullScreen: true)
    let b = OneSkinWindowGeometry(size: sideways, landscape: true, fullScreen: true)
    #expect(a.winW != b.winW, "转屏后全屏宽没变，说明用了冻结尺寸")
    #expect(a.winH != b.winH, "转屏后全屏高没变，说明用了冻结尺寸")
    #expect(a.winW == upright.width && b.winW == sideways.width)
}

// MARK: - 全出血形态：画面列高度只由列宽决定（BUG-K / 2026-11-13 收敛）

/// 画面列高度 = 列宽 ÷ 16:9 版式常量，**与片源无关**。
///
/// 历史：这里曾有第三份公式拷贝（`size.width / aspect` 夹 `size.height*0.56`），
/// 于是「单测绿、App 里另一份实现是红」——测试测的不是产品代码。
/// 现在 App 只调 `OneSkinWindowGeometry.fullBleedPictureColumnHeight`，测的也是它。
@Test func theFullBleedColumnHeightComesFromTheLayoutConstantOnly() {
    for w in [466.0, 669.0, 951.0] as [CGFloat] {
        let h = OneSkinWindowGeometry.fullBleedPictureColumnHeight(columnWidth: w)
        #expect(abs(h - (w / OneSkinWindowGeometry.fullBleedColumnAspect).rounded()) < 1.01,
                "画面列高应为 列宽 ÷ \(OneSkinWindowGeometry.fullBleedColumnAspect)，实得 \(h)（列 \(w)）")
    }
    // 669 宽的实测值（参考截图量测 376.3）。
    #expect(abs(OneSkinWindowGeometry.fullBleedPictureColumnHeight(columnWidth: 669) - 376) < 1.01)
}

/// 极小列宽也不许塌成 0（否则 capsule/详情列按 0 排）。
@Test func theFullBleedColumnHeightHasAFloor() {
    for w in [1.0, 20.0, 100.0] as [CGFloat] {
        #expect(OneSkinWindowGeometry.fullBleedPictureColumnHeight(columnWidth: w)
                >= OneSkinWindowGeometry.Metrics.minPictureHeight)
    }
}

// MARK: - 竖屏源在展开横持双栏下的窗口尺寸（用户报「只有海报」的回归锁）

/// 展开横持 951×669 时播放器列宽 522 —— 窗口必须吃满列宽、形状固定。
///
/// ⛔⛔ 2026-11-13 结论翻转：这两条测试此前断言的是「窗口跟随片源比例」
///（竖源 ≈371×659、宽度 <450、高度 >600），**那是被推翻的设计**。
///
/// 作者当时把病因判反了：真正让用户看到「只有海报」的**正是 371×659 这个形状**
///（winW 只占列宽 71%、winH 占列高 98.5%、winY 被夹到 0）。左列于是变成
/// 「窄高条 + 29% 压暗海报底」，与「只剩海报」的现象完全吻合。
///
/// 现在这条测试连片源参数都传不进来（构造器不收），只能钉「画框」本身；
/// 「片源不许影响画框」由构造器的类型签名 + `theWindowGeometryIsIndependentOfSourceAspect` 保证。
@Test func theDualColumnKeepsTheFixedWindowShape() {
    let g = OneSkinWindowGeometry(size: CGSize(width: 522, height: 669),
                                  landscape: true,
                                  fullScreen: false)
    // 窗口形状 = 版式常量 1.819。
    #expect(abs(g.winW / g.winH - OneSkinWindowGeometry.Metrics.windowAspect) < 0.02,
            "窗口比例应为固定版式 1.819，实得 \(g.winW)x\(g.winH)=\(g.winW / g.winH)")
    // 宽度吃满列宽：绝不允许再出现「71% 窄条」。
    #expect(abs(g.winW - 522) < 2, "窗口必须吃满列宽，实得 \(g.winW)")
    // 高度必须留在列高一半附近，绝不能撑满整列（那是「压暗海报底」的来源）。
    #expect(g.winH < 350, "窗口高不得接近列高（列 669），实得 \(g.winH)")
    // 垂直居中，不得顶到屏幕最上沿。
    #expect(g.winY > 100, "winY 不得为 0（顶到屏幕顶），实得 \(g.winY)")
}
