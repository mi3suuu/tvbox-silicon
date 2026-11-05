import SwiftUI
import TVCore

// The single wrapper every data page should use to express its three states — loading, content,
// and failure — instead of hand-writing `if busy && items.isEmpty { … } else if error { … }`.

enum Phase<Value> {
    case loading
    case success(Value)
    case failure(Error)
}

struct AsyncView<Value, Content: View>: View {
    let phase: Phase<Value>
    @ViewBuilder let content: (Value) -> Content

    var loading: (() -> AnyView)? = nil
    var empty: ((Value) -> Bool)? = nil
    var emptyView: ((Value) -> AnyView)? = nil
    var failure: ((Error, @escaping () -> Void) -> AnyView)? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        switch phase {
        case .loading:
            (loading?() ?? AnyView(PosterSkeletonGrid()))
                .accessibilityLabel(L10n.text("Loading…"))

        case .success(let value):
            if empty?(value) == true {
                (emptyView?(value) ?? AnyView(
                    EmptyResults(symbol: "tray", title: L10n.text("Nothing here"),
                                 message: nil, action: nil, perform: nil)
                ))
            } else {
                content(value)
            }

        case .failure(let error):
            if let failure {
                failure(error, retry ?? {})
            } else {
                ErrorStateCard(
                    title: L10n.text("Something went wrong"),
                    message: error.localizedDescription,
                    details: String(describing: error),
                    retry: retry
                )
            }
        }
    }
}

extension Phase {
    static func loadingOrSuccess(_ value: Value?) -> Phase<Value> {
        value.map(Phase.success) ?? .loading
    }
}
