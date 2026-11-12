import SwiftUI
import TVCore

#if os(iOS)
/// Settings → Playback → Player Controls: drop the player's buttons onto the ten slots of the top
/// bar or the ten slots of the bottom row, or into the More menu — and set their left-to-right
/// place. A live preview at the top mirrors the player's chrome as you drag. One layout serves
/// every player shape (folded outer screen, unfolded upright, unfolded sideways).
struct PlayerControlsSettingsView: View {
    /// 三形态各自独立配置（见 `PlayerControlsLayout.Shape`）。
    ///
    /// 此前只有一个 `playerControlsOrder` 键，所有形态共用一套槽位。
    /// 外屏顶栏只放得下 2–3 个按钮，横持能放 6 个 —— 共用一套必然有个形态是错的：
    /// 在外屏删掉的按钮，横持时也没了；为横持加的按钮，外屏会挤成一条。
    /// 现在每个形态一份，设置页顶部切换。
    @State private var editing: PlayerControlsLayout.Shape = .folded
    @AppStorage(PlayerControlsLayout.Shape.folded.storageKey)
    private var foldedRaw = PlayerControlsLayout.standard.stored
    @AppStorage(PlayerControlsLayout.Shape.unfolded.storageKey)
    private var unfoldedRaw = PlayerControlsLayout.standard.stored
    @AppStorage(PlayerControlsLayout.Shape.sideways.storageKey)
    private var sidewaysRaw = PlayerControlsLayout.standard.stored

    /// 当前正在编辑的那一份的可写代理。
    ///
    /// `@AppStorage` 不能动态选键，所以这里按形态分三支手工转发；
    /// 三支都写同一个 `String`，读回也是同一个 `String`。
    private var stored: Binding<String> {
        switch editing {
        case .folded:   return $foldedRaw
        case .unfolded: return $unfoldedRaw
        case .sideways: return $sidewaysRaw
        }
    }

    var body: some View {
        SettingsPage(title: L10n.text("Player Controls"), symbol: "slider.horizontal.3") {
            // ⛔ 这张排布表只对**原版**与 **One** 两套皮肤生效。
            //
            // 哔哩哔哩皮肤的底栏/顶栏是照 B 站二进制实测出的**绝对定位**复刻的
            // （`BiliFullScreenPage.bottomBar` / `BiliPortraitPage` 里全是硬编码偏移，
            //  `grep "PlayerControlsLayout\|PlayerControl\." App/Bili*.swift` 零命中），
            // 它读的是自己那套 `BiliMenuConfig`（`biliMenuOrder` / `biliMenuHidden`），
            // 与本页的十格槽位互不相通。
            //
            // 所以这里必须**明说**。不说的话，用户在哔哩哔哩皮肤下把这里拖了个遍、
            // 播放器纹丝不动，只会得出「设置坏了」—— 而事实是「这一套不适用」。
            // 把它写出来，是「没有实现清晰」这条需求里最便宜也最实在的一半。
            if PlaySkin.current == .bilibili {
                SettingsGroup(footer: L10n.text("This layout applies to the Original and One skins. The Bilibili skin keeps its own built-in arrangement — customise it from Customize Menu inside its More panel.")) {
                    FormLabel(symbol: "info.circle.fill", tint: .orange,
                              title: L10n.text("Not used by the Bilibili skin"))
                }
            }
            // 形态切换。三形态各自独立，切过去看到的槽位就是那个形态实际用的。
            SettingsGroup(footer: L10n.text("Each shape keeps its own layout. A button you remove on the folded outer screen stays on the unfolded one.")) {
                Picker(selection: $editing) {
                    ForEach(PlayerControlsLayout.Shape.allCases, id: \.self) { shape in
                        Text(shape.title).tag(shape)
                    }
                } label: {
                    FormLabel(symbol: "rectangle.split.2x1", tint: .teal,
                              title: L10n.text("Shape"))
                }
                .pickerStyle(.inline)
            }
            SettingsGroup {
                // ⛔ `.id(editing)` 不能省：`PlayerControlsPreview` 与 `PlayerControlsEditor`
                // 内部都用 `@State` 缓存了一份从 `stored` 解析出来的 layout，
                // 而 `@State` **只在视图身份变化时重init一次**。切形态时 `stored` 换了键，
                // 但视图身份没变 → 编辑器里还是上一个形态的 layout。
                // 后果不是「显示不对」而是**写串**：在 folded 排好 → 切到 sideways →
                // 拖任意一颗 → 整份 folded 槽位被写进 sideways 的键，两个形态互相污染。
                PlayerControlsPreview(layout: PlayerControlsLayout(stored: stored.wrappedValue))
                    .id(editing)
            }
            SettingsGroup(footer: L10n.text("Drag a button onto any slot in the top or bottom row, or into More. Empty slots stay empty.")) {
                PlayerControlsEditor(stored: stored)
                    .id(editing)
            }
            // 该形态已有自己的配置时，给一个「恢复默认」。
            // 判据是「这个键真的被写过」，不是「和 standard 相等」——
            // 用户手动排成和默认一样也算自定义过，不该被当成没改。
            if PlayerControlsLayout.hasOwnConfiguration(for: editing) {
                SettingsGroup {
                    Button(role: .destructive) {
                        PlayerControlsLayout.reset(editing)
                        stored.wrappedValue = PlayerControlsLayout.standard.stored
                    } label: {
                        Label(L10n.text("Reset This Shape to Default"), systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
    }
}

/// A miniature of the player's chrome, redrawn live as the layout changes: the top bar's round
/// buttons on their ten slots, the bottom transport row on its ten slots, and a "⋯" button when
/// anything is in More.
private struct PlayerControlsPreview: View {
    let layout: PlayerControlsLayout

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.12), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                VStack {
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 46)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 46)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.backward")
                        Text(L10n.text("Now Playing")).font(.caption).lineLimit(1)
                        Spacer()
                        ForEach(Array(layout.topSlots.enumerated()), id: \.offset) { _, control in
                            previewSlot(control)
                        }
                        if !layout.more.isEmpty { Image(systemName: "ellipsis.circle") }
                    }
                    .padding(.horizontal, 12).padding(.top, 10)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(Array(layout.bottomSlots.enumerated()), id: \.offset) { _, control in
                            previewSlot(control)
                        }
                        Spacer()
                        Image(systemName: "clock").foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
        }
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private func previewSlot(_ control: PlayerControl?) -> some View {
        // 只在「选集页直接显示」里勾过的才画：预览要和播放器一致，否则勾选框一动、上面的
        // 小播放器照旧画满一排，勾选看起来就没生效。
        if let control, layout.watchSurfaced.contains(control) {
            Image(systemName: control.symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(control.tint.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        } else {
            // An empty slot is invisible in the preview, exactly as it is in the player.
            Color.clear.frame(width: 22, height: 22)
        }
    }
}

/// The slot editor: two rows of ten drop targets (top and bottom) plus a More tray. Every control
/// — wherever it currently sits — is draggable, and every slot is a drop target, so a control moves
/// to a specific X position by being dropped on the slot there.
private struct PlayerControlsEditor: View {
    @Binding var stored: String
    @State private var layout: PlayerControlsLayout
    @State private var selected: PlayerControl?

    init(stored: Binding<String>) {
        _stored = stored
        _layout = State(initialValue: PlayerControlsLayout(stored: stored.wrappedValue))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: PlayerControlsLayout.slotCount)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Tap a control to pick it up, then tap an empty slot to drop it there — or just drag it.
            if let selected {
                HStack(spacing: 8) {
                    Image(systemName: "hand.point.up.left.fill").foregroundStyle(.secondary)
                    Text(L10n.text("Tap a slot to place %@", selected.title)).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Cancel")) { self.selected = nil }.font(.footnote)
                }
            }
            rowSection(title: L10n.text("Top Row"), slots: layout.topSlots, zone: .top)
            rowSection(title: L10n.text("Bottom Row"), slots: layout.bottomSlots, zone: .bottom)
            moreSection
            surfacingSections
        }
        .padding(.vertical, 8)
    }

    /// 两个**独立**的勾选列表：哪些控件在「选集页」控制栏直接出现、哪些在「全屏」直接出现。
    ///
    /// 同一个控件可以两边都勾 —— 用户明确要求「这两个可以都显示，不冲突」。
    /// 没勾的控件仍在「更多」菜单里，不丢功能。
    ///
    /// 列表里放的是 `PlayerControl.barControls`（所有能进顶栏的控件），而不是
    /// `layout.top`（当前顶栏里的那几个）：后者只有在用户先把控件拖到顶栏之后才会列出来，
    /// 于是「新加的按钮」永远没有勾选项 —— 用户看到的是一张缺项的表。勾上时由
    /// `surfaceInTopRow` 顺手补一个顶栏空位，所以「勾了就能看见」。
    private var surfacingSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Ticking a control puts it in the first free slot of the top row. A bar too narrow to hold them all leaves the last ones out — drag those earlier, or untick a few."))
                .font(.caption).foregroundStyle(.tertiary)
            surfacingSection(
                title: L10n.text("Shown While Watching"),
                symbol: "rectangle.on.rectangle",
                hint: L10n.text("Buttons that sit in the control bar on the episode page."),
                controls: PlayerControl.barControls,
                isOn: { isShownInBar($0, whileWatching: true) },
                toggle: { control, on in setSurfaced(control, on: on, whileWatching: true) }
            )
            surfacingSection(
                title: L10n.text("Shown in Full Screen"),
                symbol: "arrow.up.left.and.arrow.down.right",
                hint: L10n.text("Buttons that sit in the control bar in full-screen playback."),
                controls: PlayerControl.barControls,
                isOn: { isShownInBar($0, whileWatching: false) },
                toggle: { control, on in setSurfaced(control, on: on, whileWatching: false) }
            )
        }
    }

    /// 勾选框读的是「现在真的会画出来吗」，而不是「集合里有没有它」。
    ///
    /// 一个控件要出现在控制栏里，必须**同时在顶栏槽位里、又在可见集合里**。只看集合的话，
    /// 一条不在顶栏的旧记录会显示成「已勾选」而屏幕上没有那颗按钮 —— 勾选框就成了谎话。
    private func isShownInBar(_ control: PlayerControl, whileWatching: Bool) -> Bool {
        let set = whileWatching ? layout.watchSurfaced : layout.fullSurfaced
        return set.contains(control) && layout.top.contains(control)
    }

    /// 勾选／取消一个控件在某种状态下的可见性。
    /// 勾上时同时把它补进顶栏（见 `surfaceInTopRow`）：勾选集合只决定「可见」，
    /// 位置由槽位决定，两者缺一按钮就不出现 —— 「勾了没反应」的根因就在这里。
    private func setSurfaced(_ control: PlayerControl, on: Bool, whileWatching: Bool) {
        var set = whileWatching ? layout.watchSurfaced : layout.fullSurfaced
        if on {
            if !set.contains(control) { set.append(control) }
            layout.surfaceInTopRow(control)
        } else {
            set.removeAll { $0 == control }
        }
        if whileWatching { layout.watchSurfaced = set } else { layout.fullSurfaced = set }
        stored = layout.stored
    }

    private func surfacingSection(title: String, symbol: String, hint: String,
                                  controls: [PlayerControl],
                                  isOn: @escaping (PlayerControl) -> Bool,
                                  toggle: @escaping (PlayerControl, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
            Text(hint).font(.caption).foregroundStyle(.tertiary)
            ForEach(controls, id: \.self) { control in
                Toggle(isOn: Binding(get: { isOn(control) },
                                     set: { toggle(control, $0) })) {
                    Label(L10n.text(control.title), systemImage: control.symbol)
                        .font(.footnote)
                }
                .toggleStyle(.switch)
            }
        }
    }

    private func rowSection(title: String, slots: [PlayerControl?], zone: PlayerControlsLayout.Zone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: zone == .top ? "arrow.up" : "arrow.down")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, control in
                    slotCell(control, zone: zone, index: index)
                }
            }
        }
    }

    @ViewBuilder private func slotCell(_ control: PlayerControl?, zone: PlayerControlsLayout.Zone, index: Int) -> some View {
        Group {
            if let control {
                controlChip(control)
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected != nil ? Color.accentColor : Color.secondary.opacity(0.35),
                                          style: StrokeStyle(lineWidth: selected != nil ? 1.5 : 1, dash: [4, 3]))
                    }
                    .frame(height: 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if control == nil { dropSelected(into: zone, slot: index) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dropped = PlayerControl(rawValue: raw) else { return false }
            layout.place(dropped, in: zone, slot: index)
            selected = nil
            persist()
            return true
        }
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text("In More"), systemImage: "ellipsis.circle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
            Group {
                if layout.more.isEmpty {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected != nil ? Color.accentColor : Color.secondary.opacity(0.35),
                                              style: StrokeStyle(lineWidth: selected != nil ? 1.5 : 1, dash: [4, 3]))
                        }
                        .frame(height: 40)
                        .overlay(Text(L10n.text("Drop here to hide")).font(.caption).foregroundStyle(.secondary))
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(layout.more) { control in
                            controlChip(control)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { dropSelected(into: .more, slot: 0) }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dropped = PlayerControl(rawValue: raw) else { return false }
                layout.place(dropped, in: .more, slot: 0)
                selected = nil
                persist()
                return true
            }
        }
    }

    /// Puts the picked-up control into a slot (or More), clearing the selection.
    private func dropSelected(into zone: PlayerControlsLayout.Zone, slot: Int) {
        guard let picked = selected else { return }
        layout.place(picked, in: zone, slot: slot)
        selected = nil
        persist()
    }

    private func controlChip(_ control: PlayerControl) -> some View {
        HStack(spacing: 6) {
            Image(systemName: control.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(control.title)
                .font(.caption).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(LinearGradient(colors: [control.tint.blend(with: .white, by: 0.12), control.tint.blend(with: .black, by: 0.2)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected == control ? Color.white : .clear, lineWidth: 2)
        }
        .onTapGesture { selected = selected == control ? nil : control }
        .draggable(control.rawValue)
    }

    private func persist() {
        withAnimation(.smooth) { stored = layout.stored }
    }
}
#endif
