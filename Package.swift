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
        .systemLibrary(name: "CSSH", path: "Sources/CSSH"),
        .target(name: "HerdrKit", dependencies: ["CSSH"]),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"]),
    ]
)
