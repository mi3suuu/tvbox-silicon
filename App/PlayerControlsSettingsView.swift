import SwiftUI
import TVCore

#if os(iOS)
/// Settings → Playback → Player Controls: drop the player's buttons onto the ten slots of the top
/// bar or the ten slots of the bottom row, or into the More menu — and set their left-to-right
/// place. A live preview at the top mirrors the player's chrome as you drag. One layout serves
/// every player shape (folded outer screen, unfolded upright, unfolded sideways).
struct PlayerControlsSettingsView: View {
    @AppStorage(PlayerControlsLayout.storageKey) private var stored = PlayerControlsLayout.standard.stored

    var body: some View {
        SettingsPage(title: L10n.text("Player Controls"), symbol: "slider.horizontal.3") {
            SettingsGroup {
                PlayerControlsPreview(layout: PlayerControlsLayout(stored: stored))
            }
            SettingsGroup(footer: L10n.text("Drag a button onto any slot in the top or bottom row, or into More. Empty slots stay empty.")) {
                PlayerControlsEditor(stored: $stored)
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
        if let control {
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
        }
        .padding(.vertical, 8)
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
