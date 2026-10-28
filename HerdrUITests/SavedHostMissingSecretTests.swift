import XCTest

/// A saved host whose key is not in this phone's Keychain: what a phone set up from
/// another phone has, because the host list moves with the backup and the keys
/// (ThisDeviceOnly) do not. Tapping it must ask for the key and connect, not open the
/// plain editor, which claims a key is saved and only offers Save.
final class SavedHostMissingSecretTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingAHostWithoutItsKeyAsksForTheKeyAndOffersConnect() throws {
        // A fresh id each run, so no key a previous run stored can match it.
        let host: [String: Any] = [
            "id": UUID().uuidString, "host": "duo-mac.example.ts.net", "username": "jerry",
            "nickname": "Duo Mac", "authKind": "key",
        ]
        let json = try JSONSerialization.data(withJSONObject: [host])
        let app = XCUIApplication()
        // The argument domain wins over the app-group defaults the store reads, and
        // writes nothing to them.
        app.launchArguments += ["-dev.herdr.savedHosts.v1",
                                "<" + json.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Duo Mac")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded host is listed")
        row.tap()

        XCTAssertTrue(app.navigationBars["Reconnect"].waitForExistence(timeout: 10),
                      "a host without its key opens the reconnect editor, not Edit host")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                           "This phone doesn't have the key"))
            .firstMatch.exists, "the editor says why it opened")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add private key"))
            .firstMatch.exists, "the key row asks for a key instead of claiming one is saved")
    }
}
