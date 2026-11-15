import SwiftUI
import TVCore

#if os(iOS)
// MARK: - 播放器控件布局（设置 › 播放 › 播放器控件）
//
// ## 这一页为什么重写
//
// 旧版是三份独立配置（外屏 / 展开竖持 / 展开横持），顶部先选形态再一份一份地排，
// 外加两张各 27 行的「直接显示」开关表。实际后果：
//   ① 用户在外屏那份里排好，播放器正在横持 ⇒ 读的是另一份 ⇒「改了完全没反应」；
//   ② 同一件事要为三个形态各做一遍 ⇒「很乱」；
//   ③ 开关表和槽位是两个与条件，只满足一个就什么也不出现 ⇒「设置了不生效」。
//
// 现在的规则只有三条：
//   1. **一份排布**，三种形态共用。屏幕放不下的自动收进「更多」，宽屏时自动回来。
//   2. **两个列表、拖拽排序**：上面一行是画面顶部的控件，下面一行是进度条那一条。
//      进度条、时间码、剩余时间本身就是这一行里的普通条目 —— 与按钮一样可挪、可删。
//   3. **下面添加**：没放上去的控件按「更多」面板的真实分组列在下方，点 ＋ 加回去。
struct PlayerControlsSettingsView: View {
    @AppStorage(PlayerControlsLayout.storageKey)
    private var stored = PlayerControlsLayout.standard.stored

    /// 顶栏**槽位**（含空格）。空格是位置，不是空位 —— 拖到第 7 格就留在第 7 格。
    @State private var topSlots: [PlayerControl?] = PlayerControlsLayout.current.topSlots
    /// 底栏（进度那一行）槽位，同上。
    @State private var bottomSlots: [PlayerControl?] = PlayerControlsLayout.current.bottomSlots
    /// 只看预览用的形态选择器 —— 不影响配置。
    @State private var previewShape: PlayerControlsLayout.Shape = Self.initialPreviewShape
    /// 正在问「放回哪一行」的控件：两边都能放的才需要问。
    @State private var addingTo: PlayerControl?

    /// 预览默认看横持（配置最满的那个形态）。
    /// `-qaPreviewShape unfolded` 可预选，供无输入设备的截图 QA 用。
    private static var initialPreviewShape: PlayerControlsLayout.Shape {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "qaPreviewShape"),
           let shape = PlayerControlsLayout.Shape(rawValue: raw) {
            return shape
        }
        #endif
        return .sideways
    }

    private var layout: PlayerControlsLayout { PlayerControlsLayout(stored: stored) }

    /// 顶栏里**实际有控件**的那些（列表区展示用；空格是预览里的事，不占列表行）。
    private var topOrder: [PlayerControl] { topSlots.compactMap { $0 } }
    /// 底栏同上。
    private var bottomOrder: [PlayerControl] { bottomSlots.compactMap { $0 } }

    /// 预览用的布局：**由两段列表的状态数组拼出来**，不读存储。
    ///
    /// 拖动过程中每移动一格都让图片重画一次（"所见即所得"），如果每次读存储，
    /// 等于每帧写一次 UserDefaults；拼一份只读布局既不会落盘，也和列表共用同一份事实。
    private var liveLayout: PlayerControlsLayout {
        PlayerControlsLayout(topSlots: topSlots, bottomSlots: bottomSlots, more: layout.more)
    }

    var body: some View {
        SettingsPage(title: L10n.text("Player Controls"), symbol: "slider.horizontal.3") {
            if PlaySkin.current == .bilibili {
                SettingsGroup(footer: L10n.text("This layout applies to the Original and One skins. The Bilibili skin keeps its own built-in arrangement — customise it from Customize Menu inside its More panel.")) {
                    FormLabel(symbol: "info.circle.fill", tint: .orange,
                              title: L10n.text("Not used by the Bilibili skin"))
                }
            }


            // ── 预览（按真实形态 1:1 画，再整体缩放；图里的控件可以直接拖）──
            SettingsGroup(footer: L10n.text("Drawn at the real size of each screen, so what you see is what the player draws. Switching the shape only changes the preview — there is one layout for all three.")) {
                PlayerControlsPreviewCard(layout: liveLayout, shape: $previewShape,
                                          move: moveInPicture, commit: commitPictureDrag)
                    .listRowInsets(EdgeInsets())
            }

            // ── 顶栏 ──
            orderSection(
                title: L10n.text("Top Bar"),
                controls: topOrder,
                footer: L10n.text("Drag to reorder. A screen too narrow for all of them moves the rest into More instead of dropping them."),
                apply: applyTopOrder
            )

            // ── 底栏（进度那一行）──
            orderSection(
                title: L10n.text("Progress Row"),
                controls: bottomOrder,
                footer: L10n.text("Play, ±10 seconds and the episode keys sit in the middle of the picture; everything else lines up along the progress bar, in this order — the progress bar itself included. The Original skin keeps its own fixed progress row, so only the buttons move there."),
                apply: applyBottomOrder
            )

            // ── 加回来：按「更多」面板的真实分组 ──
            ForEach(PlayerControl.capabilityGroups) { group in
                let available = group.controls.filter { !topOrder.contains($0) && !bottomOrder.contains($0) }
                if !available.isEmpty {
                    SettingsGroup(title: group.title) {
                        ForEach(available) { control in
                            addRow(control)
                        }
                    }
                }
            }

            // ── 固定不动的两处（说明，不是可调项）──
            //
            // 这两颗如果也做成可移除，用户就会把自己锁死：
            //   · 「更多」是放不下的控件的唯一去处，收掉它那些控件就再也点不到；
            //   · 「退出全屏」是全屏态唯一的出口（全屏里「更多」整个收掉了）。
            // 所以它们不在上两张表里，而是作为**结构位**常在；写在这里是为了
            // 回答「播放器上还有哪些东西没出现在设置页」——不能靠猜。
            SettingsGroup(title: L10n.text("Fixed Keys"),
                          footer: L10n.text("These cannot be moved or removed: More is the only way back for whatever did not fit, Exit Full Screen is the only way out of full screen, and the lock key is the only way to unlock the controls again.")) {
                FormLabel(symbol: "ellipsis", tint: .gray,
                          title: L10n.text("More (…) — top right"))
                FormLabel(symbol: "chevron.left", tint: .gray,
                          title: L10n.text("Exit Full Screen — top left, full screen only"))
                FormLabel(symbol: "lock.open", tint: .gray,
                          title: L10n.text("Lock Controls — top right"))
            }

            if PlayerControlsLayout.hasOwnConfiguration {
                SettingsGroup {
                    Button(role: .destructive) {
                        PlayerControlsLayout.reset()
                        let fresh = PlayerControlsLayout.standard
                        stored = fresh.stored
                        topSlots = fresh.topSlots
                        bottomSlots = fresh.bottomSlots
                    } label: {
                        Label(L10n.text("Reset to Default"), systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        // 拖拽排序靠 List 自带的 `onMove`，而它只在编辑态下露出把手。
        // ⚠️ 这一行必须挂在**整页**（也就是 Form）上：editMode 是被 List 从自己环境里读的，
        // 挂在 Section 上写的是 List 的子节点，读不到 —— 那正是上一版「写着能拖、实际拖不动」。
        .environment(\.editMode, .constant(.active))
        .confirmationDialog(addTitle, isPresented: isAdding, titleVisibility: .visible) {
            if let control = addingTo {
                ForEach(control.placements, id: \.self) { placement in
                    Button(placement.title) { add(control, to: placement) }
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) { addingTo = nil }
        }
    }

    private var addTitle: String {
        guard let control = addingTo else { return "" }
        return L10n.text("Where does %@ go?", control.title)
    }

    private var isAdding: Binding<Bool> {
        Binding(get: { addingTo != nil }, set: { if !$0 { addingTo = nil } })
    }

    // MARK: 行

    /// 一个可拖拽排序的列表段。
    ///
    /// ## 为什么是 `onMove`，不是 `draggable` + `dropDestination`
    ///
    /// 上一版用的是 `.draggable(字符串)` 落 `.dropDestination`。实测症状：行提得起来，
    /// 松手什么都不发生 —— 目标行的 `dropDestination` 一次也没回调。`Form`（= `List`）
    /// 自己有托放与滚动的一整套 hit test，行内自建的 `Transferable` 落点在里面并不可靠，
    /// 而重排本来就有系统实现，没理由自己再写一套。
    ///
    /// 现在用 List 自己的 `onMove`（与「标签栏编辑」「测速源排序」同一套）：编辑态下
    /// 每行尾部出现真正的拖拽把手，手感由系统给。
    /// 编辑态由整页 `editMode` 打开，见 `body` 末尾那条注释。
    @ViewBuilder
    private func orderSection(title: String,
                              controls: [PlayerControl],
                              footer: String,
                              apply: @escaping ([PlayerControl]) -> Void) -> some View {
        SettingsGroup(title: title, footer: footer) {
            if controls.isEmpty {
                Text(L10n.text("Nothing here yet — add one below."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(controls) { control in
                orderRow(control) {
                    var updated = controls
                    updated.removeAll { $0 == control }
                    apply(updated)
                }
            }
            .onMove { source, destination in
                var updated = controls
                updated.move(fromOffsets: source, toOffset: destination)
                apply(updated)
            }
        }
    }

    /// 一行：图标 + 名称（+ 装不下/只在某形态可用的说明）+ 行尾「收进更多」。
    ///
    /// 拖拽把手由 List 在编辑态下补在行尾，这里不再自己画一个 ——
    /// 两个把手并排只会让人不知道该抓哪个。
    private func orderRow(_ control: PlayerControl, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ControlChip(control: control)
            VStack(alignment: .leading, spacing: 1) {
                Text(control.title).font(.subheadline)
                if let note = control.availabilityNote {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Move %@ to More", control.title))
        }
        .padding(.vertical, 3)
    }

    /// 「加回来」的一行：每一个落点都是它**真正画得出来**的位置。
    ///
    /// 用按钮 + 确认面板，不用 `Menu`：这一页常驻编辑态（`onMove` 需要），
    /// 行内 `Menu` 的弹出依赖行点击，容易与 List 的编辑手势重叠；
    /// 按钮 + 面板两条路都不经过行点击，编辑态开着也照常。
    /// 只有一个落点的控件（绝大多数）连面板都不弹，点一下直接回去。
    private func addRow(_ control: PlayerControl) -> some View {
        HStack(spacing: 12) {
            ControlChip(control: control)
            VStack(alignment: .leading, spacing: 1) {
                Text(control.title).font(.subheadline)
                if let note = control.availabilityNote {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                if control.placements.count == 1, let only = control.placements.first {
                    add(control, to: only)
                } else {
                    addingTo = control
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(L10n.text("Add %@", control.title))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: 写盘

    /// 把控件放回它选定的那一行（追加在末尾，之后可以拖到位）。
    private func add(_ control: PlayerControl, to placement: PlayerControl.Placement) {
        var updated = PlayerControlsLayout(stored: stored)
        updated.add(control, to: placement)
        topSlots = updated.topSlots
        bottomSlots = updated.bottomSlots
        stored = updated.stored
        addingTo = nil
    }

    /// 列表里的「拖拽排序」：把这一行的**非空控件**按新顺序重排，空的格子保留在原位。
    ///
    /// 走列表拖拽时用户表达的是「先后」，不是「第几格」；所以仍然按顺序语义换算，
    /// 但落点用**原来那些非空格子**，不会把整行压到左边。
    private func applyTopOrder(_ order: [PlayerControl]) {
        applyOrder(order, isTop: true)
    }

    private func applyBottomOrder(_ order: [PlayerControl]) {
        applyOrder(order, isTop: false)
    }

    private func applyOrder(_ order: [PlayerControl], isTop: Bool) {
        let source = isTop ? topSlots : bottomSlots
        // 非空格子的下标（这些位置被重新填上 order 里的控件，一个不多一个不少）。
        let cells = source.indices.filter { source[$0] != nil }
        var updated = isTop ? source : source
        // 先把这一行的非空全清掉，再按 order 填回原来那些格子。
        for index in cells { updated[index] = nil }
        for (offset, control) in order.enumerated() {
            if offset < cells.count { updated[cells[offset]] = control }
        }
        // order 比原来的非空格子多（加了新控件）：接在第一个空槽，没有就追加。
        if order.count > cells.count {
            for control in order.dropFirst(cells.count) {
                updated = SlotBoard.appending(control, to: updated)
            }
        }
        if isTop { setTopSlots(updated) } else { setBottomSlots(updated) }
    }

    /// 写盘（预览拖动与列表操作共用这一条）。
    private func setTopSlots(_ slots: [PlayerControl?]) {
        var updated = PlayerControlsLayout(stored: stored)
        updated.setTopSlots(slots)
        topSlots = updated.topSlots
        bottomSlots = updated.bottomSlots
        stored = updated.stored
    }

    private func setBottomSlots(_ slots: [PlayerControl?]) {
        var updated = PlayerControlsLayout(stored: stored)
        updated.setBottomSlots(slots)
        topSlots = updated.topSlots
        bottomSlots = updated.bottomSlots
        stored = updated.stored
    }

    // MARK: 在图里直接拖（拖的是坐标，落点吸附到格子）

    /// 预览里把控件拖到**某一格**：只改状态数组，**不落盘**。
    ///
    /// ## 为什么不再是「插在谁前面」
    ///
    /// 旧实现收的是 `(控件, 目标行, 插在谁前面)` —— 用户拖到哪都只影响「先后」，
    /// 于是视觉上控件自己跑掉：它被塞进邻居之间，x 由前面所有控件累计宽度决定。
    /// 现在收的是 `(控件, 目标行, 目标格下标)`，**第几格就是第几格**，
    /// 用户拖到第 7 格松手，它就落在第 7 格（`SlotBoard.assign` 负责空槽保真）。
    private func moveInPicture(_ control: PlayerControl,
                               to row: PlayerControl.Placement,
                               slot: Int) {
        var top = topSlots, bottom = bottomSlots
        // 先从两行里摘掉它自己（拖回原位时下面会重新写入）。
        top = top.map { $0 == control ? nil : $0 }
        bottom = bottom.map { $0 == control ? nil : $0 }

        var target = (row == .topBar) ? top : bottom
        let index = min(max(slot, 0), PlayerControlsLayout.slotCount - 1)
        // 铺到目标格：不够长就补空格，**不压缩**已有位置。
        while target.count <= index { target.append(nil) }
        // 目标格原有的那颗被顶开到第一个空槽（不是丢掉）。
        if let displaced = target[index], displaced != control {
            target[index] = nil
            target = SlotBoard.appending(displaced, to: target)
        }
        target[index] = control

        if row == .topBar { top = target } else { bottom = target }
        // 每帧都会调；顺序没变就别写状态，免得整页每秒重绘几十遍。
        guard top != topSlots || bottom != bottomSlots else { return }
        topSlots = top
        bottomSlots = bottom
    }

    /// 手指离开：把槽位落成一次写入（含 `assertComplete`）。
    ///
    /// 走 `setTopSlots` / `setBottomSlots` 而不是 `setTopOrder`：后者会把空格压实，
    /// 于是「拖到第 7 格」在落盘那一刻又变回第 1 格 —— 拖动期间对、松手就错位。
    private func commitPictureDrag() {
        var updated = PlayerControlsLayout(stored: stored)
        updated.setTopSlots(topSlots)
        updated.setBottomSlots(bottomSlots)
        topSlots = updated.topSlots
        bottomSlots = updated.bottomSlots
        stored = updated.stored
    }
}

// MARK: - 预览卡

private struct PlayerControlsPreviewCard: View {
    let layout: PlayerControlsLayout
    @Binding var shape: PlayerControlsLayout.Shape
    /// 在画面上拖动控件：`(控件, 目标行, 目标格下标)`。
    let move: (PlayerControl, PlayerControl.Placement, Int) -> Void
    /// 手指离开时落盘。
    let commit: () -> Void

    /// 预览画面的高度上限（见调用处的注释）。
    static let previewMaxHeight: CGFloat = 360

    /// 1:1 实际尺寸模式。
    ///
    /// 默认关（缩到卡片里看得全）；打开后预览按**设备真实点数**画，可双指缩放、单指拖动画面。
    /// 这是「精准摆放」的前提：横持 951pt 的窗口塞进 330pt 的卡片只有 0.35 倍，
    /// 一颗 13pt 的图标画出来 4.5pt —— 靠眼睛对不准，拖也拖不准。
    @State private var oneToOne: Bool = {
        // `-qaOneToOne 1` 直接以 1:1 模式打开 —— 无输入设备的真机截图/自证日志需要它，
        // 否则这个开关永远只能在模拟器上用手点开。
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "qaOneToOne")
        #else
        return false
        #endif
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $shape) {
                ForEach(PlayerControlsLayout.Shape.allCases, id: \.self) { shape in
                    Text(shape.title).tag(shape)
                }
            } label: {
                Text(L10n.text("Preview"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)

            // 高度封顶 360：竖持形态按真实比例铺满宽度要 727pt（466:678），
            // 整张卡比一屏还高，一进来就得先滚过它才碰得到任何一项可调的东西。
            // 封顶后竖持会缩成一块居中的窄屏 —— 版式仍然 1:1，只是整体更小。
            if oneToOne {
                // 1:1：真尺寸 + 可缩放可平移，摆位置时看得清每一格。
                PlayerShapePreview(shape: shape, layout: layout, move: move, commit: commit,
                                   fixedScale: 1, panZoom: true)
                    .frame(height: PlayerControlsPreviewCard.previewMaxHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                PlayerShapePreview(shape: shape, layout: layout, move: move, commit: commit)
                    .frame(maxHeight: PlayerControlsPreviewCard.previewMaxHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
            }

            Toggle(isOn: $oneToOne) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Actual size (1:1)")).font(.footnote)
                    Text(L10n.text("Draws the player at the screen's real points — pinch to zoom, drag the picture to pan."))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            // 这一行是**操作提示**，不是装饰：拖动只认长按 0.25 秒后的手势，
            // 不写出来没人会去试（而且直接拖会被页面的滚动吃掉，用户会以为坏了）。
            Label(L10n.text("Press a control in the picture, then drag it — the lists below follow."),
                  systemImage: "hand.draw")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 10)

            fitSummary
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 14)
        }
    }

    private var fit: PlayerControlsFit { PlayerControlsFit(layout: layout, shape: shape) }

    /// 一行说清「这块屏装得下几颗、几颗进了更多」。
    private var fitSummary: some View {
        let fit = self.fit
        return HStack(spacing: 12) {
            stat(L10n.text("Top"), value: fit.top.count)
            stat(L10n.text("Middle"), value: fit.center.count)
            stat(L10n.text("Bottom"), value: fit.edge.count)
            stat(L10n.text("More"), value: fit.moreCount)
            Spacer(minLength: 0)
            if !fit.overflow.isEmpty {
                Label(L10n.text("%lld moved to More", fit.overflow.count),
                      systemImage: "arrow.down.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func stat(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(value == 0 ? Color.secondary : Color.primary)
            Text(title).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 「装得下几颗」的真实计算

/// 与 `OneSkinPlayerChrome` 同一套容量规则，供预览与小结共用。
struct PlayerControlsFit {
    let top: [PlayerControl]
    let center: [PlayerControl]
    let edge: [PlayerControl]
    let overflow: [PlayerControl]
    let moreCount: Int

    init(layout: PlayerControlsLayout, shape: PlayerControlsLayout.Shape) {
        let window = PlayerShapeGeometry.windowSize(for: shape)
        let m = PreviewMetrics(size: window)

        // 顶栏按**格子**数容量（与播放器同一口径：`OneSkinChrome.topSurfaceCapacity`）。
        //
        // 两处差异是刻意的，都往「更保守」的方向偏，不会让预览比播放器画得多：
        //   · 播放器用 `barLeading + barTrailing`（含安全区），预览这里只能取 `m.edge`
        //     —— 设置页里量不到播放器那一帧的安全区；
        //   · `structural` 取 4 = 选集页（旋转 / 合拢 / 更多 / 锁定），
        //     全屏态是 2 —— 全屏不在预览范围内。
        let topCapacity = max(0, Int((window.width - m.edge * 2 - CGFloat(4) * m.hit) / m.hit))
        top = Array(layout.topSlots.prefix(topCapacity)).compactMap { $0 }

        let centerAll = layout.bottom.filter { PlayerControl.centerControls.contains($0) }
        let edgeAll = layout.bottom.filter { !PlayerControl.centerControls.contains($0) }

        let centerCapacity = max(1, Int((window.width - 2 * m.edge) / max(m.stepHit, 1)))
        let reserve = m.caption * 15 + m.hit + 120
        let edgeCapacity = max(1, Int(max(0, window.width - 2 * m.edge - reserve) / max(m.hit, 1)))

        center = Array(centerAll.prefix(centerCapacity))

        var fixed = 0
        var shown: [PlayerControl] = []
        for control in edgeAll {
            if control == .progressBar { shown.append(control); continue }
            if control == .fullScreen { shown.append(control); fixed += 1; continue }
            guard fixed < edgeCapacity else { continue }
            fixed += 1
            shown.append(control)
        }
        edge = shown

        let topOver = Array(layout.topSlots.dropFirst(topCapacity)).compactMap { $0 }
        let bottomOver = Array(centerAll.dropFirst(centerCapacity)) + edgeAll.filter { !shown.contains($0) }
        overflow = topOver + bottomOver

        var seen = Set<PlayerControl>()
        // 固定键（锁定）不在「更多」里，别把它算进这个数字。
        moreCount = (layout.more + overflow)
            .filter { !PlayerControl.fixedKeys.contains($0) }
            .filter { seen.insert($0).inserted }
            .count
    }
}

/// 预览用的比例尺 —— 与 `ChromeMetrics` 同一组公式。
struct PreviewMetrics {
    let size: CGSize
    var scale: CGFloat { min(max(size.height / 300, 0.82), 1.4) }
    var glyph: CGFloat { (13 * scale).rounded() }
    var hit: CGFloat { min(52, max(44, (glyph * 1.8).rounded())) }
    var barHeight: CGFloat { max(hit, (glyph * 2.2).rounded()) }
    var edge: CGFloat { max(4, size.width * 0.012) }
    var playGlyph: CGFloat { (glyph * 1.75).rounded() }
    var stepGlyph: CGFloat { (glyph * 1.2).rounded() }
    var playHit: CGFloat { (playGlyph * 1.7).rounded() }
    var stepHit: CGFloat { (stepGlyph * 1.9).rounded() }
    var caption: CGFloat { (glyph * 0.9).rounded() }
}

/// 三种形态的屏幕尺寸与画面窗口落位。
///
/// ⛔ **不在这里重算几何**：窗口矩形直接由播放器那个 `OneSkinWindowGeometry`
/// 产出 —— 预览与播放器从此是同一段算术，不可能再漂移。
///
/// 之前这里是手抄的一版，抄错了三处，预览就把用户带偏了：
///   · 把 `Metrics.columnLeft`(0.4501) 当成了**画面列**宽 —— 它其实是**详情列**；
///     真正的画面列是 `base − base×columnLeft`（横持 951 → 523，不是 428）；
///   · 还往窗口里减了 `insetLandscape` 的左右边距 —— 而 Core 里明写
///     「`inset` 只作旧版式记录，**不参与任何窗口几何计算**」，画面列是满宽的；
///   · 竖持顶边用了 `colH × 0.091`，而正确值是 `屏高 × 0.091 + portraitExtraDrop`
///     （Core 的 init 注释里专门为这条留了 `portraitTopInset` 参数）。
enum PlayerShapeGeometry {
    private static var M: OneSkinWindowGeometry.Metrics.Type { OneSkinWindowGeometry.Metrics.self }

    static func screenSize(for shape: PlayerControlsLayout.Shape) -> CGSize { shape.screenSize }

    static func windowSize(for shape: PlayerControlsLayout.Shape) -> CGSize {
        windowRect(for: shape).size
    }

    /// 竖持窗口顶边 —— 与 `OneSkinStage.portraitTopInset` 同一公式
    ///（外屏窄列 0.0634、内屏宽列 0.091，都要再加 `portraitExtraDrop`）。
    static func portraitTopInset(for shape: PlayerControlsLayout.Shape) -> CGFloat {
        let screen = shape.screenSize
        let ratio: CGFloat = screen.width < 500 ? 0.0634 : 0.091
        return (screen.height * ratio + OneSkin.portraitExtraDrop).rounded()
    }

    /// `pictureColumn` 实际收到的那个 size（画面列，**不是**整屏）。
    ///
    /// 横持：`colL = base − base×columnLeft`，高度整列；
    /// 竖持：宽满屏，高 = `顶边 + 窗高 + 底部呼吸位`（夹在屏高 72% 内），
    /// 与 `OneSkin.pictureHeightOf` 同一式子 —— 详情列从它下沿开始。
    static func pictureColumnSize(for shape: PlayerControlsLayout.Shape) -> CGSize {
        let screen = shape.screenSize
        switch shape {
        case .sideways:
            let detail = (screen.width * M.columnLeft).rounded()
            return CGSize(width: screen.width - detail, height: screen.height)
        case .folded, .unfolded:
            let winH = screen.width / M.portraitAspect(forColumnWidth: screen.width)
            let pictureH = min(screen.height * 0.091 + winH + screen.height * 0.04,
                               screen.height * 0.72)
            return CGSize(width: screen.width, height: pictureH.rounded())
        }
    }

    static func windowRect(for shape: PlayerControlsLayout.Shape) -> CGRect {
        let landscape = shape == .sideways
        let g = OneSkinWindowGeometry(size: pictureColumnSize(for: shape),
                                      landscape: landscape,
                                      fullScreen: false,
                                      portraitTopInset: landscape ? nil : portraitTopInset(for: shape))
        return CGRect(x: g.winX, y: g.winY, width: g.winW, height: g.winH)
    }

    /// 横持右列（详情）。预览里画一块暗色骨架，表明这是双列版式。
    static func rightColumn(for shape: PlayerControlsLayout.Shape) -> CGRect? {
        guard shape == .sideways else { return nil }
        let screen = shape.screenSize
        let width = (screen.width * M.columnLeft).rounded()
        return CGRect(x: screen.width - width, y: 0, width: width, height: screen.height)
    }
}

// MARK: - 真实形态预览

/// 按**设备真实点数**画一张播放器，再整体缩放到可用宽度。
private struct PlayerShapePreview: View {
    let shape: PlayerControlsLayout.Shape
    let layout: PlayerControlsLayout
    let move: (PlayerControl, PlayerControl.Placement, Int) -> Void
    let commit: () -> Void
    /// 非 nil 时用这个固定倍率（1 = 设备真实点数）。nil = 按可用宽度自适应缩小。
    var fixedScale: CGFloat? = nil
    /// 允许双指缩放 + 单指拖动画面（只在 1:1 模式下开：小预览里拖动会与控件拖拽抢手势）。
    var panZoom: Bool = false

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var liveZoom: CGFloat = 1

    var body: some View {
        let screen = shape.screenSize
        let window = PlayerShapeGeometry.windowRect(for: shape)
        GeometryReader { proxy in
            let fitScale = proxy.size.width / screen.width
            let scale = (fixedScale ?? fitScale) * (panZoom ? (zoom * liveZoom) : 1)
            ZStack(alignment: .topLeading) {
                screenBackground(screen)
                if let right = PlayerShapeGeometry.rightColumn(for: shape) {
                    detailColumn(right)
                }
                PlayerWindowPreview(size: window.size, layout: layout, move: move, commit: commit)
                    .frame(width: window.width, height: window.height)
                    .offset(x: window.minX, y: window.minY)
                if shape != .sideways {
                    portraitDetail(after: PlayerShapeGeometry.pictureColumnSize(for: shape).height,
                                   screen: screen)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .onAppear {
                // 自证探针：真机截不出来时，让 App 自己把几何写进 Documents/oneskin.log。
                // 判据要能回答「1:1 模式下图标是不是真的 1:1」——
                // 所以打的是 scale 与窗口尺寸，而不是「我觉得它变大了」。
                OneSkinProbe.log("SLOTS shape=\(shape.rawValue) screen=\(Int(screen.width))x\(Int(screen.height))"
                    + " window=\(Int(window.width))x\(Int(window.height))"
                    + " fitScale=\(String(format: "%.4f", fitScale))"
                    + " appliedScale=\(String(format: "%.4f", scale))"
                    + " oneToOne=\(fixedScale != nil)"
                    + " panZoom=\(panZoom) zoom=\(String(format: "%.2f", zoom))")
            }
            // 缩放后的实际占据尺寸：宽度也跟着缩放，否则在 1:1 下会被 proxy 宽度裁掉右半边。
            .frame(width: screen.width * scale, height: screen.height * scale,
                   alignment: .topLeading)
            .offset(panZoom ? pan : .zero)
        }
        // 1:1 模式不加 aspectRatio：那是"塞进卡片"用的，会把真尺寸再压一次。
        .aspectRatio(panZoom ? nil : screen.width / screen.height, contentMode: .fit)
        .contentShape(Rectangle())
        .gesture(panZoom ? panGesture : nil)
        .simultaneousGesture(panZoom ? magnification : nil)
    }

    /// 单指拖画面（1:1 下要看窗口右上角或底部时用）。
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in pan = value.translation }
    }

    /// 双指缩放。
    private var magnification: some Gesture {
        MagnificationGesture()
            .updating($liveZoom) { value, state, _ in state = value }
            .onEnded { value in
                zoom = min(max(zoom * value, 0.5), 4)
            }
    }

    private func screenBackground(_ screen: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.09, blue: 0.08),
                                    Color(red: 0.05, green: 0.04, blue: 0.045)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.white.opacity(0.06), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: screen.width, height: screen.height)
    }

    /// 竖持形态：**画面列之下**那半屏的详情骨架（标题 / 按钮 / 选集）。
    ///
    /// 起点是画面列的下沿（`pictureHeightOf` 算出的高度），不是窗口下沿 ——
    /// 两者之间还隔着 4% 屏高的呼吸位。用窗口下沿会让详情整体上移、贴住画面。
    private func portraitDetail(after top: CGFloat, screen: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.20))
                .frame(width: screen.width * 0.42, height: 13)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.10))
                .frame(width: screen.width * 0.30, height: 8)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.12)).frame(width: 62, height: 22)
                }
            }
            .padding(.top, 2)
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08))
                        .frame(width: 56, height: 78)
                }
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(.top, 18).padding(.horizontal, 16)
        .frame(width: screen.width, height: max(0, screen.height - top),
               alignment: .topLeading)
        .offset(x: 0, y: top)
    }

    private func detailColumn(_ rect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.22))
                .frame(width: rect.width * 0.55, height: 14)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12))
                .frame(width: rect.width * 0.80, height: 8)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12))
                .frame(width: rect.width * 0.68, height: 8)
            Spacer()
        }
        .padding(.top, 24).padding(.horizontal, 18)
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(Color.black.opacity(0.28))
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// 画面窗口里的播放器控件层（顶栏 / 中央 / 底栏），按真实点数绘制。
///
/// ## 图里的控件可以直接拖
///
/// 三条**横带**（顶栏 / 中央传输组 / 进度条那一行）各挂一个手势，按住 0.25 秒后进入拖动：
///   · 横向：落在哪两颗之间就插到那里。判据是"插在谁前面"而不是索引 —— 进度条那一行里
///     有进度条、时间码这些宽度不一的条目，绝对索引跨行对不上；
///   · 纵向：拖到另一条带附近就整行搬过去，只对 `placements` 允许的行生效
///     （「选集」能上下走，「播放」只能在中央那一行里挪）。
///
/// 拖动期间只改页面上的状态数组，图片和下面两张表一起重排；手指离开才写一次存储。
/// 长按是**故意**的：不带长按的直接拖会被设置页的滚动吃掉，那就又成了"看着能拖、拖不动"。
private struct PlayerWindowPreview: View {
    let size: CGSize
    let layout: PlayerControlsLayout
    let move: (PlayerControl, PlayerControl.Placement, Int) -> Void
    let commit: () -> Void

    /// 量控件矩形用的坐标系：窗口自己的点，不受外层 `scaleEffect` 影响。
    static let space = "playerWindow"

    @State private var frames: [PlayerControl: CGRect] = [:]
    @State private var dragging: PlayerControl?
    /// 上一次算出来的落点（行 + 邻居）。只有它变了才触发一次触感，避免每帧都震。
    @State private var lastRow: PlayerControl.Placement?
    @State private var lastCell: Int?
    @State private var ticks = 0
    /// 拖动中手指落到的格（画一圈高亮，告诉用户「松手会放这里」）。
    @State private var hoverCell: (row: PlayerControl.Placement, cell: Int)?

    private var m: PreviewMetrics { PreviewMetrics(size: size) }

    private var topY: CGFloat { max(size.height * 0.072, m.hit / 2 + m.edge) }
    private var bottomY: CGFloat { min(size.height * 0.928, size.height - m.hit / 2 - m.edge) }

    /// 顶栏在预览里能画几格。
    ///
    /// ⛔ 这里**不再扣结构位**（旋转/锁定/更多）。旧算式 `- 4 * hit` 是播放器的口径
    ///（`OneSkinChrome.topSurfaceCapacity` 要扣掉它自己画的那几颗结构位），
    /// 但预览图里根本不画结构位 —— 于是出现「预览显示 11 格、实际只能落 7 格」，
    /// 用户按预览去放，放到第 8 格就被挤走，观感正是「x 不受我控制」。
    ///
    /// 两边坐标系统一：预览画多少格，就能落多少格。真机容量口径见
    /// `PlayerControlsFit`（它照旧扣结构位，用于「几颗会进更多」的估算）。
    /// 顶栏在预览里画几格 —— **按实际宽度算满，不设人为上限**。
    ///
    /// 用户要求「每栏的格数都要尽可能自由」。宽度是唯一真实的约束（画不下就是画不下），
    /// 所以这里只按 `可用宽 / 格宽` 算，不再与 `slotCount` 取小 —— 取小会让
    /// 「能画出来的格」少于「能落进去的格」，用户看到格子却放不进去。
    private var topCapacity: Int {
        max(1, Int((size.width - m.edge * 2) / max(m.hit, 1)))
    }

    private var topSlots: [PlayerControl?] {
        let slots = Array(layout.topSlots.prefix(topCapacity))
        let end = (slots.lastIndex { $0 != nil } ?? -1) + 1
        return slots.prefix(end).map { $0 }
    }

    private var centerRow: [PlayerControl?] {
        let all = layout.bottomSlots.map {
            $0.flatMap { PlayerControl.centerControls.contains($0) ? $0 : nil }
        }
        let capacity = max(1, Int((size.width - 2 * m.edge) / max(m.stepHit, 1)))
        let end = (all.lastIndex { $0 != nil } ?? -1) + 1
        return Array(all.prefix(end).prefix(capacity))
    }

    private var bottomRow: [PlayerControl] {
        let all = layout.bottom.filter { !PlayerControl.centerControls.contains($0) }
        let reserve = m.caption * 15 + m.hit + 120
        let capacity = max(1, Int(max(0, size.width - 2 * m.edge - reserve) / max(m.hit, 1)))
        var fixed = 0
        var shown: [PlayerControl] = []
        for control in all {
            if control == .progressBar { shown.append(control); continue }
            if control == .fullScreen { shown.append(control); fixed += 1; continue }
            guard fixed < capacity else { continue }
            fixed += 1
            shown.append(control)
        }
        return shown
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom).frame(height: m.barHeight)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom).frame(height: m.barHeight)
            }
            topBar
            centerBar
            bottomBar
            slotGuides
            dragBands
        }
        .coordinateSpace(name: Self.space)
        .onAppear {
            let top = layout.topSlots.prefix(PlayerControlsLayout.slotCount)
                .map { $0?.rawValue ?? "-" }.joined(separator: ",")
            let bottom = layout.bottomSlots.prefix(PlayerControlsLayout.slotCount)
                .map { $0?.rawValue ?? "-" }.joined(separator: ",")
            OneSkinProbe.log("SLOTROW size=\(Int(size.width))x\(Int(size.height))"
                + " top=[\(top)] bottom=[\(bottom)]"
                + " topCell=\(Int(self.m.hit)) edge=\(Int(self.m.edge))"
                + " topCap=\(self.topCapacity)"
                // 存储上限（= 可摆放控件总数，动态）与预览可画格数（= 宽度决定）是两个数，
                // 必须分别打出来 —— 混在一起看会以为「还是只能放 10 颗」。
                + " storeCap=\(PlayerControlsLayout.slotCount)"
                + " previewCap=\(self.topCapacity)"
                + " storedTopLen=\(layout.topSlots.count)"
                + " storedBottomLen=\(layout.bottomSlots.count)")
        }
        .onPreferenceChange(ControlFrameKey.self) { frames = $0 }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // 预览在横持形态只有 0.49 倍，光靠眼睛看不出"刚才有没有换位"；每换一格震一下。
        .sensoryFeedback(.selection, trigger: ticks)
    }

    // MARK: 三条可拖的横带

    /// 宽度铺满窗口，高度等于那一行本身 —— 抓取**不要求点到图标**，落点由手势里的
    /// "最近的控件"决定。横持预览只有 0.49 倍，要求精确点到 21pt 的图标不现实。
    private var dragBands: some View {
        ZStack(alignment: .topLeading) {
            band(.topBar, height: m.barHeight, centerY: topY)
            band(.middle, height: m.playHit, centerY: size.height * 0.496)
            band(.progressRow, height: m.barHeight, centerY: bottomY)
        }
    }

    /// 拖动中把**每一格**画出来 —— 用户要求的「显示出可摆放的槽位」。
    ///
    /// 只在拖动期间出现：平时画满格子会盖住画面，反而看不清播放器长什么样。
    /// 每一格用一条细虚线方框表示「这里可以放」，手指当前对准的那一格实心高亮。
    @ViewBuilder
    private var slotGuides: some View {
        if let dragging {
            ZStack(alignment: .topLeading) {
                guideRow(.topBar, centerY: topY, allowed: dragging.placements.contains(.topBar))
                guideRow(.middle, centerY: size.height * 0.496,
                         allowed: dragging.placements.contains(.middle))
                guideRow(.progressRow, centerY: bottomY,
                         allowed: dragging.placements.contains(.progressRow))
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func guideRow(_ placement: PlayerControl.Placement,
                          centerY: CGFloat,
                          allowed: Bool) -> some View {
        // 这一行画得出几格：与容量算法同一份（都按宽度算满，不设人为上限）。
        let count = max(1, allowed ? rowCapacity(placement) : 0)
        let cell = cellWidth
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let hot = hoverCell?.row == placement && hoverCell?.cell == index
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hot ? Color.accentColor : Color.white.opacity(allowed ? 0.55 : 0.18),
                                  style: StrokeStyle(lineWidth: hot ? 2 : 1, dash: hot ? [] : [3, 3]))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hot ? Color.accentColor.opacity(0.28)
                                      : Color.white.opacity(allowed ? 0.06 : 0))
                    )
                    .frame(width: cell, height: cell)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, m.edge)
        .frame(width: size.width, alignment: .leading)
        .position(x: size.width / 2, y: centerY)
    }

    /// 某一行在当前窗口里能放几格。
    private func rowCapacity(_ placement: PlayerControl.Placement) -> Int {
        switch placement {
        case .topBar:
            return topCapacity
        case .middle:
            return max(1, Int((size.width - 2 * m.edge) / max(m.stepHit, 1)))
        case .progressRow:
            return bottomRow.count
        }
    }

    private func band(_ placement: PlayerControl.Placement,
                      height: CGFloat, centerY: CGFloat) -> some View {
        Color.clear
            .frame(width: size.width, height: max(height, m.hit * 0.78))
            .contentShape(Rectangle())
            .gesture(dragGesture(placement))
            .position(x: size.width / 2, y: centerY)
    }

    private func dragGesture(_ band: PlayerControl.Placement) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if dragging == nil {
                    guard let picked = nearest(to: drag.startLocation, in: band) else { return }
                    dragging = picked
                }
                guard let dragged = dragging else { return }
                place(dragged, at: drag.location)
            }
            .onEnded { _ in
                if dragging != nil { commit() }
                dragging = nil
                lastRow = nil
                lastCell = nil
                hoverCell = nil
            }
    }

    /// 带里离手指最近的那颗（带上任意位置都能抓起来）。
    private func nearest(to point: CGPoint, in band: PlayerControl.Placement) -> PlayerControl? {
        let candidates = row(band).filter { frames[$0] != nil }
        return candidates.min {
            abs((frames[$0]?.midX ?? 0) - point.x) < abs((frames[$1]?.midX ?? 0) - point.x)
        }
    }

    /// 拖动中：算出目标行与**目标格**，交给页面改状态。
    ///
    /// 格子由横坐标吸附得到（`SlotBoard.cellIndex`），行由纵坐标最近的那条带得到。
    /// 这样「拖到哪一格」就是「放进哪一格」——用户第一次能靠眼睛对准位置。
    private func place(_ dragged: PlayerControl, at point: CGPoint) {
        let target = targetRow(for: dragged, y: point.y)
        let cell = cellIndex(forX: point.x)
        // 落点没变就不动：手势每帧都调这里，重复写状态只会白白重绘。
        guard target != lastRow || cell != lastCell else { return }
        lastRow = target
        lastCell = cell
        hoverCell = (target, cell)
        ticks += 1
        move(dragged, target, cell)
    }

    /// 横坐标 → 第几格。用**这一行的实际几何**（边距 + 格宽）算，与绘制共用同一组常量。
    private func cellIndex(forX x: CGFloat) -> Int {
        SlotBoard.cellIndex(forX: x, leading: m.edge, cell: cellWidth)
    }

    /// 每格宽度：顶栏与进度行都按 `m.hit` 一格算 —— 与 `topCapacity` / `bottomRow` 的容量
    /// 算法一致，否则吸附到的格子与画出来的格子会错位。
    private var cellWidth: CGFloat { max(m.hit, 1) }

    private func targetRow(for control: PlayerControl, y: CGFloat) -> PlayerControl.Placement {
        let bands: [(PlayerControl.Placement, CGFloat)] = [(.topBar, topY),
                                                           (.middle, size.height * 0.496),
                                                           (.progressRow, bottomY)]
        let nearestBand = bands.min { abs($0.1 - y) < abs($1.1 - y) }?.0 ?? .progressRow
        if control.placements.contains(nearestBand) { return nearestBand }
        // 中央那条带与进度行同属底栏数组：拖到中间的非传输类控件，按进度行处理。
        if nearestBand == .middle, control.placements.contains(.progressRow) { return .progressRow }
        if nearestBand == .progressRow, control.placements.contains(.middle) { return .middle }
        // 哪儿都不许（例如把中央的播放键往上拖）：留在它本来能待的那一行。
        return control.placements.contains(.topBar) ? .topBar : .middle
    }

    /// 某条带上**实际画出来的**控件，顺序即左右顺序。
    private func row(_ placement: PlayerControl.Placement) -> [PlayerControl] {
        switch placement {
        case .topBar:      return topSlots.compactMap { $0 }
        case .middle:      return centerRow.compactMap { $0 }
        case .progressRow: return bottomRow
        }
    }

    // MARK: 三行

    private var topBar: some View {
        HStack(spacing: 0) {
            if !layout.top.contains(.rotate) {
                glyph("rectangle.landscape.rotate", base: m.glyph)
            }
            ForEach(Array(topSlots.enumerated()), id: \.offset) { _, control in
                if let control {
                    measured(control, glyph(control.symbol, base: m.glyph))
                } else {
                    Color.clear.frame(width: m.hit, height: m.hit)
                }
            }
            Spacer(minLength: 0)
            if !layout.top.contains(.lock) {
                glyph("lock.open", base: m.glyph)
            }
            glyph("ellipsis", base: m.glyph)
        }
        .padding(.horizontal, m.edge)
        .frame(width: size.width, height: m.barHeight)
        .position(x: size.width / 2, y: topY)
    }

    private var centerBar: some View {
        let count = max(1, centerRow.count)
        let slotW = min(m.playHit, max(m.stepHit, (size.width - 2 * m.edge) / CGFloat(count)))
        return HStack(spacing: 0) {
            ForEach(Array(centerRow.enumerated()), id: \.offset) { _, control in
                Group {
                    if let control {
                        measured(control, centerItem(control))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: slotW, height: m.playHit)
            }
        }
        .frame(width: size.width, height: m.playHit)
        .position(x: size.width / 2, y: size.height * 0.496)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(bottomRow.enumerated()), id: \.offset) { _, control in
                measured(control, bottomItem(control))
            }
            if !bottomRow.contains(.fullScreen), !layout.top.contains(.fullScreen) {
                glyph("arrow.up.left.and.arrow.down.right", base: m.glyph)
            }
        }
        .padding(.horizontal, m.edge)
        .frame(width: size.width, height: m.barHeight)
        .position(x: size.width / 2, y: bottomY)
    }

    @ViewBuilder
    private func centerItem(_ control: PlayerControl) -> some View {
        switch control {
        case .playPause:
            glyph("play.fill", base: m.playGlyph, weight: .semibold, box: m.playHit)
        case .backTen:
            glyph("gobackward.10", base: m.stepGlyph, box: m.stepHit)
        case .forwardTen:
            glyph("goforward.10", base: m.stepGlyph, box: m.stepHit)
        case .previousEpisode:
            glyph("backward.end.fill", base: m.stepGlyph, box: m.stepHit)
        case .nextEpisode:
            glyph("forward.end.fill", base: m.stepGlyph, box: m.stepHit)
        default:
            glyph(control.symbol, base: m.glyph)
        }
    }

    @ViewBuilder
    private func bottomItem(_ control: PlayerControl) -> some View {
        if control == .timecode {
            Text("0:12").font(.system(size: m.caption)).monospacedDigit()
                .padding(.trailing, 8)
        } else if control == .remaining {
            Text("-1:39").font(.system(size: m.caption)).monospacedDigit()
        } else if control == .progressBar {
            seekBar
        } else {
            glyph(control.symbol, base: m.glyph)
        }
    }

    /// 量出控件矩形（手势要按它算落点），顺手给正在拖的那颗描个边。
    private func measured<V: View>(_ control: PlayerControl, _ content: V) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ControlFrameKey.self,
                                           value: [control: proxy.frame(in: .named(Self.space))])
                }
            }
            .overlay {
                if dragging == control {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.18)))
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }

    private var seekBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.28)).frame(height: max(2, m.glyph * 0.18))
            GeometryReader { track in
                Capsule().fill(.white)
                    .frame(width: track.size.width * 0.34, height: max(2, m.glyph * 0.18))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: m.hit, maxHeight: m.hit)
    }

    private func glyph(_ symbol: String, base: CGFloat,
                       weight: Font.Weight = .medium, box: CGFloat? = nil) -> some View {
        Image(systemName: symbol)
            .font(.system(size: base, weight: weight))
            .frame(width: box ?? m.hit, height: box ?? m.hit)
    }
}

/// 每颗控件在窗口坐标系里的矩形。字典合并，缺的补上、有的覆盖。
private struct ControlFrameKey: PreferenceKey {
    static let defaultValue: [PlayerControl: CGRect] = [:]
    static func reduce(value: inout [PlayerControl: CGRect],
                       nextValue: () -> [PlayerControl: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - 小部件

/// 一颗控件的小圆标：只画图标，不写字。
private struct ControlChip: View {
    let control: PlayerControl

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [control.tint.opacity(0.95),
                                          control.tint.blend(with: .black, by: 0.35)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: control.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
#endif
