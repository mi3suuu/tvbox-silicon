import SwiftUI
import TVCore

// Skeleton loading screens: a shimmer sweep over grey blocks sized to the content they stand in for.

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .white.opacity(0.20), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: -proxy.size.width * 0.6 + phase * proxy.size.width * 1.6)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Radius.card
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.09))
            .modifier(Shimmer())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct PosterSkeletonGrid: View {
    var count = 12
    var body: some View {
        LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).overlay { SkeletonBlock(cornerRadius: 20) }
                    SkeletonBlock(cornerRadius: 6).frame(height: 14)
                    SkeletonBlock(cornerRadius: 6).frame(width: 70, height: 12)
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Loading…"))
    }
}

struct ChannelSkeletonGrid: View {
    var count = 12
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 14) {
                    SkeletonBlock(cornerRadius: 14).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(cornerRadius: 6).frame(maxWidth: 170).frame(height: 14)
                        SkeletonBlock(cornerRadius: 6).frame(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).contentPanel()
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Loading channels…"))
    }
}

struct ChipSkeletonRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([64, 88, 72, 100, 76, 84], id: \.self) { width in
                SkeletonBlock(cornerRadius: 18).frame(width: CGFloat(width), height: 36)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).accessibilityHidden(true)
    }
}

struct DetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(cornerRadius: 6).frame(height: 14)
                SkeletonBlock(cornerRadius: 6).frame(height: 14)
                SkeletonBlock(cornerRadius: 6).frame(maxWidth: 260).frame(height: 14)
            }
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBlock(cornerRadius: 6).frame(width: 110, height: 18)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.episodeMin), spacing: 10)], spacing: 10) {
                    ForEach(0..<10, id: \.self) { _ in SkeletonBlock(cornerRadius: 20).frame(height: 40) }
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Loading details…"))
    }
}
