import SwiftUI

enum ChatTextSize {
    static let storageKey = "chat.fontSize"
    static let defaultPoints = 16.0

    static func stepped(_ points: Double, by delta: Double) -> Double {
        min(24, max(12, points + delta))
    }
}

private struct ChatTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var chatTextScale: CGFloat {
        get { self[ChatTextScaleKey.self] }
        set { self[ChatTextScaleKey.self] = newValue }
    }
}
