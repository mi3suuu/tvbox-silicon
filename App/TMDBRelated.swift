// [mi3s] 二开：TMDB「相关推荐」与「你也许喜欢」的卡片组件。
//
// 这三个类型原本长在 App/TMDBViews.swift（上游文件）里，按「每条二开能力独立成文件」的
// 原则搬到此处。搬的边界是干净的：
//   - RelatedCard       只依赖 GlassKit 的 PosterImage（全局可见）
//   - TMDBRelatedList   只依赖 RelatedCard + tmdbCardButton
//   - tmdbCardButton    是 extension View，与 TMDBViews 无耦合，故一并搬来
// 上游 TMDBViews.swift 若新增卡片形态，请加在这里，不要长回去（D-07）。

import SwiftUI
import TVCore

struct RelatedCard: View {
    let title: String
    let subtitle: String
    let poster: URL?
    var headers: [String: String] = [:]
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: poster, headers: headers)
                .frame(width: 120, height: 120 * 9.0 / 16.0)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct TMDBRelatedList: View {
    let titles: [TMDBMatch.Candidate]
    let search: (String) -> Void
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(titles, id: \.key) { title in
                Button { search(title.name) } label: {
                    RelatedCard(title: title.name,
                                subtitle: [title.year.map(String.init), L10n.text(title.mediaType == .tv ? "TV Series" : "Movie")].compactMap { $0 }.joined(separator: " · "),
                                poster: title.poster)
                }
                .tmdbCardButton()
            }
        }
    }
}

extension View {
    @ViewBuilder func tmdbCardButton() -> some View {
        #if os(tvOS)
        // The cards' focus plate: borderless only grew the focused tile a little, too little to see which one it was.
        cardButton()
        #else
        buttonStyle(.plain)
        #endif
    }
}
