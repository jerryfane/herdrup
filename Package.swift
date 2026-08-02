// swift-tools-version:5.9
import PackageDescription

// HerdrKit is the transport + protocol layer for the iOS herdr client.
//
// It deliberately contains NO UIKit/SwiftUI so it builds and tests on Linux,
// where it can be exercised against a real herdr server. The iOS target
// consumes it unchanged.
let package = Package(
    name: "HerdrKit",
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"])
    ],
    targets: [
        // pkgConfig, not a hardcoded header path: libssh2 lives at
        // /usr/include on Debian, /opt/homebrew/include on Apple Silicon and
        // /usr/local/include on Intel macs. providers only advise on how to
        // install it; pkgConfig is what actually supplies the flags.
        .systemLibrary(
            name: "CSSH", path: "Sources/CSSH",
            pkgConfig: "libssh2",
            providers: [.brew(["libssh2"]), .apt(["libssh2-1-dev"])]),
        .target(name: "HerdrKit", dependencies: ["CSSH"]),
        // CSSH so tests can build a real Session to drive LiveChannel's
        // ownership handoff directly, rather than only through a live server.
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit", "CSSH"]),
    ]
)
