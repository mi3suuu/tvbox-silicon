import SwiftUI

// Small labelled primitives: an icon in a tinted rounded square, a one-line metadata pill, and a
// multi-line notice.

struct IconTile: View {
    let symbol: String
    var tint: Color = Brand.cyan
    var size: CGFloat = 44
    var body: some View {
        #if os(tvOS)
        let size = max(size, 56)
        #endif
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassSurface(.regular.tint(tint.opacity(0.15)), in: Capsule())
    }
}

struct StatusNotice: View {
    let text: String
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = Brand.amber
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(.regular.tint(tint.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
