import XCTest

extension XCUIApplication {
    /// A new app launched into the `HERDR_SCREENSHOT_MOCK` fixture `mock`, with
    /// `environment` added to its launch environment (a key there wins over the mock).
    static func launched(mock: String, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mock
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        return app
    }

    var terminalSurface: XCUIElement {
        // String subscripts also compare labels/values. A first-match walk can
        // time out fetching those unrelated attributes after app reactivation.
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "terminal-surface"))
            .firstMatch
    }
}
