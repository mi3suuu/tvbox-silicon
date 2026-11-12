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

/// 窗口尺寸**与片源比例无关**（锁定约定）：构造器不接受任何 aspect 参数，
/// 这条断言用「同尺寸两次构造必须完全相等」表达。
@Test func theWindowGeometryIsIndependentOfSourceAspect() {
    let size = CGSize(width: 430, height: 700)
    let a = geometry(size, landscape: false)
    let b = geometry(size, landscape: false)
    #expect(a.winW == b.winW && a.winH == b.winH && a.winX == b.winX && a.winY == b.winY)
}

/// 竖屏窗口的**下沿落在播放器控制条上沿**（用户明确要求，2026-11-11）。
///
/// ⛔ 这里原来断言的是「窗口保持版式比例 1.819」，2026-11-12 已作废：
///
/// 用户的原话是「视频满宽、下移到避开摄像头、**长度到控制条上方**」
/// （`RULES.md` §七，标注为「覆盖真机」）。按那条要求，竖屏窗口的**高度**
/// 由「顶边到控制条上沿」决定，比例只是副产品 —— 外屏 466×678 实测
/// 控制条 y=353、顶边 y≈43，于是 winH≈310，比例约 1.5，本来就不是 1.819。
///
/// 1.819 是 One 的**横屏**版式比例（1015×558 px）。把它套到竖屏，
/// 在 430×932 这种高屏上算出的窗口只有 236pt 高，会**把画面压得很扁**、
/// 底部空出一大片 —— 那正好是用户要求「长度到控制条上方」想避免的。
///
/// 所以现在守的是真正的要求：**窗口下沿不低于控制条上沿**（在小屏绝对坐标下），
/// 并且**不越出容器**（后者由 `thePortraitWindowNeverExceedsItsContainer` 覆盖）。
@Test func thePortraitWindowReachesDownToTheControlBar() {
    // 外屏竖持（真机基准 466×678）：控制条在 y=353，窗口底必须够到它，
    // 否则画面下方留出一条空白，而用户的诉求正是「长度到控制条上方」。
    let outer = geometry(CGSize(width: 466, height: 678), landscape: false)
    #expect(abs(outer.winY + outer.winH - 353) < 1.0,
            "窗口底应落在控制条上沿 y=353，实际 \(outer.winY + outer.winH)")

    // 更宽的容器（内屏/Duo 展开）按容器高度比例取控制条位置，同样要够到。
    let inner = geometry(CGSize(width: 669, height: 951), landscape: false)
    #expect(inner.winY + inner.winH >= 951 * 0.553 - 1.0,
            "内屏窗口应够到比例化的控制条位置")
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

// MARK: - 全出血形态：画面高度与胶囊条必须同源（BUG-K）

/// 画面列高度按片源比例算，胶囊条底距必须用**同一个**高度。
///
/// 修复前胶囊条按固定的 `0.56 × 整高` 反推，而画面早已改成按片源比例：
/// 669×951 放 16:9 片源时画面只有 376.3pt，胶囊条却按 532.6pt 算，
/// 下沿低了 145pt，扎进详情区。竖片恰好撞上限所以看不出问题 —— 这就是它长期漏检的原因。
private func bleedingPictureHeight(_ size: CGSize, aspect: CGFloat,
                                   lower: CGFloat, upper: CGFloat) -> CGFloat {
    let a = (aspect.isFinite && aspect > 0.2 && aspect < 6) ? aspect : 16.0 / 9.0
    return min(max(size.width / a, size.height * lower), size.height * upper)
}

/// 胶囊条底距必须随片源比例变化 —— 这正是「同源」的可观测判据。
///
/// 修复前它对所有片源返回同一个常数；修复后四种片源给出四个不同值。
@Test func theControlBarFollowsThePictureHeightNotAFixedRatio() {
    let box = CGSize(width: 669, height: 951)
    let aspects: [CGFloat] = [16.0 / 9, 4.0 / 3, 9.0 / 16, 2.35]
    let bottoms = aspects.map { aspect -> CGFloat in
        let picH = bleedingPictureHeight(box, aspect: aspect, lower: 0.28, upper: 0.56)
        return box.height - (picH * 0.928 - 13 - 8)
    }
    #expect(Set(bottoms.map { Int($0.rounded()) }).count == aspects.count,
            "四种片源应给出四个不同底距，实际：\(bottoms)")
}

/// 16:9 的具体数值：修复前 477.8，修复后 622.8，差 145pt。
@Test func theWideAspectCaseMatchesTheHandComputedValue() {
    let box = CGSize(width: 669, height: 951)
    let picH = bleedingPictureHeight(box, aspect: 16.0 / 9, lower: 0.28, upper: 0.56)
    #expect(abs(picH - 376.3) < 0.5, "16:9 画面列高度应为 376.3，实际 \(picH)")
    let bottom = box.height - (picH * 0.928 - 13 - 8)
    #expect(abs(bottom - 622.8) < 0.5, "胶囊条底距应为 622.8，实际 \(bottom)")
    // 旧公式在同一输入下给 477.8 —— 两者必须不同，否则修复无效。
    let oldBottom = box.height - (box.height * 0.56 * 0.928 - 13 - 8)
    #expect(abs(oldBottom - bottom) > 100, "新旧公式必须拉开距离（旧 \(oldBottom)）")
}

/// 竖片撞上限：新旧公式在这一档**本来就应该相同**，不能当成回归。
@Test func aPortraitSourceSitsAtTheUpperBoundEitherWay() {
    let box = CGSize(width: 669, height: 951)
    let picH = bleedingPictureHeight(box, aspect: 9.0 / 16, lower: 0.28, upper: 0.56)
    #expect(abs(picH - box.height * 0.56) < 0.5, "竖片应被上限压住")
}

/// 画面列高度永远不越出整高，胶囊条底距永远为正。
@Test func theBleedingHeightStaysInsideAndTheBarStaysOnScreen() {
    let aspects: [CGFloat] = [0.3, 4.0 / 3, 16.0 / 9, 2.35]
    let boxes = [CGSize(width: 669, height: 951), CGSize(width: 466, height: 678),
                 CGSize(width: 951, height: 669)]
    for box in boxes {
        for aspect in aspects {
            let picH = bleedingPictureHeight(box, aspect: aspect, lower: 0.28, upper: 0.56)
            #expect(picH > 0 && picH <= box.height + 0.01, "画面列越界：\(picH) / \(box)")
            let bottom = box.height - (picH * 0.928 - 13 - 8)
            #expect(bottom >= 8, "胶囊条底距为负：\(bottom)")
        }
    }
}
