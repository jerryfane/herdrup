// swift-tools-version:5.9
import PackageDescription

// HerdrKit is the transport + protocol layer for the iOS herdr client.
//
// It deliberately contains NO UIKit/SwiftUI so it builds and tests on Linux,
// where it can be exercised against a real herdr server. The iOS target
// consumes it unchanged.
let package = Package(
    name: "HerdrKit",
    // REQUIRED, and its absence was invisible from Linux. With no `platforms`,
    // SwiftPM assumes macOS 10.10 and every modern-concurrency symbol this
    // package is built on becomes unavailable — Task, AsyncThrowingStream,
    // CancellationError, withTaskCancellationHandler, and the rest. Linux does
    // no availability checking at all, so the package compiled there while
    // being unbuildable on any Apple platform.
    //
    // The floors are chosen, not defaults: macOS 13 for the toolchain that runs
    // the tests, iOS 17 because that is the floor the app target will inherit
    // and it decides which SwiftUI is available to the UI work. `platforms`
    // constrains Apple platforms only, so the "builds on Linux too" property
    // above is untouched.
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"])
    ],
    dependencies: [
        // The pure-Swift SSH stack (swift-nio-ssh + Citadel's key parsing and
        // BoringSSL crypto). Cross-platform — this is what lets HerdrKit link
        // into iOS, which libssh2 cannot. Pinned exactly: Citadel pulls a
        // swift-nio-ssh FORK (Wellz26/swift-nio-ssh), and a fork carrying the
        // transport's crypto is worth a fixed, reviewed revision rather than a
        // range. Proven to build+link for iOS-simulator (spike/citadel-ios).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        // libssh2 is gone: CitadelTransport (pure-Swift nio-ssh + Citadel)
        // replaced SSHTransport, and with it CSSH, DescriptorAudit, LiveChannel
        // and the fd-ownership thread pool. This is what lets HerdrKit build for
        // iOS at all — the libssh2 XCFramework could not link there.
        .target(
            name: "HerdrKit",
            dependencies: [.product(name: "Citadel", package: "Citadel")]),
        .testTarget(
            name: "HerdrKitTests",
            dependencies: ["HerdrKit", .product(name: "Citadel", package: "Citadel")]),
    ]
)
