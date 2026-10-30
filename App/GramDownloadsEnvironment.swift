import HerdrKit
import SwiftUI

/// The connection's Gram downloads (#574), held by `RootView` above the tab view and the
/// split view, so leaving the Gram page never ends a download the reader started there.
/// RootView cancels them all when the connection goes (disconnect, sign-out, a reconnect or
/// another session). The default serves only a view built outside RootView.
private struct GramDownloadsKey: EnvironmentKey {
    static let defaultValue = GramDownloadStore()
}

extension EnvironmentValues {
    var gramDownloads: GramDownloadStore {
        get { self[GramDownloadsKey.self] }
        set { self[GramDownloadsKey.self] = newValue }
    }
}
