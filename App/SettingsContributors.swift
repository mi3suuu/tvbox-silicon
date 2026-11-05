import SwiftUI
import TVCore

// MARK: Contributors

/// The last 30 days' contributors that Settings lists, kept between launches and asked for at most every six hours.
@MainActor @Observable final class ContributorList {
    static let shared = ContributorList()
    /// At most this many rows; the list is ranked, so the rest have the fewest commits.
    static let shown = 20
    private(set) var people: [Contributor]
    private var checking = false
    private let defaults: UserDefaults
    private static let interval: TimeInterval = 6 * 60 * 60
    private enum Keys { static let people = "contributors.people", checked = "contributors.checked" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        people = defaults.data(forKey: Keys.people).flatMap { try? JSONDecoder().decode([Contributor].self, from: $0) } ?? []
    }

    /// A failed check keeps the last list and tries again the next time Settings opens.
    func check() async {
        guard !checking else { return }
        if let checked = defaults.object(forKey: Keys.checked) as? Date, Date().timeIntervalSince(checked) < Self.interval { return }
        checking = true
        defer { checking = false }
        // Its own task: Settings restarts its task when it unlocks, and that mustn't cancel the request halfway.
        let fetch = Task { try await Contributors.fetch() }
        do {
            people = try await fetch.value.contributors
            defaults.set(try? JSONEncoder().encode(people), forKey: Keys.people)
            defaults.set(Date(), forKey: Keys.checked)
        } catch {
            Diagnostics.shared.record(.warning, "contributors", "Contributor list check failed: \(error.localizedDescription)")
        }
    }

    static func commits(_ count: Int) -> String { count == 1 ? L10n.text("1 commit") : L10n.text("%lld commits", count) }
}

/// A contributor's GitHub picture in a circle, or their initial while it loads or when it can't.
private struct ContributorAvatar: View {
    let person: Contributor
    let size: CGFloat
    var body: some View {
        AsyncImage(url: person.avatar(points: Int(size.rounded(.up)))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(person.login.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
    }
}

#if os(tvOS)
/// Everyone with commits in the last 30 days, most first. Apple TV can't open their GitHub pages, so the rows only show them.
struct ContributorsSection: View {
    private var list: ContributorList { .shared }
    var body: some View {
        if !list.people.isEmpty {
            TVSettingsSection(title: L10n.text("Contributors"), footer: L10n.text("Ranked by commits in the last 30 days.")) {
                ForEach(list.people.prefix(ContributorList.shown)) { person in
                    HStack(spacing: 18) {
                        ContributorAvatar(person: person, size: 52)
                        Text(person.login).font(.system(size: 29, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 32)
                        Text(ContributorList.commits(person.commits)).font(.system(size: 27)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // The insets of a `glassRow()`, so these line up with the rows that can be selected.
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
#else
/// Everyone with commits in the last 30 days, most first; a row opens the person's GitHub page.
struct ContributorsSection: View {
    @Environment(\.openURL) private var openURL
    private var list: ContributorList { .shared }
    var body: some View {
        if !list.people.isEmpty {
            Section {
                ForEach(list.people.prefix(ContributorList.shown)) { person in
                    Button { if let profile = person.profile { openURL(profile) } } label: {
                        HStack(spacing: 8) {
                            Label { Text(person.login).lineLimit(1) } icon: { ContributorAvatar(person: person, size: FormMetrics.icon) }
                                .foregroundStyle(.primary).layoutPriority(1)
                            Spacer(minLength: 0)
                            Text(ContributorList.commits(person.commits)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tint(.primary)
                    .formRowButton()
                }
            } header: {
                Text(L10n.text("Contributors"))
            } footer: {
                Text(L10n.text("Ranked by commits in the last 30 days."))
            }
        }
    }
}
#endif
