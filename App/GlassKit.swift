import SwiftUI
import ImageIO
import CoreImage
import TVCore

extension View {
    @ViewBuilder func catalogSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(tvOS)
        // The system search, as in the TV app and Global Search: a large search line over the keyboard row.
        // A text field of our own sat in a corner the remote could not reach from the content below.
        searchable(text: text, prompt: Text(prompt))
        #elseif os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        #else
        searchable(text: text, prompt: Text(prompt))
        #endif
    }
}

/// A Liquid Glass recipe. On macOS 26, iOS 26 and tvOS 26 it is real glass; on macOS 15, iOS 17–18 and tvOS 17–18,
/// which have no glass, `glassSurface` draws a material with the same tint instead.
struct GlassStyle {
    var tint: Color?
    var isInteractive = false
    var isVisible = true
    static let regular = GlassStyle()
    static let identity = GlassStyle(isVisible: false)
    func tint(_ color: Color) -> GlassStyle { var style = self; style.tint = color; return style }
    func interactive() -> GlassStyle { var style = self; style.isInteractive = true; return style }
    @available(macOS 26, iOS 26, tvOS 26, *)
    var glass: Glass {
        guard isVisible else { return .identity }
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return isInteractive ? glass.interactive() : glass
    }
}

/// `GlassEffectContainer` where it exists, so nearby glass shapes blend; a plain group before OS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Apple TVs without Liquid Glass on tvOS 26 take the material path too: there the glass dropped its tint, so a
    /// focused chip's white plate never showed and its black label sat on a dark capsule (#214).
    @ViewBuilder func glassSurface(_ style: GlassStyle = .regular, in shape: some Shape) -> some View {
        #if os(tvOS)
        modifier(CoverGlass(style: style, shape: shape))
        #else
        liveGlassSurface(style, in: shape)
        #endif
    }

    @ViewBuilder fileprivate func liveGlassSurface(_ style: GlassStyle, in shape: some Shape) -> some View {
        if #available(macOS 26, iOS 26, tvOS 26, *), LiquidGlassSupport.current {
            glassEffect(style.glass, in: shape)
        } else if style.isVisible {
            background {
                shape.fill(.ultraThinMaterial).overlay { if let tint = style.tint { shape.fill(tint) } }
            }
        } else {
            self
        }
    }

    #if !os(tvOS)
    /// A bar pinned to the top that content scrolls under: a soft scroll edge on OS 26, a bar material before.
    /// `hardEdge` for a tall bar, which content must not show through.
    @ViewBuilder func topBar<Bar: View>(hardEdge: Bool = false, @ViewBuilder _ bar: () -> Bar) -> some View {
        let bar = bar()
        if #available(macOS 26, iOS 26, *) {
            scrollEdgeEffectStyle(hardEdge ? .hard : .soft, for: .top).safeAreaBar(edge: .top, spacing: 0) { bar }
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar.background(.bar) }
        }
    }
    #endif

    #if os(macOS)
    /// A page whose artwork runs under the window toolbar: the toolbar draws no backing and, on macOS 26, the scroll
    /// edge is soft, so the art fades under the toolbar instead of stopping at a solid band.
    @ViewBuilder func artUnderToolbar() -> some View {
        if #available(macOS 26, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar).scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }

    /// Hides or shows a bar managed by SwiftUI. `.toolbarVisibility(_:for:)` (iOS 18+) is the
    /// reliable form; the older `.toolbar(_, for:)` is deprecated on iOS 27, where it silently
    /// stops hiding the floating Liquid Glass tab bar — leaving the capsule over a full-screen
    /// video. Before iOS 18 the old form is all there is.
    @ViewBuilder func setBarVisibility(_ visibility: Visibility, for placement: ToolbarPlacement) -> some View {
        if #available(iOS 18, *) {
            toolbarVisibility(visibility, for: placement)
        } else {
            toolbar(visibility, for: placement)
        }
    }
    #endif

    // iOS 17 and tvOS 17 stand-ins for iOS 18 and tvOS 18 APIs. macOS 15 always takes the first branch.

    /// Calls `action` when someone starts scrolling by hand. Before iOS 18 there is no scroll phase,
    /// so a drag on the scroll view stands in.
    @ViewBuilder func onScrollByHand(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18, tvOS 18, *) {
            onScrollPhaseChange { _, phase in if phase == .interacting { action() } }
        } else {
            #if os(tvOS)
            self
            #else
            simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in action() })
            #endif
        }
    }

    /// Tells the poster loader whether this scroll view is moving, so decoding is capped while the
    /// finger is down. Pairs with `ImageLoadGate`: the phase is the input, the gate is the policy.
    @ViewBuilder func reportsScrollingToPosterLoader() -> some View {
        if #available(iOS 18, tvOS 18, *) {
            onScrollPhaseChange { _, phase in
                Task { await PosterLoader.shared.setScrolling(phase != .idle) }
            }
        } else {
            #if os(tvOS)
            self
            #else
            simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in Task { await PosterLoader.shared.setScrolling(true) } }
                    .onEnded { _ in Task { await PosterLoader.shared.setScrolling(false) } }
            )
            .onDisappear { Task { await PosterLoader.shared.setScrolling(false) } }
            #endif
        }
    }

    /// `onScrollVisibilityChange`; before iOS 18 and tvOS 18 the visible share comes from the view's bounds
    /// against its scroll view's.
    @ViewBuilder func onScrolledIntoView(threshold: Double, _ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18, tvOS 18, *) {
            onScrollVisibilityChange(threshold: threshold, action)
        } else {
            onGeometryChange(for: Bool.self) { geometry in
                let own = CGRect(origin: .zero, size: geometry.size)
                guard own.width * own.height > 0, let viewport = geometry.bounds(of: .scrollView) else { return false }
                let shown = own.intersection(viewport)
                return !shown.isNull && shown.width * shown.height >= own.width * own.height * threshold
            } action: { action($0) }
        }
    }

    #if !os(tvOS)
    /// `searchFocused`; before iOS 18 a search field can't be focused from code, so it keeps the viewer's focus.
    @ViewBuilder func searchFieldFocused(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18, *) { searchFocused(focused) } else { self }
    }
    #endif

    /// `controlSize` 的包装。上游 #634 里为此在 tvOS 上加了 `@inline(never) @_optimize(none)`：
    /// 那版 SwiftUI 导出的函数在 tvOS 17 上会让 App 启动即崩，关掉内联与优化才稳。
    /// 这段是上游 225 提交里新增的，我们原来的 GlassKit 没有 —— 融合时必须补上，
    /// 否则 CloudFilesView / XunleiSignInView 等处编译不过。
    #if os(tvOS)
    @inline(never) @_optimize(none)
    func appControlSize(_ size: ControlSize) -> some View { controlSize(size) }
    #else
    func appControlSize(_ size: ControlSize) -> some View { controlSize(size) }
    #endif

    /// The breathing symbol effect; iOS 17 and tvOS 17 have no breathe, so the symbol pulses instead.
    @ViewBuilder func breathingSymbol() -> some View {
        if #available(iOS 18, tvOS 18, *) {
            symbolEffect(.breathe, options: .repeat(.periodic(delay: 2.5)))
        } else {
            symbolEffect(.pulse, options: .repeating.speed(0.4))
        }
    }
}

extension Color {
    /// `mix(with:by:)`; before iOS 18 and tvOS 18 a plain blend in sRGB.
    func blend(with other: Color, by fraction: Double) -> Color {
        if #available(iOS 18, tvOS 18, *) { return mix(with: other, by: fraction) }
        let environment = EnvironmentValues()
        let from = resolve(in: environment), to = other.resolve(in: environment)
        // Resolved components are linear; blending gamma-encoded values looks closer to mix's perceptual default.
        func encoded(_ linear: Float) -> Double { Double(pow(max(0, linear), 1 / 2.2)) }
        func mixed(_ a: Float, _ b: Float) -> Double { encoded(a) + (encoded(b) - encoded(a)) * fraction }
        return Color(.sRGB, red: mixed(from.red, to.red), green: mixed(from.green, to.green), blue: mixed(from.blue, to.blue),
                     opacity: Double(from.opacity + (to.opacity - from.opacity) * Float(fraction)))
    }
}

// MARK: - Settings page shell
//
// The settings sub-pages (AI translation, environments, artwork language …) are
// built on SwiftUI's `Form`, which is the right control for a list of labelled
// switches and fields. The problem was that a bare `Form` brings its own
// background and its own type ramp, so walking from a hand-drawn page like
// Cloud Files into one of these felt like leaving the app. This modifier keeps
// the control and gives it the house background, so only the layout differs.
extension View {
    func settingsPage() -> some View {
        self
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(Brand.pageBackground)
    }
}

/// Shared opaque surfaces keep content and controls legible in both appearances.
/// 画布本色，不带 `ignoresSafeArea`。
///
/// ⛔ 不能叫 `Canvas` —— SwiftUI 自己有一个 `Canvas`（立刻模式绘图层），同名会把
/// `DanmakuView` 里那种 `Canvas { context, size in … }` 的调用变成「多了一个尾闭包」。
///
/// `Backdrop` 是给整页铺底的（它要撑满安全区），而**吸顶的分组头**只需要在滚动内容上盖一层
/// 与画布同色的底 —— 用 `Backdrop` 会把那层底撑到屏幕边缘，压住导航栏与标签栏。
/// 两处必须是同一个颜色：写两份 RGB 就会在某一版里慢慢跑偏，分组头看起来像一块补丁。
struct CanvasColor: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(red: 0.020, green: 0.035, blue: 0.090) : Color(red: 0.955, green: 0.965, blue: 0.985))
    }
}

struct Backdrop: View {
    var body: some View {
        // Flat canvas (the icon's navy / cool white); artwork supplies the rest of the colour.
        CanvasColor().ignoresSafeArea()
    }
}

struct Surface: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(red: 0.075, green: 0.105, blue: 0.19) : Color(red: 0.915, green: 0.935, blue: 0.965))
    }
}

extension View {
    /// Fills the screen first: applied to a bare `ContentUnavailableView` the backdrop would
    /// otherwise shrink to that view and show as a box.
    func screenBackdrop() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity).background { Backdrop() }
    }

    @ViewBuilder func screenTitle(_ title: String, width: CGFloat = Layout.maxWidth) -> some View {
        #if os(tvOS)
        navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(title).font(.system(size: 38, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: width, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Layout.gutter).padding(.top, 16).padding(.bottom, 12)
                    .background(TVStyle.background)
            }
        #else
        navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        #endif
    }

    /// A tab's root page: titled on iPhone, iPad and Mac, untitled on tvOS, where the tab bar already
    /// names the page and a second title under it only repeats it.
    @ViewBuilder func tabTitle(_ title: String) -> some View {
        #if os(tvOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        screenTitle(title)
        #endif
    }

    @ViewBuilder func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder func pageContainer() -> some View {
        #if os(tvOS)
        padding(.horizontal, Layout.gutter).padding(.vertical, 28)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        #else
        padding(Layout.gutter).frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        #endif
    }

    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        contentPanel(cornerRadius: min(cornerRadius, 16))
    }

    func contentPanel(cornerRadius: CGFloat = 12) -> some View {
        glassSurface(.regular, in: RoundedRectangle(cornerRadius: max(cornerRadius, 14), style: .continuous))
    }

    /// A cover with captions under it. On Apple TV it takes Discover's focus: the cover itself lifts with the
    /// system's Liquid Glass rim and parallax (the first image in the label, rounded by `shape`) while the captions
    /// stay; there is no plate around the card. Covers inside use `posterClip`, as a clip would cut the rim off.
    @ViewBuilder func cardButton(_ shape: ButtonBorderShape = .roundedRectangle(radius: 12)) -> some View {
        #if os(tvOS)
        modifier(TVCardButton(shape: shape))
        #else
        buttonStyle(LiftButtonStyle())
        #endif
    }

    /// A row of a small picture beside text: on Apple TV the whole row lifts on Liquid Glass with a light rim.
    @ViewBuilder func rowCardButton() -> some View {
        #if os(tvOS)
        buttonStyle(TVPanelStyle(cornerRadius: 16, plate: true))
        #else
        buttonStyle(LiftButtonStyle())
        #endif
    }

    /// A card made of several pictures, or with its own surface: on Apple TV the whole card lifts with a light
    /// glass rim, as Rex's large cards do, since there is no single cover for the system's lift.
    @ViewBuilder func panelCardButton(cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        buttonStyle(TVPanelStyle(cornerRadius: cornerRadius))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// Rounds a cover, except inside a card button on Apple TV, whose border shape rounds it instead.
    func posterClip<S: Shape>(_ shape: S) -> some View { modifier(PosterClip(shape: shape)) }

    /// Captions under the cover of a `cardButton`: on Apple TV they move down as the cover lifts, as on Discover.
    func cardCaption() -> some View { modifier(CardCaption()) }

    /// An overlay on a cover, such as a progress bar or a badge, on the view that holds its `PosterImage`. On Apple TV
    /// the image paints it into its own bitmap, so the focus lift grows, moves and tilts it with the artwork, as Rex's
    /// overlayContentView does: SwiftUI lifts only the image, never views over it, not even overlays attached to it.
    /// `animated` content (a spinner) can't be painted; it is scaled with the lift instead, which matches until the
    /// remote's touch tilts the cover.
    @ViewBuilder func coverOverlay<V: View>(alignment: Alignment = .center, animated: Bool = false,
                                            @ViewBuilder _ content: () -> V) -> some View {
        #if os(tvOS)
        if animated {
            overlay { content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment).modifier(CoverLift()) }
        } else {
            let layer = CoverOverlay(alignment: alignment, view: AnyView(content()))
            // The outer modifier runs first; inserting at the front keeps the order the overlays were written in.
            transformEnvironment(\.coverOverlays) { $0.insert(layer, at: 0) }
        }
        #else
        overlay(alignment: alignment, content: content)
        #endif
    }

    /// For cards that paint their own focus state (source cards).
    @ViewBuilder func tileButton() -> some View {
        #if os(tvOS)
        buttonStyle(TVTileStyle())
        #else
        buttonStyle(LiftButtonStyle())
        #endif
    }
}

private struct InCardButtonKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Inside a `cardButton` on Apple TV.
    var inCardButton: Bool {
        get { self[InCardButtonKey.self] }
        set { self[InCardButtonKey.self] = newValue }
    }
}

#if os(tvOS)
/// The height of the cover in a card button, which sets how far its captions move.
struct CardCoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CardCoverHeightEnvironmentKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var cardCoverHeight: CGFloat {
        get { self[CardCoverHeightEnvironmentKey.self] }
        set { self[CardCoverHeightEnvironmentKey.self] = newValue }
    }
}

private struct TVCardButton: ViewModifier {
    let shape: ButtonBorderShape
    @State private var cover: CGFloat = 0
    func body(content: Content) -> some View {
        content.buttonStyle(.borderless).buttonBorderShape(shape)
            .environment(\.inCardButton, true).environment(\.cardCoverHeight, cover)
            .onPreferenceChange(CardCoverHeightKey.self) { cover = $0 }
    }
}
#endif

/// An overlay that `coverOverlay` hands down to the cover's `PosterImage`.
struct CoverOverlay {
    let alignment: Alignment
    let view: AnyView
}

private struct CoverOverlaysKey: EnvironmentKey { static var defaultValue: [CoverOverlay] { [] } }
private struct BakingCoverKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var coverOverlays: [CoverOverlay] {
        get { self[CoverOverlaysKey.self] }
        set { self[CoverOverlaysKey.self] = newValue }
    }
    /// Painting a cover's overlays into its bitmap, where glass doesn't render.
    var bakingCover: Bool {
        get { self[BakingCoverKey.self] }
        set { self[BakingCoverKey.self] = newValue }
    }
}

/// The `coverOverlay`s of a cover that isn't a `PosterImage`, which has no bitmap to paint them into: they grow with
/// the lift instead.
struct CoverOverlayStack: View {
    @Environment(\.coverOverlays) private var overlays
    var body: some View { CoverOverlayLayers(overlays: overlays).modifier(CoverLift()) }
}

fileprivate struct CoverOverlayLayers: View {
    let overlays: [CoverOverlay]
    var body: some View {
        ZStack {
            ForEach(overlays.indices, id: \.self) { index in
                overlays[index].view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: overlays[index].alignment)
            }
        }
    }
}

#if os(tvOS)
/// Glass can't be painted into a bitmap, so a badge baked into a cover gets its tint as a plain fill.
private struct CoverGlass<S: Shape>: ViewModifier {
    let style: GlassStyle
    let shape: S
    @Environment(\.bakingCover) private var baking
    @ViewBuilder func body(content: Content) -> some View {
        if baking {
            content.background { if style.isVisible { shape.fill(style.tint ?? .black.opacity(0.3)) } }
        } else {
            content.liveGlassSurface(style, in: shape)
        }
    }
}
#endif

private struct CoverLift: ViewModifier {
    #if os(tvOS)
    @Environment(\.isFocused) private var focused
    @Environment(\.inCardButton) private var inCardButton
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        // The system grows a focused cover by 12% about its centre (measured on the TV, as in Rex).
        content.scaleEffect(inCardButton && focused ? 1.12 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: focused)
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

private struct CardCaption: ViewModifier {
    #if os(tvOS)
    @Environment(\.isFocused) private var focused
    @Environment(\.cardCoverHeight) private var cover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        // 6% of the cover's height, as Rex's captions and DiscoverTVNativeShelf.Cell's move.
        content.offset(y: focused ? cover * 0.06 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: focused)
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

private struct PosterClip<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.inCardButton) private var inCardButton
    @ViewBuilder func body(content: Content) -> some View {
        if inCardButton { content } else { content.clipShape(shape) }
    }
}

/// Pointer-aware press and hover feedback for content cards.
struct LiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LiftBody(configuration: configuration) }
    struct LiftBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.72 : (hovering ? 0.88 : 1))
                .animation(.smooth(duration: 0.22), value: hovering)
                .animation(.smooth(duration: 0.15), value: configuration.isPressed)
                #if !os(tvOS)
                .onHover { hovering = $0 }
                #endif
                #if os(macOS)
                .pointerStyle(.link)
                #endif
        }
    }
}

#if !os(tvOS)
private struct FilterChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Brand.onAccent : .primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .glassSurface(selected ? .regular.tint(Brand.accent).interactive() : .regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#endif

#if os(tvOS)
/// Liquid Glass filter chip: clear glass at rest, a lighter glass for the selection, and a bright
/// white glass lift on focus, as in the TV app.
private struct TVChipStyle: ButtonStyle {
    let selected: Bool
    var lift: CGFloat = 1.06
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration, selected: selected, lift: lift) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let lift: CGFloat
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .frame(minHeight: 58)
                .glassSurface(glass, in: Capsule())
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? lift : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
                .animation(.smooth(duration: 0.2), value: selected)
        }
        private var glass: GlassStyle {
            if focused { return .regular.tint(.white.opacity(0.9)).interactive() }
            if selected { return .regular.tint(.white.opacity(0.28)).interactive() }
            return .regular.interactive()
        }
    }
}

extension View {
    /// A Liquid Glass capsule that turns white on focus, like the chips.
    /// `lift` is how much it grows on focus; 1 keeps a wide pill (the search field) its own size.
    func glassPill(lift: CGFloat = 1.06) -> some View { buttonStyle(TVChipStyle(selected: false, lift: lift)) }
}

/// The query as a glass pill after a magnifying glass, as in the TV app's search. The remote's
/// keyboard has no return key, so this is what runs a typed search.
struct SearchQueryButton: View {
    let query: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(query, systemImage: "magnifyingglass").lineLimit(1) }
            .glassPill()
            .accessibilityLabel(L10n.text("Search %@", query))
    }
}
#endif

/// Neutral filters reserve high contrast for the current selection.
/// Set by `ScrollStrip` while the user drags it, so the chip under the pointer ignores the mouse-up.
@MainActor final class StripDrag { var active = false }
extension EnvironmentValues { @Entry var stripDrag: StripDrag? = nil }
/// Draws `controlButton()` and the source chips as Liquid Glass, on the iPhone watch page (#293).
extension EnvironmentValues { @Entry var glassControls = false }

/// A horizontal chip row: a `ScrollStrip` (drag and arrows on Mac), or a plain focus-driven
/// scroll view on tvOS.
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        #if os(tvOS)
        // Unclipped so a focused chip's lift and glow aren't cut at the row's ends.
        ScrollView(.horizontal, showsIndicators: false) { content.padding(.vertical, 8) }.scrollClipDisabled()
        #else
        // Room inside the strip's clip for the glass chips' edges and hover growth, given back
        // outside so the first chip still lines up with the page.
        ScrollStrip { content.padding(.horizontal, 6) }.padding(.horizontal, -6)
        #endif
    }
}

struct Chip: View {
    let title: String
    var selected = false
    var fill = false
    /// Leads with the Bilibili mark.
    var mark = false
    /// A status dot after the title, such as a source's health.
    var dot: Color? = nil
    let action: () -> Void
    @Environment(\.stripDrag) private var drag
    var body: some View {
        let button = Button { if drag?.active != true { action() } } label: {
            HStack(spacing: 5) {
                if mark { BilibiliGlyph(size: 22).foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(BilibiliMark.blue)) }
                Text(title).lineLimit(1)
                if let dot { Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(dot) }
            }.padding(.horizontal, 4).frame(maxWidth: fill ? .infinity : nil)
        }.accessibilityAddTraits(selected ? [.isSelected] : [])
        #if os(tvOS)
        button.buttonStyle(TVChipStyle(selected: selected))
        #else
        button.buttonStyle(FilterChipStyle(selected: selected))
        #endif
    }
}

/// Two-line card title that always takes two lines of height (so cards in a grid row match)
/// but centres a one-line title instead of leaving a gap under it.
struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text).lineLimit(2, reservesSpace: true).hidden()
            .overlay(alignment: .leading) {
                Text(text).lineLimit(2).foregroundStyle(.primary)
            }
            .font(.headline).multilineTextAlignment(.leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

struct SectionHeader: View {
    private var sectionFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .title2.weight(.bold)
        #endif
    }
    let title: String
    var action: (() -> Void)?
    var body: some View {
        if let action {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title).font(sectionFont)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    #if !os(tvOS)
                    Spacer(minLength: 0)
                    #endif
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain)
            #if os(tvOS)
            // The focus highlight hugs the title instead of spanning the screen.
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        } else {
            Text(title).font(sectionFont)
        }
    }
}

/// A cover's average colour, for backdrops tinted by the artwork, as the music player has. It
/// shares the posters' cache, so a cover already on screen costs no download.
enum PosterPalette {
    static func average(_ url: URL, headers: [String: String] = [:]) async -> Color? {
        guard let bitmap = try? await PosterLoader.shared.load(PosterResource(url: url, headers: headers)) else { return nil }
        let image = CIImage(cgImage: bitmap.image)
        guard let output = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                               format: .RGBA8, colorSpace: nil)
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }

    #if os(macOS)
    /// A few of the cover's most colourful patches, distinct from one another, for backdrops that drift between
    /// them (the detail page's aurora). Empty when the cover can't be read.
    static func colors(_ url: URL, headers: [String: String] = [:], count: Int = 4) async -> [Color] {
        guard let bitmap = try? await PosterLoader.shared.load(PosterResource(url: url, headers: headers)) else { return [] }
        // A 6×6 thumbnail: each pixel is a patch of the cover, averaged.
        let side = 6
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        let chroma = { (rgb: SIMD3<Double>) in rgb.max() - rgb.min() }
        let patches = stride(from: 0, to: pixels.count, by: 4)
            .map { SIMD3(Double(pixels[$0]), Double(pixels[$0 + 1]), Double(pixels[$0 + 2])) / 255 }
            .sorted { chroma($0) > chroma($1) }
        var picked: [SIMD3<Double>] = []
        for patch in patches where picked.count < count && picked.allSatisfy({ (($0 - patch) * ($0 - patch)).sum() > 0.04 }) {
            picked.append(patch)
        }
        return picked.map { Color(red: $0.x, green: $0.y, blue: $0.z) }
    }
    #endif

    /// The cover itself, from the same cache, for the Lock Screen and Control Center.
    static func image(_ url: URL, headers: [String: String] = [:]) async -> CGImage? {
        try? await PosterLoader.shared.load(PosterResource(url: url, headers: headers)).image
    }
}

private final class PosterBitmap: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor PosterLoader {
    static let shared = PosterLoader()
    /// Caps how many posters decode at once while a grid is moving. Scrolling competes with
    /// decoding for the same cores, so a fast fling that asks for twenty posters is slower than one
    /// that asks for two — the gate turns that into a policy instead of a hope.
    private let gate = ImageLoadGate()
    private let cache = NSCache<NSString, PosterBitmap>()
    private var pending: [PosterResource: Task<PosterBitmap, Error>] = [:]
    private var revision = MediaCache.shared.revision
    init() { cache.countLimit = 96; cache.totalCostLimit = 48 * 1024 * 1024 }

    func load(_ resource: PosterResource) async throws -> PosterBitmap {
        let current = MediaCache.shared.revision
        if revision != current { cache.removeAllObjects(); revision = current }
        let key = resource.cacheKey as NSString
        if let image = cache.object(forKey: key) { return image }
        if let task = pending[resource] { return try await task.value }
        // No slot means the queue is full while scrolling: this poster is off screen by the time a
        // slot frees, so skip it rather than piling work behind the finger. It will be asked for
        // again if it scrolls back.
        guard await gate.begin() else { throw CancellationError() }
        let task = Task {
            let disk = MediaCache.shared
            let ticket = disk.ticket()
            let scope = PosterResource.artworkScope(resource.url)
            let cached = disk.data(for: resource.cacheKey, kind: .artwork, scope: scope)
            let data: Data
            if let cached { data = cached }
            // Saved songs keep their covers, for listening with no connection.
            else if let saved = try? Data(contentsOf: MusicDownloadLibrary.artworkFile(for: resource.url)) { data = saved }
            else { data = try await HTTPClient().get(resource.url, headers: resource.headers).0 }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw NSError(domain: "PosterLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid poster image"])
            }
            if cached == nil {
                disk.store(data, for: resource.cacheKey, kind: .artwork, scope: scope, ttl: 30 * 86400, ticket: ticket)
            }
            return PosterBitmap(image)
        }
        pending[resource] = task
        do {
            let bitmap = try await task.value
            pending[resource] = nil
            await gate.finish()
            if current == MediaCache.shared.revision { cache.setObject(bitmap, forKey: key, cost: bitmap.image.bytesPerRow * bitmap.image.height) }
            return bitmap
        } catch { pending[resource] = nil; await gate.finish(); throw error }
    }

    /// Told by a grid as it starts and stops moving.
    func setScrolling(_ scrolling: Bool) { gate.setScrolling(scrolling) }
}

struct PosterImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    /// Shown until the image loads, and when there is none.
    var symbol = "film"
    /// Receives the loaded image's width over height, for a frame that shows the whole cover.
    var aspect: Binding<CGFloat?>? = nil
    @State private var bitmap: PosterBitmap?
    #if os(tvOS)
    @Environment(\.coverOverlays) private var overlays
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif
    private var resource: PosterResource? { url.map { PosterResource(url: $0, headers: headers) } }
    var body: some View {
        artwork
        .contentShape(.rect)
        .task(id: resource) {
            bitmap = nil
            guard let resource else { return }
            if let image = try? await PosterLoader.shared.load(resource), !Task.isCancelled {
                bitmap = image
                aspect?.wrappedValue = CGFloat(image.image.width) / CGFloat(max(image.image.height, 1))
            }
        }
    }

    #if os(tvOS)
    /// One image, cropped to the frame and never clipped: a borderless button lifts the first image in its label and
    /// draws the glass rim around it, which a clip would cut off, as on Discover's covers.
    private var artwork: some View {
        GeometryReader { proxy in
            Image(decorative: baked(Self.cover(bitmap?.image, proxy.size), proxy.size), scale: 1).resizable()
                .overlay { if bitmap == nil { Image(systemName: symbol).font(.title2).foregroundStyle(.white.opacity(0.55)) } }
                .preference(key: CardCoverHeightKey.self, value: proxy.size.height)
        }
    }

    private static let placeholder: CGImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
        UIColor(white: 0.2, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }.cgImage!

    /// The cover with its `coverOverlay`s painted in, so the lift moves, grows and tilts them with the artwork.
    private func baked(_ cover: CGImage, _ size: CGSize) -> CGImage {
        guard !overlays.isEmpty, size.width > 0, size.height > 0 else { return cover }
        let renderer = ImageRenderer(content: ZStack {
            Image(decorative: cover, scale: 1).resizable()
            CoverOverlayLayers(overlays: overlays)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, colorScheme).environment(\.locale, locale)
        .environment(\.layoutDirection, layoutDirection).environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.bakingCover, true))
        renderer.scale = displayScale
        return renderer.cgImage ?? cover
    }

    /// The middle of the image at the frame's shape, as a fill would show it.
    /// [mi3s] 二开融合（I-07）：由 `private` 提为 internal，供上游 1.8.11 的 `MangaCover`（tvOS 分支）复用同一裁剪实现。
    static func cover(_ image: CGImage?, _ size: CGSize) -> CGImage {
        guard let image else { return placeholder }
        guard size.width > 0, size.height > 0 else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height), shape = size.width / size.height
        let rect = width / height > shape
            ? CGRect(x: (width - height * shape) / 2, y: 0, width: height * shape, height: height)
            : CGRect(x: 0, y: (height - width / shape) / 2, width: width, height: width / shape)
        return image.cropping(to: rect.integral) ?? image
    }
    #else
    private var artwork: some View {
        ZStack {
            Color(white: 0.20)
            Image(systemName: symbol).font(.title2).foregroundStyle(.white.opacity(0.55))
            if let bitmap { Color.clear.overlay { Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill() } }
        }
        // A filled cover is wider than its frame; clip its drawing and its hit area, or the overflow
        // lies over the neighbouring cards and takes their clicks.
        .clipped()
    }
    #endif
}

struct PosterCard: View {
    let name: String
    let poster: URL?
    let headers: [String: String]
    let remarks: String
    init(video: Video) {
        name = video.name; poster = video.poster; headers = video.posterHeaders; remarks = video.remarks
    }
    init(recommendation: Recommendation) {
        name = recommendation.name; poster = recommendation.poster?.url
        headers = recommendation.poster?.headers ?? [:]; remarks = recommendation.remarks
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { PosterImage(url: poster, headers: headers) }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .coverOverlay(alignment: .bottomLeading) {
                    if !remarks.isEmpty {
                        Text(remarks).font(.caption2.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                            .glassSurface(.regular.tint(.black.opacity(0.45)), in: Capsule()).padding(8)
                    }
                }
            // One line, cut with an ellipsis: a title that wrapped made its card taller than the rest of the row.
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail).cardCaption()
        }
    }
}

extension View {
    /// Text selection where the platform supports it (not tvOS).
    @ViewBuilder func selectable() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}

// MARK: Skeleton loading

extension View {
    /// While a page is still loading it may have no focusable control. tvOS then sends
    /// the Menu/Back press to the system, which leaves the app instead of going back.
    /// `takeFocus` claims focus for pages with nothing else to focus (a video page's header).
    @ViewBuilder func loadingFocus(takeFocus: Bool = false, onExit: @escaping () -> Void) -> some View {
        #if os(tvOS)
        modifier(LoadingFocus(takeFocus: takeFocus, onExit: onExit))
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// tvOS does not move focus onto a plain focusable view in a newly pushed page, so the view takes
/// it once the push settles. Without focus the Back press never reaches `onExitCommand`.
private struct LoadingFocus: ViewModifier {
    let takeFocus: Bool
    let onExit: () -> Void
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focusable().focused($focused).onExitCommand(perform: onExit)
            .task {
                guard takeFocus else { return }
                try? await Task.sleep(for: .milliseconds(300))
                focused = true
            }
    }
}
#endif

#if os(tvOS)
enum TVStyle {
    static let background = Color(red: 0.020, green: 0.035, blue: 0.090)
    static let surface = Color(red: 0.09, green: 0.125, blue: 0.22)
    static let raised = Color(red: 0.13, green: 0.175, blue: 0.29)
}
/// Tiles that draw their own surface and light it up on focus (`\.isFocused` reaches the label),
/// so there is no second plate around them: just the lift.
private struct TVTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }
    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.05 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
/// The whole label lifts under focus with a light glass rim. `plate` lays Liquid Glass under rows that have no surface
/// of their own; it bleeds into the gutter so the layout size stays the same.
private struct TVPanelStyle: ButtonStyle {
    let cornerRadius: CGFloat
    var plate = false
    func makeBody(configuration: Configuration) -> some View { Panel(configuration: configuration, style: self) }
    private struct Panel: View {
        let configuration: ButtonStyleConfiguration
        let style: TVPanelStyle
        @Environment(\.isFocused) private var focused
        var body: some View {
            let inset: CGFloat = style.plate ? 12 : 0
            let shape = RoundedRectangle(cornerRadius: style.cornerRadius + inset, style: .continuous)
            configuration.label
                .padding(inset)
                .background {
                    if style.plate { Color.clear.glassSurface(focused ? .regular.tint(.white.opacity(0.18)).interactive() : .identity, in: shape) }
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.18), .white.opacity(0.45)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 2)
                        .opacity(focused ? 1 : 0)
                }
                .padding(-inset)
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? (style.plate ? 1.03 : 1.06) : 1)
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 14)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif

extension View {
    /// A round icon button in the player's top bar.
    @ViewBuilder func chromeButton() -> some View {
        #if os(iOS)
        buttonStyle(ChromeButtonStyle())
        #else
        controlButton().buttonBorderShape(.circle).controlSize(.large)
        #endif
    }

    /// Solid, high-contrast controls. Glass styles take their fill from the tint, which made
    /// prominent labels vanish against a white fill.
    @ViewBuilder func controlButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        // On tvOS the only highlight is focus: a coloured primary button beside a white focused one
        // left people unsure which was focused, so every control is the same glass until focused.
        buttonStyle(TVControlStyle())
        #else
        buttonStyle(ContentControlStyle(prominent: prominent))
        #endif
    }
    @ViewBuilder func controlBackdrop() -> some View {
        #if os(tvOS)
        background(Color.clear.glassSurface(.regular, in: .rect))
        #else
        background(.bar)
        #endif
    }
}
#if os(tvOS)
/// Every control on Apple TV is Liquid Glass, as the chips are: clear at rest, white on focus. Solid plates beside
/// glass chips read as two kinds of button, and the white of focus is the only highlight.
private struct TVControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TVChipStyle(selected: false).makeBody(configuration: configuration) }
}
#endif

#if os(tvOS)
/// A list row on tvOS: the focused row floats on a Liquid Glass capsule, never a square plate, padded so
/// its leading content never meets the edge. It grows from the leading edge so rows stay in line;
/// scroll views holding these rows pad their content (`glassRowInsets`) so the lift isn't clipped.
struct GlassRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal, 28).padding(.vertical, 12)
                .glassSurface(focused ? .regular.tint(.white.opacity(0.22)).interactive() : .identity, in: Capsule())
                .opacity(enabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.99 : focused ? 1.02 : 1, anchor: .leading)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
#endif

extension View {
    /// List-row buttons: the Liquid Glass row on tvOS, plain elsewhere.
    @ViewBuilder func glassRow() -> some View {
        #if os(tvOS)
        buttonStyle(GlassRowStyle())
        #else
        buttonStyle(.plain)
        #endif
    }
    /// Room around rows using `glassRow()` inside a scroll view, for the focused row's lift.
    @ViewBuilder func glassRowInsets() -> some View {
        #if os(tvOS)
        padding(.horizontal, 40).padding(.vertical, 24)
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder func tvDefaultControls() -> some View {
        #if os(tvOS)
        buttonStyle(TVControlStyle())
        #else
        self
        #endif
    }
}

#if !os(tvOS)
#if os(iOS)
/// 44-point glass circles: `ContentControlStyle` ignores the border shape, so its "circles" were
/// capsules too wide for a phone's player bar.
private struct ChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .glassSurface(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }
}
#endif

extension View {
    /// `glass` where the system draws Liquid Glass; otherwise, or when `glass` is nil, the flat `fill`. iPhones before
    /// iOS 26 keep the fill they had, with no material blur added.
    @ViewBuilder func glassOrFill(_ glass: GlassStyle?, _ fill: some ShapeStyle, in shape: some Shape) -> some View {
        if #available(macOS 26, iOS 26, *), LiquidGlassSupport.current, let glass {
            glassEffect(glass.glass, in: shape)
        } else {
            background(fill, in: shape)
        }
    }
}

private struct ContentControlStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @Environment(\.glassControls) private var glass
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Brand.onAccent : Color.primary)
            .padding(.horizontal, size == .large ? 20 : 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            // Secondary fill is relative to the page so it stays visible on light and dark canvases.
            .glassOrFill(glass ? (prominent ? GlassStyle.regular.tint(Brand.accent).interactive() : .regular.interactive()) : nil,
                         prominent ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }
}
#endif

extension Color {
    /// A colour that follows the current light/dark appearance.
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #endif
    }
}

#if os(iOS)
/// 直接把 App 的标签栏从 UIKit 层收掉。
///
/// 为什么不能只靠 `.toolbarVisibility(.hidden, for: .tabBar)`：
/// iOS 26 的浮动标签栏会在**旋转 / 进全屏 / 系统栏显隐**这些时机被系统重新摆回来，
/// 而 SwiftUI 的 toolbar 偏好不一定跟着重算 —— 实测同一个页面，刚进去是收掉的，
/// 播起来或者转一次屏，那条液态玻璃胶囊又压回画面上（盖住选集卡与右栏文字）。
///
/// 所以再补一道 UIKit 层的硬开关：找到包住观看页的 `UITabBarController`，
/// 直接改 `tabBar.isHidden`，并在每次布局时复核一遍（系统摆回来就再收掉）。
///
/// 只做「隐藏/恢复」这一件事，不碰选中项、不碰导航，页面退出时由 SwiftUI
/// 把 `hidden` 置回 false 自动恢复。
struct TabBarHider: UIViewRepresentable {
    let hidesBar: Bool

    func makeUIView(context: Context) -> TabBarHiderView {
        let view = TabBarHiderView()
        view.isUserInteractionEnabled = false
        view.hidesBar = hidesBar
        return view
    }

    func updateUIView(_ view: TabBarHiderView, context: Context) {
        view.hidesBar = hidesBar
    }
}

final class TabBarHiderView: UIView {
    /// 记住我们动过的那根 tabBar：视图被移出 window 时响应链已断，
    /// 沿 responder 找不回 controller，只能靠这个弱引用恢复。
    private weak var touchedTabBar: UITabBar?

    var hidesBar = false {
        didSet { apply() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // 页面退出：不管当时是不是全屏，都把菜单栏还回去。
            // 少了这一步，在全屏态直接返回会让标签栏永久消失 ——
            // 用户要的是「只有全屏才隐藏」，不是「看完就再也不显示」。
            touchedTabBar?.isHidden = false
            touchedTabBar = nil
        } else {
            apply()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    private func apply() {
        guard let tab = enclosingTabBarController() else { return }
        touchedTabBar = tab.tabBar
        guard tab.tabBar.isHidden != hidesBar else { return }
        tab.tabBar.isHidden = hidesBar
    }

    /// 沿响应链往上找 `UITabBarController`：视图 → 宿主控制器 → 导航控制器 → 标签控制器。
    private func enclosingTabBarController() -> UITabBarController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let tab = current as? UITabBarController { return tab }
            responder = current.next
        }
        return nil
    }
}

extension View {
    /// 收掉 App 的标签栏（见 `TabBarHider`）。挂在页面背景里，不占布局。
    func hidesAppTabBar(_ hidden: Bool) -> some View {
        background { TabBarHider(hidesBar: hidden) }
    }
}
#endif
