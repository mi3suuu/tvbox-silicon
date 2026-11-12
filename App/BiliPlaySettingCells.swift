#if os(iOS)
import SwiftUI
import TVCore

// MARK: - 播放设置五个 Cell（swift-section 实证结构）
//
// 来源（`swift-section objc dump` → /tmp/bili_objc.txt:788530）：
//   @interface BBPlayerPlaySettingWidget : BBPlayerOperationWidget {
//       BBPlayerOperationListCell            *_operationListCell;
//       BBPlayerPlaySettingPlaybackRateCell  *_playbackRateCell;
//       BBPlayerPlaySettingPlaybackModeCell  *_playbackModeCell;
//       BBPlayerPlaySettingScaleCell         *_scaleCell;
//       BBPlayerPlaySettingConfigCell        *_configCell;
//   }
//
// 每个 Cell 的内部形态（同一处 dump）：
//   UILabel *_titleLbl;  NSArray *_btnArray;  NSArray *_modelArray;
//   - (unsigned long long)calculateBtnNumOfLineWithWidth:(double)width;   // ★
//   - (double)defaultHeight;
//
// ★ 关键：每行按钮数**按可用宽度动态计算**。
//   所以形态是「每个 Cell 一行标题 + 一排按钮，按钮按宽度自动折行」，
//   不是固定三列，也不是九行列表。

/// 五个 Cell，顺序与二进制成员声明顺序一致。
enum BiliPlaySettingSection: String, CaseIterable, Identifiable {
    case operation       // BBPlayerOperationListCell
    case playbackRate    // BBPlayerPlaySettingPlaybackRateCell
    case playbackMode    // BBPlayerPlaySettingPlaybackModeCell
    case scale           // BBPlayerPlaySettingScaleCell
    case config          // BBPlayerPlaySettingConfigCell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .operation:    return ""                    // 操作四键无标题（`_withTitle` 可为 false）
        case .playbackRate: return "Speed"
        case .playbackMode: return "Playback Mode"
        case .scale:        return "Aspect Ratio"
        case .config:       return "Options"
        }
    }

}

// MARK: - Cell 容器

/// 一个 Cell：`titleLbl` + 按宽度自动折行的 `btnArray`。
///
/// 折行规则取自 `-calculateBtnNumOfLineWithWidth:` 的语义：
/// 给定宽度与单个 chip 的最小宽度，算出每行能放几个，再按该数量铺。
struct BiliPSCellRow<Content: View>: View {
    let title: String
    /// 每个 chip 的最小宽度（含左右内边距）。二进制里按钮等宽排布。
    var minChipWidth: CGFloat = 64
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(L10n.text(title))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BiliPalette.tertiary)
            }
            // 用 `LazyVGrid(adaptive:)` 实现「按宽度自动算每行几个」——
            // 这正是 `calculateBtnNumOfLineWithWidth:` 的行为，
            // 不需要自己算列数，宽度变了它自己折。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minChipWidth), spacing: 6)],
                      alignment: .leading, spacing: 4) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

/// Cell 里的一个 chip（对应 `_btnArray` 的一颗 UIButton）。
struct BiliPSChip: View {
    let text: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? BiliPalette.accent : BiliPalette.lightPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? BiliPalette.accent.opacity(0.14) : BiliPalette.lightFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
    }
}

/// 配置项开关行（`_showMirrorItem` 等 16 个布尔对应的 UI）。
struct BiliPSToggleChip: View {
    let text: String
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(on ? BiliPalette.accent : BiliPalette.lightTertiary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(BiliPalette.lightPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
    }
}
#endif
