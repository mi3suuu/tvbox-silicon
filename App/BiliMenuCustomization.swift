#if os(iOS)
import SwiftUI
import TVCore

// MARK: - 播放器菜单项自定义（`bbplayer_playersetting_optionsedit`）
//
// 与 **One 皮肤完全独立**：
//   · 本文件只被哔哩哔哩皮肤（`BiliFullScreenPage`）引用；
//   · 存储键全部以 `biliMenu` 前缀，One 的任何键都不碰；
//   · One 侧没有对应功能，互不影响。
//
// 二进制实证：`bbplayer_playersetting_optionsedit` /
// `PlaySetting]playersetting_optionsedit` —— B 站允许用户编辑播放设置里
// 哪些项出现在菜单中、以及顺序。

/// 可在「更多」面板里出现的所有条目。
/// 只有我们**真正实现了**的才列出来，不列空壳。
enum BiliMenuItem: String, CaseIterable, Identifiable {
    case speed
    case quality
    case subtitles
    case episodes
    case timer
    case aspectRatio
    case colorFilter
    case danmuSettings
    case backgroundPlay
    case mirrorFlip
    case miniPlayer
    case screenshot
    case lockScreen
    /// 广告拦截总开关。
    ///
    /// 哔哩哔哩这一套菜单（`BiliMenuItem`）与 One/原版的 `PlayerControl` 是两张独立的表，
    /// 各自记录自己的顺序与显隐 —— 所以「广告拦截」在 One 里加进 `PlayerControl`
    /// 并不会让它自动出现在这里。这一项是给哔哩哔哩皮肤补的同名入口，
    /// 写的是同一个键（`AdSkip.key`），三个皮肤共用一个真身。
    case adBlock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speed:          return "Speed"
        case .quality:        return "Resolution"
        case .subtitles:      return "Subtitles"
        case .episodes:       return "Episodes"
        case .timer:          return "Timer"
        case .aspectRatio:    return "Aspect Ratio"
        case .colorFilter:    return "Color Filter"
        case .danmuSettings:  return "Danmu Settings"
        case .backgroundPlay: return "Background Play"
        case .mirrorFlip:     return "Mirror Flip"
        case .miniPlayer:     return "Mini player"
        case .screenshot:     return "Screenshot"
        case .lockScreen:     return "Lock screen"
        case .adBlock:        return "Ad Blocking"
        }
    }

    var symbol: String {
        switch self {
        case .speed:          return "speedometer"
        case .quality:        return "rectangle.badge.checkmark"
        case .subtitles:      return "captions.bubble"
        case .episodes:       return "list.bullet"
        case .timer:          return "timer"
        case .aspectRatio:    return "aspectratio"
        case .colorFilter:    return "camera.filters"
        case .danmuSettings:  return "text.bubble"
        case .backgroundPlay: return "play.square.stack"
        case .mirrorFlip:     return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .miniPlayer:     return "pip"
        case .screenshot:     return "camera"
        case .lockScreen:     return "lock"
        case .adBlock:        return "shield.lefthalf.filled"
        }
    }

    /// 出厂顺序。
    static var defaultOrder: [BiliMenuItem] {
        [.speed, .quality, .subtitles, .episodes, .timer,
         .aspectRatio, .colorFilter, .danmuSettings,
         .backgroundPlay, .mirrorFlip,
         .miniPlayer, .screenshot, .lockScreen, .adBlock]
    }
}

/// 用户自定义：顺序 + 显隐。
///
/// 存储：`biliMenuOrder`（逗号分隔 rawValue）、`biliMenuHidden`（同上）。
/// **不共用 One 的任何键。**
enum BiliMenuConfig {
    static let orderKey = "biliMenuOrder"
    static let hiddenKey = "biliMenuHidden"

    /// 当前生效顺序（含新增但用户还没排过的项，追加在末尾）。
    static var order: [BiliMenuItem] {
        let raw = UserDefaults.standard.string(forKey: orderKey) ?? ""
        var result: [BiliMenuItem] = raw
            .split(separator: ",")
            .compactMap { BiliMenuItem(rawValue: String($0)) }
        // 去重
        var seen = Set<BiliMenuItem>()
        result = result.filter { seen.insert($0).inserted }
        // 补齐未出现的新项
        for item in BiliMenuItem.defaultOrder where !seen.contains(item) {
            result.append(item)
        }
        return result
    }

    static var hidden: Set<BiliMenuItem> {
        let raw = UserDefaults.standard.string(forKey: hiddenKey) ?? ""
        return Set(raw.split(separator: ",").compactMap { BiliMenuItem(rawValue: String($0)) })
    }

    /// 界面上真正显示的条目（保序 + 过滤隐藏）。
    static var visible: [BiliMenuItem] {
        let h = hidden
        return order.filter { !h.contains($0) }
    }

    static func setOrder(_ items: [BiliMenuItem]) {
        UserDefaults.standard.set(items.map(\.rawValue).joined(separator: ","), forKey: orderKey)
    }

    static func setHidden(_ items: Set<BiliMenuItem>) {
        UserDefaults.standard.set(items.map(\.rawValue).joined(separator: ","), forKey: hiddenKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: orderKey)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
    }
}
#endif

#if os(iOS)

// MARK: - 编辑界面

/// 菜单项自定义面板。从「更多」面板底部 `Customize Menu >` 进入。
/// 支持拖动排序 + 开关显隐 + 恢复默认。
struct BiliMenuEditorView: View {
    @State private var order: [BiliMenuItem] = BiliMenuConfig.order
    @State private var hidden: Set<BiliMenuItem> = BiliMenuConfig.hidden
    @State private var editMode: EditMode = .active
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // 标题行：左标题、右「恢复默认」
            HStack(spacing: 0) {
                Text(L10n.text("Customize Menu"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BiliPalette.lightPrimary)
                Spacer(minLength: 8)
                Button {
                    BiliMenuConfig.reset()
                    order = BiliMenuConfig.order
                    hidden = BiliMenuConfig.hidden
                } label: {
                    Text(L10n.text("Reset"))
                        .font(.system(size: 12))
                        .foregroundStyle(BiliPalette.accent)
                }
                .buttonStyle(.plain)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BiliPalette.lightTertiary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
            }
            .padding(.horizontal, BiliPopupMetrics.rowInset)
            .frame(height: BiliPopupMetrics.headerHeight)

            Divider().overlay(BiliPalette.lightLine)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(order) { (item: BiliMenuItem) in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12))
                                .foregroundStyle(BiliPalette.lightTertiary)
                            Image(systemName: item.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(BiliPalette.lightSecondary)
                                .frame(width: 20)
                            Text(L10n.text(item.label))
                                .font(.system(size: 13))
                                .foregroundStyle(hidden.contains(item)
                                                 ? BiliPalette.lightTertiary
                                                 : BiliPalette.lightPrimary)
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(
                                get: { !hidden.contains(item) },
                                set: { on in
                                    if on { hidden.remove(item) } else { hidden.insert(item) }
                                    BiliMenuConfig.setHidden(hidden)
                                }
                            ))
                            .labelsHidden()
                            .tint(BiliPalette.accent)
                        }
                        .padding(.horizontal, BiliPopupMetrics.rowInset)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        BiliMenuConfig.setOrder(order)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .environment(\.editMode, $editMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BiliPalette.lightPanel)
    }
}
#endif
