import SwiftUI

/// A lightweight four-state machine for "load a resource, show a spinner while it loads, and a retry
/// button when it fails". It collapses the usual `@State var loading/busy/failed` booleans (plus the
/// value they guard) into one value, so the three states can't drift out of sync.
enum LoadState<Value> {
    /// Nothing has been requested yet.
    case idle
    /// A request is in flight.
    case loading
    /// A request finished with this value.
    case loaded(Value)
    /// A request failed with this error.
    case failed(Error)

    /// The loaded value, or `nil` while idle, loading, or failed.
    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
    /// The failure, or `nil` unless failed.
    var error: Error? {
        if case .failed(let error) = self { return error }
        return nil
    }
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A content wrapper for `LoadState`: renders the loaded value, a `ProgressView` while loading, and a
/// retry button on failure. Views that need richer chrome (poster walls, styled error cards) switch on
/// `LoadState` directly; this covers the plain case.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retryTitle: String
    let retryIdentifier: String
    let retry: () -> Void
    private let content: (Value) -> Content

    init(state: LoadState<Value>, retryTitle: String, retryIdentifier: String, retry: @escaping () -> Void,
         @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.retryTitle = retryTitle
        self.retryIdentifier = retryIdentifier
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .loaded(let value):
            content(value)
        case .loading:
            ProgressView()
        case .failed:
            Button(retryTitle, action: retry).accessibilityIdentifier(retryIdentifier)
        case .idle:
            EmptyView()
        }
    }
}
