import SwiftUI
import AVFoundation
import TVCore

#if !os(tvOS)
/// 直接在**画面上**剪广告：拖两根手柄，边拖边看那一帧。
///
/// 为什么不沿用设置页那种表单：
///   · 表单遮住画面，用户只能靠时间码猜边界，看不到自己要剪的到底是哪一帧；
///   · 表单的深色背景压在运动画面上，分组标题只有 3.9:1 对比度（低于 WCAG 正文 4.5:1），
///     用户的原话是「字都看不清」。
///
/// 这一层的做法：
///   · 画面**完全可见**，只在下方三分之一压一条渐变，保证刻度与数字读得清；
///   · 两根手柄直接标在时间条上，拖动时**立刻 seek 到那个时间点**，
///     用户看到的就是"剪到这一帧为止"；
///   · 数字用大字号 + 实底色药丸，不靠半透明白字叠在画面上；
///   · 松手不提交，按「完成」才落盘 —— 拖动过程中误触不会改数据。
///
/// 与 `AdRangeEditor`（表单版）的分工：这里是播放页里的快速剪，表单版留给
/// 需要精确输入时间码或批量管理本集广告段的场合。
struct AdTrimOverlay: View {
    let session: PlaybackSession
    /// 初始区间（打开时用播放位置做起点）。
    var onCancel: () -> Void = {}
    var onSaved: (AdRange) -> Void = { _ in }

    @State private var start: Double = 0
    @State private var end: Double = 0
    /// 正在拖哪一端，决定 seek 到哪一帧。
    @State private var dragging: End?
    @State private var scrubbing = false
    @State private var saving = false
    @State private var message: String?

    private enum End { case start, end }

    private var duration: Double {
        session.duration.isFinite && session.duration > 0 ? session.duration : 0
    }

    private var draft: AdRange? {
        AdMarkRange.make(from: start, to: end, duration: duration)
    }

    /// 起点与终点至少要拉开这么宽才给保存（和模型层的 `shortest` 同一个值）。
    private var tooShort: Bool { draft == nil }

    /// 与「更多」面板**同一套视觉语言**：近黑不透明底、同一圆角、同样的白字层级与描边。
    ///
    /// ⛔ 上一版用的是「透明 + 底部压渐变」：字直接压在运动画面上，
    ///    底随每一帧在变，细字发花；而且和播放器其它面板（近黑实底 + 圆角 + 细描边）
    ///    完全不是一套，看起来像另一个 App 的界面。
    ///    现在整块改成一个卡片，配色全部取自 `morePanel`：
    ///      底 `Color(white: 0.07)` / 描边 `white 0.22` / 标题纯白 / 次文 `white 0.80`。
    private var panelFill: Color { Color(white: 0.07) }
    private var panelStroke: Color { Color.white.opacity(0.22) }
    private var panelCorner: CGFloat { 14 }

    var body: some View {
        ZStack {
            // 画面留出来：只压一层很轻的暗化，让卡片被"托住"，
            // 但不做整屏黑 —— 剪的时候仍要看得见画面。
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { /* 点空白不关闭：误触会丢掉已拖好的区间 */ }
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 卡片贴底：画面在上方完整可见，卡片只占下方一条。
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    topBar
                    trimmer
                }
                // 与「更多」面板同一套：近黑实底 + 同圆角 + 细描边。
                // 实底是关键：字不再压在运动画面上，对比度恒定。
                .background(panelFill,
                            in: RoundedRectangle(cornerRadius: panelCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: panelCorner, style: .continuous)
                        .strokeBorder(panelStroke, lineWidth: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .onAppear(perform: prepare)
    }

    // MARK: - 顶部（标题 + 读数）

    /// 标题行 —— 与 `morePanel` 的标题行同一构造：左标题、右关闭。
    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(L10n.text("Trim the Ad"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 6)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Cancel"))
        }
        .padding(.leading, 14).padding(.trailing, 2).padding(.top, 2)
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            headerRow
            Divider().overlay(panelStroke)
            HStack(spacing: 8) {
                readout(L10n.text("From"), start)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.80))
                readout(L10n.text("To"), end)
                Spacer(minLength: 0)
                Text(draft.map { EpisodeSkipSettings.formatTime($0.length) } ?? "--:--")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
    }

    /// 读数：**不加底片**，直接是面板卡上的字 —— 避免"卡片里再套一堆小卡片"。
    private func readout(_ title: String, _ seconds: Double) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
            Text(EpisodeSkipSettings.formatTime(seconds))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    // MARK: - 时间条 + 双手柄

    private var trimmer: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let barH: CGFloat = 40
                let x0 = x(for: start, width: width)
                let x1 = x(for: end, width: width)

                ZStack(alignment: .leading) {
                    // 整条底轨
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(height: barH)

                    // 已选区间：高亮 + 两侧白边，一眼看出剪的是哪一段
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, x1 - x0), height: barH)
                        .offset(x: x0)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                                .frame(width: max(2, x1 - x0), height: barH)
                                .offset(x: x0)
                        }

                    // 播放头：拖动时能对到自己要看的那一帧
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: barH + 12)
                        .offset(x: x(for: dragging == .end ? end : start, width: width))

                    handle(at: x0, width: width, which: .start, barH: barH)
                    handle(at: x1, width: width, which: .end, barH: barH)
                }
                .frame(height: barH)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // 整条也能拖：直接拖到想剪的位置当起点，比先找手柄快。
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let t = time(at: v.location.x, width: width)
                            dragging = .start
                            start = t
                            if end <= start { end = min(duration, start + AdMarkRange.shortest) }
                            previewSeek(to: start)
                        }
                        .onEnded { _ in endDrag() }
                )
            }
            .frame(height: 56)

            HStack(spacing: 10) {
                // 用当前帧定位：拖完手柄常有半秒偏差，这两个键补上。
                Button {
                    start = clamped(session.position)
                    if end <= start { end = min(duration, start + AdMarkRange.shortest) }
                } label: {
                    label(L10n.text("Start Here"), "arrow.right.to.line")
                }
                .buttonStyle(.plain)

                Button {
                    end = clamped(session.position)
                    if start >= end { start = max(0, end - AdMarkRange.shortest) }
                } label: {
                    label(L10n.text("End Here"), "arrow.left.to.line")
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                // 主按钮用填充色 —— 与设置页那种"唯一强调动作"的写法一致。
                Button { Task { await save() } } label: {
                    Text(saving ? L10n.text("Saving…") : L10n.text("Done"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(tooShort || saving || duration <= 0)
                .opacity(tooShort || saving ? 0.45 : 1)
            }

            let hint: String? = message ?? (tooShort
                ? L10n.text("Drag both ends so the range is at least %@ long.",
                            EpisodeSkipSettings.formatTime(AdMarkRange.shortest))
                : nil)
            if let hint {
                // 提示是面板内的一行次文，不再套第二个黑底卡片。
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// 面板内的次级按钮：细描边胶囊，跟面板同色系（不做成第二个"小黑卡"）。
    private func label(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 11).padding(.vertical, 8)
        .overlay {
            Capsule().strokeBorder(panelStroke, lineWidth: 1)
        }
    }

    /// 起点/终点手柄：竖白条 + 中间一条抓握纹，热区比视觉宽 2.6 倍。
    private func handle(at x: CGFloat, width: CGFloat, which: End, barH: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 22, height: barH + 10)
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Color.black.opacity(0.35)).frame(width: 10, height: 2)
                    }
                }
            }
            .contentShape(Rectangle().size(width: 56, height: barH + 28)
                .offset(x: -17, y: -9))
            .offset(x: x - 11)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = which
                        let t = time(at: x + v.translation.width, width: width)
                        switch which {
                        case .start:
                            start = min(t, end - AdMarkRange.shortest)
                            if start < 0 { start = 0 }
                            previewSeek(to: start)
                        case .end:
                            end = max(t, start + AdMarkRange.shortest)
                            if end > duration { end = duration }
                            previewSeek(to: end)
                        }
                    }
                    .onEnded { _ in endDrag() }
            )
    }

    // MARK: - 换算与动作

    private func prepare() {
        guard duration > 0 else {
            message = L10n.text("Wait for the video duration before marking an ad.")
            return
        }
        let here = clamped(session.position)
        start = here
        end = min(duration, here + 15)
        if end - start < AdMarkRange.shortest { start = max(0, end - AdMarkRange.shortest) }
    }

    private func clamped(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(0, t), max(duration, 0))
    }

    private func x(for t: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(min(max(t / duration, 0), 1))
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return min(max(Double(x / width) * duration, 0), duration)
    }

    /// 拖动时把画面 seek 过去 —— 用户要的就是"看着那一帧在剪"。
    private func previewSeek(to t: Double) {
        guard duration > 0 else { return }
        if !scrubbing { scrubbing = true }
        session.seek(to: clamped(t))
    }

    private func endDrag() {
        scrubbing = false
        dragging = nil
    }

    private func save() async {
        guard let draft, !saving else { return }
        saving = true
        defer { saving = false }
        let saved = await session.markAd(from: draft.start, to: draft.end)
        if let saved {
            onSaved(saved)
        } else {
            message = L10n.text("This video can't remember marks. Open it from a series to use them.")
        }
    }
}
#endif
